## Wasmtime-backed shell play instance invocation.
##
## This is the production ABI boundary for host-to-guest buffers and guest
## host calls. Server/lane integration is later; this module owns the checked
## invocation mechanics and reports deterministic results for tests.

import std/options

import abi, body_map, emit_validator, module_cache, runtime, types, wasmtime_c

type
  InvocationKind* = enum
    ivManifest
    ivInit
    ivStep
    ivRetune

  ShellEmission* = object
    bytes*: string
    code*: int32
    normalized*: bool
    intent*: Intent
    policy*: CombatPolicy

  ShellInvocationResult* = object
    kind*: InvocationKind
    returned*: int32
    faulted*: bool
    refused*: bool
    reason*: string
    counters*: AbiCounters
    emitCodes*: seq[int32]
    lastAccepted*: Option[ShellEmission]
    manifestBytes*: string
    fuelInstalledBeforeAlloc*: bool

  InstanceHostState = object
    invocation: AbiInvocation
    inAllocator: bool
    map: BodyMap
    selfPos: BodyPoint
    emitClass: EmitClass
    pendingAccepted: Option[ShellEmission]
    manifestBytes: string
    emitCodes: seq[int32]

  ShellInstance* = ref object
    module: RuntimeModule
    store: ptr WasmtimeStore
    context: ptr WasmtimeContext
    raw: WasmtimeInstance
    memory: WasmtimeMemory
    playAlloc: WasmtimeFunc
    playManifest: WasmtimeFunc
    playInit: WasmtimeFunc
    playStep: WasmtimeFunc
    playRetune: WasmtimeFunc
    hasRetune: bool
    host: InstanceHostState
    lastAccepted: Option[ShellEmission]

proc byteVecString(bytes: WasmByteVec): string =
  result = newString(bytes.size.int)
  if bytes.size > 0:
    copyMem(addr result[0], bytes.data, bytes.size)

proc consumeError(error: ptr WasmtimeError): string =
  if error == nil:
    return ""
  var message: WasmByteVec
  wasmtimeErrorMessage(error, addr message)
  result = byteVecString(message)
  wasmByteVecDelete(addr message)
  wasmtimeErrorDelete(error)

proc consumeTrap(trap: ptr WasmTrap): string =
  if trap == nil:
    return ""
  var message: WasmByteVec
  wasmTrapMessage(trap, addr message)
  result = byteVecString(message)
  wasmByteVecDelete(addr message)
  wasmTrapDelete(trap)

proc requireNoError(error: ptr WasmtimeError; operation: string) =
  if error != nil:
    raise newException(ShellRuntimeError, operation & ": " & consumeError(error))

proc setI32(result: ptr WasmtimeVal, value: int32) {.inline.} =
  shellWasmtimeValI32Set(result, value)

proc memorySize(instance: ShellInstance): int =
  wasmtimeMemoryDataSize(instance.context, addr instance.memory).int

proc memoryBase(instance: ShellInstance): ptr uint8 =
  wasmtimeMemoryData(instance.context, addr instance.memory)

proc checkedGuestBytes(caller: ptr WasmtimeCaller, ptrValue, lenValue: int32,
                       limit: int): string =
  if ptrValue < 0 or lenValue < 0 or lenValue > limit:
    raise newException(ShellRuntimeError, "invalid guest byte range")
  var memoryItem: WasmtimeExtern
  if not wasmtimeCallerExportGet(caller, "memory", 6, addr memoryItem):
    raise newException(ShellRuntimeError, "host call has no memory export")
  defer: wasmtimeExternDelete(addr memoryItem)
  if shellWasmtimeExternKind(addr memoryItem) != WasmtimeExternMemory:
    raise newException(ShellRuntimeError, "host call memory export has wrong kind")
  let context = wasmtimeCallerContext(caller)
  let memory = shellWasmtimeExternMemory(addr memoryItem)
  let available = wasmtimeMemoryDataSize(context, memory).uint64
  let stop = uint64(ptrValue) + uint64(lenValue)
  if stop < uint64(ptrValue) or stop > available:
    raise newException(ShellRuntimeError, "guest byte range exceeds memory")
  result = newString(lenValue)
  if lenValue > 0:
    copyMem(addr result[0], cast[pointer](
      cast[uint](wasmtimeMemoryData(context, memory)) + uint(ptrValue)),
      lenValue)

proc readI32Le(bytes: string, offset: int): int32 =
  int32(uint32(uint8(bytes[offset])) or
    (uint32(uint8(bytes[offset + 1])) shl 8) or
    (uint32(uint8(bytes[offset + 2])) shl 16) or
    (uint32(uint8(bytes[offset + 3])) shl 24))

proc packPoint(point: BodyPoint): int64 =
  (int64(point.x) shl 32) or int64(uint32(point.y))

proc emitCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let host = cast[ptr InstanceHostState](env)
  if host == nil or nargs != 2 or nresults != 1:
    return nil
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  if host.inAllocator or not host.invocation.noteEmit():
    host.invocation.fault("emit is illegal in this invocation phase")
    host.emitCodes.add(AbiSchemaViolation)
    setI32(results, AbiSchemaViolation)
    return nil
  try:
    let bytes = checkedGuestBytes(caller,
      shellWasmtimeValI32Get(addr values[0]),
      shellWasmtimeValI32Get(addr values[1]), MaxEmitBytes)
    if host.invocation.phase == apManifest:
      if host.invocation.counters.emits != 1:
        host.invocation.fault("play_manifest emitted more than once")
        host.emitCodes.add(AbiSchemaViolation)
        setI32(results, AbiSchemaViolation)
      else:
        host.manifestBytes = bytes
        host.emitCodes.add(AbiOk)
        setI32(results, AbiOk)
      return nil
    let outcome = validateEmit(bytes, EmitValidationContext(
      map: host.map, selfPos: host.selfPos, emitClass: host.emitClass))
    if outcome.accepted:
      host.pendingAccepted = some(ShellEmission(
        bytes: outcome.canonicalBytes,
        code: outcome.code,
        normalized: outcome.normalized,
        intent: outcome.intent,
        policy: outcome.policy))
    host.emitCodes.add(outcome.code)
    setI32(results, outcome.code)
  except CatchableError as error:
    host.invocation.fault(error.msg)
    host.emitCodes.add(AbiSchemaViolation)
    setI32(results, AbiSchemaViolation)

proc logCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let host = cast[ptr InstanceHostState](env)
  if host == nil or nargs != 3 or nresults != 0:
    return nil
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  if host.inAllocator or not hostCallAllowed(host.invocation.phase, false, ahLog):
    host.invocation.fault("log is illegal in this invocation phase")
    return nil
  if host.invocation.noteLog():
    try:
      discard checkedGuestBytes(caller,
        shellWasmtimeValI32Get(addr values[1]),
        shellWasmtimeValI32Get(addr values[2]), MaxLogBytesPerCall)
    except CatchableError as error:
      host.invocation.fault(error.msg)

proc nearestReachableCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let host = cast[ptr InstanceHostState](env)
  if host == nil or nargs != 2 or nresults != 1:
    return nil
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  if host.inAllocator:
    host.invocation.fault("nearest_reachable is illegal during play_alloc")
    shellWasmtimeValI64Set(results, -1)
    return nil
  let quota = host.invocation.noteSpatial()
  if quota != AbiOk:
    shellWasmtimeValI64Set(results, int64(quota))
    return nil
  let x = shellWasmtimeValI32Get(addr values[0])
  let y = shellWasmtimeValI32Get(addr values[1])
  if x < 0 or y < 0 or host.map == nil or x.int >= host.map.width or
      y.int >= host.map.height:
    shellWasmtimeValI64Set(results, -3)
    return nil
  let goal = host.map.validateGoal((x.int, y.int), host.selfPos)
  let answer: int64 = if goal.isSome: packPoint(goal.get.goalPoint) else: -1
  shellWasmtimeValI64Set(results, answer)

proc nearestCoverCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let host = cast[ptr InstanceHostState](env)
  if host == nil or nargs != 6 or nresults != 1:
    return nil
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  if host.inAllocator:
    host.invocation.fault("nearest_cover is illegal during play_alloc")
    shellWasmtimeValI64Set(results, -1)
    return nil
  let quota = host.invocation.noteSpatial()
  if quota != AbiOk:
    shellWasmtimeValI64Set(results, int64(quota))
    return nil
  let
    x = shellWasmtimeValI32Get(addr values[0])
    y = shellWasmtimeValI32Get(addr values[1])
    radius = shellWasmtimeValI32Get(addr values[2])
    bearing = shellWasmtimeValI32Get(addr values[3])
    threatsPtr = shellWasmtimeValI32Get(addr values[4])
    threatsLen = shellWasmtimeValI32Get(addr values[5])
  if host.map == nil or x < 0 or y < 0 or x.int >= host.map.width or
      y.int >= host.map.height or radius <= 0 or
      bearing < -1 or bearing > 255 or threatsLen < 0 or
      threatsLen > MaxCoverThreats:
    shellWasmtimeValI64Set(results, -3)
    return nil
  try:
    if threatsLen > 0:
      let bytes = checkedGuestBytes(caller, threatsPtr, threatsLen * 8,
        MaxCoverThreats * 8)
      for index in 0 ..< threatsLen.int:
        let threatX = readI32Le(bytes, index * 8)
        let threatY = readI32Le(bytes, index * 8 + 4)
        if threatX < 0 or threatY < 0 or threatX.int >= host.map.width or
            threatY.int >= host.map.height:
          shellWasmtimeValI64Set(results, -3)
          return nil
  except CatchableError as error:
    host.invocation.fault(error.msg)
    shellWasmtimeValI64Set(results, -1)
    return nil
  shellWasmtimeValI64Set(results, -1)

proc defineHostFunc(linker: ptr WasmtimeLinker; name: string;
    functionType: ptr WasmFuncType; callback: WasmtimeCallback;
    host: ptr InstanceHostState) =
  requireNoError(shellWasmtimeLinkerDefineFunc(linker, "play", 4,
    name.cstring, name.len.csize_t, functionType, callback, host),
    "define play." & name)

proc exportedFunc(instance: ShellInstance, name: string): Option[WasmtimeFunc] =
  var item: WasmtimeExtern
  if not wasmtimeInstanceExportGet(instance.context, addr instance.raw,
      name.cstring, name.len.csize_t, addr item):
    return none(WasmtimeFunc)
  defer: wasmtimeExternDelete(addr item)
  if shellWasmtimeExternKind(addr item) != WasmtimeExternFunc:
    return none(WasmtimeFunc)
  some(shellWasmtimeExternFunc(addr item)[])

proc requireExportedFunc(instance: ShellInstance, name: string): WasmtimeFunc =
  let exported = instance.exportedFunc(name)
  if exported.isNone:
    raise newException(ShellRuntimeError, "missing function export " & name)
  exported.get

proc newShellInstance*(module: RuntimeModule, map: BodyMap,
                       selfPos: BodyPoint,
                       emitClass = ecController): ShellInstance =
  if module == nil or module.rawModule == nil or not module.ownerEngine.isOpen:
    raise newException(ShellRuntimeError, "module or Engine is closed")
  new(result)
  result.module = module
  result.host.map = map
  result.host.selfPos = selfPos
  result.host.emitClass = emitClass
  result.store = wasmtimeStoreNew(module.ownerEngine.rawEngine, nil, nil)
  if result.store == nil:
    raise newException(ShellRuntimeError, "instance Store creation failed")
  result.context = wasmtimeStoreContext(result.store)
  wasmtimeStoreLimiter(result.store, MaxMemoryBytes.int64, -1, 1, 1, 1)
  requireNoError(wasmtimeContextSetFuel(result.context, InitialStoreFuel),
    "initial instance Store fuel")
  wasmtimeContextSetEpochDeadline(result.context,
    runtime.EpochDeadlineTicks.uint64)

  let linker = wasmtimeLinkerNew(module.ownerEngine.rawEngine)
  if linker == nil:
    raise newException(ShellRuntimeError, "instance linker creation failed")
  defer: wasmtimeLinkerDelete(linker)
  let emitType = shellWasmtimeEmitFuncType()
  let logType = shellWasmtimeLogFuncType()
  let reachableType = shellWasmtimeReachableFuncType()
  let coverType = shellWasmtimeCoverFuncType()
  if emitType == nil or logType == nil or reachableType == nil or coverType == nil:
    raise newException(ShellRuntimeError, "host type creation failed")
  defer:
    wasmFuncTypeDelete(coverType)
    wasmFuncTypeDelete(reachableType)
    wasmFuncTypeDelete(logType)
    wasmFuncTypeDelete(emitType)
  linker.defineHostFunc("emit", emitType, emitCallback, addr result.host)
  linker.defineHostFunc("log", logType, logCallback, addr result.host)
  linker.defineHostFunc("nearest_reachable", reachableType,
    nearestReachableCallback, addr result.host)
  linker.defineHostFunc("nearest_cover", coverType,
    nearestCoverCallback, addr result.host)

  var trap: ptr WasmTrap
  let error = wasmtimeLinkerInstantiate(linker, result.context,
    module.rawModule, addr result.raw, addr trap)
  if error != nil:
    if trap != nil: discard consumeTrap(trap)
    raise newException(ShellRuntimeError, "instance instantiate: " &
      consumeError(error))
  if trap != nil:
    raise newException(ShellRuntimeTrap, "instance instantiate trapped: " &
      consumeTrap(trap))

  var memoryItem: WasmtimeExtern
  if not wasmtimeInstanceExportGet(result.context, addr result.raw, "memory", 6,
      addr memoryItem) or
      shellWasmtimeExternKind(addr memoryItem) != WasmtimeExternMemory:
    raise newException(ShellRuntimeError, "missing memory export")
  result.memory = shellWasmtimeExternMemory(addr memoryItem)[]
  wasmtimeExternDelete(addr memoryItem)
  result.playAlloc = result.requireExportedFunc("play_alloc")
  result.playManifest = result.requireExportedFunc("play_manifest")
  result.playInit = result.requireExportedFunc("play_init")
  result.playStep = result.requireExportedFunc("play_step")
  let retune = result.exportedFunc("play_retune")
  result.hasRetune = retune.isSome
  if retune.isSome:
    result.playRetune = retune.get

proc close*(instance: ShellInstance) =
  if instance != nil and instance.store != nil:
    wasmtimeStoreDelete(instance.store)
    instance.store = nil
    instance.context = nil

proc isOpen*(instance: ShellInstance): bool =
  instance != nil and instance.store != nil

proc callFunc(instance: ShellInstance, callee: var WasmtimeFunc,
              args: var openArray[WasmtimeVal],
              results: var openArray[WasmtimeVal]): int32 =
  var trap: ptr WasmTrap
  let argsPtr =
    if args.len == 0: nil
    else: addr args[0]
  let resultsPtr =
    if results.len == 0: nil
    else: addr results[0]
  let error = wasmtimeFuncCall(instance.context, addr callee,
    argsPtr, args.len.csize_t, resultsPtr, results.len.csize_t, addr trap)
  if error != nil:
    if trap != nil: discard consumeTrap(trap)
    instance.host.invocation.fault(consumeError(error))
    return -1
  if trap != nil:
    instance.host.invocation.fault(consumeTrap(trap))
    return -1
  if results.len == 0:
    0
  else:
    shellWasmtimeValI32Get(addr results[0])

proc setMetering(instance: ShellInstance, fuel: uint64) =
  requireNoError(wasmtimeContextSetFuel(instance.context, fuel),
    "set invocation fuel")
  wasmtimeContextSetEpochDeadline(instance.context,
    runtime.EpochDeadlineTicks.uint64)
  instance.host.invocation.installFuelAndDeadline()

proc allocate(instance: ShellInstance, len: int): Option[AbiBuffer] =
  if len < 0 or len > high(int32):
    instance.host.invocation.fault("host buffer length overflows i32")
    return none(AbiBuffer)
  if not instance.host.invocation.noteAllocation():
    return none(AbiBuffer)
  var args: array[1, WasmtimeVal]
  var results: array[1, WasmtimeVal]
  shellWasmtimeValI32Set(addr args[0], int32(len))
  instance.host.inAllocator = true
  let ptrValue = instance.callFunc(instance.playAlloc, args, results)
  instance.host.inAllocator = false
  if instance.host.invocation.faulted:
    return none(AbiBuffer)
  instance.host.invocation.acceptAllocatedBuffer(instance.memorySize,
    ptrValue, int32(len))

proc writeGuest(instance: ShellInstance, buffer: AbiBuffer, bytes: string) =
  if bytes.len > 0:
    copyMem(cast[pointer](cast[uint](instance.memoryBase) + uint(buffer.offset)),
      unsafeAddr bytes[0], bytes.len)

proc prepareInvocation(instance: ShellInstance, phase: AbiPhase,
                       kind: InvocationKind, fuel: uint64) =
  instance.host.invocation = beginInvocation(phase)
  instance.host.pendingAccepted = none(ShellEmission)
  instance.host.manifestBytes.setLen(0)
  instance.host.emitCodes.setLen(0)
  instance.setMetering(fuel)

proc finishResult(instance: ShellInstance, kind: InvocationKind,
                  returned: int32, refused = false): ShellInvocationResult =
  result = ShellInvocationResult(
    kind: kind,
    returned: returned,
    faulted: instance.host.invocation.faulted,
    refused: refused,
    reason: instance.host.invocation.faultReason,
    counters: instance.host.invocation.counters,
    emitCodes: instance.host.emitCodes,
    lastAccepted: instance.lastAccepted,
    manifestBytes: instance.host.manifestBytes,
    fuelInstalledBeforeAlloc: instance.host.invocation.fuelInstalledBeforeAlloc)
  instance.host.invocation.finish()
  if result.faulted or (kind == ivRetune and refused):
    instance.close()

proc invokeManifest*(instance: ShellInstance): ShellInvocationResult =
  instance.prepareInvocation(apManifest, ivManifest, ManifestFuel.uint64)
  var noArgs: array[0, WasmtimeVal]
  var noResults: array[0, WasmtimeVal]
  let returned = instance.callFunc(instance.playManifest, noArgs, noResults)
  if not instance.host.invocation.faulted and
      instance.host.invocation.counters.emits != 1:
    instance.host.invocation.fault("play_manifest must emit exactly once")
  instance.finishResult(ivManifest, returned)

proc invokeInit*(instance: ShellInstance, paramsBytes,
                 contextBytes: string): ShellInvocationResult =
  instance.prepareInvocation(apInit, ivInit, InitFuel.uint64)
  let params = instance.allocate(paramsBytes.len)
  let context = instance.allocate(contextBytes.len)
  if params.isSome and context.isSome:
    instance.writeGuest(params.get, paramsBytes)
    instance.writeGuest(context.get, contextBytes)
    var args: array[4, WasmtimeVal]
    var results: array[1, WasmtimeVal]
    shellWasmtimeValI32Set(addr args[0], params.get.offset)
    shellWasmtimeValI32Set(addr args[1], params.get.length)
    shellWasmtimeValI32Set(addr args[2], context.get.offset)
    shellWasmtimeValI32Set(addr args[3], context.get.length)
    let returned = instance.callFunc(instance.playInit, args, results)
    if returned != 0 and not instance.host.invocation.faulted:
      instance.host.invocation.fault("play_init returned nonzero")
    return instance.finishResult(ivInit, returned)
  instance.finishResult(ivInit, -1)

proc invokeStep*(instance: ShellInstance, viewBytes: string,
                 tick: uint32): ShellInvocationResult =
  discard tick
  let previous = instance.lastAccepted
  instance.prepareInvocation(apStep, ivStep, StepFuel.uint64)
  let view = instance.allocate(viewBytes.len)
  if view.isSome:
    instance.writeGuest(view.get, viewBytes)
    var args: array[2, WasmtimeVal]
    var results: array[1, WasmtimeVal]
    shellWasmtimeValI32Set(addr args[0], view.get.offset)
    shellWasmtimeValI32Set(addr args[1], view.get.length)
    let returned = instance.callFunc(instance.playStep, args, results)
    if returned != 0 and not instance.host.invocation.faulted:
      instance.host.invocation.fault("play_step returned nonzero")
    if not instance.host.invocation.faulted and
        instance.host.pendingAccepted.isSome:
      instance.lastAccepted = instance.host.pendingAccepted
    elif instance.host.invocation.faulted:
      instance.lastAccepted = previous
    return instance.finishResult(ivStep, returned)
  instance.lastAccepted = previous
  instance.finishResult(ivStep, -1)

proc invokeRetune*(instance: ShellInstance, oldParams,
                   newParams: string): ShellInvocationResult =
  if not instance.hasRetune:
    result = ShellInvocationResult(kind: ivRetune, returned: 1, refused: true,
      reason: "play_retune export absent", lastAccepted: instance.lastAccepted)
    instance.close()
    return
  instance.prepareInvocation(apRetune, ivRetune, InitFuel.uint64)
  let oldBuffer = instance.allocate(oldParams.len)
  let newBuffer = instance.allocate(newParams.len)
  if oldBuffer.isSome and newBuffer.isSome:
    instance.writeGuest(oldBuffer.get, oldParams)
    instance.writeGuest(newBuffer.get, newParams)
    var args: array[4, WasmtimeVal]
    var results: array[1, WasmtimeVal]
    shellWasmtimeValI32Set(addr args[0], oldBuffer.get.offset)
    shellWasmtimeValI32Set(addr args[1], oldBuffer.get.length)
    shellWasmtimeValI32Set(addr args[2], newBuffer.get.offset)
    shellWasmtimeValI32Set(addr args[3], newBuffer.get.length)
    let returned = instance.callFunc(instance.playRetune, args, results)
    let refused = returned != 0 or instance.host.invocation.faulted
    return instance.finishResult(ivRetune, returned, refused)
  instance.finishResult(ivRetune, -1, refused = true)

proc terminalReason(entry: StatusEntry): string =
  case entry.kind
  of skPlayFaulted:
    entry.faultReason
  of skRetuneRefused:
    entry.faultReason
  else:
    ""

proc setTerminalReason(entry: var StatusEntry; reason: string) =
  case entry.kind
  of skPlayFaulted, skRetuneRefused:
    entry.faultReason = reason
  else:
    discard

proc fitTerminalStatus(entry: var StatusEntry) =
  while entry.terminalReason.len > 0 and
      encodeStatusEntry(entry).len > StatusEntryMaxBytes:
    var reason = entry.terminalReason
    reason.setLen(reason.len - 1)
    entry.setTerminalReason(reason)

proc terminalStatus*(invocationResult: ShellInvocationResult; ordinal,
                     originGeneration, epoch: uint64;
                     entryId: string): Option[StatusEntry] =
  ## Maps autonomous runtime terminal results to durable shell status entries.
  ## Non-terminal success and negative emit rejections are not statuses here:
  ## ladder call acceptance/rejection is owned by the later guard/call phases.
  if invocationResult.kind == ivRetune and invocationResult.refused:
    var entry = StatusEntry(kind: skRetuneRefused, ordinal: ordinal,
      originGeneration: originGeneration, faultEpoch: epoch,
      entryId: entryId, faultReason: invocationResult.reason)
    entry.fitTerminalStatus()
    return some(entry)
  if invocationResult.faulted:
    var entry = StatusEntry(kind: skPlayFaulted, ordinal: ordinal,
      originGeneration: originGeneration, faultEpoch: epoch,
      entryId: entryId, faultReason: invocationResult.reason)
    entry.fitTerminalStatus()
    return some(entry)
  none(StatusEntry)

proc terminalStatusBytes*(invocationResult: ShellInvocationResult; ordinal,
                          originGeneration, epoch: uint64;
                          entryId: string): string =
  let status = invocationResult.terminalStatus(ordinal, originGeneration,
    epoch, entryId)
  if status.isSome:
    encodeStatusEntry(status.get)
  else:
    ""

## Production Wasmtime Engine and Store ownership for the Season 2 shell.
##
## The server will own one `RuntimeEngine`; it starts one epoch ticker. Every
## `RuntimeInstance`, including a manifest probe, owns a distinct Store and
## returns its pooling slot as soon as `close` drops that Store.

import std/[atomics, os, strutils]

import types
import wasmtime_c

when not compileOption("threads"):
  {.error: "shell runtime requires --threads:on for the epoch ticker".}

when not defined(noSignalHandler):
  {.error: "shell runtime requires -d:noSignalHandler".}

const
  WasmtimeVersion* = "48.0.1"
  MaxWasmStackBytes* = 262_144
  MaxMemoryBytes* = 1_048_576
  MemoryGuardBytes* = 65_536
  RuntimePoolSlots* = 514
  EpochPeriodMs* = 5
  EpochDeadlineTicks* = 4
  InitialStoreFuel* = 1_000_000'u64

  WasmtimeReleaseDigests* = [
    ("x86_64-linux", "67683d04b416a8b91f0e607e7b4c22bd32f18f947c10b5372eb8c277ae3b883a"),
    ("aarch64-linux", "1c521a9be661644541158b360df8f7c7ec5bc2d88d23ff4dbbc12f639247c266"),
    ("x86_64-macos", "a5d92170718d41e4bd08173049019f0cedb318d0156365a52667d4a35ea3ca69"),
    ("aarch64-macos", "9e3c636ed487a41026ff76388c5fa6f3a48ea0968408d033ed4b5e8082c20d69")]

type
  ShellRuntimeError* = object of CatchableError

  ShellRuntimeTrap* = object of ShellRuntimeError
    code*: uint8

  EpochTickerState = object
    engine: ptr WasmEngine
    stopped: Atomic[bool]
    ticks: Atomic[uint64]

  RuntimeEngine* = ref object
    raw: ptr WasmEngine
    tickerState: ptr EpochTickerState
    ticker: Thread[ptr EpochTickerState]
    tickerStarted: bool
    tickerJoined: bool
    compilationCount: Atomic[uint64]

  RuntimeModule* = ref object
    owner: RuntimeEngine
    raw: ptr WasmtimeModule

  RuntimeInstance* = ref object
    module: RuntimeModule
    store: ptr WasmtimeStore
    context: ptr WasmtimeContext
    raw: WasmtimeInstance

proc bytesPtr(bytes: openArray[byte]): ptr uint8 =
  if bytes.len == 0:
    nil
  else:
    cast[ptr uint8](unsafeAddr bytes[0])

proc byteVecString(bytes: WasmByteVec): string =
  result = newString(bytes.size.int)
  if bytes.size > 0:
    copyMem(addr result[0], bytes.data, bytes.size)

proc consumeError(error: ptr WasmtimeError): string =
  ## Consumes exactly one owned Wasmtime error.
  if error == nil:
    return ""
  var message: WasmByteVec
  wasmtimeErrorMessage(error, addr message)
  result = byteVecString(message).strip(chars = {'\0', '\n'})
  wasmByteVecDelete(addr message)
  wasmtimeErrorDelete(error)

proc consumeTrap(trap: ptr WasmTrap): tuple[code: uint8, message: string] =
  ## Consumes exactly one owned Wasmtime trap.
  result.code = high(uint8)
  discard wasmtimeTrapCode(trap, addr result.code)
  var message: WasmByteVec
  wasmTrapMessage(trap, addr message)
  result.message = byteVecString(message).strip(chars = {'\0', '\n'})
  wasmByteVecDelete(addr message)
  wasmTrapDelete(trap)

proc requireNoError(error: ptr WasmtimeError; operation: string) =
  if error != nil:
    raise newException(ShellRuntimeError,
      operation & ": " & consumeError(error))

proc configureFeatures(config: ptr WasmConfig) =
  ## Freeze WebAssembly 2.0 core features and refuse later proposals.
  wasmtimeConfigWasmThreadsSet(config, false)
  wasmtimeConfigSharedMemorySet(config, false)
  wasmtimeConfigWasmTailCallSet(config, false)
  wasmtimeConfigWasmReferenceTypesSet(config, true)
  wasmtimeConfigWasmFunctionReferencesSet(config, false)
  wasmtimeConfigWasmGcSet(config, false)
  wasmtimeConfigGcSupportSet(config, false)
  wasmtimeConfigWasmSimdSet(config, true)
  wasmtimeConfigWasmRelaxedSimdSet(config, false)
  wasmtimeConfigWasmBulkMemorySet(config, true)
  wasmtimeConfigWasmMultiValueSet(config, true)
  wasmtimeConfigWasmMultiMemorySet(config, false)
  wasmtimeConfigWasmMemory64Set(config, false)
  wasmtimeConfigWasmWideArithmeticSet(config, false)
  wasmtimeConfigWasmBranchHintingSet(config, false)
  wasmtimeConfigWasmExceptionsSet(config, false)
  wasmtimeConfigWasmCustomPageSizesSet(config, false)
  wasmtimeConfigWasmStackSwitchingSet(config, false)

proc tickerMain(state: ptr EpochTickerState) {.thread.} =
  while not state.stopped.load(moAcquire):
    sleep(EpochPeriodMs)
    if state.stopped.load(moAcquire):
      break
    wasmtimeEngineIncrementEpoch(state.engine)
    discard state.ticks.fetchAdd(1'u64, moRelease)

proc close*(runtime: RuntimeEngine)

proc newRuntimeEngine*(): RuntimeEngine =
  let config = wasmConfigNew()
  if config == nil:
    raise newException(ShellRuntimeError, "wasm_config_new returned nil")

  wasmtimeConfigStrategySet(config, WasmtimeStrategyCranelift)
  wasmtimeConfigParallelCompilationSet(config, false)
  configureFeatures(config)
  wasmtimeConfigConsumeFuelSet(config, true)
  wasmtimeConfigEpochInterruptionSet(config, true)
  wasmtimeConfigMaxWasmStackSet(config, MaxWasmStackBytes.csize_t)
  wasmtimeConfigCraneliftNanCanonicalizationSet(config, true)
  wasmtimeConfigMemoryMayMoveSet(config, false)
  wasmtimeConfigMemoryReservationSet(config, MaxMemoryBytes.uint64)
  wasmtimeConfigMemoryGuardSizeSet(config, MemoryGuardBytes.uint64)
  wasmtimeConfigSignalsBasedTrapsSet(config, true)
  when defined(macosx):
    wasmtimeConfigMacosUseMachPortsSet(config, true)

  let pool = wasmtimePoolingConfigNew()
  if pool == nil:
    wasmConfigDelete(config)
    raise newException(ShellRuntimeError,
      "wasmtime_pooling_allocation_config_new returned nil")
  wasmtimePoolingTotalCoreInstancesSet(pool, RuntimePoolSlots.uint32)
  wasmtimePoolingTotalMemoriesSet(pool, RuntimePoolSlots.uint32)
  wasmtimePoolingMaxMemoriesPerModuleSet(pool, 1)
  wasmtimePoolingMaxMemorySizeSet(pool, MaxMemoryBytes.csize_t)
  wasmtimePoolingLinearMemoryKeepResidentSet(pool, 0)
  wasmtimePoolingAllocationStrategySet(config, pool)
  wasmtimePoolingConfigDelete(pool)

  new(result)
  result.raw = wasmEngineNewWithConfig(config) # consumes config
  if result.raw == nil:
    raise newException(ShellRuntimeError,
      "Wasmtime rejected the production Engine configuration")

  result.tickerState = cast[ptr EpochTickerState](
    allocShared0(sizeof(EpochTickerState)))
  if result.tickerState == nil:
    wasmEngineDelete(result.raw)
    result.raw = nil
    raise newException(ShellRuntimeError, "could not allocate epoch ticker")
  result.tickerState.engine = result.raw
  result.tickerState.stopped.store(false, moRelaxed)
  result.tickerState.ticks.store(0'u64, moRelaxed)
  try:
    createThread(result.ticker, tickerMain, result.tickerState)
    result.tickerStarted = true
  except:
    result.close()
    raise

proc close*(runtime: RuntimeEngine) =
  if runtime == nil:
    return
  if runtime.tickerStarted and not runtime.tickerJoined:
    runtime.tickerState.stopped.store(true, moRelease)
    joinThread(runtime.ticker)
    runtime.tickerJoined = true
  if runtime.raw != nil:
    wasmEngineDelete(runtime.raw)
    runtime.raw = nil
  if runtime.tickerState != nil:
    deallocShared(runtime.tickerState)
    runtime.tickerState = nil

proc isOpen*(runtime: RuntimeEngine): bool =
  runtime != nil and runtime.raw != nil

proc tickerWasJoined*(runtime: RuntimeEngine): bool =
  runtime != nil and runtime.tickerJoined

proc epochTickCount*(runtime: RuntimeEngine): uint64 =
  if runtime == nil or runtime.tickerState == nil:
    return 0
  runtime.tickerState.ticks.load(moAcquire)

proc close*(module: RuntimeModule) =
  if module != nil and module.raw != nil:
    wasmtimeModuleDelete(module.raw)
    module.raw = nil

proc validateModuleBytes*(runtime: RuntimeEngine; bytes: openArray[byte])
proc compileValidatedModule*(runtime: RuntimeEngine;
    bytes: openArray[byte]): RuntimeModule

proc compileModule*(runtime: RuntimeEngine;
    bytes: openArray[byte]): RuntimeModule =
  runtime.validateModuleBytes(bytes)
  runtime.compileValidatedModule(bytes)

proc validateModuleBytes*(runtime: RuntimeEngine; bytes: openArray[byte]) =
  if not runtime.isOpen:
    raise newException(ShellRuntimeError, "Engine is closed")
  requireNoError(wasmtimeModuleValidate(runtime.raw, bytes.bytesPtr,
    bytes.len.csize_t), "module validation")

proc compileValidatedModule*(runtime: RuntimeEngine;
    bytes: openArray[byte]): RuntimeModule =
  ## Compiles bytes already accepted by `validateModuleBytes`. Keeping this
  ## operation separate makes the function-count gate observably pre-compile.
  if not runtime.isOpen:
    raise newException(ShellRuntimeError, "Engine is closed")
  discard runtime.compilationCount.fetchAdd(1'u64, moRelaxed)
  var compiled: ptr WasmtimeModule
  let error = wasmtimeModuleNew(runtime.raw, bytes.bytesPtr,
    bytes.len.csize_t, addr compiled)
  if error != nil:
    if compiled != nil:
      wasmtimeModuleDelete(compiled)
    raise newException(ShellRuntimeError,
      "module compilation: " & consumeError(error))
  if compiled == nil:
    raise newException(ShellRuntimeError,
      "module compilation returned no module")
  new(result)
  result.owner = runtime
  result.raw = compiled

proc moduleCompilationCount*(runtime: RuntimeEngine): uint64 =
  if runtime == nil:
    return 0
  runtime.compilationCount.load(moRelaxed)

type
  ManifestProbeState = object
    emissions: int
    logs: int
    bytes: string
    callbackError: string

proc callerBytes(caller: ptr WasmtimeCaller; offset, length, limit: int32): string =
  if caller == nil or offset < 0 or length < 0 or length > limit:
    raise newException(ShellRuntimeError, "invalid host-call byte range")
  var memoryItem: WasmtimeExtern
  if not wasmtimeCallerExportGet(caller, "memory", 6, addr memoryItem):
    raise newException(ShellRuntimeError, "host call has no memory export")
  defer: wasmtimeExternDelete(addr memoryItem)
  if shellWasmtimeExternKind(addr memoryItem) != WasmtimeExternMemory:
    raise newException(ShellRuntimeError, "host call memory export has wrong kind")
  let context = wasmtimeCallerContext(caller)
  let memory = shellWasmtimeExternMemory(addr memoryItem)
  let available = wasmtimeMemoryDataSize(context, memory).uint64
  if offset.uint64 + length.uint64 > available:
    raise newException(ShellRuntimeError, "host-call byte range exceeds memory")
  result = newString(length)
  if length > 0:
    copyMem(addr result[0], cast[pointer](cast[uint](
      wasmtimeMemoryData(context, memory)) + offset.uint), length)

proc manifestEmitCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let state = cast[ptr ManifestProbeState](env)
  if state == nil or nargs != 2 or nresults != 1:
    return nil
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  inc state.emissions
  try:
    state.bytes = callerBytes(caller,
      shellWasmtimeValI32Get(addr values[0]),
      shellWasmtimeValI32Get(addr values[1]), MaxEmitBytes.int32)
    shellWasmtimeValI32Set(results, 0)
  except CatchableError as error:
    state.callbackError = error.msg
    shellWasmtimeValI32Set(results, -1)

proc manifestLogCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let state = cast[ptr ManifestProbeState](env)
  if state == nil or nargs != 3 or nresults != 0:
    return nil
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  inc state.logs
  try:
    if state.logs > MaxLogCallsPerInvocation:
      raise newException(ShellRuntimeError, "manifest log call limit exceeded")
    discard callerBytes(caller, shellWasmtimeValI32Get(addr values[1]),
      shellWasmtimeValI32Get(addr values[2]), MaxLogBytesPerCall.int32)
  except CatchableError as error:
    state.callbackError = error.msg

proc manifestSpatialCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t): ptr WasmTrap {.cdecl.} =
  let state = cast[ptr ManifestProbeState](env)
  if state != nil:
    state.callbackError = "spatial imports are unavailable during manifest probe"
  if nresults == 1:
    shellWasmtimeValI64Set(results, -1)

proc defineProbeFunc(linker: ptr WasmtimeLinker; name: string;
    functionType: ptr WasmFuncType; callback: WasmtimeCallback;
    state: ptr ManifestProbeState) =
  requireNoError(shellWasmtimeLinkerDefineFunc(linker, "play", 4,
    name.cstring, name.len.csize_t, functionType, callback, state),
    "define play." & name)

proc probeManifestBytes*(module: RuntimeModule;
    fuel = ManifestFuel.uint64): string =
  ## Runs one metered manifest invocation in one fresh Store. The Store is
  ## always deleted before return, immediately releasing its pooling slot.
  if module == nil or module.raw == nil or not module.owner.isOpen:
    raise newException(ShellRuntimeError, "module or Engine is closed")
  var state: ManifestProbeState
  let store = wasmtimeStoreNew(module.owner.raw, nil, nil)
  if store == nil:
    raise newException(ShellRuntimeError, "manifest Store creation failed")
  defer: wasmtimeStoreDelete(store)
  let context = wasmtimeStoreContext(store)
  wasmtimeStoreLimiter(store, MaxMemoryBytes.int64, -1, 1, 1, 1)
  requireNoError(wasmtimeContextSetFuel(context, fuel), "manifest Store fuel")
  wasmtimeContextSetEpochDeadline(context, EpochDeadlineTicks.uint64)

  let linker = wasmtimeLinkerNew(module.owner.raw)
  if linker == nil:
    raise newException(ShellRuntimeError, "manifest linker creation failed")
  defer: wasmtimeLinkerDelete(linker)
  let emitType = shellWasmtimeEmitFuncType()
  let logType = shellWasmtimeLogFuncType()
  let reachableType = shellWasmtimeReachableFuncType()
  let coverType = shellWasmtimeCoverFuncType()
  if emitType == nil or logType == nil or reachableType == nil or coverType == nil:
    if coverType != nil: wasmFuncTypeDelete(coverType)
    if reachableType != nil: wasmFuncTypeDelete(reachableType)
    if logType != nil: wasmFuncTypeDelete(logType)
    if emitType != nil: wasmFuncTypeDelete(emitType)
    raise newException(ShellRuntimeError, "manifest host type creation failed")
  defer:
    wasmFuncTypeDelete(coverType)
    wasmFuncTypeDelete(reachableType)
    wasmFuncTypeDelete(logType)
    wasmFuncTypeDelete(emitType)
  defineProbeFunc(linker, "emit", emitType, manifestEmitCallback, addr state)
  defineProbeFunc(linker, "log", logType, manifestLogCallback, addr state)
  defineProbeFunc(linker, "nearest_reachable", reachableType,
    manifestSpatialCallback, addr state)
  defineProbeFunc(linker, "nearest_cover", coverType,
    manifestSpatialCallback, addr state)

  var instance: WasmtimeInstance
  var trap: ptr WasmTrap
  let instantiateError = wasmtimeLinkerInstantiate(linker, context, module.raw,
    addr instance, addr trap)
  if instantiateError != nil:
    if trap != nil: discard consumeTrap(trap)
    raise newException(ShellRuntimeError,
      "manifest instantiation: " & consumeError(instantiateError))
  if trap != nil:
    let detail = consumeTrap(trap)
    raise newException(ShellRuntimeTrap,
      "manifest instantiation trapped: " & detail.message)

  var manifestItem: WasmtimeExtern
  if not wasmtimeInstanceExportGet(context, addr instance, "play_manifest", 13,
      addr manifestItem) or
      shellWasmtimeExternKind(addr manifestItem) != WasmtimeExternFunc:
    raise newException(ShellRuntimeError, "missing play_manifest export")
  defer: wasmtimeExternDelete(addr manifestItem)
  trap = nil
  let callError = wasmtimeFuncCall(context,
    shellWasmtimeExternFunc(addr manifestItem), nil, 0, nil, 0, addr trap)
  if callError != nil:
    if trap != nil: discard consumeTrap(trap)
    raise newException(ShellRuntimeError,
      "play_manifest call: " & consumeError(callError))
  if trap != nil:
    let detail = consumeTrap(trap)
    var exception = newException(ShellRuntimeTrap,
      "play_manifest trapped: " & detail.message)
    exception.code = detail.code
    raise exception
  if state.callbackError.len > 0:
    raise newException(ShellRuntimeError,
      "manifest host call: " & state.callbackError)
  if state.emissions != 1:
    raise newException(ShellRuntimeError,
      "play_manifest emitted " & $state.emissions & " times; expected exactly one")
  state.bytes

proc close*(instance: RuntimeInstance) =
  ## The Store owns the instance and returns its pool slot on deletion.
  if instance != nil and instance.store != nil:
    wasmtimeStoreDelete(instance.store)
    instance.store = nil
    instance.context = nil

proc instantiate*(module: RuntimeModule;
    fuel = InitialStoreFuel): RuntimeInstance =
  if module == nil or module.raw == nil or not module.owner.isOpen:
    raise newException(ShellRuntimeError, "module or Engine is closed")

  new(result)
  result.module = module
  result.store = wasmtimeStoreNew(module.owner.raw, nil, nil)
  if result.store == nil:
    raise newException(ShellRuntimeError, "wasmtime_store_new returned nil")
  result.context = wasmtimeStoreContext(result.store)
  wasmtimeStoreLimiter(result.store, MaxMemoryBytes.int64, -1, 1, 1, 1)

  try:
    requireNoError(wasmtimeContextSetFuel(result.context, fuel),
      "initial Store fuel")
    wasmtimeContextSetEpochDeadline(result.context,
      EpochDeadlineTicks.uint64)
    var trap: ptr WasmTrap
    let error = wasmtimeInstanceNew(result.context, module.raw, nil, 0,
      addr result.raw, addr trap)
    if error != nil:
      let message = consumeError(error)
      if trap != nil:
        discard consumeTrap(trap)
      raise newException(ShellRuntimeError,
        "module instantiation: " & message)
    if trap != nil:
      let detail = consumeTrap(trap)
      var exception = newException(ShellRuntimeTrap,
        "module instantiation trapped: " & detail.message)
      exception.code = detail.code
      raise exception
  except:
    result.close()
    raise

proc isOpen*(module: RuntimeModule): bool =
  module != nil and module.raw != nil

proc isOpen*(instance: RuntimeInstance): bool =
  instance != nil and instance.store != nil

proc runtimeTarget*(): string =
  when defined(macosx) and defined(arm64):
    "aarch64-macos"
  elif defined(macosx) and defined(amd64):
    "x86_64-macos"
  elif defined(linux) and defined(arm64):
    "aarch64-linux"
  elif defined(linux) and defined(amd64):
    "x86_64-linux"
  else:
    "unsupported"

proc wasmtimeReleaseDigest*(): string =
  let target = runtimeTarget()
  for entry in WasmtimeReleaseDigests:
    if entry[0] == target:
      return entry[1]
  "unsupported"

proc runtimeManifest*(): string =
  let linkedVersion = $shellWasmtimeVersion()
  "target=" & runtimeTarget() & " wasmtime=" & linkedVersion &
    " asset_sha256=" & wasmtimeReleaseDigest() &
    " compiler=cranelift fuel=on epochs=5ms/4 nan=canonical" &
    " stack=262144 memory=1048576 reservation=1048576 guard=65536" &
    " pool=514"

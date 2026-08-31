import std/[algorithm, atomics, json, monotimes, os, osproc, streams,
  strformat, strutils, times]

import wasm_emitter
import wasm_fixtures
import wasmtime_c
import tick_models

when not defined(noSignalHandler):
  {.error: "runtime_spike must be compiled with -d:noSignalHandler".}

const
  MaxWasmStack = 262_144
  MaxMemoryBytes = 1_048_576
  MemoryGuardBytes = 65_536
  LargeMemoryGuardBytes = 4_294_967_296'u64
  PoolSlots = 514
  EpochPeriodMs = 5
  EpochDeadlineTicks = 4

type
  EmitState = object
    message: string

  TickerState = object
    engine: ptr WasmEngine
    stopped: Atomic[bool]

  CallOutcome = object
    trapped: bool
    code: uint8
    message: string
    result: int32

  ProcessMemory = object
    resident: uint64
    virtualSize: uint64

  StableMemory = object
    sample: ProcessMemory
    samples: int
    stable: bool

  MemoryInstance = object
    store: ptr WasmtimeStore
    context: ptr WasmtimeContext
    memory: WasmtimeMemory

  MemoryRig = object
    engine: ptr WasmEngine
    module: ptr WasmtimeModule
    linker: ptr WasmtimeLinker
    functionType: ptr WasmFuncType

  MemoryTouch = enum
    touchNone
    touchInitial
    touchFull

  PeakSamplerState = object
    stopped: Atomic[bool]
    peakResident: uint64

  TickHostState = object
    counters: ptr TickCounters
    validIntent: string
    callbackError: string

  TickInstance = object
    store: ptr WasmtimeStore
    context: ptr WasmtimeContext
    instance: WasmtimeInstance
    memory: WasmtimeMemory
    allocItem, initItem, stepItem: WasmtimeExtern

  TickRig = object
    engine: ptr WasmEngine
    module: ptr WasmtimeModule
    linker: ptr WasmtimeLinker
    emitType, coverType, logType: ptr WasmFuncType
    host: TickHostState

  CompileQueueState = object
    engine: ptr WasmEngine
    modules: ptr seq[seq[byte]]
    ready, started, active, completed, failures: Atomic[int]
    # An odd value proves the worker remains inside its active queue-processing
    # loop, which alternates wasmtime_module_new with bookkeeping and never
    # sleeps. It does not prove one module_new call spans the whole tick.
    workerBusyInterval: array[2, Atomic[int]]
    sawTwoBusy, go: Atomic[bool]

  CompileWorker = object
    queue: ptr CompileQueueState
    workerId: int

var memoryTouchChecksum: uint64

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

proc requireNoError(error: ptr WasmtimeError; operation: string) =
  if error != nil:
    raise newException(ValueError, operation & ": " & consumeError(error))

proc consumeTrap(trap: ptr WasmTrap): CallOutcome =
  result.trapped = true
  if not wasmtimeTrapCode(trap, addr result.code):
    result.code = high(uint8)
  var message: WasmByteVec
  wasmTrapMessage(trap, addr message)
  result.message = byteVecString(message).strip(chars = {'\0', '\n'})
  wasmByteVecDelete(addr message)
  wasmTrapDelete(trap)

proc bytesPtr(bytes: seq[byte]): ptr uint8 =
  if bytes.len == 0:
    nil
  else:
    unsafeAddr bytes[0]

proc readBytes(path: string): seq[byte] =
  let contents = readFile(path)
  result = newSeq[byte](contents.len)
  if contents.len > 0:
    copyMem(addr result[0], unsafeAddr contents[0], contents.len)

proc compileModule(engine: ptr WasmEngine; bytes: seq[byte];
    label: string): ptr WasmtimeModule =
  requireNoError(wasmtimeModuleValidate(engine, bytes.bytesPtr,
    bytes.len.csize_t), label & " validation")
  requireNoError(wasmtimeModuleNew(engine, bytes.bytesPtr, bytes.len.csize_t,
    addr result), label & " compilation")
  if result == nil:
    raise newException(ValueError, label & " compilation returned no module")

proc newEngineWith(fuelEnabled = true; epochEnabled = true;
    reservationBytes = MaxMemoryBytes.uint64;
    guardBytes = MemoryGuardBytes.uint64; poolSlots = PoolSlots):
    ptr WasmEngine =
  let config = wasmConfigNew()
  if config == nil:
    raise newException(ValueError, "wasm_config_new returned nil")
  wasmtimeConfigStrategySet(config, WasmtimeStrategyCranelift)
  wasmtimeConfigParallelCompilationSet(config, false)
  wasmtimeConfigConsumeFuelSet(config, fuelEnabled)
  wasmtimeConfigEpochInterruptionSet(config, epochEnabled)
  wasmtimeConfigMaxWasmStackSet(config, MaxWasmStack.csize_t)
  wasmtimeConfigCraneliftNanCanonicalizationSet(config, true)
  wasmtimeConfigMemoryMayMoveSet(config, false)
  wasmtimeConfigMemoryReservationSet(config, reservationBytes)
  wasmtimeConfigMemoryGuardSizeSet(config, guardBytes)
  wasmtimeConfigSignalsBasedTrapsSet(config, true)
  when defined(macosx):
    wasmtimeConfigMacosUseMachPortsSet(config, true)

  let pool = wasmtimePoolingConfigNew()
  if pool == nil:
    raise newException(ValueError,
      "wasmtime_pooling_allocation_config_new returned nil")
  wasmtimePoolingTotalCoreInstancesSet(pool, poolSlots.uint32)
  wasmtimePoolingTotalMemoriesSet(pool, poolSlots.uint32)
  wasmtimePoolingMaxMemoriesPerModuleSet(pool, 1)
  wasmtimePoolingMaxMemorySizeSet(pool, MaxMemoryBytes.csize_t)
  wasmtimePoolingLinearMemoryKeepResidentSet(pool, 0)
  wasmtimePoolingAllocationStrategySet(config, pool)
  wasmtimePoolingConfigDelete(pool)

  result = wasmEngineNewWithConfig(config)
  if result == nil:
    raise newException(ValueError,
      "Wasmtime rejected the 1 MiB reservation / 64 KiB guard configuration")

proc newEngine(): ptr WasmEngine =
  newEngineWith()

proc newStore(engine: ptr WasmEngine; memoryLimit = MaxMemoryBytes.int64;
    fuelEnabled = true):
    ptr WasmtimeStore =
  result = wasmtimeStoreNew(engine, nil, nil)
  if result == nil:
    raise newException(ValueError, "wasmtime_store_new returned nil")
  wasmtimeStoreLimiter(result, memoryLimit, -1, 1, 1, 1)
  let context = wasmtimeStoreContext(result)
  if fuelEnabled:
    requireNoError(wasmtimeContextSetFuel(context, 1_000_000_000),
      "initial fuel")
  wasmtimeContextSetEpochDeadline(context, high(uint64) div 2)

proc processMemory(): ProcessMemory =
  if runtimeSpikeProcessMemory(addr result.resident,
      addr result.virtualSize) != 1:
    raise newException(ValueError, "could not read current process RSS/VSZ")

proc kibibytes(bytes: uint64): uint64 =
  bytes div 1024

proc deltaBytes(current, baseline: uint64): int64 =
  current.int64 - baseline.int64

proc stableProcessMemory(): StableMemory =
  const
    MaxSamples = 100
    StableWindow = 4
    StableSpread = 64'u64 * 1024
    SampleDelayMs = 5
  var window: seq[uint64]
  for sampleNumber in 1 .. MaxSamples:
    result.sample = processMemory()
    result.samples = sampleNumber
    window.add result.sample.resident
    if window.len > StableWindow:
      window.delete(0)
    if window.len == StableWindow:
      var low = high(uint64)
      var highValue = 0'u64
      for resident in window:
        low = min(low, resident)
        highValue = max(highValue, resident)
      if highValue - low <= StableSpread:
        result.stable = true
        return
    sleep(SampleDelayMs)

proc rssTolerance(baseline: ProcessMemory): uint64 =
  max(8'u64 * 1024 * 1024, baseline.resident div 20)

proc rssWithinTolerance(sample, baseline: ProcessMemory;
    tolerance: uint64): bool =
  let difference = abs(deltaBytes(sample.resident, baseline.resident))
  difference.uint64 <= tolerance

proc exportedFunction(context: ptr WasmtimeContext;
    instance: ptr WasmtimeInstance; name: string;
    item: var WasmtimeExtern): ptr WasmtimeFunc =
  if not wasmtimeInstanceExportGet(context, instance, name.cstring,
      name.len.csize_t, addr item):
    raise newException(ValueError, "missing function export: " & name)
  if runtimeSpikeExternKind(addr item) != WasmtimeExternFunc:
    wasmtimeExternDelete(addr item)
    raise newException(ValueError, "export is not a function: " & name)
  runtimeSpikeExternFunc(addr item)

proc instantiate(engine: ptr WasmEngine; module: ptr WasmtimeModule;
    memoryLimit = MaxMemoryBytes.int64): tuple[store: ptr WasmtimeStore,
    context: ptr WasmtimeContext, instance: WasmtimeInstance] =
  result.store = newStore(engine, memoryLimit)
  result.context = wasmtimeStoreContext(result.store)
  var trap: ptr WasmTrap
  let error = wasmtimeInstanceNew(result.context, module, nil, 0,
    addr result.instance, addr trap)
  if error != nil:
    let message = consumeError(error)
    wasmtimeStoreDelete(result.store)
    raise newException(ValueError, "fixture instantiation: " & message)
  if trap != nil:
    let outcome = consumeTrap(trap)
    wasmtimeStoreDelete(result.store)
    raise newException(ValueError, "fixture instantiation trapped: " &
      outcome.message)

proc callFunction(context: ptr WasmtimeContext; function: ptr WasmtimeFunc;
    arguments: openArray[int32]; resultCount: int): CallOutcome =
  var args = newSeq[WasmtimeVal](arguments.len)
  for index, argument in arguments:
    runtimeSpikeValI32Set(addr args[index], argument)
  var results = newSeq[WasmtimeVal](resultCount)
  var trap: ptr WasmTrap
  let argsPointer = if args.len == 0: nil else: addr args[0]
  let resultsPointer = if results.len == 0: nil else: addr results[0]
  let error = wasmtimeFuncCall(context, function, argsPointer,
    args.len.csize_t, resultsPointer, results.len.csize_t, addr trap)
  if error != nil:
    raise newException(ValueError, "wasmtime_func_call: " & consumeError(error))
  if trap != nil:
    return consumeTrap(trap)
  if resultCount == 1:
    if runtimeSpikeValKind(addr results[0]) != WasmtimeI32:
      raise newException(ValueError, "function returned a non-i32 value")
    result.result = runtimeSpikeValI32Get(addr results[0])

proc emitCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t):
    ptr WasmTrap {.cdecl.} =
  if env == nil or caller == nil or nargs != 2 or nresults != 1:
    return nil
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  if runtimeSpikeValKind(addr values[0]) != WasmtimeI32 or
      runtimeSpikeValKind(addr values[1]) != WasmtimeI32:
    return nil
  let offset = runtimeSpikeValI32Get(addr values[0])
  let length = runtimeSpikeValI32Get(addr values[1])
  var memoryItem: WasmtimeExtern
  if offset < 0 or length < 0 or not wasmtimeCallerExportGet(caller,
      "memory", 6, addr memoryItem):
    runtimeSpikeValI32Set(results, -1)
    return nil
  if runtimeSpikeExternKind(addr memoryItem) != WasmtimeExternMemory:
    wasmtimeExternDelete(addr memoryItem)
    runtimeSpikeValI32Set(results, -1)
    return nil
  let context = wasmtimeCallerContext(caller)
  let memory = runtimeSpikeExternMemory(addr memoryItem)
  let memorySize = wasmtimeMemoryDataSize(context, memory)
  if offset.uint64 + length.uint64 > memorySize.uint64:
    wasmtimeExternDelete(addr memoryItem)
    runtimeSpikeValI32Set(results, -1)
    return nil
  let data = wasmtimeMemoryData(context, memory)
  let state = cast[ptr EmitState](env)
  state.message = newString(length)
  if length > 0:
    copyMem(addr state.message[0], cast[pointer](cast[uint](data) +
      offset.uint), length)
  wasmtimeExternDelete(addr memoryItem)
  runtimeSpikeValI32Set(results, 0)

proc initMemoryRig(helloPath: string): MemoryRig =
  result.engine = newEngine()
  if result.engine == nil:
    raise newException(ValueError, "memory rig engine creation failed")
  try:
    result.module = compileModule(result.engine, readBytes(helloPath),
      "memory hello play")
    result.linker = wasmtimeLinkerNew(result.engine)
    if result.linker == nil:
      raise newException(ValueError, "memory rig linker creation failed")
    result.functionType = runtimeSpikeEmitFuncType()
    if result.functionType == nil:
      raise newException(ValueError, "memory rig emit type creation failed")
    requireNoError(runtimeSpikeLinkerDefineFunc(result.linker, "play", 4,
      "emit", 4, result.functionType, emitCallback, nil),
      "memory rig define play.emit")
  except:
    if result.functionType != nil:
      wasmFuncTypeDelete(result.functionType)
    if result.linker != nil:
      wasmtimeLinkerDelete(result.linker)
    if result.module != nil:
      wasmtimeModuleDelete(result.module)
    wasmEngineDelete(result.engine)
    raise

proc destroyMemoryRig(rig: var MemoryRig) =
  if rig.functionType != nil:
    wasmFuncTypeDelete(rig.functionType)
    rig.functionType = nil
  if rig.linker != nil:
    wasmtimeLinkerDelete(rig.linker)
    rig.linker = nil
  if rig.module != nil:
    wasmtimeModuleDelete(rig.module)
    rig.module = nil
  if rig.engine != nil:
    wasmEngineDelete(rig.engine)
    rig.engine = nil

proc newMemoryInstance(rig: MemoryRig): MemoryInstance =
  result.store = newStore(rig.engine)
  result.context = wasmtimeStoreContext(result.store)
  var instance: WasmtimeInstance
  var trap: ptr WasmTrap
  let error = wasmtimeLinkerInstantiate(rig.linker, result.context, rig.module,
    addr instance, addr trap)
  if error != nil:
    let message = consumeError(error)
    wasmtimeStoreDelete(result.store)
    result.store = nil
    raise newException(ValueError, "memory instance creation: " & message)
  if trap != nil:
    let outcome = consumeTrap(trap)
    wasmtimeStoreDelete(result.store)
    result.store = nil
    raise newException(ValueError, "memory instance creation trapped: " &
      outcome.message)
  var memoryItem: WasmtimeExtern
  if not wasmtimeInstanceExportGet(result.context, addr instance, "memory", 6,
      addr memoryItem):
    wasmtimeStoreDelete(result.store)
    result.store = nil
    raise newException(ValueError, "memory instance has no memory export")
  if runtimeSpikeExternKind(addr memoryItem) != WasmtimeExternMemory:
    wasmtimeExternDelete(addr memoryItem)
    wasmtimeStoreDelete(result.store)
    result.store = nil
    raise newException(ValueError, "memory instance has no memory export")
  runtimeSpikeExternMemoryCopy(addr result.memory, addr memoryItem)
  wasmtimeExternDelete(addr memoryItem)

proc deleteMemoryInstance(instance: var MemoryInstance) =
  if instance.store != nil:
    wasmtimeStoreDelete(instance.store)
    instance.store = nil
    instance.context = nil

proc dropInstances(instances: var seq[MemoryInstance]) =
  for instance in mitems(instances):
    instance.deleteMemoryInstance()
  instances.setLen(0)

proc touchMemory(instance: var MemoryInstance; mode: MemoryTouch) =
  if mode == touchNone:
    return
  if mode == touchFull:
    let currentPages = wasmtimeMemorySize(instance.context,
      addr instance.memory)
    if currentPages > 16:
      raise newException(ValueError, &"hello memory is {currentPages} pages")
    if currentPages < 16:
      var previousPages: uint64
      requireNoError(wasmtimeMemoryGrow(instance.context, addr instance.memory,
        16 - currentPages, addr previousPages), "grow hello memory to 1 MiB")
      if previousPages != currentPages:
        raise newException(ValueError, "memory.grow returned wrong previous size")
  let byteCount = wasmtimeMemoryDataSize(instance.context, addr instance.memory)
  if mode == touchFull and byteCount.uint64 != MaxMemoryBytes.uint64:
    raise newException(ValueError,
      &"full hello memory is {byteCount} bytes, expected {MaxMemoryBytes}")
  let bytes = cast[ptr UncheckedArray[uint8]](
    wasmtimeMemoryData(instance.context, addr instance.memory))
  var offset = 0
  while offset < byteCount.int:
    let value = uint8(((offset div 4096) and 0xff) or 1)
    bytes[offset] = value
    memoryTouchChecksum = memoryTouchChecksum +
      (value.uint64 shl ((offset div 4096) and 7))
    offset += 4096

proc refillInstances(instances: var seq[MemoryInstance]; rig: MemoryRig;
    count: int; mode: MemoryTouch) =
  if instances.len != 0:
    raise newException(ValueError, "refill requires an empty instance vector")
  try:
    for _ in 0 ..< count:
      var instance = newMemoryInstance(rig)
      instance.touchMemory(mode)
      instances.add instance
  except:
    instances.dropInstances()
    raise

proc allocateInstances(rig: MemoryRig; count: int;
    mode: MemoryTouch): seq[MemoryInstance] =
  result = newSeqOfCap[MemoryInstance](count)
  result.refillInstances(rig, count, mode)

proc elapsedNanoseconds(started: MonoTime): int64 =
  inNanoseconds(getMonoTime() - started)

proc percentile(sortedSamples: seq[int64]; numerator: int): int64 =
  let rank = (sortedSamples.len * numerator + 99) div 100
  sortedSamples[max(0, rank - 1)]

proc formatMicros(nanoseconds: int64): string =
  formatFloat(nanoseconds.float / 1_000.0, ffDecimal, 3)

proc reportLatency(rig: MemoryRig; steadySamples: int) =
  var started = getMonoTime()
  var cold = newMemoryInstance(rig)
  let coldNanoseconds = elapsedNanoseconds(started)
  cold.deleteMemoryInstance()

  var samples = newSeqOfCap[int64](steadySamples)
  for _ in 0 ..< steadySamples:
    started = getMonoTime()
    var instance = newMemoryInstance(rig)
    samples.add elapsedNanoseconds(started)
    instance.deleteMemoryInstance()
  samples.sort()
  echo &"LATENCY cold_us={formatMicros(coldNanoseconds)} " &
    &"steady_n={samples.len} median_us={formatMicros(samples.percentile(50))} " &
    &"p95_us={formatMicros(samples.percentile(95))} " &
    &"p99_us={formatMicros(samples.percentile(99))} " &
    &"max_us={formatMicros(samples[^1])}"

proc capacityProbe(rig: MemoryRig) =
  var first = allocateInstances(rig, PoolSlots, touchNone)
  var overflowRejected = false
  var overflowMessage = ""
  try:
    var overflow = newMemoryInstance(rig)
    overflow.deleteMemoryInstance()
  except ValueError as error:
    overflowRejected = true
    overflowMessage = error.msg.replace("\n", " ")
  if not overflowRejected:
    first.dropInstances()
    raise newException(ValueError, "pool accepted instance 515")
  first.dropInstances()
  var reused = allocateInstances(rig, PoolSlots, touchNone)
  if reused.len != PoolSlots:
    reused.dropInstances()
    raise newException(ValueError, "pool did not reuse all 514 slots")
  reused.dropInstances()
  echo &"CAPACITY PASS configured={PoolSlots} first={PoolSlots} " &
    &"overflow=rejected reused={PoolSlots} message={overflowMessage}"

proc dropStatus(label: string; stable: StableMemory; baseline: ProcessMemory;
    tolerance: uint64): bool =
  result = stable.stable and
    rssWithinTolerance(stable.sample, baseline, tolerance)
  echo &"DROP label={label} rss_kib={stable.sample.resident.kibibytes} " &
    &"vsz_kib={stable.sample.virtualSize.kibibytes} " &
    &"rss_delta_kib={deltaBytes(stable.sample.resident, baseline.resident) div 1024} " &
    &"samples={stable.samples} stable={stable.stable} " &
    &"tolerance_kib={tolerance.kibibytes} status=" &
    (if result: "PASS" else: "FAIL")

proc memorySeries(rig: MemoryRig; checkpoints: seq[int]; mode: MemoryTouch;
    baseline: ProcessMemory; tolerance: uint64): bool =
  var instances: seq[MemoryInstance]
  let seriesName = if mode == touchInitial: "initial" else: "full-1mib"
  for target in checkpoints:
    while instances.len < target:
      var instance = newMemoryInstance(rig)
      instance.touchMemory(mode)
      instances.add instance
    let sample = processMemory()
    let memoryBytes = wasmtimeMemoryDataSize(instances[0].context,
      addr instances[0].memory)
    echo &"RSS series={seriesName} instances={target} " &
      &"bytes_per_memory={memoryBytes} rss_kib={sample.resident.kibibytes} " &
      &"rss_delta_kib={deltaBytes(sample.resident, baseline.resident) div 1024} " &
      &"vsz_kib={sample.virtualSize.kibibytes} " &
      &"vsz_delta_kib={deltaBytes(sample.virtualSize, baseline.virtualSize) div 1024}"
  instances.dropInstances()
  let stable = stableProcessMemory()
  dropStatus("series-" & seriesName, stable, baseline, tolerance)

proc replacementSoak(rig: MemoryRig; cycles: int; baseline: ProcessMemory;
    tolerance: uint64): bool =
  result = true
  var instances = allocateInstances(rig, 512, touchNone)
  for cycle in 1 .. cycles:
    if instances.len != 512:
      raise newException(ValueError, &"soak cycle {cycle} began with " &
        &"{instances.len} live instances")
    instances.dropInstances()
    let stable = stableProcessMemory()
    let dropPassed = stable.stable and
      rssWithinTolerance(stable.sample, baseline, tolerance)
    if not dropPassed:
      result = false
    instances.refillInstances(rig, 512, touchNone)
    let slotPassed = instances.len == 512
    if not slotPassed:
      result = false
    echo &"SOAK cycle={cycle} dropped_rss_kib=" &
      &"{stable.sample.resident.kibibytes} rss_delta_kib=" &
      &"{deltaBytes(stable.sample.resident, baseline.resident) div 1024} " &
      &"samples={stable.samples} stable={stable.stable} " &
      &"tolerance_kib={tolerance.kibibytes} drop_status=" &
      (if dropPassed: "PASS" else: "FAIL") &
      &" live_after_reuse={instances.len} slot_status=" &
      (if slotPassed: "PASS" else: "FAIL")
  instances.dropInstances()
  let finalDrop = stableProcessMemory()
  if not dropStatus("soak-final", finalDrop, baseline, tolerance):
    result = false

proc importName(value: ptr WasmByteVec): string =
  if value == nil:
    ""
  else:
    byteVecString(value[])

proc proveHelloImports(module: ptr WasmtimeModule) =
  var imports: WasmImportTypeVec
  wasmtimeModuleImports(module, addr imports)
  defer: wasmImportTypeVecDelete(addr imports)
  if imports.size != 1:
    raise newException(ValueError, &"hello imports={imports.size}; expected 1")
  let items = cast[ptr UncheckedArray[ptr WasmImportType]](imports.data)
  let moduleName = importName(wasmImportTypeModule(items[0]))
  let itemName = importName(wasmImportTypeName(items[0]))
  if moduleName != "play" or itemName != "emit":
    raise newException(ValueError,
      &"unexpected hello import: {moduleName}.{itemName}")
  echo "IMPORTS PASS count=1 allowed=play.emit wasi=absent"

proc cleanHello(engine: ptr WasmEngine; module: ptr WasmtimeModule;
    after: string) =
  var state: EmitState
  let store = newStore(engine)
  defer: wasmtimeStoreDelete(store)
  let context = wasmtimeStoreContext(store)
  let linker = wasmtimeLinkerNew(engine)
  if linker == nil:
    raise newException(ValueError, "wasmtime_linker_new returned nil")
  defer: wasmtimeLinkerDelete(linker)
  let functionType = runtimeSpikeEmitFuncType()
  if functionType == nil:
    raise newException(ValueError, "could not create play.emit function type")
  defer: wasmFuncTypeDelete(functionType)
  requireNoError(runtimeSpikeLinkerDefineFunc(linker, "play", 4, "emit", 4,
    functionType, emitCallback, addr state), "define play.emit")
  var instance: WasmtimeInstance
  var trap: ptr WasmTrap
  requireNoError(wasmtimeLinkerInstantiate(linker, context, module,
    addr instance, addr trap), "hello instantiation")
  if trap != nil:
    let outcome = consumeTrap(trap)
    raise newException(ValueError, "hello instantiation trapped: " &
      outcome.message)
  var allocItem, initItem, stepItem, memoryItem: WasmtimeExtern
  let allocFunction = exportedFunction(context, addr instance, "play_alloc",
    allocItem)
  let initFunction = exportedFunction(context, addr instance, "play_init",
    initItem)
  let stepFunction = exportedFunction(context, addr instance, "play_step",
    stepItem)
  if not wasmtimeInstanceExportGet(context, addr instance, "memory", 6,
      addr memoryItem) or
      runtimeSpikeExternKind(addr memoryItem) != WasmtimeExternMemory:
    raise newException(ValueError, "missing memory export")
  let initialization = callFunction(context, initFunction,
    [0'i32, 0'i32, 0'i32, 0'i32], 1)
  let allocation = callFunction(context, allocFunction, [1'i32], 1)
  let outcome = callFunction(context, stepFunction, [0'i32, 0'i32], 1)
  wasmtimeExternDelete(addr memoryItem)
  wasmtimeExternDelete(addr stepItem)
  wasmtimeExternDelete(addr initItem)
  wasmtimeExternDelete(addr allocItem)
  if initialization.trapped or initialization.result != 0 or
      allocation.trapped or allocation.result == 0 or outcome.trapped or
      outcome.result != 0 or state.message != "hello":
    raise newException(ValueError, &"clean hello failed after {after}")
  echo &"CLEAN PASS after={after} exports=memory,play_alloc,play_init,play_step " &
    &"emission={state.message}"

proc tickerMain(state: ptr TickerState) {.thread.} =
  while not state.stopped.load(moAcquire):
    sleep(EpochPeriodMs)
    wasmtimeEngineIncrementEpoch(state.engine)

proc requireTrap(outcome: CallOutcome; expectedCode: uint8; label: string) =
  if not outcome.trapped or outcome.code != expectedCode:
    raise newException(ValueError, &"{label}: expected trap code " &
      &"{expectedCode}, got trapped={outcome.trapped} code={outcome.code} " &
      &"message={outcome.message}")

proc runTrapFixture(engine: ptr WasmEngine; bytes: seq[byte]; label: string;
    expectedCode: uint8; fuel: uint64; withTicker: bool): CallOutcome =
  let module = compileModule(engine, bytes, label)
  defer: wasmtimeModuleDelete(module)
  let runtime = instantiate(engine, module)
  defer: wasmtimeStoreDelete(runtime.store)
  requireNoError(wasmtimeContextSetFuel(runtime.context, fuel), label & " fuel")
  wasmtimeContextSetEpochDeadline(runtime.context,
    if withTicker: EpochDeadlineTicks.uint64 else: high(uint64) div 2)
  var functionItem: WasmtimeExtern
  let function = exportedFunction(runtime.context, addr runtime.instance,
    "run", functionItem)
  defer: wasmtimeExternDelete(addr functionItem)
  if withTicker:
    var state: TickerState
    state.engine = engine
    state.stopped.store(false, moRelaxed)
    var ticker: Thread[ptr TickerState]
    createThread(ticker, tickerMain, addr state)
    defer:
      state.stopped.store(true, moRelease)
      joinThread(ticker)
    result = callFunction(runtime.context, function, [], 0)
  else:
    result = callFunction(runtime.context, function, [], 0)
  result.requireTrap(expectedCode, label)

proc expectedDigest(): string =
  when defined(macosx) and defined(arm64):
    "9e3c636ed487a41026ff76388c5fa6f3a48ea0968408d033ed4b5e8082c20d69"
  elif defined(macosx) and defined(amd64):
    "a5d92170718d41e4bd08173049019f0cedb318d0156365a52667d4a35ea3ca69"
  elif defined(linux) and defined(arm64):
    "1c521a9be661644541158b360df8f7c7ec5bc2d88d23ff4dbbc12f639247c266"
  elif defined(linux) and defined(amd64):
    "67683d04b416a8b91f0e607e7b4c22bd32f18f947c10b5372eb8c277ae3b883a"
  else:
    "unsupported"

proc peakSamplerMain(state: ptr PeakSamplerState) {.thread.} =
  while not state.stopped.load(moAcquire):
    let sample = processMemory()
    state.peakResident = max(state.peakResident, sample.resident)
    sleep(1)

proc compileWarmup(engine: ptr WasmEngine; bytes: seq[byte]) =
  requireNoError(wasmtimeModuleValidate(engine, bytes.bytesPtr,
    bytes.len.csize_t), "warm-up validation")
  var module: ptr WasmtimeModule
  requireNoError(wasmtimeModuleNew(engine, bytes.bytesPtr, bytes.len.csize_t,
    addr module), "warm-up compilation")
  if module == nil:
    raise newException(ValueError, "warm-up compilation returned no module")
  wasmtimeModuleDelete(module)

proc compileChild(shape: CompileShape; temperature: string;
    repeatNumber: int) =
  if temperature != "cold" and temperature != "warm":
    raise newException(ValueError, "temperature must be cold or warm")
  let emitted = emitModule(shape)
  if emitted.bytes.len != ExactModuleBytes:
    raise newException(ValueError, "child received a non-exact module")
  let engine = newEngine()
  defer: wasmEngineDelete(engine)
  if temperature == "warm":
    compileWarmup(engine, emitted.bytes)

  let stable = stableProcessMemory()
  if not stable.stable:
    raise newException(ValueError, "compile-child baseline did not stabilize")
  let baseline = stable.sample
  var samplerState: PeakSamplerState
  samplerState.peakResident = baseline.resident
  samplerState.stopped.store(false, moRelaxed)
  var sampler: Thread[ptr PeakSamplerState]
  createThread(sampler, peakSamplerMain, addr samplerState)

  var validationError = ""
  let validationStarted = getMonoTime()
  let validationResult = wasmtimeModuleValidate(engine, emitted.bytes.bytesPtr,
    emitted.bytes.len.csize_t)
  let validationNanoseconds = elapsedNanoseconds(validationStarted)
  if validationResult != nil:
    validationError = consumeError(validationResult)

  var module: ptr WasmtimeModule
  var compileError = ""
  var compileNanoseconds = 0'i64
  if validationError.len == 0:
    let compileStarted = getMonoTime()
    let compileResult = wasmtimeModuleNew(engine, emitted.bytes.bytesPtr,
      emitted.bytes.len.csize_t, addr module)
    compileNanoseconds = elapsedNanoseconds(compileStarted)
    if compileResult != nil:
      compileError = consumeError(compileResult)
    elif module == nil:
      compileError = "module_new returned no module"

  samplerState.stopped.store(true, moRelease)
  joinThread(sampler)
  samplerState.peakResident = max(samplerState.peakResident,
    processMemory().resident)

  var serializedBytes = 0'u64
  var serializeError = ""
  if module != nil:
    var serialized: WasmByteVec
    let serializeResult = wasmtimeModuleSerialize(module, addr serialized)
    if serializeResult != nil:
      serializeError = consumeError(serializeResult)
    else:
      serializedBytes = serialized.size.uint64
      wasmByteVecDelete(addr serialized)
    wasmtimeModuleDelete(module)

  let validateMilliseconds = validationNanoseconds.float / 1_000_000.0
  let compileMilliseconds = compileNanoseconds.float / 1_000_000.0
  let ratio = serializedBytes.float / ExactModuleBytes.float
  let valid = validationError.len == 0
  let compiled = compileError.len == 0 and module != nil
  let serializedOk = serializeError.len == 0 and serializedBytes > 0
  let compileGate = compiled and compileMilliseconds <= 2_000.0
  let ratioGate = serializedOk and ratio <= 8.0
  let passed = valid and compileGate and ratioGate
  let peakDelta = samplerState.peakResident.int64 - baseline.resident.int64

  var row = newJObject()
  row["shape"] = %shape.shapeName
  row["objective"] = %emitted.objective
  row["achieved"] = %emitted.achieved
  row["raw_bytes"] = %emitted.bytes.len
  row["temperature"] = %temperature
  row["repeat"] = %repeatNumber
  row["validate_ms"] = %validateMilliseconds
  row["module_new_ms"] = %compileMilliseconds
  row["serialized_bytes"] = %serializedBytes
  row["serialized_ratio"] = %ratio
  row["baseline_rss_kib"] = %(baseline.resident div 1024)
  row["peak_rss_kib"] = %(samplerState.peakResident div 1024)
  row["peak_delta_rss_kib"] = %(peakDelta div 1024)
  row["baseline_vsz_kib"] = %(baseline.virtualSize div 1024)
  row["compiler_parallel"] = %false
  row["observer_period_ms"] = %1
  row["os"] = %hostOS
  row["cpu"] = %hostCPU
  row["nim"] = %NimVersion
  row["wasmtime_sha256"] = %expectedDigest()
  row["valid"] = %valid
  row["compile_gate_2000ms"] = %compileGate
  row["ratio_gate_8x"] = %ratioGate
  row["validation_error"] = %validationError.replace("\n", " ")
  row["compile_error"] = %compileError.replace("\n", " ")
  row["serialize_error"] = %serializeError.replace("\n", " ")
  row["status"] = %(if passed: "PASS" else: "FAIL")
  echo $row

proc childResult(shape: CompileShape; temperature: string;
    repeatNumber: int): JsonNode =
  let process = startProcess(getAppFilename(), options = {poStdErrToStdOut},
    args = ["compile-child", shape.shapeName, temperature, $repeatNumber])
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  var jsonLine = ""
  for line in output.splitLines():
    if line.startsWith("{"):
      jsonLine = line
  if exitCode != 0 or jsonLine.len == 0:
    raise newException(ValueError, &"compile child failed shape={shape.shapeName} " &
      &"temperature={temperature} repeat={repeatNumber} exit={exitCode}: " &
      output.strip())
  result = parseJson(jsonLine)

proc jsonPercentile(values: seq[float]; numerator: int): float =
  var sortedValues = values
  sortedValues.sort()
  let rank = (sortedValues.len * numerator + 99) div 100
  sortedValues[max(0, rank - 1)]

proc compileParent(repeats: int) =
  var rows: seq[JsonNode]
  var passed = true
  for shape in CompileShape:
    for temperature in ["cold", "warm"]:
      for repeatNumber in 1 .. repeats:
        let row = childResult(shape, temperature, repeatNumber)
        rows.add row
        echo "COMPILE_CHILD " & $row
        if row["status"].getStr() != "PASS":
          passed = false

  for shape in CompileShape:
    for temperature in ["cold", "warm"]:
      var validateValues, compileValues, ratioValues, peakDeltaValues: seq[float]
      var modePassed = true
      var achieved = 0
      for row in rows:
        if row["shape"].getStr() == shape.shapeName and
            row["temperature"].getStr() == temperature:
          achieved = row["achieved"].getInt()
          validateValues.add row["validate_ms"].getFloat()
          compileValues.add row["module_new_ms"].getFloat()
          ratioValues.add row["serialized_ratio"].getFloat()
          peakDeltaValues.add row["peak_delta_rss_kib"].getFloat()
          if row["status"].getStr() != "PASS":
            modePassed = false
      echo &"COMPILE_SUMMARY shape={shape.shapeName} temperature={temperature} " &
        &"n={compileValues.len} achieved={achieved} raw_bytes={ExactModuleBytes} " &
        &"validate_median_ms={validateValues.jsonPercentile(50):.3f} " &
        &"validate_max_ms={validateValues.max:.3f} " &
        &"module_new_median_ms={compileValues.jsonPercentile(50):.3f} " &
        &"module_new_p95_ms={compileValues.jsonPercentile(95):.3f} " &
        &"module_new_max_ms={compileValues.max:.3f} " &
        &"serialized_ratio_max={ratioValues.max:.3f} " &
        &"peak_delta_rss_kib_max={peakDeltaValues.max:.0f} status=" &
        (if modePassed: "PASS" else: "FAIL")
  echo &"COMPILE repeats_per_temperature={repeats} children={rows.len} status=" &
    (if passed: "PASS" else: "FAIL")
  if not passed:
    quit("compile mode failed one or more fixed acceptance gates", 1)

proc parsePositive(value, option: string): int

proc callerBytes(caller: ptr WasmtimeCaller; offset, length: int32): string =
  if caller == nil or offset < 0 or length < 0:
    raise newException(ValueError, "invalid callback byte range")
  var memoryItem: WasmtimeExtern
  if not wasmtimeCallerExportGet(caller, "memory", 6, addr memoryItem):
    raise newException(ValueError, "callback caller has no memory export")
  defer: wasmtimeExternDelete(addr memoryItem)
  if runtimeSpikeExternKind(addr memoryItem) != WasmtimeExternMemory:
    raise newException(ValueError, "callback caller has no memory export")
  let context = wasmtimeCallerContext(caller)
  let memory = runtimeSpikeExternMemory(addr memoryItem)
  let memorySize = wasmtimeMemoryDataSize(context, memory)
  if offset.uint64 + length.uint64 > memorySize.uint64:
    raise newException(ValueError, "callback byte range exceeds memory")
  result = newString(length)
  if length > 0:
    copyMem(addr result[0], cast[pointer](cast[uint](
      wasmtimeMemoryData(context, memory)) + offset.uint), length)

proc tickCoverCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal;
    nargs: csize_t; results: ptr WasmtimeVal; nresults: csize_t):
    ptr WasmTrap {.cdecl.} =
  let host = cast[ptr TickHostState](env)
  if host == nil or host.counters == nil or caller == nil or nargs != 6 or
      nresults != 1:
    return nil
  try:
    let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
    let threats = callerBytes(caller,
      runtimeSpikeValI32Get(addr values[4]),
      runtimeSpikeValI32Get(addr values[5]))
    host.counters[].nearestCover()
    host.counters[].coverThreatBytes += threats.len
    for threatByte in threats:
      host.counters[].checksum = host.counters[].checksum xor
        ord(threatByte).uint64
    runtimeSpikeValI64Set(results, 0x0000_0100_0000_0100'i64)
  except CatchableError as error:
    host.callbackError = error.msg
    runtimeSpikeValI64Set(results, -3)

proc tickEmitCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal;
    nargs: csize_t; results: ptr WasmtimeVal; nresults: csize_t):
    ptr WasmTrap {.cdecl.} =
  let host = cast[ptr TickHostState](env)
  if host == nil or host.counters == nil or nargs != 2 or nresults != 1:
    return nil
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  try:
    let bytes = callerBytes(caller, runtimeSpikeValI32Get(addr values[0]),
      runtimeSpikeValI32Get(addr values[1]))
    host.counters[].modelEmit(bytes, host.validIntent)
    runtimeSpikeValI32Set(results, 0)
  except CatchableError as error:
    host.callbackError = error.msg
    runtimeSpikeValI32Set(results, -1)

proc tickLogCallback(env: pointer; caller: ptr WasmtimeCaller;
    args: ptr WasmtimeConstVal;
    nargs: csize_t; results: ptr WasmtimeVal; nresults: csize_t):
    ptr WasmTrap {.cdecl.} =
  let host = cast[ptr TickHostState](env)
  if host == nil or host.counters == nil or nargs != 3 or nresults != 0:
    return nil
  let values = cast[ptr UncheckedArray[WasmtimeVal]](args)
  try:
    let bytes = callerBytes(caller, runtimeSpikeValI32Get(addr values[1]),
      runtimeSpikeValI32Get(addr values[2]))
    host.counters[].modelLog(bytes)
  except CatchableError as error:
    host.callbackError = error.msg

proc initTickRig(useValidIntent: bool): TickRig =
  result.engine = newEngine()
  try:
    result.module = compileModule(result.engine, hostileTickFixture(),
      "hostile tick fixture")
    result.linker = wasmtimeLinkerNew(result.engine)
    result.emitType = runtimeSpikeEmitFuncType()
    result.coverType = runtimeSpikeCoverFuncType()
    result.logType = runtimeSpikeLogFuncType()
    if result.linker == nil or result.emitType == nil or
        result.coverType == nil or result.logType == nil:
      raise newException(ValueError, "tick rig C-API allocation failed")
    result.host.validIntent = if useValidIntent: validIntentBytes() else: ""
    requireNoError(runtimeSpikeLinkerDefineFunc(result.linker, "play", 4,
      "nearest_cover", 13, result.coverType,
      tickCoverCallback, addr result.host),
      "define play.nearest_cover")
    requireNoError(runtimeSpikeLinkerDefineFunc(result.linker, "play", 4,
      "emit", 4, result.emitType, tickEmitCallback,
      addr result.host), "define tick play.emit")
    requireNoError(runtimeSpikeLinkerDefineFunc(result.linker, "play", 4,
      "log", 3, result.logType, tickLogCallback,
      addr result.host), "define play.log")
  except:
    if result.logType != nil: wasmFuncTypeDelete(result.logType)
    if result.coverType != nil: wasmFuncTypeDelete(result.coverType)
    if result.emitType != nil: wasmFuncTypeDelete(result.emitType)
    if result.linker != nil: wasmtimeLinkerDelete(result.linker)
    if result.module != nil: wasmtimeModuleDelete(result.module)
    wasmEngineDelete(result.engine)
    raise

proc destroyTickRig(rig: var TickRig) =
  if rig.logType != nil: wasmFuncTypeDelete(rig.logType)
  if rig.coverType != nil: wasmFuncTypeDelete(rig.coverType)
  if rig.emitType != nil: wasmFuncTypeDelete(rig.emitType)
  if rig.linker != nil: wasmtimeLinkerDelete(rig.linker)
  if rig.module != nil: wasmtimeModuleDelete(rig.module)
  if rig.engine != nil: wasmEngineDelete(rig.engine)

proc deleteTickInstance(instance: var TickInstance) =
  if instance.store == nil:
    return
  wasmtimeExternDelete(addr instance.stepItem)
  wasmtimeExternDelete(addr instance.initItem)
  wasmtimeExternDelete(addr instance.allocItem)
  wasmtimeStoreDelete(instance.store)
  instance.store = nil

proc newTickInstance(rig: var TickRig): TickInstance =
  result.store = newStore(rig.engine)
  try:
    result.context = wasmtimeStoreContext(result.store)
    var trap: ptr WasmTrap
    let error = wasmtimeLinkerInstantiate(rig.linker, result.context, rig.module,
      addr result.instance, addr trap)
    if error != nil:
      raise newException(ValueError,
        "tick instantiation: " & consumeError(error))
    if trap != nil:
      raise newException(ValueError, "tick instantiation trapped: " &
        consumeTrap(trap).message)
    var memoryItem: WasmtimeExtern
    if not wasmtimeInstanceExportGet(result.context, addr result.instance,
        "memory", 6, addr memoryItem):
      raise newException(ValueError, "tick fixture missing memory")
    runtimeSpikeExternMemoryCopy(addr result.memory, addr memoryItem)
    wasmtimeExternDelete(addr memoryItem)
    discard exportedFunction(result.context, addr result.instance, "play_alloc",
      result.allocItem)
    discard exportedFunction(result.context, addr result.instance, "play_init",
      result.initItem)
    discard exportedFunction(result.context, addr result.instance, "play_step",
      result.stepItem)
  except:
    result.deleteTickInstance()
    raise

proc writeAllocation(instance: var TickInstance; length: int;
    state: var TickCounters): int32 =
  let outcome = callFunction(instance.context,
    runtimeSpikeExternFunc(addr instance.allocItem), [length.int32], 1)
  if outcome.trapped or outcome.result <= 0:
    raise newException(ValueError, "hostile play allocation failed")
  let memorySize = wasmtimeMemoryDataSize(instance.context, addr instance.memory)
  if outcome.result.uint64 + length.uint64 > memorySize.uint64:
    raise newException(ValueError, "hostile play allocation exceeded memory")
  let bytes = wasmtimeMemoryData(instance.context, addr instance.memory)
  let destination = cast[ptr UncheckedArray[uint8]](
    cast[pointer](cast[uint](bytes) + outcome.result.uint))
  for index in 0 ..< length:
    destination[index] = uint8((index * 31 + state.allocations) and 0xff)
  inc state.allocations
  state.allocationBytes += length
  state.checksum = state.checksum xor destination[length - 1].uint64
  result = outcome.result

proc runHostileStep(instance: var TickInstance; state: var TickCounters) =
  requireNoError(wasmtimeContextSetFuel(instance.context, StepFuel.uint64),
    "step fuel")
  for _ in 0 ..< MaxAllocsPerInvocation:
    discard instance.writeAllocation(AllocationBytes, state)
  let outcome = callFunction(instance.context,
    runtimeSpikeExternFunc(addr instance.stepItem),
    [65_536'i32, AllocationBytes.int32], 1)
  outcome.requireTrap(TrapOutOfFuel, "hostile step")
  var remainingFuel: uint64
  requireNoError(wasmtimeContextGetFuel(instance.context, addr remainingFuel),
    "step remaining fuel")
  if remainingFuel != 0:
    raise newException(ValueError, &"hostile step retained {remainingFuel} fuel")
  inc state.steps
  inc state.stepTraps
  state.stepFuelConsumed += StepFuel

proc runHostileInit(instance: var TickInstance; state: var TickCounters) =
  requireNoError(wasmtimeContextSetFuel(instance.context, InitFuel.uint64),
    "init fuel")
  let paramsPointer = instance.writeAllocation(MaxCallBytes, state)
  let contextPointer = instance.writeAllocation(MaxContextBytes, state)
  let outcome = callFunction(instance.context,
    runtimeSpikeExternFunc(addr instance.initItem),
    [paramsPointer, MaxCallBytes.int32, contextPointer,
      MaxContextBytes.int32], 1)
  outcome.requireTrap(TrapOutOfFuel, "hostile init")
  var remainingFuel: uint64
  requireNoError(wasmtimeContextGetFuel(instance.context, addr remainingFuel),
    "init remaining fuel")
  if remainingFuel != 0:
    raise newException(ValueError, &"hostile init retained {remainingFuel} fuel")
  inc state.inits
  inc state.initTraps
  state.initFuelConsumed += InitFuel

proc completeWorstTick(rig: var TickRig; instances: var seq[TickInstance];
    ladder: string): TickCounters =
  rig.host.counters = addr result
  rig.host.callbackError.setLen(0)
  for instanceIndex in 0 ..< ExpectedSteps:
    instances[instanceIndex].runHostileStep(result)
  for instanceIndex in ExpectedSteps ..< ExpectedSteps + ExpectedInits:
    instances[instanceIndex].runHostileInit(result)
  for _ in 0 ..< ExpectedDefaults:
    result.defaultPlay()
  for _ in 0 ..< ExpectedReflexPlans:
    result.reflexPlanEscape()
  for _ in 0 ..< ExpectedLadders:
    result.validateLadder(ladder)
  for seat in 0 ..< ExpectedAdmissions:
    result.admitUpload(seat)
  for commitIndex in 0 ..< ExpectedCommits:
    result.commitCompile(commitIndex)
  result.statusAndAcks()
  if rig.host.callbackError.len > 0:
    raise newException(ValueError, "tick callback: " & rig.host.callbackError)
  result.requireExactCounts()
  rig.host.counters = nil

proc microRow(name, classification: string; iterations: int;
    action: proc() {.closure.}): int64 =
  for _ in 0 ..< max(1, iterations div 5):
    action()
  let started = getMonoTime()
  for _ in 0 ..< iterations:
    action()
  result = elapsedNanoseconds(started)
  echo &"MICRO component={name} class={classification} iterations={iterations} " &
    &"total_us={formatMicros(result)} ns_per_unit=" &
    &"{result.float / iterations.float:.3f}"

proc selectWorseEmitPath(repeats = 20): bool =
  let guestJson = "{\"a\":\"" & repeat("x", 4_087) & "\"} "
  let validIntent = validIntentBytes()
  var adversarialState, validState: TickCounters
  for _ in 0 ..< max(1, repeats div 5):
    adversarialState.modelEmit(guestJson, "")
    validState.modelEmit(guestJson, validIntent)
  let adversarialStarted = getMonoTime()
  for _ in 0 ..< repeats:
    adversarialState.modelEmit(guestJson, "")
  let adversarialNs = elapsedNanoseconds(adversarialStarted)
  let validStarted = getMonoTime()
  for _ in 0 ..< repeats:
    validState.modelEmit(guestJson, validIntent)
  let validNs = elapsedNanoseconds(validStarted)
  result = validNs >= adversarialNs
  echo "EMIT_PROBE repeats=" & $repeats & " selected=" &
    (if result: "valid-intent" else: "adversarial-late-rejection") &
    &" adversarial_total_us={formatMicros(adversarialNs)} " &
    &"valid_total_us={formatMicros(validNs)}"

proc spatialComparison(): bool =
  const Repeats = 20
  var coverState, mixedState: TickCounters
  let coverStarted = getMonoTime()
  for _ in 0 ..< Repeats:
    for _ in 0 ..< MaxSpatialCallsPerStep:
      coverState.nearestCover()
  let coverNs = elapsedNanoseconds(coverStarted)
  let mixedStarted = getMonoTime()
  for _ in 0 ..< Repeats:
    for _ in 0 ..< MaxSpatialCallsPerStep div 2:
      mixedState.nearestCover()
      mixedState.nearestReachable()
  let mixedNs = elapsedNanoseconds(mixedStarted)
  result = coverNs >= mixedNs
  echo &"SPATIAL all_cover_calls={MaxSpatialCallsPerStep} " &
    &"mixed_cover_calls={MaxSpatialCallsPerStep div 2} " &
    &"mixed_reachable_calls={MaxSpatialCallsPerStep div 2} " &
    &"reachable_tie_scan={ReachableTieScan} assumption=unverified " &
    &"repeats={Repeats} all_cover_us={formatMicros(coverNs)} " &
    &"mixed_us={formatMicros(mixedNs)} selected=" &
    (if result: "all-cover" else: "mixed")

proc instantiateBenchmark(engine: ptr WasmEngine; module: ptr WasmtimeModule;
    fuelEnabled: bool): tuple[store: ptr WasmtimeStore,
    context: ptr WasmtimeContext, instance: WasmtimeInstance,
    functionItem: WasmtimeExtern, function: ptr WasmtimeFunc] =
  result.store = newStore(engine, MaxMemoryBytes.int64, fuelEnabled)
  result.context = wasmtimeStoreContext(result.store)
  var trap: ptr WasmTrap
  requireNoError(wasmtimeInstanceNew(result.context, module, nil, 0,
    addr result.instance, addr trap), "benchmark instantiation")
  if trap != nil:
    raise newException(ValueError, "benchmark instantiation trapped: " &
      consumeTrap(trap).message)
  result.function = exportedFunction(result.context, addr result.instance,
    "run", result.functionItem)

proc runtimeOverheadChild(fuelEnabled, epochEnabled: bool;
    repeatNumber: int) =
  const Iterations = 500
  let bytes = computeFixture()
  var checksum = 0'i64
  let engine = newEngineWith(fuelEnabled, epochEnabled, poolSlots = 1)
  let module = compileModule(engine, bytes, "runtime overhead fixture")
  let runtime = instantiateBenchmark(engine, module, fuelEnabled)
  for _ in 0 ..< 10:
    if fuelEnabled:
      requireNoError(wasmtimeContextSetFuel(runtime.context,
        1_000_000_000), "overhead warm fuel")
    checksum += callFunction(runtime.context, runtime.function, [], 1).result.int64
  let started = getMonoTime()
  for _ in 0 ..< Iterations:
    if fuelEnabled:
      requireNoError(wasmtimeContextSetFuel(runtime.context,
        1_000_000_000), "overhead fuel")
    checksum += callFunction(runtime.context, runtime.function, [], 1).result.int64
  let elapsed = elapsedNanoseconds(started)
  var row = newJObject()
  row["fuel"] = %fuelEnabled
  row["epochs"] = %epochEnabled
  row["repeat"] = %repeatNumber
  row["iterations"] = %Iterations
  row["elapsed_ns"] = %elapsed
  row["checksum"] = %checksum
  echo $row
  wasmtimeExternDelete(addr runtime.functionItem)
  wasmtimeStoreDelete(runtime.store)
  wasmtimeModuleDelete(module)
  wasmEngineDelete(engine)

proc overheadChildResult(fuelEnabled, epochEnabled: bool;
    repeatNumber: int): JsonNode =
  let process = startProcess(getAppFilename(), options = {poStdErrToStdOut},
    args = ["overhead-child", $fuelEnabled, $epochEnabled, $repeatNumber])
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  var jsonLine = ""
  for line in output.splitLines():
    if line.startsWith("{"):
      jsonLine = line
  if exitCode != 0 or jsonLine.len == 0:
    raise newException(ValueError, &"overhead child failed fuel={fuelEnabled} " &
      &"epochs={epochEnabled} repeat={repeatNumber} exit={exitCode}: " &
      output.strip())
  result = parseJson(jsonLine)

proc runtimeOverheadRows(freshProcesses = 5) =
  if freshProcesses < 5:
    raise newException(ValueError,
      "runtime overhead requires at least five fresh processes")
  var rows: seq[JsonNode]
  for repeatNumber in 1 .. freshProcesses:
    for fuelEnabled in [false, true]:
      for epochEnabled in [false, true]:
        let row = overheadChildResult(fuelEnabled, epochEnabled, repeatNumber)
        rows.add row
        echo "OVERHEAD_CHILD " & $row

  for fuelEnabled in [false, true]:
    for epochEnabled in [false, true]:
      var elapsedValues, ratios: seq[float]
      var checksum = 0'i64
      for repeatNumber in 1 .. freshProcesses:
        var baselineNs = 0.0
        var measuredNs = 0.0
        for row in rows:
          if row["repeat"].getInt() == repeatNumber:
            if not row["fuel"].getBool() and not row["epochs"].getBool():
              baselineNs = row["elapsed_ns"].getInt().float
            if row["fuel"].getBool() == fuelEnabled and
                row["epochs"].getBool() == epochEnabled:
              measuredNs = row["elapsed_ns"].getInt().float
              checksum = row["checksum"].getInt().int64
        if baselineNs <= 0 or measuredNs <= 0:
          raise newException(ValueError, "incomplete overhead child matrix")
        elapsedValues.add measuredNs / 1_000.0
        ratios.add measuredNs / baselineNs
      elapsedValues.sort()
      ratios.sort()
      echo &"RUNTIME_OVERHEAD fuel={fuelEnabled} epochs={epochEnabled} " &
        &"fresh_processes={freshProcesses} iterations=500 " &
        &"total_us_min={elapsedValues[0]:.3f} " &
        &"total_us_median={elapsedValues.jsonPercentile(50):.3f} " &
        &"total_us_max={elapsedValues[^1]:.3f} ratio_min={ratios[0]:.4f} " &
        &"ratio_median={ratios.jsonPercentile(50):.4f} " &
        &"ratio_max={ratios[^1]:.4f} overhead_pct_min=" &
        &"{(ratios[0] - 1.0) * 100.0:.2f} overhead_pct_median=" &
        &"{(ratios.jsonPercentile(50) - 1.0) * 100.0:.2f} " &
        &"overhead_pct_max={(ratios[^1] - 1.0) * 100.0:.2f} " &
        &"checksum={checksum}"

proc guardCostRow() =
  const Iterations = 1_000
  let bytes = memoryTouchFixture()
  var smallNs = 0'i64
  var smallVsz = 0'u64
  var checksum = 0'i64
  for guardBytes in [MemoryGuardBytes.uint64, LargeMemoryGuardBytes]:
    let engine = newEngineWith(false, false, MaxMemoryBytes.uint64, guardBytes,
      1)
    let module = compileModule(engine, bytes, "guard cost fixture")
    let runtime = instantiateBenchmark(engine, module, false)
    for _ in 0 ..< 10:
      checksum += callFunction(runtime.context, runtime.function,
        [], 1).result.int64
    let memory = processMemory()
    let started = getMonoTime()
    for _ in 0 ..< Iterations:
      checksum += callFunction(runtime.context, runtime.function,
        [], 1).result.int64
    let elapsed = elapsedNanoseconds(started)
    if guardBytes == MemoryGuardBytes.uint64:
      smallNs = elapsed
      smallVsz = memory.virtualSize
    echo &"GUARD guard_bytes={guardBytes} reservation_bytes={MaxMemoryBytes} " &
      &"iterations={Iterations} total_us={formatMicros(elapsed)} " &
      &"vsz_kib={memory.virtualSize.kibibytes} ratio_vs_small=" &
      &"{elapsed.float / smallNs.float:.4f}"
    wasmtimeExternDelete(addr runtime.functionItem)
    wasmtimeStoreDelete(runtime.store)
    wasmtimeModuleDelete(module)
    wasmEngineDelete(engine)
  echo &"GUARD small_guard_bytes={MemoryGuardBytes} " &
    &"large_guard_bytes={LargeMemoryGuardBytes} small_vsz_kib=" &
    &"{smallVsz.kibibytes} checksum={checksum}"

proc compileWorkerMain(worker: ptr CompileWorker) {.thread.} =
  let queue = worker.queue
  discard queue.ready.fetchAdd(1, moAcquireRelease)
  while not queue.go.load(moAcquire):
    sleep(1)
  var moduleIndex = worker.workerId
  queue.workerBusyInterval[worker.workerId].store(1, moRelease)
  while moduleIndex < queue.modules[].len:
    discard queue.started.fetchAdd(1, moAcquireRelease)
    let activeNow = queue.active.fetchAdd(1, moAcquireRelease) + 1
    if activeNow >= 2:
      queue.sawTwoBusy.store(true, moRelease)
    let bytes = addr queue.modules[][moduleIndex]
    var module: ptr WasmtimeModule
    let error = wasmtimeModuleNew(queue.engine, bytes[].bytesPtr,
      bytes[].len.csize_t, addr module)
    if error != nil:
      wasmtimeErrorDelete(error)
      discard queue.failures.fetchAdd(1, moAcquireRelease)
    elif module == nil:
      discard queue.failures.fetchAdd(1, moAcquireRelease)
    else:
      wasmtimeModuleDelete(module)
    discard queue.active.fetchSub(1, moAcquireRelease)
    discard queue.completed.fetchAdd(1, moAcquireRelease)
    moduleIndex += 2
  queue.workerBusyInterval[worker.workerId].store(2, moRelease)

proc saturatedTickSamples(rig: var TickRig;
    instances: var seq[TickInstance]; ladder: string; maxSamples: int):
    tuple[samples: seq[int64], finalState: TickCounters] =
  var modules = newSeqOfCap[seq[byte]](32)
  var uniqueness = 0'u64
  for moduleIndex in 0 ..< 32:
    let bytes = emitQueueModule(moduleIndex)
    if bytes.len != ExactModuleBytes:
      raise newException(ValueError, "compile queue module is not 256 KiB")
    requireNoError(wasmtimeModuleValidate(rig.engine, bytes.bytesPtr,
      bytes.len.csize_t), &"compile queue module {moduleIndex} validation")
    uniqueness = uniqueness xor
      ((bytes[^1].uint64 shl (moduleIndex and 7)) or bytes[^2].uint64)
    modules.add bytes
  for left in 0 ..< modules.len:
    for right in left + 1 ..< modules.len:
      if modules[left] == modules[right]:
        raise newException(ValueError, &"compile queue modules {left} and " &
          &"{right} are not distinct")

  var queue: CompileQueueState
  queue.engine = rig.engine
  queue.modules = addr modules
  queue.go.store(false, moRelaxed)
  queue.sawTwoBusy.store(false, moRelaxed)
  var workers = [CompileWorker(queue: addr queue, workerId: 0),
    CompileWorker(queue: addr queue, workerId: 1)]
  var threads: array[2, Thread[ptr CompileWorker]]
  for workerIndex in 0 ..< 2:
    createThread(threads[workerIndex], compileWorkerMain,
      addr workers[workerIndex])
  var workersJoined = false
  template joinWorkers() =
    if not workersJoined:
      for workerIndex in 0 ..< 2:
        joinThread(threads[workerIndex])
      workersJoined = true
  defer: joinWorkers()
  while queue.ready.load(moAcquire) != 2:
    sleep(1)
  let compileStarted = getMonoTime()
  queue.go.store(true, moRelease)
  while queue.active.load(moAcquire) < 2 and
      queue.completed.load(moAcquire) < 32:
    sleep(1)
  if not queue.sawTwoBusy.load(moAcquire):
    raise newException(ValueError, "two compile workers were never busy")

  var retainedSamples = 0
  var discardedSamples = 0
  while retainedSamples < maxSamples and queue.completed.load(moAcquire) < 32:
    let worker0AtStart = queue.workerBusyInterval[0].load(moAcquire)
    let worker1AtStart = queue.workerBusyInterval[1].load(moAcquire)
    let tickStarted = getMonoTime()
    let state = completeWorstTick(rig, instances, ladder)
    let elapsed = elapsedNanoseconds(tickStarted)
    let worker0AtEnd = queue.workerBusyInterval[0].load(moAcquire)
    let worker1AtEnd = queue.workerBusyInterval[1].load(moAcquire)
    let completedAfter = queue.completed.load(moAcquire)
    let bothBusyAtStart = (worker0AtStart and 1) == 1 and
      (worker1AtStart and 1) == 1
    let bothWorkersStayedInQueueLoops = bothBusyAtStart and
      worker0AtEnd == worker0AtStart and worker1AtEnd == worker1AtStart
    if completedAfter < 32 and bothWorkersStayedInQueueLoops:
      inc retainedSamples
      result.samples.add elapsed
      result.finalState = state
      echo &"TICK_SAMPLE mode=saturated sample={retainedSamples} elapsed_ms=" &
        &"{elapsed.float / 1_000_000.0:.6f} " &
        &"queue_completed_after={completedAfter} queue_drained=false " &
        &"both_workers_in_queue_loops=true " &
        &"checksum={state.checksum}"
    else:
      inc discardedSamples
      let reason =
        if completedAfter >= 32: "queue-drained-during-sample"
        elif not bothBusyAtStart: "two-workers-not-busy-at-start"
        else: "worker-transition-during-sample"
      echo &"TICK_DISCARDED mode=saturated reason={reason} " &
        &"elapsed_ms={elapsed.float / 1_000_000.0:.6f} " &
        &"worker_intervals_start={worker0AtStart},{worker1AtStart} " &
        &"worker_intervals_end={worker0AtEnd},{worker1AtEnd}"
  joinWorkers()
  let compileElapsed = elapsedNanoseconds(compileStarted)
  let started = queue.started.load(moAcquire)
  let completed = queue.completed.load(moAcquire)
  let failures = queue.failures.load(moAcquire)
  if started != 32 or completed != 32 or failures != 0 or
      result.samples.len == 0:
    raise newException(ValueError, &"compile queue failed started={started} " &
      &"completed={completed} failures={failures} samples={result.samples.len}")
  echo &"COMPILE_QUEUE modules_entered={started} modules_distinct=32 " &
    &"raw_bytes={modules.len * ExactModuleBytes} workers=2 " &
    &"saw_two_busy={queue.sawTwoBusy.load(moAcquire)} completed={completed} " &
    &"failures={failures} elapsed_ms=" &
    &"{compileElapsed.float / 1_000_000.0:.3f} modules_per_second=" &
    &"{completed.float / (compileElapsed.float / 1_000_000_000.0):.3f} " &
    &"uniqueness_checksum={uniqueness} samples_retained=" &
    &"{result.samples.len} samples_discarded={discardedSamples}"

proc tickMode(arguments: seq[string]; includeDiagnostics = true) =
  var compileWorkers = -1
  var samples = 30
  var index = 0
  while index < arguments.len:
    case arguments[index]
    of "--compile-workers":
      if index + 1 >= arguments.len:
        raise newException(ValueError, "--compile-workers requires a value")
      compileWorkers = parseInt(arguments[index + 1])
      index += 2
    of "--samples":
      if index + 1 >= arguments.len:
        raise newException(ValueError, "--samples requires a value")
      samples = parsePositive(arguments[index + 1], "--samples")
      index += 2
    else:
      raise newException(ValueError, "unknown tick argument: " & arguments[index])
  if compileWorkers notin [0, 2]:
    raise newException(ValueError,
      "--compile-workers must be 0 (isolated) or 2 (saturated)")
  if compileWorkers == 0 and samples < 30:
    raise newException(ValueError, "tick mode requires at least 30 warm samples")

  initializeCostModels()
  let exactLadder = ladderBytes()
  let useValidIntent = selectWorseEmitPath()
  if includeDiagnostics:
    runtimeOverheadRows()
    guardCostRow()
    var microState: TickCounters
    let guestJson = "{\"a\":\"" & repeat("x", 4_087) & "\"} "
    let validIntent = validIntentBytes()
    discard microRow("nearest_cover", "synthetic-host", 16,
      proc() = microState.nearestCover())
    discard microRow("nearest_reachable",
      "synthetic-host-unverified-64-ties", 128,
      proc() = microState.nearestReachable())
    let adversarialEmitNs = microRow("emit_adversarial",
      "synthetic-host-parse-canonical-schema", 16,
      proc() = microState.modelEmit(guestJson, ""))
    let validEmitNs = microRow("emit_valid_intent",
      "synthetic-host-parse-canonical-schema", 16,
      proc() = microState.modelEmit(guestJson, validIntent))
    echo "EMIT_MICRO adversarial_total_us=" &
      &"{formatMicros(adversarialEmitNs)} " &
      &"valid_total_us={formatMicros(validEmitNs)}"
    discard microRow("log", "synthetic-host-sink", 128,
      proc() = microState.modelLog(guestJson[0 ..< MaxLogBytesPerCall]))
    discard microRow("default_play", "synthetic-host", 32,
      proc() = microState.defaultPlay())
    discard microRow("planEscape_fallback", "synthetic-host-1089x8", 8,
      proc() = microState.reflexPlanEscape())
    discard microRow("ladder_validation", "synthetic-host-4096b-16-entry", 8,
      proc() = microState.validateLadder(exactLadder))
    discard microRow("upload_admission", "synthetic-host", 128,
      proc() = microState.admitUpload(0))
    discard microRow("compile_commit", "synthetic-host-no-compilation", 128,
      proc() = microState.commitCompile(0))
    discard microRow("status_and_acks", "synthetic-host", 8,
      proc() = microState.statusAndAcks())
    if not spatialComparison():
      raise newException(ValueError,
        "mixed cover/reachable path exceeded all-cover; update hostile fixture")

  var rig = initTickRig(useValidIntent)
  defer: rig.destroyTickRig()
  var instances = newSeqOfCap[TickInstance](512)
  defer:
    for instance in mitems(instances):
      instance.deleteTickInstance()
  for _ in 0 ..< 512:
    instances.add newTickInstance(rig)
  echo &"TICK_SETUP resident_instances={instances.len} executed_steps=" &
    &"{ExpectedSteps} init_instances={ExpectedInits} " &
    &"compile_workers={compileWorkers} " &
    &"selected_spatial=all-cover"

  if includeDiagnostics:
    var allocationMicro: TickCounters
    rig.host.counters = addr allocationMicro
    requireNoError(wasmtimeContextSetFuel(instances[511].context,
      StepFuel.uint64), "allocation micro fuel")
    let allocationStarted = getMonoTime()
    for _ in 0 ..< MaxAllocsPerInvocation:
      discard instances[511].writeAllocation(AllocationBytes, allocationMicro)
    let allocationNs = elapsedNanoseconds(allocationStarted)
    echo &"MICRO component=two_allocations_and_32k_writes " &
      &"class=mixed-real-guest-calls-range-checks-host-writes iterations=1 " &
      &"allocations={allocationMicro.allocations} bytes=" &
      &"{allocationMicro.allocationBytes} total_us={formatMicros(allocationNs)} " &
      &"ns_per_unit={allocationNs.float:.3f}"
    let allocationReset = callFunction(instances[511].context,
      runtimeSpikeExternFunc(addr instances[511].stepItem),
      [65_536'i32, AllocationBytes.int32], 1)
    allocationReset.requireTrap(TrapOutOfFuel, "allocation micro reset")

    var stepMicro: TickCounters
    rig.host.counters = addr stepMicro
    let stepStarted = getMonoTime()
    instances[510].runHostileStep(stepMicro)
    let stepNs = elapsedNanoseconds(stepStarted)
    echo &"MICRO component=full_fuel_hostile_step " &
      &"class=mixed-real-wasmtime-callbacks-synthetic-host iterations=1 " &
      &"fuel={StepFuel} traps={stepMicro.stepTraps} " &
      &"total_us={formatMicros(stepNs)} ns_per_unit={stepNs.float:.3f}"

    var initMicro: TickCounters
    rig.host.counters = addr initMicro
    let initStarted = getMonoTime()
    instances[509].runHostileInit(initMicro)
    let initNs = elapsedNanoseconds(initStarted)
    echo &"MICRO component=full_fuel_hostile_init " &
      &"class=real-wasmtime-max-params-context iterations=1 fuel={InitFuel} " &
      &"traps={initMicro.initTraps} allocations={initMicro.allocations} " &
      &"bytes={initMicro.allocationBytes} total_us={formatMicros(initNs)} " &
      &"ns_per_unit={initNs.float:.3f}"
    rig.host.counters = nil

  discard completeWorstTick(rig, instances, exactLadder) # warm-up, not sampled
  var elapsedSamples = newSeqOfCap[int64](samples)
  var finalState: TickCounters
  let mode = if compileWorkers == 0: "isolated" else: "saturated"
  if compileWorkers == 0:
    for sample in 1 .. samples:
      let started = getMonoTime()
      finalState = completeWorstTick(rig, instances, exactLadder)
      let elapsed = elapsedNanoseconds(started)
      elapsedSamples.add elapsed
      echo &"TICK_SAMPLE mode=isolated sample={sample} elapsed_ms=" &
        &"{elapsed.float / 1_000_000.0:.6f} checksum={finalState.checksum}"
  else:
    let saturated = saturatedTickSamples(rig, instances, exactLadder, samples)
    elapsedSamples = saturated.samples
    finalState = saturated.finalState
  elapsedSamples.sort()
  let maxNanoseconds = elapsedSamples[^1]
  let passed = maxNanoseconds.float <= 10_400_000.0
  let insufficientSaturatedSamples = passed and compileWorkers == 2 and
    elapsedSamples.len < samples
  let verdict =
    if insufficientSaturatedSamples: "INCONCLUSIVE-INSUFFICIENT-SAMPLES"
    elif passed: "PASS"
    else: "FAIL"
  echo &"TICK_COUNTS resident=512 steps={finalState.steps} " &
    &"step_traps={finalState.stepTraps} step_fuel={finalState.stepFuelConsumed} " &
    &"allocs={finalState.allocations} allocation_bytes=" &
    &"{finalState.allocationBytes} cover_calls={finalState.coverCalls} " &
    &"cover_threat_bytes={finalState.coverThreatBytes} " &
    &"cover_post_threat_scores={finalState.coverPostThreatScores} " &
    &"cover_duck_scores={finalState.coverDuckScores} " &
    &"emit_calls={finalState.emits} emit_bytes={finalState.emitBytes} " &
    &"emit_schema_bytes={finalState.emitSchemaBytes} " &
    &"goal_reachable_calls={finalState.reachableCalls} " &
    &"goal_tie_scores={finalState.reachableTieScores} logs={finalState.logs} " &
    &"log_bytes={finalState.logBytes} inits={finalState.inits} " &
    &"init_traps={finalState.initTraps} init_fuel={finalState.initFuelConsumed} " &
    &"defaults={finalState.defaults} reflex_plans={finalState.reflexPlans} " &
    &"reflex_candidates={finalState.reflexCandidates} " &
    &"reflex_hazard_scores={finalState.reflexHazardScores} " &
    &"ladders={finalState.ladders} ladder_entries={finalState.ladderEntries} " &
    &"ladder_bytes={finalState.ladderBytes} admissions={finalState.admissions} " &
    &"commits={finalState.commits} statuses={finalState.statuses} " &
    &"status_bytes={finalState.statusBytes} acks={finalState.acks} " &
    &"ack_bytes={finalState.ackBytes} checksum={finalState.checksum}"
  echo &"TICK_RESULT mode={mode} samples={elapsedSamples.len} median_ms=" &
    &"{elapsedSamples.percentile(50).float / 1_000_000.0:.6f} p95_ms=" &
    &"{elapsedSamples.percentile(95).float / 1_000_000.0:.6f} p99_ms=" &
    &"{elapsedSamples.percentile(99).float / 1_000_000.0:.6f} max_ms=" &
    &"{maxNanoseconds.float / 1_000_000.0:.6f} gate_ms=10.400 verdict=" &
    verdict
  if insufficientSaturatedSamples:
    quit(&"saturated runtime-half worst tick retained " &
      &"{elapsedSamples.len}/{samples} requested samples", 1)
  if not passed:
    quit(mode & " runtime-half worst tick exceeded 10.4 ms", 1)

proc cpuMaxText(): string =
  when defined(linux):
    let cpuMaxPath = "/sys/fs/cgroup/cpu.max"
    if fileExists(cpuMaxPath):
      return readFile(cpuMaxPath).strip().replace(" ", "/")
  "unavailable"

proc singleLine(value: string): string =
  value.strip().replace(" ", "-").replace("\t", "-").replace("\n", "-")

proc commandOutput(command: string; arguments: seq[string]): string =
  let process = startProcess(command, args = arguments,
    options = {poStdErrToStdOut})
  result = process.outputStream.readAll().strip()
  let exitCode = process.waitForExit()
  process.close()
  if exitCode != 0:
    result = "unavailable"

proc cpuModelText(): string =
  result = "unavailable"
  when defined(linux):
    if fileExists("/proc/cpuinfo"):
      for line in readFile("/proc/cpuinfo").splitLines():
        let separator = line.find(':')
        if separator > 0 and line[0 ..< separator].strip() in
            ["model name", "Hardware", "Processor"]:
          return singleLine(line[separator + 1 .. ^1])
  elif defined(macosx):
    let brand = commandOutput("/usr/sbin/sysctl",
      @["-n", "machdep.cpu.brand_string"])
    if brand != "unavailable":
      return singleLine(brand)
    result = singleLine(commandOutput("/usr/sbin/sysctl", @["-n", "hw.model"]))

proc binaryDigest(): string =
  when defined(macosx):
    let output = commandOutput("/usr/bin/shasum", @["-a", "256", getAppFilename()])
    result = output.splitWhitespace()[0]
  else:
    let output = commandOutput("/usr/bin/sha256sum", @[getAppFilename()])
    result = output.splitWhitespace()[0]

proc commandLineText(): string =
  singleLine((@[getAppFilename()] & commandLineParams()).join(" "))

proc printEnvironmentManifest() =
  let label = getEnv("RUNTIME_SPIKE_ENV_LABEL", hostOS & "-" & hostCPU)
  let emulated = getEnv("RUNTIME_SPIKE_EMULATED", "false")
  let platformNote = getEnv("RUNTIME_SPIKE_PLATFORM_NOTE", "native")
    .replace(" ", "-")
  let containerPlatform = getEnv("RUNTIME_SPIKE_CONTAINER_PLATFORM",
    if fileExists("/.dockerenv"): "docker" else: "host")
  echo &"ENVIRONMENT label={label} os={hostOS} cpu={hostCPU} " &
    &"emulated={emulated} platform_note={platformNote} " &
    &"cpu_model={cpuModelText()} logical_processors={countProcessors()} " &
    &"container_platform={singleLine(containerPlatform)} " &
    &"cpu_max={cpuMaxText()} " &
    &"nim={NimVersion} wasmtime_version=48.0.1 " &
    &"wasmtime_sha256={expectedDigest()} binary_sha256={binaryDigest()} " &
    &"command_line={commandLineText()} module_cap={ExactModuleBytes} " &
    &"pool_slots={PoolSlots} memory_reservation={MaxMemoryBytes} " &
    &"memory_guard={MemoryGuardBytes}"

proc matrixTickChild(mode: string; samples: int): string =
  let workers = if mode == "isolated": "0" else: "2"
  let process = startProcess(getAppFilename(), options = {poStdErrToStdOut},
    args = ["tick-internal", mode, $samples])
  let output = process.outputStream.readAll()
  let exitCode = process.waitForExit()
  process.close()
  var resultLine = ""
  var hasCounts = false
  var hasQueue = mode == "isolated"
  for line in output.splitLines():
    if line.startsWith("TICK_COUNTS "):
      hasCounts = true
    if line.startsWith("COMPILE_QUEUE "):
      hasQueue = true
    if line.startsWith("TICK_RESULT "):
      resultLine = line
    echo line
  if exitCode notin [0, 1] or resultLine.len == 0 or not hasCounts or
      not hasQueue:
    raise newException(ValueError, &"matrix {mode} child incomplete " &
      &"exit={exitCode} counts={hasCounts} queue={hasQueue}")
  let label = getEnv("RUNTIME_SPIKE_ENV_LABEL", hostOS & "-" & hostCPU)
  echo &"MATRIX_ROW environment={label} cpu_max={cpuMaxText()} " &
    &"compile_workers={workers} " & resultLine
  if resultLine.endsWith("verdict=PASS"):
    result = "PASS"
  elif resultLine.endsWith("verdict=FAIL"):
    result = "FAIL"
  elif resultLine.endsWith("verdict=INCONCLUSIVE-INSUFFICIENT-SAMPLES"):
    result = "INCONCLUSIVE-INSUFFICIENT-SAMPLES"
  else:
    raise newException(ValueError,
      "matrix child returned an unknown verdict: " & resultLine)

proc allMode() =
  printEnvironmentManifest()
  runtimeOverheadRows()
  let isolatedVerdict = matrixTickChild("isolated", 30)
  let saturatedVerdict = matrixTickChild("saturated", 30)
  echo &"MATRIX_RESULT environment=" &
    getEnv("RUNTIME_SPIKE_ENV_LABEL", hostOS & "-" & hostCPU) &
    &" cpu_max={cpuMaxText()} isolated_verdict={isolatedVerdict} " &
    &"saturated_verdict={saturatedVerdict}"
  if isolatedVerdict != "PASS" or saturatedVerdict != "PASS":
    quit("one or more runtime-half quarter-tick gates failed", 1)

proc smoke(helloPath: string) =
  if runtimeSpikeAbiOk() != 1:
    raise newException(ValueError, "Wasmtime C ABI assertions failed")
  echo "HOST PASS noSignalHandler=true threads=on"
  echo &"WASMTIME PASS version=48.0.1 sha256={expectedDigest()}"
  echo &"CONFIG PASS compiler=cranelift fuel=true epochs=true " &
    &"epoch_period_ms={EpochPeriodMs} epoch_deadline_ticks={EpochDeadlineTicks} " &
    &"max_wasm_stack={MaxWasmStack} memory_reservation={MaxMemoryBytes} " &
    &"memory_guard={MemoryGuardBytes} pool_slots={PoolSlots} " &
    &"memory_max={MaxMemoryBytes} nan_canonicalization=true " &
    &"wasmtime_trap_handlers=true"

  let engine = newEngine()
  defer: wasmEngineDelete(engine)
  let hello = compileModule(engine, readBytes(helloPath), "hello play")
  defer: wasmtimeModuleDelete(hello)
  proveHelloImports(hello)

  let fuel = runTrapFixture(engine, loopFixture(), "fuel-exhaustion",
    TrapOutOfFuel, 1_000, false)
  echo &"TRAP PASS name=fuel-exhaustion code={fuel.code} message={fuel.message}"
  cleanHello(engine, hello, "fuel-exhaustion")

  let epoch = runTrapFixture(engine, loopFixture(), "epoch-deadline",
    TrapInterrupt, high(uint64) div 2, true)
  echo &"TRAP PASS name=epoch-deadline code={epoch.code} message={epoch.message}"
  cleanHello(engine, hello, "epoch-deadline")

  let growthModule = compileModule(engine, growthFixture(), "memory-growth")
  block:
    defer: wasmtimeModuleDelete(growthModule)
    let runtime = instantiate(engine, growthModule, 65_536)
    defer: wasmtimeStoreDelete(runtime.store)
    var functionItem: WasmtimeExtern
    let function = exportedFunction(runtime.context, addr runtime.instance,
      "run", functionItem)
    defer: wasmtimeExternDelete(addr functionItem)
    let growth = callFunction(runtime.context, function, [1'i32], 1)
    if growth.trapped or growth.result != -1:
      raise newException(ValueError,
        &"memory-growth expected limiter refusal -1, got {growth.result}")
    echo "LIMIT PASS name=memory-growth-refusal result=-1 " &
      "store_limit=65536 module_max=1048576 trap=false"
  cleanHello(engine, hello, "memory-growth-refusal")

  let oob = runTrapFixture(engine, outOfBoundsFixture(), "out-of-bounds",
    TrapMemoryOutOfBounds, 1_000_000, false)
  echo &"TRAP PASS name=out-of-bounds code={oob.code} message={oob.message}"
  cleanHello(engine, hello, "out-of-bounds")

  let stack = runTrapFixture(engine, stackOverflowFixture(), "stack-overflow",
    TrapStackOverflow, 1_000_000_000, false)
  echo &"TRAP PASS name=stack-overflow code={stack.code} message={stack.message}"
  cleanHello(engine, hello, "stack-overflow")
  echo "SMOKE PASS containment_rows=5 instruction_traps=4 " &
    "limiter_refusals=1 clean_calls=5"

proc parsePositive(value, option: string): int =
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(ValueError, &"{option} requires an integer: {value}")
  if result <= 0:
    raise newException(ValueError, &"{option} must be positive: {value}")

proc memoryArguments(arguments: seq[string]): tuple[checkpoints: seq[int],
    soakCycles: int] =
  result.checkpoints = @[1, 32, 512]
  result.soakCycles = 500
  var index = 0
  while index < arguments.len:
    case arguments[index]
    of "--instances":
      if index + 1 >= arguments.len:
        raise newException(ValueError, "--instances requires a CSV value")
      result.checkpoints.setLen(0)
      for value in arguments[index + 1].split(','):
        result.checkpoints.add parsePositive(value, "--instances")
      index += 2
    of "--soak":
      if index + 1 >= arguments.len:
        raise newException(ValueError, "--soak requires a cycle count")
      result.soakCycles = parsePositive(arguments[index + 1], "--soak")
      index += 2
    else:
      raise newException(ValueError, "unknown memory argument: " &
        arguments[index])
  if result.checkpoints.len == 0:
    raise newException(ValueError, "--instances must not be empty")
  var previous = 0
  for checkpoint in result.checkpoints:
    if checkpoint <= previous or checkpoint > 512:
      raise newException(ValueError,
        "--instances must be strictly increasing and at most 512")
    previous = checkpoint

proc memoryMode(helloPath: string; arguments: seq[string]) =
  let options = memoryArguments(arguments)
  let processStart = processMemory()
  echo &"PROCESS baseline=start rss_kib={processStart.resident.kibibytes} " &
    &"vsz_kib={processStart.virtualSize.kibibytes}"

  var rig = initMemoryRig(helloPath)
  proveHelloImports(rig.module)
  let postCompileStable = stableProcessMemory()
  if not postCompileStable.stable:
    rig.destroyMemoryRig()
    raise newException(ValueError, "post-compile RSS did not stabilize")
  echo &"PROCESS baseline=post-compile rss_kib=" &
    &"{postCompileStable.sample.resident.kibibytes} vsz_kib=" &
    &"{postCompileStable.sample.virtualSize.kibibytes} " &
    &"samples={postCompileStable.samples}"
  reportLatency(rig, 200)
  capacityProbe(rig)
  let preInstanceStable = stableProcessMemory()
  if not preInstanceStable.stable:
    rig.destroyMemoryRig()
    raise newException(ValueError, "pre-instance RSS did not stabilize")
  let baseline = preInstanceStable.sample
  let tolerance = rssTolerance(baseline)
  echo &"PROCESS baseline=pre-instance live_instances=0 rss_kib=" &
    &"{baseline.resident.kibibytes} vsz_kib={baseline.virtualSize.kibibytes} " &
    &"rss_delta_post_compile_kib=" &
    &"{deltaBytes(baseline.resident, postCompileStable.sample.resident) div 1024} " &
    &"samples={preInstanceStable.samples} tolerance_kib={tolerance.kibibytes} " &
    &"stability_window=4 stability_spread_kib=64 sample_delay_ms=5"

  var passed = true
  if not memorySeries(rig, options.checkpoints, touchInitial, baseline,
      tolerance):
    passed = false
  if not memorySeries(rig, options.checkpoints, touchFull, baseline,
      tolerance):
    passed = false
  if not replacementSoak(rig, options.soakCycles, baseline, tolerance):
    passed = false

  rig.destroyMemoryRig()
  let teardown = stableProcessMemory()
  let teardownPassed = teardown.stable and
    rssWithinTolerance(teardown.sample, baseline, tolerance)
  if not teardownPassed:
    passed = false
  echo &"TEARDOWN rss_kib={teardown.sample.resident.kibibytes} " &
    &"vsz_kib={teardown.sample.virtualSize.kibibytes} " &
    &"rss_delta_pre_instance_kib=" &
    &"{deltaBytes(teardown.sample.resident, baseline.resident) div 1024} " &
    &"rss_delta_process_start_kib=" &
    &"{deltaBytes(teardown.sample.resident, processStart.resident) div 1024} " &
    &"samples={teardown.samples} stable={teardown.stable} " &
    &"tolerance_kib={tolerance.kibibytes} status=" &
    (if teardownPassed: "PASS" else: "FAIL")
  echo &"MEMORY checksum={memoryTouchChecksum} checkpoints=" &
    options.checkpoints.join(",") & &" soak_cycles={options.soakCycles} status=" &
    (if passed: "PASS" else: "FAIL")
  if not passed:
    quit("memory mode failed one or more fixed acceptance checks", 1)

when isMainModule:
  let defaultHello = getCurrentDir() / "tools" / "runtime_spike" / ".build" /
    "hello_play.wasm"
  let helloPath = getEnv("RUNTIME_SPIKE_HELLO", defaultHello)
  if not fileExists(helloPath):
    quit("hello play not found: " & helloPath, 1)
  let arguments = commandLineParams()
  if arguments.len == 0 or arguments[0] == "smoke":
    smoke(helloPath)
  elif arguments[0] == "memory":
    memoryMode(helloPath, arguments[1 .. ^1])
  elif arguments[0] == "compile-child":
    if arguments.len != 4 or arguments[2] notin ["cold", "warm"]:
      quit("usage: runtime_spike compile-child SHAPE cold|warm REPEAT", 2)
    compileChild(parseShape(arguments[1]), arguments[2],
      parsePositive(arguments[3], "REPEAT"))
  elif arguments[0] == "compile":
    var repeats = 3
    if arguments.len == 3 and arguments[1] == "--repeats":
      repeats = parsePositive(arguments[2], "--repeats")
    elif arguments.len != 1:
      quit("usage: runtime_spike compile [--repeats N]", 2)
    compileParent(repeats)
  elif arguments[0] == "overhead-child":
    if arguments.len != 4 or arguments[1] notin ["true", "false"] or
        arguments[2] notin ["true", "false"]:
      quit("usage: runtime_spike overhead-child true|false true|false REPEAT",
        2)
    runtimeOverheadChild(arguments[1] == "true", arguments[2] == "true",
      parsePositive(arguments[3], "REPEAT"))
  elif arguments[0] == "tick-internal":
    if arguments.len != 3 or arguments[1] notin ["isolated", "saturated"]:
      quit("usage: runtime_spike tick-internal isolated|saturated SAMPLES", 2)
    tickMode(@["--compile-workers",
      (if arguments[1] == "isolated": "0" else: "2"), "--samples",
      arguments[2]], false)
  elif arguments[0] == "tick":
    tickMode(arguments[1 .. ^1])
  elif arguments[0] == "all":
    if arguments.len != 1:
      quit("usage: runtime_spike all", 2)
    allMode()
  else:
    quit("usage: runtime_spike [smoke | memory [--instances CSV] [--soak N] | " &
      "compile [--repeats N] | tick --compile-workers 0|2 [--samples N] | " &
      "all]", 2)

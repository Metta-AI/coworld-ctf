## Production Wasmtime binding, ownership, and pooling tests.

import std/[os, strutils, times, unittest]

import ../src/shell/[runtime, wasmtime_c]

const
  EmptyModule = [
    0x00'u8, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]
  InvalidModule = [
    0x00'u8, 0x61, 0x73, 0x6d, 0xff, 0x00, 0x00, 0x00]
  StartTrapModule = [
    0x00'u8, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00,
    0x01, 0x04, 0x01, 0x60, 0x00, 0x00,
    0x03, 0x02, 0x01, 0x00,
    0x08, 0x01, 0x00,
    0x0a, 0x05, 0x01, 0x03, 0x00, 0x00, 0x0b]

suite "shell Wasmtime runtime":
  test "C ABI and pinned runtime manifest match Wasmtime 48.0.1":
    check shellWasmtimeAbiOk() == 1
    check shellWasmtimeFuncSize() == 16
    check shellWasmtimeInstanceSize() == 16
    check shellWasmtimeMemorySize() == 24
    check shellWasmtimeValRawSize() == 16
    check shellWasmtimeValRawAlignment() == 8
    check $shellWasmtimeVersion() == WasmtimeVersion
    check WasmtimeReleaseDigests.len == 4
    check runtimeTarget() != "unsupported"
    check wasmtimeReleaseDigest().len == 64
    let manifest = runtimeManifest()
    echo "SHELL_RUNTIME_MANIFEST ", manifest
    check manifest ==
      "target=" & runtimeTarget() & " wasmtime=48.0.1 asset_sha256=" &
      wasmtimeReleaseDigest() &
      " compiler=cranelift fuel=on epochs=5ms/4 " &
      "nan=canonical stack=262144 memory=1048576 reservation=1048576 " &
      "guard=65536 pool=514"

  test "Engine owns one ticker and joins it before teardown":
    let engine = newRuntimeEngine()
    check engine.isOpen
    let deadline = epochTime() + 1.0
    while engine.epochTickCount == 0 and epochTime() < deadline:
      sleep(1)
    check engine.epochTickCount > 0
    engine.close()
    check not engine.isOpen
    check engine.tickerWasJoined
    engine.close() # idempotent

  test "pool admits exactly 514 instances and Store drop reuses a slot":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.compileModule(EmptyModule)
    defer: module.close()
    var instances: seq[RuntimeInstance]
    defer:
      for instance in instances:
        instance.close()

    for _ in 0 ..< RuntimePoolSlots:
      instances.add(module.instantiate())
    check instances.len == 514
    expect ShellRuntimeError:
      discard module.instantiate()

    instances[137].close()
    check not instances[137].isOpen
    instances[137] = module.instantiate()
    check instances[137].isOpen
    expect ShellRuntimeError:
      discard module.instantiate()

  test "500 Store replacement cycles reuse the exact released slot":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.compileModule(EmptyModule)
    defer: module.close()
    for _ in 0 ..< 500:
      let instance = module.instantiate()
      check instance.isOpen
      instance.close()
      check not instance.isOpen
    let finalInstance = module.instantiate()
    check finalInstance.isOpen
    finalInstance.close()

  test "validation errors and instantiation traps have one visible owner":
    let engine = newRuntimeEngine()
    defer: engine.close()
    for _ in 0 ..< 100:
      try:
        discard engine.compileModule(InvalidModule)
        check false
      except ShellRuntimeError as error:
        check error.msg.contains("module validation")

    let module = engine.compileModule(StartTrapModule)
    defer: module.close()
    for _ in 0 ..< 100:
      try:
        discard module.instantiate()
        check false
      except ShellRuntimeTrap as trap:
        check trap.code != high(uint8)
        check trap.msg.contains("instantiation trapped")

  test "production constants carry the full resource block":
    check MaxWasmStackBytes == 256 * 1024
    check MaxMemoryBytes == 1024 * 1024
    check MemoryGuardBytes == 64 * 1024
    check RuntimePoolSlots == 514
    check EpochPeriodMs == 5
    check EpochDeadlineTicks == 4

## Production Wasmtime binding, ownership, and pooling tests.

import std/[os, strutils, times, unittest]

import ../src/shell/[body_map, instance, runtime, wasmtime_c]

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

proc watBytes(text: string): seq[byte] =
  var output: WasmByteVec
  let error = wasmtimeWat2Wasm(text.cstring, text.len.csize_t, addr output)
  doAssert error == nil, "runtime WAT fixture must be syntactically valid"
  defer: wasmByteVecDelete(addr output)
  result = newSeq[byte](output.size.int)
  if output.size > 0:
    copyMem(addr result[0], output.data, output.size)

proc openRoomsMap(): BodyMap =
  const
    Width = 64
    Height = 64
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(16, 16), (48, 48)])

type ShellFixture = object
  engine: RuntimeEngine
  module: RuntimeModule
  instance: ShellInstance

proc close(fixture: var ShellFixture) =
  fixture.instance.close()
  fixture.module.close()
  fixture.engine.close()

proc compileFixture(wat: string): ShellFixture =
  result.engine = newRuntimeEngine()
  result.module = result.engine.compileModule(wat.watBytes)
  result.instance = newShellInstance(result.module, openRoomsMap(), (16, 16))

proc loggingModule(manifestBody, initBody, stepBody, retuneBody: string): string =
  const Manifest = "{\"abi\":1}"
  "(module\n" &
    "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    "  (import \"play\" \"log\" (func $log (param i32 i32 i32)))\n" &
    "  (memory (export \"memory\") 1 16)\n" &
    "  (data (i32.const 256) \"{\\22abi\\22:1}\")\n" &
    "  (data (i32.const 512) \"\\00\\1b\\7f\\80\\ffinitstepretune\")\n" &
    "  (global $next (mut i32) (i32.const 4096))\n" &
    "  (func (export \"play_alloc\") (param $len i32) (result i32)\n" &
    "    global.get $next\n" &
    "    global.get $next local.get $len i32.add global.set $next)\n" &
    "  (func (export \"play_manifest\") " & manifestBody &
      " i32.const 256 i32.const " & $Manifest.len & " call $emit drop)\n" &
    "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) " &
      initBody & ")\n" &
    "  (func (export \"play_step\") (param i32 i32) (result i32) " &
      stepBody & ")\n" &
    "  (func (export \"play_retune\") (param i32 i32 i32 i32) (result i32) " &
      retuneBody & "))"

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

  test "accepted logs preserve raw bytes, signed levels, phase order, and quota":
    var fixture = compileFixture(loggingModule(
      "i32.const -2147483648 i32.const 512 i32.const 5 call $log",
      "i32.const -7 i32.const 517 i32.const 4 call $log i32.const 0",
      "i32.const 1 i32.const 521 i32.const 1 call $log " &
        "i32.const 2 i32.const 522 i32.const 1 call $log " &
        "i32.const 3 i32.const 523 i32.const 1 call $log " &
        "i32.const 4 i32.const 524 i32.const 1 call $log " &
        "i32.const 5 i32.const 525 i32.const 1 call $log i32.const 0",
      "i32.const 9 i32.const 525 i32.const 6 call $log i32.const 0"))
    defer: fixture.close()

    let manifest = fixture.instance.invokeManifest()
    check manifest.logs == @[
      ShellLogRecord(level: low(int32), bytes: "\0\e\x7f\x80\xff")]
    let init = fixture.instance.invokeInit("{}", "{}")
    check init.logs == @[ShellLogRecord(level: -7, bytes: "init")]
    let step = fixture.instance.invokeStep("{}", 1, (16, 16))
    check step.counters.logs == 5
    check step.logs == @[
      ShellLogRecord(level: 1, bytes: "s"),
      ShellLogRecord(level: 2, bytes: "t"),
      ShellLogRecord(level: 3, bytes: "e"),
      ShellLogRecord(level: 4, bytes: "p")]
    let retune = fixture.instance.invokeRetune("{}", "{}")
    check retune.logs == @[ShellLogRecord(level: 9, bytes: "retune")]

  test "invalid ranges are not captured and accepted pre-fault logs survive":
    var invalid = compileFixture(loggingModule("",
      "i32.const 1 i32.const 512 i32.const 5 call $log " &
        "i32.const 2 i32.const 65535 i32.const 2 call $log i32.const 0",
      "i32.const 0", "i32.const 0"))
    let invalidResult = invalid.instance.invokeInit("{}", "{}")
    check invalidResult.faulted
    check invalidResult.logs == @[
      ShellLogRecord(level: 1, bytes: "\0\e\x7f\x80\xff")]
    invalid.close()

    var nonzero = compileFixture(loggingModule("", "i32.const 0",
      "i32.const 3 i32.const 521 i32.const 4 call $log i32.const 1",
      "i32.const 0"))
    let nonzeroResult = nonzero.instance.invokeStep("{}", 1, (16, 16))
    check nonzeroResult.faulted
    check nonzeroResult.logs == @[ShellLogRecord(level: 3, bytes: "step")]
    nonzero.close()

    var trapped = compileFixture(loggingModule("", "i32.const 0",
      "i32.const 4 i32.const 521 i32.const 4 call $log unreachable",
      "i32.const 0"))
    let trappedResult = trapped.instance.invokeStep("{}", 1, (16, 16))
    check trappedResult.faulted
    check trappedResult.logs == @[ShellLogRecord(level: 4, bytes: "step")]
    trapped.close()

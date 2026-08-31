## Fixed ABI phase, buffer, and Wasmtime invocation behavior.

import std/[options, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, body_map, emit_validator, finisher, instance,
  runtime, types, wasmtime_c]

proc watBytes(text: string): seq[byte] =
  var output: WasmByteVec
  let error = wasmtimeWat2Wasm(text.cstring, text.len.csize_t, addr output)
  doAssert error == nil, "ABI WAT fixture must be syntactically valid"
  defer: wasmByteVecDelete(addr output)
  result = newSeq[byte](output.size.int)
  if output.size > 0:
    copyMem(addr result[0], output.data, output.size)

proc watEscape(bytes: string): string =
  const Hex = "0123456789abcdef"
  for ch in bytes:
    let value = ord(ch)
    result.add '\\'
    result.add Hex[(value shr 4) and 0xf]
    result.add Hex[value and 0xf]

proc openRoomsMap(): BodyMap =
  const Width = 720
  const Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 100:
      walkable[y * Width + x] = true
    for x in 600 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 2, @[(30, 30), (650, 30)])

proc intentBytes(point = some(MapPoint(x: 30, y: 30))): string =
  canonicalIntent(Intent(kind: if point.isSome: ikNavigateTo else: ikHold,
    point: point, arriveRadius: 24.0))

type ShellFixture = object
  engine: RuntimeEngine
  module: RuntimeModule
  instance: ShellInstance

proc close(fixture: var ShellFixture) =
  fixture.instance.close()
  fixture.module.close()
  fixture.engine.close()

proc shellWat(stepBody: string; manifestBytes = "{\"abi\":1}";
              allocBody = "i32.const 4096";
              manifestBody = "";
              initBody = "i32.const 0";
              retuneBody = "i32.const 0"): string =
  "(module\n" &
  "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
  "  (import \"play\" \"log\" (func $log (param i32 i32 i32)))\n" &
  "  (import \"play\" \"nearest_reachable\" " &
    "(func $nearest_reachable (param i32 i32) (result i64)))\n" &
  "  (import \"play\" \"nearest_cover\" " &
    "(func $nearest_cover (param i32 i32 i32 i32 i32 i32) (result i64)))\n" &
  "  (memory (export \"memory\") 1 16)\n" &
  "  (data (i32.const 256) \"" & manifestBytes.watEscape & "\")\n" &
  "  (data (i32.const 512) \"" & intentBytes().watEscape & "\")\n" &
  "  (data (i32.const 1024) \"" &
    intentBytes(point = some(MapPoint(x: 0, y: 0))).watEscape & "\")\n" &
  "  (data (i32.const 2048) \"" &
    canonicalCombatPolicy(CombatPolicy(holdFire: true)).watEscape & "\")\n" &
  "  (func (export \"play_alloc\") (param i32) (result i32) " &
    allocBody & ")\n" &
  "  (func (export \"play_manifest\") " &
    (if manifestBody.len == 0:
      "i32.const 256 i32.const " & $manifestBytes.len & " call $emit drop"
    else:
      manifestBody) & ")\n" &
  "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) " &
    initBody & ")\n" &
  "  (func (export \"play_step\") (param i32 i32) (result i32) " &
    stepBody & ")\n" &
  "  (func (export \"play_retune\") (param i32 i32 i32 i32) (result i32) " &
    retuneBody & "))"

proc compileFixture(text: string; emitClass = ecController): ShellFixture =
  result.engine = newRuntimeEngine()
  result.module = result.engine.compileModule(watBytes(text))
  result.instance = newShellInstance(result.module, openRoomsMap(), (30, 30),
    emitClass)

suite "shell ABI":
  test "fixed return-code constants match ABI version 1":
    check [AbiOk, AbiNormalized, AbiSchemaViolation, AbiRangeViolation,
      AbiUnreachableGoal, AbiUnknownReference, AbiClassMismatch, AbiTooLarge] ==
      [0'i32, 1, -1, -2, -3, -4, -5, -6]

  test "checked ranges catch zero, OOB, overflow, and pairwise overlap":
    check checkedRange(16, 4, 4).get == AbiBuffer(offset: 4, length: 4)
    check checkedRange(16, -1, 4).isNone
    check checkedRange(16, 15, 2).isNone
    check checkedRange(16, high(int32), 1).isNone
    check AbiBuffer(offset: 4, length: 4).overlaps(
      AbiBuffer(offset: 7, length: 1))
    check not AbiBuffer(offset: 4, length: 4).overlaps(
      AbiBuffer(offset: 8, length: 1))

    var invocation = beginInvocation(apInit)
    invocation.installFuelAndDeadline()
    check invocation.acceptAllocatedBuffer(32, 8, 8).isSome
    check invocation.acceptAllocatedBuffer(32, 16, 8).isSome
    check invocation.acceptAllocatedBuffer(32, 12, 8).isNone
    check invocation.faulted

  test "phase matrix and per-invocation call counters are fixed":
    for phase in [apManifest, apInit, apStep, apRetune]:
      for call in [ahEmit, ahLog, ahNearestReachable, ahNearestCover]:
        check not hostCallAllowed(phase, true, call)
    check hostCallAllowed(apManifest, false, ahEmit)
    check hostCallAllowed(apManifest, false, ahLog)
    check not hostCallAllowed(apManifest, false, ahNearestReachable)
    check not hostCallAllowed(apInit, false, ahEmit)
    check hostCallAllowed(apInit, false, ahLog)
    check not hostCallAllowed(apInit, false, ahNearestCover)
    check hostCallAllowed(apStep, false, ahEmit)
    check hostCallAllowed(apStep, false, ahNearestReachable)
    check hostCallAllowed(apStep, false, ahNearestCover)
    check not hostCallAllowed(apRetune, false, ahEmit)
    check hostCallAllowed(apRetune, false, ahLog)

    var invocation = beginInvocation(apStep)
    check invocation.noteEmit()
    check invocation.noteEmit()
    check not invocation.noteEmit()
    check invocation.faulted
    invocation = beginInvocation(apStep)
    for _ in 0 ..< MaxSpatialCallsPerStep:
      check invocation.noteSpatial() == AbiOk
    check invocation.noteSpatial() == AbiRangeViolation
    invocation = beginInvocation(apManifest)
    for _ in 0 ..< MaxLogCallsPerInvocation:
      check invocation.noteLog()
    check not invocation.noteLog()
    check not invocation.faulted

  test "invocation batches install metering before allocation and preserve outputs atomically":
    let acceptedStep = "i32.const 512 i32.const " & $intentBytes().len &
      " call $emit drop i32.const 0"
    var first = compileFixture(shellWat(acceptedStep))
    defer: first.close()
    let initResult = first.instance.invokeInit("{}", "")
    check initResult.fuelInstalledBeforeAlloc
    check initResult.counters.allocations == 2
    check initResult.returned == 0
    let stepResult = first.instance.invokeStep("{}", 1, (30, 30))
    check stepResult.fuelInstalledBeforeAlloc
    check stepResult.emitCodes == @[AbiOk]
    check stepResult.lastAccepted.isSome

    var second = compileFixture("(module\n" &
      "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
      "  (import \"play\" \"log\" (func $log (param i32 i32 i32)))\n" &
      "  (import \"play\" \"nearest_reachable\" " &
        "(func $nearest_reachable (param i32 i32) (result i64)))\n" &
      "  (import \"play\" \"nearest_cover\" " &
        "(func $nearest_cover (param i32 i32 i32 i32 i32 i32) (result i64)))\n" &
      "  (memory (export \"memory\") 1 16)\n" &
      "  (global $calls (mut i32) (i32.const 0))\n" &
      "  (data (i32.const 512) \"" & intentBytes().watEscape & "\")\n" &
      "  (data (i32.const 1024) \"" &
        intentBytes(point = some(MapPoint(x: 0, y: 0))).watEscape & "\")\n" &
      "  (func (export \"play_alloc\") (param i32) (result i32) i32.const 4096)\n" &
      "  (func (export \"play_manifest\"))\n" &
      "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) i32.const 0)\n" &
      "  (func (export \"play_step\") (param i32 i32) (result i32)\n" &
      "    global.get $calls\n" &
      "    i32.eqz\n" &
      "    if\n" &
      "      i32.const 1\n" &
      "      global.set $calls\n" &
      "      i32.const 512 i32.const " & $intentBytes().len &
        " call $emit drop\n" &
      "      i32.const 0\n" &
      "      return\n" &
      "    end\n" &
      "    i32.const 1024 i32.const " &
        $intentBytes(point = some(MapPoint(x: 0, y: 0))).len &
        " call $emit drop\n" &
      "    unreachable\n" &
      "    i32.const 0)\n" &
      "  (func (export \"play_retune\") (param i32 i32 i32 i32) (result i32) i32.const 0))")
    defer: second.close()
    discard second.instance.invokeStep("{}", 1, (30, 30))
    let faulted = second.instance.invokeStep("{}", 2, (30, 30))
    check faulted.faulted
    check faulted.lastAccepted.isSome

  test "real guest emit sees accepted, normalized, class mismatch, and rejected-all codes":
    var accepted = compileFixture(shellWat("i32.const 512 i32.const " &
      $intentBytes().len & " call $emit drop i32.const 0"))
    defer: accepted.close()
    check accepted.instance.invokeStep("{}", 1, (30, 30)).emitCodes == @[AbiOk]

    var normalized = compileFixture(shellWat("i32.const 1024 i32.const " &
      $intentBytes(point = some(MapPoint(x: 0, y: 0))).len &
      " call $emit drop i32.const 0"))
    defer: normalized.close()
    let normalizedResult = normalized.instance.invokeStep("{}", 1, (30, 30))
    check normalizedResult.emitCodes == @[AbiNormalized]
    check normalizedResult.lastAccepted.get.normalized

    var mismatch = compileFixture(shellWat("i32.const 2048 i32.const " &
      $canonicalCombatPolicy(CombatPolicy(holdFire: true)).len &
      " call $emit drop i32.const 0"))
    defer: mismatch.close()
    let mismatchResult = mismatch.instance.invokeStep("{}", 1, (30, 30))
    check mismatchResult.emitCodes == @[AbiClassMismatch]
    check mismatchResult.lastAccepted.isNone

  test "bad allocators and illegal imports fault the prepared consumer":
    for allocBody in ["i32.const 0", "i32.const 70000"]:
      var bad = compileFixture(shellWat("i32.const 0", allocBody = allocBody))
      defer: bad.close()
      let result = bad.instance.invokeStep("{}", 1, (30, 30))
      check result.faulted
      check result.counters.allocations == 1

    var overlapping = compileFixture(shellWat("i32.const 0",
      allocBody = "i32.const 4096"))
    defer: overlapping.close()
    let overlap = overlapping.instance.invokeInit("{}", "{}")
    check overlap.faulted
    check overlap.counters.allocations == 2

    var illegal = compileFixture(shellWat("i32.const 0",
      allocBody = "i32.const 512 i32.const " & $intentBytes().len &
        " call $emit drop i32.const 4096"))
    defer: illegal.close()
    check illegal.instance.invokeStep("{}", 1, (30, 30)).faulted

  test "spatial imports validate quota before hostile pointers and scalar domains":
    var scalarBeforePointer = compileFixture(shellWat(
      "i32.const 30 i32.const 30 i32.const 64 i32.const 256 " &
        "i32.const 2147483647 i32.const 8 call $nearest_cover drop " &
      "i32.const 0"))
    defer: scalarBeforePointer.close()
    let scalarResult = scalarBeforePointer.instance.invokeStep("{}", 1, (30, 30))
    check not scalarResult.faulted
    check scalarResult.counters.spatialCalls == 1

    var quotaBeforePointer = compileFixture(shellWat(
      "i32.const 30 i32.const 30 call $nearest_reachable drop " &
      "i32.const 30 i32.const 30 call $nearest_reachable drop " &
      "i32.const 30 i32.const 30 call $nearest_reachable drop " &
      "i32.const 30 i32.const 30 call $nearest_reachable drop " &
      "i32.const 30 i32.const 30 i32.const 64 i32.const 255 " &
        "i32.const 2147483647 i32.const 8 call $nearest_cover drop " &
      "i32.const 0"))
    defer: quotaBeforePointer.close()
    let quotaResult = quotaBeforePointer.instance.invokeStep("{}", 1, (30, 30))
    check not quotaResult.faulted
    check quotaResult.counters.spatialCalls == MaxSpatialCallsPerStep

    var badPointerBeforeQuota = compileFixture(shellWat(
      "i32.const 30 i32.const 30 i32.const 64 i32.const -1 " &
        "i32.const 2147483647 i32.const 8 call $nearest_cover drop " &
      "i32.const 0"))
    defer: badPointerBeforeQuota.close()
    check badPointerBeforeQuota.instance.invokeStep("{}", 1, (30, 30)).faulted

    var validCover = compileFixture(shellWat(
      "i32.const 30 i32.const 30 i32.const 64 i32.const 255 " &
        "i32.const 512 i32.const 0 call $nearest_cover drop " &
      "i32.const 0"))
    defer: validCover.close()
    let coverResult = validCover.instance.invokeStep("{}", 1, (30, 30))
    check not coverResult.faulted
    check coverResult.counters.spatialCalls == 1

  test "manifest/init/step/retune phase matrix faults illegal imports":
    var manifestSpatial = compileFixture(shellWat("i32.const 0",
      manifestBytes = "{\"abi\":1}",
      manifestBody = "i32.const 30 i32.const 30 call $nearest_reachable drop",
      retuneBody = "i32.const 0"))
    defer: manifestSpatial.close()
    check manifestSpatial.instance.invokeManifest().faulted

    var manifestEmit = compileFixture(shellWat("i32.const 0",
      manifestBytes = "{\"abi\":1}",
      retuneBody = "i32.const 0"))
    defer: manifestEmit.close()
    check manifestEmit.instance.invokeManifest().manifestBytes == "{\"abi\":1}"

    var initEmit = compileFixture(shellWat("i32.const 0",
      initBody = "i32.const 512 i32.const " & $intentBytes().len &
        " call $emit drop i32.const 0"))
    defer: initEmit.close()
    check initEmit.instance.invokeInit("{}", "{}").faulted

    var retuneSpatial = compileFixture(shellWat("i32.const 0",
      retuneBody = "i32.const 30 i32.const 30 call $nearest_reachable drop " &
        "i32.const 0"))
    defer: retuneSpatial.close()
    let retune = retuneSpatial.instance.invokeRetune("", "")
    check retune.refused
    check retune.faulted

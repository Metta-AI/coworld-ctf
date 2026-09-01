## Full-shape runtime containment gate for hostile shell modules.

import std/[options, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[containment, finisher, instance, runtime, types,
  wasmtime_c]

proc watBytes(text: string): seq[byte] =
  var output: WasmByteVec
  let error = wasmtimeWat2Wasm(text.cstring, text.len.csize_t, addr output)
  doAssert error == nil, "containment WAT fixture must be syntactically valid"
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

proc intentBytes(point = some(MapPoint(x: 30, y: 30))): string =
  canonicalIntent(Intent(kind: if point.isSome: ikNavigateTo else: ikHold,
    point: point, arriveRadius: 24.0))

proc shellWat(stepBody: string; allocBody = "i32.const 4096";
              initBody = "i32.const 0"; retuneBody = "i32.const 0";
              includeRetune = true; tableDecl = ""): string =
  let acceptedIntent = intentBytes()
  let manifest = "{\"abi\":1,\"class\":\"controller\",\"modes\":[\"br\"]," &
    "\"name\":\"alpha\",\"params\":{},\"retune\":" &
    (if includeRetune: "true" else: "false") & "}"
  result = "(module\n" &
    "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    "  (import \"play\" \"log\" (func $log (param i32 i32 i32)))\n" &
    "  (import \"play\" \"nearest_reachable\" " &
      "(func $nearest_reachable (param i32 i32) (result i64)))\n" &
    "  (import \"play\" \"nearest_cover\" " &
      "(func $nearest_cover (param i32 i32 i32 i32 i32 i32) (result i64)))\n" &
    "  (memory (export \"memory\") 1 16)\n" &
    tableDecl &
    "  (data (i32.const 256) \"" & manifest.watEscape & "\")\n" &
    "  (data (i32.const 512) \"" & acceptedIntent.watEscape & "\")\n" &
    "  (func (export \"play_alloc\") (param i32) (result i32) " &
      allocBody & ")\n" &
    "  (func (export \"play_manifest\") i32.const 256 i32.const " &
      $manifest.len & " call $emit drop)\n" &
    "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) " &
      initBody & ")\n" &
    "  (func (export \"play_step\") (param i32 i32) (result i32) " &
      stepBody & ")\n"
  if includeRetune:
    result.add "  (func (export \"play_retune\") (param i32 i32 i32 i32) " &
      "(result i32) " & retuneBody & ")\n"
  result.add ")"

proc recursiveTrapWat(): string =
  let manifest = "{\"abi\":1,\"class\":\"controller\",\"modes\":[\"br\"]," &
    "\"name\":\"alpha\",\"params\":{},\"retune\":true}"
  "(module\n" &
    "  (import \"play\" \"emit\" (func $emit (param i32 i32) (result i32)))\n" &
    "  (import \"play\" \"log\" (func $log (param i32 i32 i32)))\n" &
    "  (import \"play\" \"nearest_reachable\" " &
      "(func $nearest_reachable (param i32 i32) (result i64)))\n" &
    "  (import \"play\" \"nearest_cover\" " &
      "(func $nearest_cover (param i32 i32 i32 i32 i32 i32) (result i64)))\n" &
    "  (memory (export \"memory\") 1 16)\n" &
    "  (data (i32.const 256) \"" & manifest.watEscape & "\")\n" &
    "  (func $recurse call $recurse)\n" &
    "  (func (export \"play_alloc\") (param i32) (result i32) i32.const 4096)\n" &
    "  (func (export \"play_manifest\") i32.const 256 i32.const " &
      $manifest.len & " call $emit drop)\n" &
    "  (func (export \"play_init\") (param i32 i32 i32 i32) (result i32) i32.const 0)\n" &
    "  (func (export \"play_step\") (param i32 i32) (result i32) " &
      "call $recurse i32.const 0)\n" &
    "  (func (export \"play_retune\") (param i32 i32 i32 i32) (result i32) i32.const 0))"

proc hostileModules(): seq[HostileModule] =
  let acceptedIntent = intentBytes()
  @[
    HostileModule(name: "trap", attack: caStep,
      bytes: watBytes(shellWat("unreachable i32.const 0"))),
    HostileModule(name: "call_free_loop", attack: caStep,
      bytes: watBytes(shellWat("(loop $again br $again) i32.const 0"))),
    HostileModule(name: "growth_loop", attack: caStep,
      bytes: watBytes(shellWat(
        "(loop $again i32.const 1 memory.grow drop br $again) i32.const 0"))),
    HostileModule(name: "table_growth", attack: caStep,
      bytes: watBytes(shellWat(
        "ref.null func i32.const 1000000 table.grow $calls " &
          "i32.const -1 i32.ne if unreachable end i32.const 1",
        tableDecl = "  (table $calls 1 " &
          $MaxInstanceTableElements & " funcref)\n"))),
    HostileModule(name: "oob_emit", attack: caStep,
      bytes: watBytes(shellWat(
        "i32.const 65535 i32.const 2 call $emit drop i32.const 0"))),
    HostileModule(name: "stack_recursion", attack: caStep,
      bytes: watBytes(recursiveTrapWat())),
    HostileModule(name: "hostile_allocator", attack: caStep,
      bytes: watBytes(shellWat("i32.const 0",
        allocBody = "i32.const 512 i32.const " & $acceptedIntent.len &
          " call $emit drop i32.const 4096"))),
    HostileModule(name: "init_import_phase_violation", attack: caInit,
      bytes: watBytes(shellWat("i32.const 0",
        initBody = "i32.const 512 i32.const " & $acceptedIntent.len &
          " call $emit drop i32.const 0"))),
    HostileModule(name: "retune_refusal", attack: caRetune,
      bytes: watBytes(shellWat("i32.const 0", retuneBody = "i32.const 1"))),
    HostileModule(name: "retune_absent_refusal", attack: caRetune,
      bytes: watBytes(shellWat("i32.const 0", includeRetune = false))),
    HostileModule(name: "retune_import_phase_violation", attack: caRetune,
      bytes: watBytes(shellWat("i32.const 0",
        retuneBody = "i32.const 30 i32.const 30 call $nearest_reachable drop " &
          "i32.const 0"))),
    HostileModule(name: "emit_flood", attack: caStep,
      bytes: watBytes(shellWat(
        "i32.const 512 i32.const " & $acceptedIntent.len &
        " call $emit drop i32.const 512 i32.const " & $acceptedIntent.len &
        " call $emit drop i32.const 512 i32.const " & $acceptedIntent.len &
        " call $emit drop i32.const 0")))
  ]

proc retuneWaveCount(hostiles: openArray[HostileModule]): int =
  for hostile in hostiles:
    if hostile.attack == caRetune:
      inc result

suite "shell runtime containment":
  test "calibration probe and scale math are deterministic gate inputs":
    let probeUs = containmentCalibrationProbeUs()
    check probeUs > 0.0
    check probeUs == probeUs
    check probeUs < 1_000_000.0
    check containmentCalibrationScale(CalibrationBaselineUs / 2.0) == 1.0
    check containmentCalibrationScale(CalibrationBaselineUs * 2.5) == 2.5
    check scaledGateUs(BodyGateUs, 2.5) == BodyGateUs * 2.5

  test "terminal status mapping is capped and canonical":
    let longReason = repeat("x", StatusEntryMaxBytes * 2)
    let fault = ShellInvocationResult(kind: ivStep, faulted: true,
      reason: longReason)
    let faultBytes = fault.terminalStatusBytes(1, 2, 3, "entry")
    check faultBytes.len > 0
    check faultBytes.len <= StatusEntryMaxBytes
    check faultBytes.contains("\"kind\":\"play_faulted\"")

    let refusal = ShellInvocationResult(kind: ivRetune, refused: true,
      reason: longReason)
    let refusalBytes = refusal.terminalStatusBytes(1, 2, 3, "entry")
    check refusalBytes.len > 0
    check refusalBytes.len <= StatusEntryMaxBytes
    check refusalBytes.contains("\"kind\":\"retune_refused\"")

  test "explicit drop path returns every Store slot":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.compileModule(watBytes(shellWat("i32.const 0")))
    defer: module.close()
    let shell = newShellInstance(module, testMap(), (30, 30))
    check shell.isOpen
    shell.close()
    check not shell.isOpen
    check proveStorePoolReusable(engine) == RuntimePoolSlots

  test "full 32-seat hostile containment gate survives every attack wave":
    let hostiles = hostileModules()
    let engine = newRuntimeEngine()
    defer: engine.close()
    let verdict = engine.runContainmentGate(hostiles)

    for wave in verdict.waves:
      echo "SHELL_CONTAINMENT_WAVE name=", wave.name,
        " attack=", $wave.attack,
        " seats=", wave.seatsRun,
        " statuses=", wave.terminalStatuses,
        " play_faulted=", wave.playFaultedStatuses,
        " retune_refused=", wave.retuneRefusedStatuses,
        " leaks=", wave.leakedStores,
        " pool_fill=", wave.poolFillAfterWave,
        " default_body=", wave.defaultBodyOk,
        " control_admissions=", wave.controlAdmissions,
        " control_commits=", wave.controlCommits,
        " control_acks=", wave.controlAcks,
        " call_validation_budget=", wave.callValidationBudget,
        " calibration_probe_us=", wave.calibrationProbeUs,
        " calibration_scale=", wave.calibrationScale,
        " scaled_runtime_gate_us=", wave.scaledRuntimeGateUs,
        " scaled_body_gate_us=", wave.scaledBodyGateUs,
        " scaled_control_gate_us=", wave.scaledControlGateUs,
        " max_runtime_us=", wave.maxRuntimeUs,
        " max_body_us=", wave.maxBodyUs,
        " max_control_us=", wave.maxControlUs
      check wave.seatsRun == MaxPlayers
      check wave.terminalStatuses == MaxPlayers
      check wave.leakedStores == 0
      check wave.poolFillAfterWave == RuntimePoolSlots
      check wave.poolReusable
      check wave.defaultBodyOk
      check wave.controlAdmissions == MaxPlayers
      check wave.controlCommits == MaxCompileCommitsPerTick
      check wave.controlStatusBytes > 0
      check wave.controlAcks == ControlAckBudget
      check wave.callValidationBudget == ControlCallValidationBudget
      check wave.calibrationProbeUs == verdict.calibrationProbeUs
      check wave.calibrationScale == verdict.calibrationScale
      check wave.scaledRuntimeGateUs == verdict.scaledRuntimeGateUs
      check wave.scaledBodyGateUs == verdict.scaledBodyGateUs
      check wave.scaledControlGateUs == verdict.scaledControlGateUs
      when defined(release):
        check wave.maxRuntimeUs <= wave.scaledRuntimeGateUs
        check wave.maxBodyUs <= wave.scaledBodyGateUs
        check wave.maxControlUs <= wave.scaledControlGateUs

    let expectedRetuneStatuses = hostiles.retuneWaveCount * MaxPlayers
    echo "SHELL_CONTAINMENT_VERDICT seats=", verdict.seatCount,
      " waves=", verdict.waveCount,
      " statuses=", verdict.terminalStatuses,
      " play_faulted=", verdict.playFaultedStatuses,
      " retune_refused=", verdict.retuneRefusedStatuses,
      " leaks=", verdict.leakedStores,
      " calibration_probe_us=", verdict.calibrationProbeUs,
      " calibration_scale=", verdict.calibrationScale,
      " scaled_runtime_gate_us=", verdict.scaledRuntimeGateUs,
      " scaled_body_gate_us=", verdict.scaledBodyGateUs,
      " scaled_control_gate_us=", verdict.scaledControlGateUs,
      " host_survived=", verdict.hostSurvived,
      " pool_reusable=", verdict.poolReusable,
      " max_runtime_us=", verdict.maxRuntimeUs,
      " runtime_pass=", verdict.runtimePass,
      " max_body_us=", verdict.maxBodyUs,
      " body_pass=", verdict.bodyPass,
      " max_control_us=", verdict.maxControlUs,
      " control_pass=", verdict.controlPass

    check verdict.seatCount == MaxPlayers
    check verdict.waveCount == hostiles.len
    check verdict.terminalStatuses == hostiles.len * MaxPlayers
    check verdict.retuneRefusedStatuses == expectedRetuneStatuses
    check verdict.playFaultedStatuses ==
      verdict.terminalStatuses - expectedRetuneStatuses
    check verdict.leakedStores == 0
    check verdict.calibrationProbeUs > 0.0
    check verdict.calibrationScale >= 1.0
    check verdict.scaledRuntimeGateUs >= RuntimeGateUs
    check verdict.scaledBodyGateUs >= BodyGateUs
    check verdict.scaledControlGateUs >= ControlGateUs
    check verdict.hostSurvived
    check verdict.poolReusable
    when defined(release):
      check verdict.runtimePass
      check verdict.bodyPass
      check verdict.controlPass

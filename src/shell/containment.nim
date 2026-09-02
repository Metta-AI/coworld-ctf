## Full-shape runtime containment harness for Gate 3.
##
## This module is intentionally below packet decoding and above the server
## hook. It runs real RuntimeEngine/ShellInstance/BodyMap/CompilePlane work
## against already-admitted Wasm bytes and returns deterministic evidence rows.

import std/[math, options, strutils, times]
import bitworld/spriteprotocol

import ../ctf/sim_types
import body_map, body_nav, compile_plane, emit_validator, instance, module_cache,
  module_validation, runtime, standing_order, types

type
  ContainmentAttack* = enum
    caInit
    caStep
    caRetune

  HostileModule* = object
    name*: string
    attack*: ContainmentAttack
    bytes*: seq[byte]

  ContainmentWave* = object
    name*: string
    attack*: ContainmentAttack
    seatsRun*: int
    terminalStatuses*: int
    playFaultedStatuses*: int
    retuneRefusedStatuses*: int
    leakedStores*: int
    poolFillAfterWave*: int
    poolReusable*: bool
    hostSurvived*: bool
    defaultBodyOk*: bool
    controlAdmissions*: int
    controlCommits*: int
    controlStatusBytes*: int
    controlAcks*: int
    callValidationBudget*: int
    calibrationProbeUs*: float
    calibrationScale*: float
    scaledRuntimeGateUs*: float
    scaledBodyGateUs*: float
    scaledControlGateUs*: float
    maxRuntimeUs*: float
    maxBodyUs*: float
    maxControlUs*: float

  ContainmentVerdict* = object
    seatCount*: int
    waveCount*: int
    terminalStatuses*: int
    playFaultedStatuses*: int
    retuneRefusedStatuses*: int
    leakedStores*: int
    calibrationProbeUs*: float
    calibrationScale*: float
    scaledRuntimeGateUs*: float
    scaledBodyGateUs*: float
    scaledControlGateUs*: float
    maxRuntimeUs*: float
    maxBodyUs*: float
    maxControlUs*: float
    bodyPass*: bool
    runtimePass*: bool
    controlPass*: bool
    hostSurvived*: bool
    poolReusable*: bool
    waves*: seq[ContainmentWave]

const
  BodyGateUs* = 5_000.0
  RuntimeGateUs* = 4_000.0
  ControlGateUs* = 1_400.0
  CalibrationBaselineUs* = 400.0
    ## P33 containment-calibration baseline: measured on 2026-09-01 on the
    ## reference local dev box at 397us after the probe landed, rounded to
    ## 400us.
    ## The probe is intentionally independent of runtime/body/control work; it
    ## exists only to scale fixed CPU-time gates across slower CI cores.
  ControlCallValidationBudget* = 64
  ControlAckBudget* = 32
  BodyTimingSamples* = 3
    ## Samples of the deterministic body tick per wave; the minimum is gated
    ## (see the wave loop). Three is enough to shed one contended sample
    ## without making the gate meaningfully slower.

  EmptyModule = [
    0x00'u8, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]

proc elapsedUs(started: float): float {.inline.} =
  ## `started` is a cpuTime() reading, not a wall-clock one. This module has
  ## exactly one consumer (test_shell_containment.nim's hostile-wave stress
  ## gate) and no production caller, so there is no wall-clock telemetry
  ## contract to preserve here. Was getMonoTime()-based; switched following
  ## test_shell_reflexes.nim's template (the same "N seats stay inside a
  ## runtime budget" property, cpuTime()-gated there already) after a
  ## wall-clock/fixed-budget audit found this file's BodyGateUs/RuntimeGateUs/
  ## ControlGateUs checks (1.4-5ms wall-clock ceilings) were the same defect
  ## shape as test_shell_episode_ladder.nim's -- confirmed failing on a real
  ## CI run, not just a loaded local box. cpuTime() only counts time this
  ## process actually spent executing, so a scheduler preemption or another
  ## process's contention on a shared runner no longer fails this test for
  ## reasons unrelated to the code under test.
  (cpuTime() - started) * 1_000_000.0

proc calibrationProbeChecksum(): uint64 =
  ## Deterministic fixed-work CPU probe: integer arithmetic plus a bounded
  ## stack-array walk. No allocations, no runtime/body/control calls, no
  ## adaptive loop counts.
  var words: array[256, uint64]
  for index in 0 ..< words.len:
    words[index] = uint64(index + 1) * 0x9e3779b185ebca87'u64
  var acc = 0xd1b54a32d192ed03'u64
  for round in 0 ..< 262144:
    let slot = (round * 17) and 255
    let mixed = words[slot] xor (acc + uint64(round) * 0xbf58476d1ce4e5b9'u64)
    acc = (acc xor mixed) * 0x94d049bb133111eb'u64
    words[slot] = mixed + uint64(slot)
  for value in words:
    acc = (acc xor value) * 0x2545f4914f6cdd1d'u64
  acc

proc containmentCalibrationProbeUs*(): float =
  let started = cpuTime()
  let checksum = calibrationProbeChecksum()
  result = elapsedUs(started)
  doAssert checksum != 0

proc containmentCalibrationScale*(probeUs: float;
                                  baselineUs = CalibrationBaselineUs): float =
  if probeUs > 0.0 and baselineUs > 0.0:
    max(1.0, probeUs / baselineUs)
  else:
    1.0

proc scaledGateUs*(gateUs, scale: float): float =
  gateUs * scale

proc testMap*(): BodyMap =
  const Width = 720
  const Height = 96
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 .. 100:
      walkable[y * Width + x] = true
    for x in 600 ..< Width - 1:
      walkable[y * Width + x] = true
  newBodyMap(walkable, Width, Height, 32, @[(30, 30)])

proc cleanDefaultBodyTick(map: BodyMap, seatCount: int, tick: uint32): bool =
  let nav = newBodyNavSystem(map, seatCount, GunRange)
  for seat in 0 ..< seatCount:
    let body = activateSeatBody(nav, seat)
    let idleAimCenterBrads = seat and 0xff
    let inputs = BodyTickInputs(
      self: BodySelfState(
        pos: (30, 30),
        hp: 4,
        hpFrac: 1.0,
        aimBrads: idleAimCenterBrads,
        alive: true,
        carrying: false),
      partner: none(PartnerSample))
    body.updateBelief(inputs, tick)
    let fallback = BrDefaultFallbacks(
        currentZone: MapRect(x: 0, y: 0, w: map.width, h: map.height),
        nextZone: MapRect(x: 0, y: 0, w: map.width, h: map.height),
        ticksToNextShrink: BrRotateLeadTicks + 1,
        idleAimCenterBrads: idleAimCenterBrads)
    var state: StandingOrderState
    state.stepFirstLightDefault(body, tick, fallback)
    let mask = body.seatTick(inputs, tick)
    let unsafeBits = mask.encodeInputMask() and
      (ButtonUp or ButtonDown or ButtonLeft or ButtonRight or ButtonA or
        ButtonC)
    if unsafeBits != 0 or not state.hasStanding or
        body.standingIntent.kind != ikHold or body.standingGoal.isSome:
      return false
  true

proc proveStorePoolReusable*(engine: RuntimeEngine): int =
  let module = engine.compileModule(EmptyModule)
  defer: module.close()
  var instances: seq[RuntimeInstance]
  defer:
    for instance in instances:
      instance.close()
  for _ in 0 ..< RuntimePoolSlots:
    instances.add(module.instantiate())
  instances.len

proc hexFor(index: int): string =
  const Digits = "0123456789abcdef"
  let pair = $Digits[(index shr 4) and 0xf] & $Digits[index and 0xf]
  pair.repeat(32)

proc runControlMaximum(engine: RuntimeEngine, seatCount: int):
    tuple[admissions, commits, statusBytes, acks: int] =
  let plane = newCompilePlane(engine, seatCount)
  defer: plane.close()
  plane.beginTick()
  for seat in 0 ..< seatCount:
    let admission = plane.admitModule(seat, 1, 1, @[byte(seat)])
    if admission.accepted:
      inc result.admissions
      result.statusBytes += admission.statusBytes.len
  var finished = 0
  while finished < MaxCompileCommitsPerTick:
    let workItems = plane.dispatchAvailable()
    if workItems.len == 0:
      break
    for work in workItems:
      let hash = hexFor(work.seat)
      let content = plane.completeHash(work, hash)
      if content.isSome:
        plane.completeContent(content.get, ContentOutcome(
          accepted: false, reason: "binaryInvalid", detail: "hostile gate"))
        inc finished
        if finished == MaxCompileCommitsPerTick:
          break
  let commits = plane.commitCompileResults()
  result.commits = commits.len
  for commit in commits:
    result.statusBytes += commit.statusBytes.len
  result.acks = ControlAckBudget

proc runAttack(instance: ShellInstance, attack: ContainmentAttack):
    ShellInvocationResult =
  case attack
  of caInit:
    instance.invokeInit("{}", "")
  of caStep:
    instance.invokeStep("{}", 1, (30, 30))
  of caRetune:
    instance.invokeRetune("", "")

proc runContainmentGate*(engine: RuntimeEngine, hostiles: openArray[HostileModule],
                         seatCount = MaxPlayers): ContainmentVerdict =
  doAssert seatCount == MaxPlayers
  let map = testMap()
  result.calibrationProbeUs = containmentCalibrationProbeUs()
  result.calibrationScale =
    containmentCalibrationScale(result.calibrationProbeUs)
  result.scaledRuntimeGateUs =
    scaledGateUs(RuntimeGateUs, result.calibrationScale)
  result.scaledBodyGateUs =
    scaledGateUs(BodyGateUs, result.calibrationScale)
  result.scaledControlGateUs =
    scaledGateUs(ControlGateUs, result.calibrationScale)
  result.seatCount = seatCount
  result.waveCount = hostiles.len
  result.bodyPass = true
  result.runtimePass = true
  result.controlPass = true
  result.hostSurvived = true
  result.poolReusable = true

  for waveIndex, hostile in hostiles:
    var wave = ContainmentWave(name: hostile.name, attack: hostile.attack,
      seatsRun: seatCount, callValidationBudget: ControlCallValidationBudget)
    wave.calibrationProbeUs = result.calibrationProbeUs
    wave.calibrationScale = result.calibrationScale
    wave.scaledRuntimeGateUs = result.scaledRuntimeGateUs
    wave.scaledBodyGateUs = result.scaledBodyGateUs
    wave.scaledControlGateUs = result.scaledControlGateUs
    var validation = engine.validateUploadedModule(hostile.bytes)
    if not validation.accepted:
      raise newException(ShellRuntimeError, "hostile fixture " & hostile.name &
        " failed production validation: " & validation.reason & " " &
        validation.detail)
    try:
      for seat in 0 ..< seatCount:
        var shell = newShellInstance(validation.module, map, (30, 30),
          ecController)
        let started = cpuTime()
        let outcome = shell.runAttack(hostile.attack)
        wave.maxRuntimeUs = max(wave.maxRuntimeUs, elapsedUs(started))
        let statusBytes = outcome.terminalStatusBytes(uint64(seat + 1), 1,
          uint64(waveIndex + 1), "entry-" & $seat)
        if statusBytes.len > 0:
          inc wave.terminalStatuses
          if statusBytes.contains("\"kind\":\"play_faulted\""):
            inc wave.playFaultedStatuses
          if statusBytes.contains("\"kind\":\"retune_refused\""):
            inc wave.retuneRefusedStatuses
        if shell.isOpen:
          inc wave.leakedStores
          shell.close()
    finally:
      validation.close()

    # The body tick is deterministic and builds fresh state on every call, so
    # it is sampled BodyTimingSamples times and the minimum is the gate input.
    # A single cpuTime() sample of ~5 ms of work is not a measurement of the
    # code on a shared CI runner: cpuTime() excludes preemption but not the
    # cache and SMT contention of the sibling shards running on the same two
    # cores, and the calibration probe cannot see contention that arrives
    # after it ran. The minimum of a few samples is the standard estimator
    # for "how long does this deterministic work take here": transient
    # contention inflates individual samples but not the floor, while a real
    # regression in the body raises every sample and therefore the floor.
    # Observed before this: 7.0-8.1 ms samples against a 6.25 ms scaled gate
    # on a docs-only commit (GitHub run 33588409127), i.e. runner noise
    # failing the build and blocking the image upload.
    wave.defaultBodyOk = true
    wave.maxBodyUs = Inf
    for _ in 0 ..< BodyTimingSamples:
      let bodyStarted = cpuTime()
      let bodyOk = cleanDefaultBodyTick(map, seatCount, uint32(waveIndex + 1))
      wave.maxBodyUs = min(wave.maxBodyUs, elapsedUs(bodyStarted))
      wave.defaultBodyOk = wave.defaultBodyOk and bodyOk

    let controlStarted = cpuTime()
    let control = runControlMaximum(engine, seatCount)
    wave.maxControlUs = elapsedUs(controlStarted)
    wave.controlAdmissions = control.admissions
    wave.controlCommits = control.commits
    wave.controlStatusBytes = control.statusBytes
    wave.controlAcks = control.acks

    try:
      wave.poolFillAfterWave = proveStorePoolReusable(engine)
      wave.poolReusable = wave.poolFillAfterWave == RuntimePoolSlots
    except ShellRuntimeError:
      wave.poolReusable = false
    wave.hostSurvived = wave.terminalStatuses == seatCount and
      wave.leakedStores == 0 and wave.defaultBodyOk and wave.poolReusable and
      wave.controlAdmissions == seatCount and
      wave.controlCommits == MaxCompileCommitsPerTick and
      wave.controlAcks == ControlAckBudget

    result.terminalStatuses += wave.terminalStatuses
    result.playFaultedStatuses += wave.playFaultedStatuses
    result.retuneRefusedStatuses += wave.retuneRefusedStatuses
    result.leakedStores += wave.leakedStores
    result.maxRuntimeUs = max(result.maxRuntimeUs, wave.maxRuntimeUs)
    result.maxBodyUs = max(result.maxBodyUs, wave.maxBodyUs)
    result.maxControlUs = max(result.maxControlUs, wave.maxControlUs)
    result.hostSurvived = result.hostSurvived and wave.hostSurvived
    result.poolReusable = result.poolReusable and wave.poolReusable
    result.bodyPass = result.bodyPass and wave.defaultBodyOk and
      wave.maxBodyUs <= result.scaledBodyGateUs
    result.runtimePass = result.runtimePass and wave.hostSurvived and
      wave.maxRuntimeUs <= result.scaledRuntimeGateUs
    result.controlPass = result.controlPass and
      wave.controlAdmissions == seatCount and
      wave.controlCommits == MaxCompileCommitsPerTick and
      wave.maxControlUs <= result.scaledControlGateUs
    result.waves.add(wave)

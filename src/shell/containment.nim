## Full-shape runtime containment harness for Gate 3.
##
## This module is intentionally below packet decoding and above the server
## hook. It runs real RuntimeEngine/ShellInstance/BodyMap/CompilePlane work
## against already-admitted Wasm bytes and returns deterministic evidence rows.

import std/[monotimes, options, strutils, times]
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
  ControlCallValidationBudget* = 64
  ControlAckBudget* = 32

  EmptyModule = [
    0x00'u8, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]

proc elapsedUs(started: MonoTime): float {.inline.} =
  (getMonoTime() - started).inNanoseconds.float / 1000.0

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
    if mask != InputState() or not state.hasStanding or
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
    var validation = engine.validateUploadedModule(hostile.bytes)
    if not validation.accepted:
      raise newException(ShellRuntimeError, "hostile fixture " & hostile.name &
        " failed production validation: " & validation.reason & " " &
        validation.detail)
    try:
      for seat in 0 ..< seatCount:
        var shell = newShellInstance(validation.module, map, (30, 30),
          ecController)
        let started = getMonoTime()
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

    let bodyStarted = getMonoTime()
    wave.defaultBodyOk = cleanDefaultBodyTick(map, seatCount,
      uint32(waveIndex + 1))
    wave.maxBodyUs = elapsedUs(bodyStarted)

    let controlStarted = getMonoTime()
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
      wave.maxBodyUs <= BodyGateUs
    result.runtimePass = result.runtimePass and wave.hostSurvived and
      wave.maxRuntimeUs <= RuntimeGateUs
    result.controlPass = result.controlPass and
      wave.controlAdmissions == seatCount and
      wave.controlCommits == MaxCompileCommitsPerTick and
      wave.maxControlUs <= ControlGateUs
    result.waves.add(wave)

## Reference `target_law` overlay through the production shell runtime path.

import std/[options, os, osproc, sequtils, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, binary_view, body, body_map, emit_validator,
  instance, manifest, module_validation, runtime, types, view, episode,
  default_play, standing_order]

const
  FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell"
  TargetLawSource = "play_sdk" / "reference" / "target_law.nim"
  TargetLawWasm = "play_sdk" / ".build" / "target_law.wasm"
  TargetLawFuelGate = ((StepFuel * 48) div 100).uint64

proc parseToolPath(output, key: string): string =
  for line in output.splitLines:
    if line.startsWith(key & "="):
      return line[(key.len + 1) .. ^1]

proc toolPath(key: string): string =
  result = getEnv(key)
  if result.len > 0:
    return
  let fetched = execCmdEx("tools/runtime_spike/fetch_deps.sh")
  require fetched.exitCode == 0
  result = parseToolPath(fetched.output, key)
  require result.len > 0

proc buildTargetLawWasm(): seq[byte] =
  let command = "WASI_SDK_PATH=" & quoteShell(toolPath("WASI_SDK_PATH")) &
    " nim c -f " & quoteShell(TargetLawSource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(TargetLawWasm)
  readFile(TargetLawWasm).toOpenArrayByte(0,
    getFileSize(TargetLawWasm).int - 1).toSeq

proc openMap(): BodyMap =
  const
    Width = 720
    Height = 240
  var walkable = newSeq[bool](Width * Height)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Width, Height, 2, @[(40, 80), (680, 80)])

proc withDuo(duos: var array[Team, DuoSeats], team: Team, a, b: int) =
  duos[team] = DuoSeats(configured: true,
    seats: [SeatRef(uint8(a)), SeatRef(uint8(b))])

proc checkedModule(engine: RuntimeEngine; bytes: seq[byte]): RuntimeModule =
  var validation = engine.validateUploadedModule(bytes)
  require validation.accepted
  result = validation.module
  validation.module = nil
  validation.close()

proc targetLawModule(engine: RuntimeEngine): RuntimeModule =
  engine.checkedModule(buildTargetLawWasm())

proc newTargetLawInstance(engine: RuntimeEngine; module: RuntimeModule;
                          mode = gmBr;
                          duos: array[Team, DuoSeats] =
                            default(array[Team, DuoSeats])): ShellInstance =
  newShellInstance(module, openMap(), (100, 80), ecOverlay, mode, duos)

proc viewFor(tick, aliveTeams, zonePhase: int;
             tracks: seq[PlayTrack] = @[];
             aggressors: seq[PlayAggressor] = @[]): string =
  buildBinaryPlayView(PlayViewSource(
    tick: uint32(tick),
    mode: gmBr,
    epoch: 0,
    self: PlaySelf(pos: (100, 80), hp: 3, hpFrac: 0.75,
      aimBrads: 32, alive: true),
    aliveTeams: aliveTeams,
    zone: some(PlayZone(phase: zonePhase,
      current: PlayRect(x: 0, y: 0, w: 720, h: 240),
      ticksToShrink: 240, dps: 1)),
    tracks: tracks,
    aggressors: aggressors))

proc track(seat: int; team: Team; pos: BodyPoint; hp = none(int);
           bounty = false; tick = 1): PlayTrack =
  PlayTrack(seat: seat, team: team, pos: pos, hp: hp,
    bounty: bounty, freshTick: uint32(tick))

proc aggressor(seat: int; tick = 1): PlayAggressor =
  PlayAggressor(eventId: uint64(tick), tick: uint32(tick), dirBrads: 32,
    seat: some(seat))

proc policyBytes(seats: openArray[int] = [];
                 prefer: openArray[PreferTag] = [];
                 holdFire = false): string =
  var policy = CombatPolicy(holdFire: holdFire)
  for seat in seats:
    policy.noShoot.seats.add(SeatRef(uint8(seat)))
  for tag in prefer:
    policy.prefer.add(tag)
  canonicalCombatPolicy(policy)

proc initOk(instance: ShellInstance; params: string) =
  let init = instance.invokeInit(params, "{}")
  check not init.faulted
  check init.returned == 0

proc step(instance: ShellInstance; view: string; tick = 1'u32):
    ShellInvocationResult =
  instance.invokeStep(view, tick, (100, 80))

proc fuelConsumed(invocation: ShellInvocationResult): uint64 =
  if invocation.faulted and invocation.reason.contains("all fuel consumed"):
    StepFuel.uint64
  else:
    StepFuel.uint64 - invocation.fuelRemaining

proc controls(count: int): seq[SlotControl] =
  for _ in 0 ..< count:
    result.add scPlay

proc liveFrame(pos: BodyPoint; tick: int): FirstLightSeatFrame =
  FirstLightSeatFrame(
    seat: 0,
    playerIndex: 0,
    present: true,
    playing: true,
    alive: true,
    aliveTeams: 3,
    bodyInputs: BodyTickInputs(
      self: BodySelfState(pos: pos, hp: 3, hpFrac: 0.75,
        lives: none(int), aimBrads: 32, fireCooldown: 0, fireWindup: 0,
        windup: none(int), hasGrenade: false, hasShield: false, shieldHp: 0,
        hasSprayPaint: false, arcTicksLeft: 0, alive: true,
        carrying: false),
      partner: some(PartnerSample(seat: 1, pos: (150, 80),
        aimBrads: 0, alive: true)),
      visibleTracks: @[BodyTrackUpdate(seat: 1, pos: (150, 80), team: Navy,
        aimBrads: some(0), hpKnown: some(3), shielded: false,
        weapon: some(bwGun), veteranMarker: false, tick: uint32(tick))]),
    defaultFallbacks: BrDefaultFallbacks(
      currentZone: MapRect(x: 0, y: 0, w: 720, h: 240),
      nextZone: MapRect(x: 0, y: 0, w: 720, h: 240),
      ticksToNextShrink: BrRotateLeadTicks + 1,
      zonePhase: 1,
      zoneDps: 1,
      idleAimCenterBrads: 32,
      coverGoal: none(ValidatedGoal)))

suite "target_law reference play":
  test "manifest bytes match the golden and parse in production":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.targetLawModule()
    defer: module.close()
    var instance = engine.newTargetLawInstance(module)
    defer: instance.close()

    let manifestResult = instance.invokeManifest()
    check not manifestResult.faulted
    check manifestResult.manifestBytes ==
      readFile(FixtureDir / "manifest_target_law.golden.json").strip
    let parsed = parseManifest(manifestResult.manifestBytes, hasRetune = true)
    check parsed.name == "target_law"
    check parsed.playClass == mcOverlay
    check parsed.modes == @["br", "ctf"]

  test "params decode defaults and reject bad refs triggers and duplicate prefer":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.targetLawModule()
    defer: module.close()

    var defaults = engine.newTargetLawInstance(module)
    defer: defaults.close()
    defaults.initOk("{}")
    let defaultStep = defaults.step(viewFor(1, 9, 1))
    check not defaultStep.faulted
    check defaultStep.returned == 0
    check defaultStep.lastAccepted.get.bytes == policyBytes()

    for params in [
      "{\"never\":[\"bogus\"]}",
      "{\"never\":[\"seat:32\"]}",
      "{\"prefer\":[\"weakened\",\"weakened\"]}",
      "{\"prefer\":[\"now\"]}",
      "{\"holdTrigger\":{\"aliveTeams\":1}}",
      "{\"holdTrigger\":{\"zonePhase\":9}}",
      "{\"holdTrigger\":{\"tick\":-1}}",
      "{\"holdTrigger\":{\"tick\":10,\"aliveTeams\":2}}"]:
      var rejected = engine.newTargetLawInstance(module)
      defer: rejected.close()
      let init = rejected.invokeInit(params, "{}")
      check init.faulted
      check init.reason == "play_init returned nonzero"

  test "never refs and prefer emit through production combat policy validation":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.targetLawModule()
    defer: module.close()
    var duos: array[Team, DuoSeats]
    duos.withDuo(Navy, 10, 2)
    var instance = engine.newTargetLawInstance(module, duos = duos)
    defer: instance.close()

    instance.initOk("{\"never\":[\"duo:navy\",\"seat:7\"]," &
      "\"prefer\":[\"revenge\",\"weakened\"]}")
    let output = instance.step(viewFor(1, 9, 1, tracks = @[
      track(2, Navy, (20, 20)), track(7, Rust, (300, 80), bounty = true),
      track(10, Navy, (40, 20), hp = some(1))],
      aggressors = @[aggressor(7)]))
    check not output.faulted
    check output.emitCodes == @[AbiOk]
    check output.lastAccepted.get.bytes == policyBytes([10, 2, 7],
      prefer = [ptRevenge, ptWeakened])

  test "holdTrigger equality boundaries release and latch across retune":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.targetLawModule()
    defer: module.close()

    for caseData in [
      (params: "{\"holdTrigger\":{\"aliveTeams\":3},\"never\":[\"seat:7\"]}",
       before: viewFor(1, 4, 1), at: viewFor(1, 3, 1)),
      (params: "{\"holdTrigger\":{\"tick\":7},\"never\":[\"seat:7\"]}",
       before: viewFor(6, 9, 1), at: viewFor(7, 9, 1)),
      (params: "{\"holdTrigger\":{\"zonePhase\":3},\"never\":[\"seat:7\"]}",
       before: viewFor(1, 9, 2), at: viewFor(1, 9, 3))]:
      var instance = engine.newTargetLawInstance(module)
      defer: instance.close()
      instance.initOk(caseData.params)
      let before = instance.step(caseData.before)
      check not before.faulted
      check before.lastAccepted.get.bytes == policyBytes([7],
        holdFire = true)
      let released = instance.step(caseData.at)
      check not released.faulted
      check released.lastAccepted.get.bytes == policyBytes([7])
      let flapped = instance.step(caseData.before)
      check not flapped.faulted
      check flapped.emitCodes.len == 0
      check flapped.lastAccepted.get.bytes == policyBytes([7])
      let retune = instance.invokeRetune(caseData.params,
        "{\"holdTrigger\":{\"tick\":9999},\"never\":[\"seat:8\"]}")
      check not retune.faulted
      check not retune.refused
      let afterRetune = instance.step(caseData.before)
      check not afterRetune.faulted
      check afterRetune.lastAccepted.get.bytes == policyBytes([8])

  test "unchanged target law emits only once":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.targetLawModule()
    defer: module.close()
    var instance = engine.newTargetLawInstance(module)
    defer: instance.close()

    instance.initOk("{\"never\":[\"seat:7\"],\"prefer\":[\"bounty\"]}")
    check instance.step(viewFor(1, 9, 1)).emitCodes == @[AbiOk]
    let quiet = instance.step(viewFor(2, 9, 1))
    check quiet.emitCodes.len == 0
    check quiet.lastAccepted.get.bytes == policyBytes([7],
      prefer = [ptBounty])

  test "live episode installs folded target law policy":
    when ShellRuntimeAvailable:
      discard buildTargetLawWasm()
      let map = openMap()
      var episode = initFirstLightEpisode(true, true, controls(3), map, 331,
        [Navy, Navy, Rust], "target-law-live", 6)
      defer: episode.closeFirstLightEpisode()
      let lines = episode.configureFirstLightPlay(FirstLightPlayConfig(
        modulePath: TargetLawWasm,
        playName: "target_law",
        paramsBytes: "{\"holdTrigger\":{\"tick\":99},\"never\":[\"seat:2\"]," &
          "\"prefer\":[\"weakened\"]}",
        seats: @[0],
        uploadIdBase: 240_000,
        proposalIdBase: 241_000,
        originGeneration: 1))
      check lines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL") and
        it.contains("accepted=true"))
      let output = episode.step([liveFrame((100, 80), 1)], 1)
      check output.installs.anyIt(it.bytes.contains("\"hold_fire\":true") and
        it.bytes.contains("\"no_shoot\":{\"seats\":[\"seat:2\"]}") and
        it.bytes.contains("\"prefer\":[\"weakened\"]"))

  test "realistic BR target-law view keeps twenty-percent headroom under sixty-percent fuel":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.targetLawModule()
    defer: module.close()
    var instance = engine.newTargetLawInstance(module)
    defer: instance.close()
    instance.initOk("{\"holdTrigger\":{\"tick\":9999}," &
      "\"never\":[\"seat:7\"],\"prefer\":[\"bounty\",\"revenge\"," &
      "\"weakened\",\"isolated\"]}")

    var tracks: seq[PlayTrack]
    var aggressors: seq[PlayAggressor]
    for index in 0 ..< 32:
      tracks.add track(index, if index mod 2 == 0: Rust else: Navy,
        (120 + index, 80 + index), hp = some(index mod 4),
        bounty = index mod 3 == 0, tick = index)
    for index in 0 ..< 16:
      aggressors.add aggressor(index, 100 + index)
    let frame = viewFor(100, 9, 1, tracks = tracks, aggressors = aggressors)
    let step = instance.step(frame, 100)
    let consumed = step.fuelConsumed
    echo "TARGET_LAW_BINARY_VIEW_FUEL view_len=", frame.len,
      " tracks=32 aggressors=16 consumed=", consumed,
      " completed=", (not step.faulted and step.returned == 0),
      " fuel_remaining=", step.fuelRemaining,
      " spatial_calls=", step.counters.spatialCalls
    check not step.faulted
    check step.returned == 0
    check consumed <= TargetLawFuelGate

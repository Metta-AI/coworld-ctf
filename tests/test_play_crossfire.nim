## Reference `crossfire` controller through the production shell runtime path.

import std/[options, os, osproc, sequtils, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, binary_view, body, body_map, default_play, episode,
  emit_validator, instance, manifest, module_validation, runtime,
  standing_order, types, view]

const
  FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell"
  CrossfireSource = "play_sdk" / "reference" / "crossfire.nim"
  CrossfireWasm = "play_sdk" / ".build" / "crossfire.wasm"
  CrossfireFuelGate = ((StepFuel * 48) div 100).uint64

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

proc buildCrossfireWasm(): seq[byte] =
  let command = "WASI_SDK_PATH=" & quoteShell(toolPath("WASI_SDK_PATH")) &
    " nim c -f " & quoteShell(CrossfireSource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(CrossfireWasm)
  readFile(CrossfireWasm).toOpenArrayByte(0,
    getFileSize(CrossfireWasm).int - 1).toSeq

proc openMap(): BodyMap =
  const
    Width = 720
    Height = 240
  var walkable = newSeq[bool](Width * Height)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Width, Height, 2, @[(40, 80), (680, 80)])

proc checkedModule(engine: RuntimeEngine; bytes: seq[byte]): RuntimeModule =
  var validation = engine.validateUploadedModule(bytes)
  require validation.accepted
  result = validation.module
  validation.module = nil
  validation.close()

proc crossfireModule(engine: RuntimeEngine): RuntimeModule =
  engine.checkedModule(buildCrossfireWasm())

proc contextBytes(selfTeam = Navy; duoPartner = 1): string =
  buildBinaryPlayContext(PlayContextSource(
    mode: gmBr,
    mapName: "crossfire-test",
    mapWidth: 720,
    mapHeight: 240,
    roster: @[
      PlayContextRosterRow(seat: 0, team: selfTeam, control: pccPlay),
      PlayContextRosterRow(seat: 1, team: selfTeam, control: pccPlay),
      PlayContextRosterRow(seat: 2, team: Rust, control: pccInput)],
    selfSeat: 0,
    selfTeam: selfTeam,
    duoPartner: some(duoPartner),
    gunRange: 331,
    viewInterval: 6))

proc initOk(instance: ShellInstance; params: string) =
  let init = instance.invokeInit(params, contextBytes())
  check not init.faulted
  check init.returned == 0

proc fuelConsumed(invocation: ShellInvocationResult): uint64 =
  if invocation.faulted and invocation.reason.contains("all fuel consumed"):
    StepFuel.uint64
  else:
    StepFuel.uint64 - invocation.fuelRemaining

proc pointOf(invocation: ShellInvocationResult): BodyPoint =
  let point = invocation.lastAccepted.get.intent.point.get
  (point.x, point.y)

proc reasonOf(invocation: ShellInvocationResult): string =
  invocation.lastAccepted.get.intent.reason

proc track(seat: int; team: Team; pos: BodyPoint; tick = 1): PlayTrack =
  PlayTrack(seat: seat, team: team, pos: pos, freshTick: uint32(tick))

proc viewFor(self: BodyPoint; tracks: seq[PlayTrack];
             includeZone = true): string =
  buildBinaryPlayView(PlayViewSource(
    tick: 1'u32,
    mode: gmBr,
    epoch: 0,
    self: PlaySelf(pos: self, hp: 3, hpFrac: 1.0, aimBrads: 32,
      alive: true),
    aliveTeams: 9,
    zone: if includeZone:
      some(PlayZone(phase: 1,
        current: PlayRect(x: 0, y: 0, w: 720, h: 240),
        ticksToShrink: 240, dps: 1))
    else:
      none(PlayZone),
    tracks: tracks))

proc newCrossfireInstance(engine: RuntimeEngine; module: RuntimeModule;
                          pos: BodyPoint): ShellInstance =
  newShellInstance(module, openMap(), pos, ecController, gmBr)

proc liveFrame(pos: BodyPoint; tick: int): FirstLightSeatFrame =
  FirstLightSeatFrame(
    seat: 0,
    playerIndex: 0,
    present: true,
    playing: true,
    alive: true,
    aliveTeams: 2,
    bodyInputs: BodyTickInputs(
      self: BodySelfState(pos: pos, hp: 3, hpFrac: 1.0,
        lives: none(int), aimBrads: 32, fireCooldown: 0, fireWindup: 0,
        windup: none(int), hasGrenade: false, hasShield: false, shieldHp: 0,
        hasSprayPaint: false, arcTicksLeft: 0, alive: true,
        carrying: false),
      partner: some(PartnerSample(seat: 1, pos: (100, 80),
        aimBrads: 0, alive: true)),
      visibleTracks: @[BodyTrackUpdate(seat: 1, pos: (100, 80), team: Navy,
        aimBrads: some(0), hpKnown: some(3), shielded: false,
        weapon: some(bwGun), veteranMarker: false, tick: uint32(tick)),
        BodyTrackUpdate(seat: 2, pos: (500, 80), team: Rust,
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

suite "crossfire reference play":
  test "manifest bytes match the golden and parse in production":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.crossfireModule()
    defer: module.close()
    var instance = engine.newCrossfireInstance(module, (220, 80))
    defer: instance.close()

    let manifestResult = instance.invokeManifest()
    check not manifestResult.faulted
    check manifestResult.manifestBytes ==
      readFile(FixtureDir / "manifest_crossfire.golden.json").strip
    let parsed = parseManifest(manifestResult.manifestBytes, hasRetune = true)
    check parsed.name == "crossfire"
    check parsed.playClass == mcController
    check parsed.modes == @["br"]

  test "params decode defaults and reject invalid spacing and angle":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.crossfireModule()
    defer: module.close()
    var defaults = engine.newCrossfireInstance(module, (500, 80))
    defer: defaults.close()
    defaults.initOk("{}")
    let defaultStep = defaults.invokeStep(viewFor((500, 80),
      @[track(1, Navy, (100, 80))]), 1, (500, 80))
    check not defaultStep.faulted
    check defaultStep.reasonOf == "crossfire:close"

    for params in ["{\"spacing\":[320,120]}", "{\"spacing\":[120,601]}",
                   "{\"spacing\":[120]}", "{\"minAngle\":129}"]:
      var rejected = engine.newCrossfireInstance(module, (220, 80))
      defer: rejected.close()
      let init = rejected.invokeInit(params, contextBytes())
      check init.faulted
      check init.reason == "play_init returned nonzero"

  test "spacing band closes, backs off, and opens the shared angle":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.crossfireModule()
    defer: module.close()

    block closeToMaxSpacing:
      var instance = engine.newCrossfireInstance(module, (500, 80))
      defer: instance.close()
      instance.initOk("{\"minAngle\":32,\"spacing\":[80,160]}")
      let step = instance.invokeStep(viewFor((500, 80),
        @[track(1, Navy, (100, 80))]), 1, (500, 80))
      check not step.faulted
      check step.reasonOf == "crossfire:close"
      check step.pointOf == (260, 80)

    block backOffToMinSpacing:
      var instance = engine.newCrossfireInstance(module, (140, 80))
      defer: instance.close()
      instance.initOk("{\"minAngle\":32,\"spacing\":[80,320]}")
      let step = instance.invokeStep(viewFor((140, 80),
        @[track(1, Navy, (100, 80))]), 1, (140, 80))
      check not step.faulted
      check step.reasonOf == "crossfire:backoff"
      check step.pointOf == (180, 80)

    block openAngleAwayFromZoneEdge:
      var instance = engine.newCrossfireInstance(module, (220, 80))
      defer: instance.close()
      instance.initOk("{\"minAngle\":32,\"spacing\":[80,320]}")
      let step = instance.invokeStep(viewFor((220, 80), @[
        track(1, Navy, (100, 80)),
        track(2, Rust, (500, 80))]), 1, (220, 80))
      check not step.faulted
      check step.reasonOf == "crossfire:angle"
      check step.pointOf == (220, 160)

  test "missing partner track uses last known position, then plain hold":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.crossfireModule()
    defer: module.close()

    var remembered = engine.newCrossfireInstance(module, (220, 80))
    defer: remembered.close()
    remembered.initOk("{\"minAngle\":0,\"spacing\":[80,160]}")
    discard remembered.invokeStep(viewFor((220, 80),
      @[track(1, Navy, (100, 80))]), 1, (220, 80))
    let follow = remembered.invokeStep(viewFor((500, 80), @[]), 2, (500, 80))
    check not follow.faulted
    check follow.reasonOf == "crossfire:close"

    var unknown = engine.newCrossfireInstance(module, (500, 80))
    defer: unknown.close()
    unknown.initOk("{\"minAngle\":0,\"spacing\":[80,160]}")
    let first = unknown.invokeStep(viewFor((500, 80), @[]), 1, (500, 80))
    check not first.faulted
    check first.reasonOf == "crossfire:hold"

  test "live episode installs crossfire angle order":
    when ShellRuntimeAvailable:
      discard buildCrossfireWasm()
      let map = openMap()
      var episode = initFirstLightEpisode(true, true,
        [scPlay, scPlay, scInput], map, 331, [Navy, Navy, Rust],
        "crossfire-live", 6)
      defer: episode.closeFirstLightEpisode()
      let lines = episode.configureFirstLightPlay(FirstLightPlayConfig(
        modulePath: CrossfireWasm,
        playName: "crossfire",
        paramsBytes: "{\"minAngle\":32,\"spacing\":[80,320]}",
        seats: @[0],
        uploadIdBase: 220_000,
        proposalIdBase: 221_000,
        originGeneration: 1))
      check lines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL") and
        it.contains("accepted=true"))
      let output = episode.step([liveFrame((220, 80), 1)], 1)
      check output.installs.anyIt(it.provenance == "entry:crossfire" and
        it.bytes.contains("crossfire:angle"))

  test "realistic BR track view keeps twenty-percent headroom under sixty-percent fuel":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.crossfireModule()
    defer: module.close()
    var instance = engine.newCrossfireInstance(module, (220, 80))
    defer: instance.close()
    instance.initOk("{\"minAngle\":32,\"spacing\":[80,320]}")

    var tracks: seq[PlayTrack]
    tracks.add track(1, Navy, (100, 80))
    tracks.add track(0, Navy, (210, 80), tick = 0)
    for index in 0 ..< 30:
      tracks.add track(index + 2, Rust, (500 + index, 80 + index),
        tick = index)
    let frame = viewFor((220, 80), tracks)
    let step = instance.invokeStep(frame, 1, (220, 80))
    let consumed = step.fuelConsumed
    echo "CROSSFIRE_BINARY_VIEW_FUEL view_len=", frame.len,
      " tracks=32 consumed=", consumed,
      " completed=", (not step.faulted and step.returned == 0),
      " fuel_remaining=", step.fuelRemaining,
      " spatial_calls=", step.counters.spatialCalls
    check not step.faulted
    check step.returned == 0
    check consumed <= CrossfireFuelGate

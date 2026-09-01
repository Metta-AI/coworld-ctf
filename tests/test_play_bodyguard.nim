## Reference `bodyguard` controller through the production shell runtime path.

import std/[options, os, osproc, sequtils, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, binary_view, body, body_map, default_play, episode,
  emit_validator, instance, manifest, module_validation, runtime,
  standing_order, types, view]

const
  FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell"
  BodyguardSource = "play_sdk" / "reference" / "bodyguard.nim"
  BodyguardWasm = "play_sdk" / ".build" / "bodyguard.wasm"

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

proc buildBodyguardWasm(): seq[byte] =
  let command = "WASI_SDK_PATH=" & quoteShell(toolPath("WASI_SDK_PATH")) &
    " nim c -f " & quoteShell(BodyguardSource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(BodyguardWasm)
  readFile(BodyguardWasm).toOpenArrayByte(0,
    getFileSize(BodyguardWasm).int - 1).toSeq

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

proc bodyguardModule(engine: RuntimeEngine): RuntimeModule =
  engine.checkedModule(buildBodyguardWasm())

proc contextBytes(selfSeat = 0; selfTeam = Navy; duoPartner = 1): string =
  buildBinaryPlayContext(PlayContextSource(
    mode: gmBr,
    mapName: "bodyguard-test",
    mapWidth: 720,
    mapHeight: 240,
    roster: @[
      PlayContextRosterRow(seat: 0, team: selfTeam, control: pccPlay),
      PlayContextRosterRow(seat: 1, team: selfTeam, control: pccPlay),
      PlayContextRosterRow(seat: 2, team: Rust, control: pccInput)],
    selfSeat: selfSeat,
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

proc track(seat: int; team: Team; pos: BodyPoint; hp = none(int);
           tick = 1): PlayTrack =
  PlayTrack(seat: seat, team: team, pos: pos, hp: hp,
    freshTick: uint32(tick))

proc viewFor(self: BodyPoint; tracks: seq[PlayTrack]): string =
  buildBinaryPlayView(PlayViewSource(
    tick: 1'u32,
    mode: gmBr,
    epoch: 0,
    self: PlaySelf(pos: self, hp: 3, hpFrac: 1.0, aimBrads: 32,
      alive: true),
    aliveTeams: 9,
    zone: some(PlayZone(phase: 1,
      current: PlayRect(x: 0, y: 0, w: 720, h: 240),
      ticksToShrink: 240)),
    tracks: tracks))

proc newBodyguardInstance(engine: RuntimeEngine; module: RuntimeModule;
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
      partner: some(PartnerSample(seat: 1, pos: (100, 80), alive: true)),
      visibleTracks: @[BodyTrackUpdate(seat: 1, pos: (100, 80), team: Navy,
        aimBrads: some(0), hpKnown: some(3), shielded: false,
        weapon: some(bwGun), veteranMarker: false, tick: uint32(tick)),
        BodyTrackUpdate(seat: 2, pos: (260, 80), team: Rust,
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

suite "bodyguard reference play":
  test "manifest bytes match the golden and parse in production":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.bodyguardModule()
    defer: module.close()
    var instance = engine.newBodyguardInstance(module, (260, 80))
    defer: instance.close()

    let manifestResult = instance.invokeManifest()
    check not manifestResult.faulted
    check manifestResult.manifestBytes ==
      readFile(FixtureDir / "manifest_bodyguard.golden.json").strip
    let parsed = parseManifest(manifestResult.manifestBytes, hasRetune = true)
    check parsed.name == "bodyguard"
    check parsed.playClass == mcController
    check parsed.modes == @["br"]

  test "params decode context default ward and reject invalid forms":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.bodyguardModule()
    defer: module.close()
    var defaults = engine.newBodyguardInstance(module, (260, 80))
    defer: defaults.close()
    defaults.initOk("{}")
    let defaultStep = defaults.invokeStep(viewFor((260, 80),
      @[track(1, Navy, (100, 80))]), 1, (260, 80))
    check not defaultStep.faulted
    check defaultStep.reasonOf == "bodyguard:hold"

    var validLeash = engine.newBodyguardInstance(module, (260, 80))
    defer: validLeash.close()
    validLeash.initOk("{\"leash\":[80,220]}")

    for params in ["{\"leash\":[220,80]}", "{\"leash\":[80]}",
                   "{\"ward\":\"duo:navy\"}", "{\"peelHp\":65}"]:
      var rejected = engine.newBodyguardInstance(module, (260, 80))
      defer: rejected.close()
      let init = rejected.invokeInit(params, contextBytes())
      check init.faulted
      check init.reason == "play_init returned nonzero"

  test "leash and interpose decisions use ward fog tracks":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.bodyguardModule()
    defer: module.close()

    block closeToMaxLeash:
      var instance = engine.newBodyguardInstance(module, (300, 80))
      defer: instance.close()
      instance.initOk("{\"interpose\":false,\"leash\":[80,100],\"peelHp\":2,\"ward\":\"seat:1\"}")
      let step = instance.invokeStep(viewFor((300, 80),
        @[track(1, Navy, (100, 80))]), 1, (300, 80))
      check not step.faulted
      check step.reasonOf == "bodyguard:close"
      check step.pointOf == (200, 80)

    block backOffToMinLeash:
      var instance = engine.newBodyguardInstance(module, (120, 80))
      defer: instance.close()
      instance.initOk("{\"interpose\":false,\"leash\":[80,220],\"peelHp\":2,\"ward\":\"seat:1\"}")
      let step = instance.invokeStep(viewFor((120, 80),
        @[track(1, Navy, (100, 80))]), 1, (120, 80))
      check not step.faulted
      check step.reasonOf == "bodyguard:backoff"
      check step.pointOf == (180, 80)

    block interposeTowardThreat:
      var instance = engine.newBodyguardInstance(module, (260, 80))
      defer: instance.close()
      instance.initOk("{\"interpose\":true,\"leash\":[80,220],\"peelHp\":2,\"ward\":\"seat:1\"}")
      let step = instance.invokeStep(viewFor((260, 80), @[
        track(1, Navy, (100, 80)),
        track(2, Rust, (260, 80))]), 1, (260, 80))
      check not step.faulted
      check step.reasonOf == "bodyguard:interpose"
      check step.pointOf == (180, 80)

  test "peel wounded ward chooses the nearest visible threat":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.bodyguardModule()
    defer: module.close()
    var instance = engine.newBodyguardInstance(module, (180, 80))
    defer: instance.close()
    instance.initOk("{\"interpose\":true,\"leash\":[80,220],\"peelHp\":2,\"ward\":\"seat:1\"}")
    let step = instance.invokeStep(viewFor((180, 80), @[
      track(1, Navy, (100, 80), hp = some(1)),
      track(2, Rust, (260, 80)),
      track(3, Rust, (400, 80))]), 1, (180, 80))
    check not step.faulted
    check step.returned == 0
    check step.counters.spatialCalls == 1
    check step.reasonOf == "bodyguard:peel"
    check step.pointOf == (260, 80)

  test "live episode installs context-default bodyguard order":
    when ShellRuntimeAvailable:
      discard buildBodyguardWasm()
      let map = openMap()
      var episode = initFirstLightEpisode(true, true, [scPlay, scPlay], map,
        331, [Navy, Navy], "bodyguard-live", 6)
      defer: episode.closeFirstLightEpisode()
      let lines = episode.configureFirstLightPlay(FirstLightPlayConfig(
        modulePath: BodyguardWasm,
        playName: "bodyguard",
        paramsBytes: "{}",
        seats: @[0],
        uploadIdBase: 210_000,
        proposalIdBase: 211_000,
        originGeneration: 1))
      check lines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL") and
        it.contains("accepted=true"))
      let output = episode.step([liveFrame((260, 80), 1)], 1)
      check output.installs.anyIt(it.provenance == "entry:bodyguard" and
        it.bytes.contains("bodyguard:interpose"))

  test "realistic BR track view stays inside the sixty-percent fuel budget":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.bodyguardModule()
    defer: module.close()
    var instance = engine.newBodyguardInstance(module, (300, 80))
    defer: instance.close()
    instance.initOk("{\"interpose\":true,\"leash\":[80,220],\"peelHp\":2,\"ward\":\"seat:1\"}")

    var tracks: seq[PlayTrack]
    tracks.add track(1, Navy, (100, 80), hp = some(3))
    for index in 0 ..< 31:
      let seat = if index == 0: 0 else: index + 1
      tracks.add track(seat, Rust, (260 + index, 80 + index),
        hp = some(3), tick = index)
    let frame = viewFor((300, 80), tracks)
    let step = instance.invokeStep(frame, 1, (300, 80))
    let consumed = step.fuelConsumed
    echo "BODYGUARD_BINARY_VIEW_FUEL view_len=", frame.len,
      " tracks=32 consumed=", consumed,
      " completed=", (not step.faulted and step.returned == 0),
      " fuel_remaining=", step.fuelRemaining,
      " spatial_calls=", step.counters.spatialCalls
    check not step.faulted
    check step.returned == 0
    check consumed <= ((StepFuel * 60) div 100).uint64

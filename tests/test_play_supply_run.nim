## Reference `supply_run` controller through the production shell runtime path.

import std/[options, os, osproc, sequtils, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, binary_view, body, body_map, default_play, episode,
  emit_validator, instance, manifest, module_validation, runtime,
  standing_order, types, view]

const
  FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell"
  SupplyRunSource = "play_sdk" / "reference" / "supply_run.nim"
  SupplyRunWasm = "play_sdk" / ".build" / "supply_run.wasm"
  SupplyRunFuelGate = ((StepFuel * 48) div 100).uint64

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

proc buildSupplyRunWasm(): seq[byte] =
  let command = "WASI_SDK_PATH=" & quoteShell(toolPath("WASI_SDK_PATH")) &
    " nim c -f " & quoteShell(SupplyRunSource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(SupplyRunWasm)
  readFile(SupplyRunWasm).toOpenArrayByte(0,
    getFileSize(SupplyRunWasm).int - 1).toSeq

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

proc supplyModule(engine: RuntimeEngine): RuntimeModule =
  engine.checkedModule(buildSupplyRunWasm())

proc contextBytes(): string =
  buildBinaryPlayContext(PlayContextSource(
    mode: gmBr,
    mapName: "supply-test",
    mapWidth: 720,
    mapHeight: 240,
    roster: @[
      PlayContextRosterRow(seat: 0, team: Navy, control: pccPlay),
      PlayContextRosterRow(seat: 1, team: Navy, control: pccPlay),
      PlayContextRosterRow(seat: 2, team: Rust, control: pccInput)],
    selfSeat: 0,
    selfTeam: Navy,
    duoPartner: some(1),
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

proc medkit(id: uint64; pos: BodyPoint; present = some(true)): PlayItem =
  PlayItem(eventId: id, kind: pikMedkit, pos: pos, present: present,
    freshTick: 1'u32)

proc shield(id: uint64; pos: BodyPoint): PlayItem =
  PlayItem(eventId: id, kind: pikShield, pos: pos, present: some(true),
    freshTick: 1'u32)

proc track(seat: int; team: Team; pos: BodyPoint; tick = 1): PlayTrack =
  PlayTrack(seat: seat, team: team, pos: pos, freshTick: uint32(tick))

proc viewFor(self: BodyPoint; hp: int; items: seq[PlayItem] = @[];
             tracks: seq[PlayTrack] = @[]): string =
  buildBinaryPlayView(PlayViewSource(
    tick: 1'u32,
    mode: gmBr,
    epoch: 0,
    self: PlaySelf(pos: self, hp: hp, hpFrac: hp.float / 3.0,
      aimBrads: 32, alive: true),
    aliveTeams: 9,
    zone: some(PlayZone(phase: 1,
      current: PlayRect(x: 0, y: 0, w: 720, h: 240),
      ticksToShrink: 240)),
    tracks: tracks,
    items: items))

proc newSupplyInstance(engine: RuntimeEngine; module: RuntimeModule;
                       pos: BodyPoint): ShellInstance =
  newShellInstance(module, openMap(), pos, ecController, gmBr)

proc liveFrame(pos: BodyPoint; tick: int;
               tracks: seq[BodyTrackUpdate] = @[]): FirstLightSeatFrame =
  FirstLightSeatFrame(
    seat: 0,
    playerIndex: 0,
    present: true,
    playing: true,
    alive: true,
    aliveTeams: 2,
    bodyInputs: BodyTickInputs(
      self: BodySelfState(pos: pos, hp: 1, hpFrac: 1.0 / 3.0,
        lives: none(int), aimBrads: 32, fireCooldown: 0, fireWindup: 0,
        windup: none(int), hasGrenade: false, hasShield: false, shieldHp: 0,
        hasSprayPaint: false, arcTicksLeft: 0, alive: true,
        carrying: false),
      partner: some(PartnerSample(seat: 1, pos: (80, 80), alive: true)),
      visibleTracks: tracks,
      sightedItems: @[ItemSighting(kind: bikMedkit, pos: (140, 80),
        present: true, tick: uint32(tick))]),
    defaultFallbacks: BrDefaultFallbacks(
      currentZone: MapRect(x: 0, y: 0, w: 720, h: 240),
      nextZone: MapRect(x: 0, y: 0, w: 720, h: 240),
      ticksToNextShrink: BrRotateLeadTicks + 1,
      zonePhase: 1,
      zoneDps: 1,
      idleAimCenterBrads: 32,
      coverGoal: none(ValidatedGoal)))

suite "supply_run reference play":
  test "manifest bytes match the golden and parse in production":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.supplyModule()
    defer: module.close()
    var instance = engine.newSupplyInstance(module, (40, 80))
    defer: instance.close()

    let manifestResult = instance.invokeManifest()
    check not manifestResult.faulted
    check manifestResult.manifestBytes ==
      readFile(FixtureDir / "manifest_supply_run.golden.json").strip
    let parsed = parseManifest(manifestResult.manifestBytes, hasRetune = true)
    check parsed.name == "supply_run"
    check parsed.playClass == mcController
    check parsed.modes == @["br"]

  test "params decode defaults and reject invalid bounds":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.supplyModule()
    defer: module.close()
    var defaults = engine.newSupplyInstance(module, (40, 80))
    defer: defaults.close()
    defaults.initOk("{}")
    let defaultStep = defaults.invokeStep(viewFor((40, 80), 2,
      items = @[medkit(1, (120, 80))]), 1, (40, 80))
    check not defaultStep.faulted
    check defaultStep.reasonOf == "supply_run:medkit"

    for params in ["{\"contested\":\"fight\"}", "{\"detourMax\":4097}",
                   "{\"whenHpBelow\":65}"]:
      var rejected = engine.newSupplyInstance(module, (40, 80))
      defer: rejected.close()
      let init = rejected.invokeInit(params, contextBytes())
      check init.faulted
      check init.reason == "play_init returned nonzero"

  test "item reader chooses reachable medkits and ignores absent or non-medkit rows":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.supplyModule()
    defer: module.close()
    var instance = engine.newSupplyInstance(module, (40, 80))
    defer: instance.close()
    instance.initOk("{\"contested\":\"avoid\",\"detourMax\":200,\"whenHpBelow\":3}")

    let step = instance.invokeStep(viewFor((40, 80), 2, items = @[
      shield(1, (70, 80)),
      medkit(2, (100, 80), present = some(false)),
      medkit(3, (150, 80)),
      medkit(4, (120, 80))]), 1, (40, 80))
    check not step.faulted
    check step.returned == 0
    check step.counters.spatialCalls == 1
    check step.reasonOf == "supply_run:medkit"
    check step.pointOf == (120, 80)

  test "contested avoid skips and race requires strictly closer self distance":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.supplyModule()
    defer: module.close()

    block avoid:
      var instance = engine.newSupplyInstance(module, (40, 80))
      defer: instance.close()
      instance.initOk("{\"contested\":\"avoid\",\"detourMax\":200,\"whenHpBelow\":3}")
      let step = instance.invokeStep(viewFor((40, 80), 2,
        items = @[medkit(1, (100, 80))],
        tracks = @[track(2, Rust, (108, 80), tick = 0)]), 1, (40, 80))
      check not step.faulted
      check step.reasonOf == "supply_run:hold"

    block raceLosesTie:
      var instance = engine.newSupplyInstance(module, (88, 80))
      defer: instance.close()
      instance.initOk("{\"contested\":\"race\",\"detourMax\":200,\"whenHpBelow\":3}")
      let step = instance.invokeStep(viewFor((88, 80), 2,
        items = @[medkit(1, (100, 80))],
        tracks = @[track(2, Rust, (112, 80))]), 1, (88, 80))
      check not step.faulted
      check step.reasonOf == "supply_run:hold"

    block raceWins:
      var instance = engine.newSupplyInstance(module, (40, 80))
      defer: instance.close()
      instance.initOk("{\"contested\":\"race\",\"detourMax\":200,\"whenHpBelow\":3}")
      let step = instance.invokeStep(viewFor((92, 80), 2,
        items = @[medkit(1, (100, 80))],
        tracks = @[track(2, Rust, (111, 80))]), 1, (92, 80))
      check not step.faulted
      check step.reasonOf == "supply_run:medkit"

  test "live episode sighted item reaches the seat body as supply_run":
    when ShellRuntimeAvailable:
      discard buildSupplyRunWasm()
      let map = openMap()
      var episode = initFirstLightEpisode(true, true, [scPlay, scPlay], map,
        331, [Navy, Navy], "supply-live", 6)
      defer: episode.closeFirstLightEpisode()
      let lines = episode.configureFirstLightPlay(FirstLightPlayConfig(
        modulePath: SupplyRunWasm,
        playName: "supply_run",
        paramsBytes: "{\"contested\":\"avoid\",\"detourMax\":200,\"whenHpBelow\":3}",
        seats: @[0],
        uploadIdBase: 200_000,
        proposalIdBase: 201_000,
        originGeneration: 1))
      check lines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL") and
        it.contains("accepted=true"))
      let output = episode.step([liveFrame((40, 80), 1)], 1)
      check output.installs.anyIt(it.provenance == "entry:supply_run" and
        it.bytes.contains("supply_run:medkit"))

  test "live episode context uses the configured non-Navy team":
    when ShellRuntimeAvailable:
      discard buildSupplyRunWasm()
      let map = openMap()
      var episode = initFirstLightEpisode(true, true,
        [scPlay, scPlay, scInput], map, 331, [Rust, Rust, Navy],
        "supply-live", 6)
      defer: episode.closeFirstLightEpisode()
      let lines = episode.configureFirstLightPlay(FirstLightPlayConfig(
        modulePath: SupplyRunWasm,
        playName: "supply_run",
        paramsBytes: "{\"contested\":\"avoid\",\"detourMax\":200,\"whenHpBelow\":3}",
        seats: @[0],
        uploadIdBase: 202_000,
        proposalIdBase: 203_000,
        originGeneration: 1))
      check lines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL") and
        it.contains("accepted=true"))
      let output = episode.step([liveFrame((40, 80), 1, @[
        BodyTrackUpdate(seat: 2, pos: (145, 80), team: Navy,
          aimBrads: some(0), hpKnown: some(3), shielded: false,
          weapon: some(bwGun), veteranMarker: false, tick: 1'u32)])], 1)
      check output.installs.anyIt(it.provenance == "entry:supply_run" and
        it.bytes.contains("supply_run:hold"))

  test "realistic BR item view stays inside the sixty-percent fuel budget":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.supplyModule()
    defer: module.close()
    var instance = engine.newSupplyInstance(module, (40, 80))
    defer: instance.close()
    instance.initOk("{\"contested\":\"race\",\"detourMax\":1000,\"whenHpBelow\":3}")

    var items: seq[PlayItem]
    var tracks: seq[PlayTrack]
    for index in 0 ..< 32:
      items.add medkit(uint64(index + 1), (100 + index * 5, 80 + index))
      tracks.add track(index, Rust, (600 + index, 200), tick = index)
    let frame = viewFor((40, 80), 2, items = items, tracks = tracks)
    let step = instance.invokeStep(frame, 1, (40, 80))
    let consumed = step.fuelConsumed
    echo "SUPPLY_RUN_BINARY_VIEW_FUEL view_len=", frame.len,
      " items=32 tracks=32 consumed=", consumed,
      " completed=", (not step.faulted and step.returned == 0),
      " fuel_remaining=", step.fuelRemaining,
      " spatial_calls=", step.counters.spatialCalls
    check not step.faulted
    check step.returned == 0
    check consumed <= SupplyRunFuelGate

## Reference `jackal` controller through the production shell runtime path.

import std/[options, os, osproc, sequtils, strutils, unittest]

import ../src/ctf/sim_types
import ../src/shell/[abi, binary_view, body, body_map, default_play, episode,
  emit_validator, instance, manifest, module_validation, runtime,
  standing_order, types, view]

const
  FixtureDir = currentSourcePath.parentDir / "fixtures" / "shell"
  JackalSource = "play_sdk" / "reference" / "jackal.nim"
  JackalWasm = "play_sdk" / ".build" / "jackal.wasm"
  JackalFuelGate = ((StepFuel * 48) div 100).uint64

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

proc buildJackalWasm(): seq[byte] =
  let command = "WASI_SDK_PATH=" & quoteShell(toolPath("WASI_SDK_PATH")) &
    " nim c -f " & quoteShell(JackalSource)
  let built = execCmdEx(command)
  require built.exitCode == 0
  require fileExists(JackalWasm)
  readFile(JackalWasm).toOpenArrayByte(0,
    getFileSize(JackalWasm).int - 1).toSeq

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

proc jackalModule(engine: RuntimeEngine): RuntimeModule =
  engine.checkedModule(buildJackalWasm())

proc contextBytes(selfTeam = Navy): string =
  buildBinaryPlayContext(PlayContextSource(
    mode: gmBr,
    mapName: "jackal-test",
    mapWidth: 720,
    mapHeight: 240,
    roster: @[
      PlayContextRosterRow(seat: 0, team: selfTeam, control: pccPlay),
      PlayContextRosterRow(seat: 1, team: Rust, control: pccInput),
      PlayContextRosterRow(seat: 2, team: Rust, control: pccInput)],
    selfSeat: 0,
    selfTeam: selfTeam,
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

proc track(seat: int; team: Team; pos: BodyPoint; hp = none(int);
           tick = 1): PlayTrack =
  PlayTrack(seat: seat, team: team, pos: pos, hp: hp,
    freshTick: uint32(tick))

proc kill(id: uint64; tick: int; killerTeam: Team;
          victimSeat: int): PlayKillFeedRow =
  PlayKillFeedRow(eventId: id, tick: uint32(tick),
    killerTeam: killerTeam, victimSeat: victimSeat)

proc viewFor(self: BodyPoint; hp: int; tick: int;
             tracks: seq[PlayTrack] = @[];
             killFeed: seq[PlayKillFeedRow] = @[]): string =
  buildBinaryPlayView(PlayViewSource(
    tick: uint32(tick),
    mode: gmBr,
    epoch: 0,
    self: PlaySelf(pos: self, hp: hp, hpFrac: hp.float / 4.0,
      aimBrads: 32, alive: true),
    aliveTeams: 9,
    zone: some(PlayZone(phase: 1,
      current: PlayRect(x: 0, y: 0, w: 720, h: 240),
      ticksToShrink: 240, dps: 1)),
    tracks: tracks,
    killFeed: killFeed))

proc newJackalInstance(engine: RuntimeEngine; module: RuntimeModule;
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
      self: BodySelfState(pos: pos, hp: 3, hpFrac: 0.75,
        lives: none(int), aimBrads: 32, fireCooldown: 0, fireWindup: 0,
        windup: none(int), hasGrenade: false, hasShield: false, shieldHp: 0,
        hasSprayPaint: false, arcTicksLeft: 0, alive: true,
        carrying: false),
      visibleTracks: @[BodyTrackUpdate(seat: 2, pos: (220, 80), team: Rust,
        aimBrads: some(0), hpKnown: some(3), shielded: false,
        weapon: some(bwGun), veteranMarker: false, tick: uint32(tick))],
      killFeed: @[KillEvent(eventId: 1, tick: uint32(tick),
        killerTeam: Rust, victimSeat: 7)]),
    defaultFallbacks: BrDefaultFallbacks(
      currentZone: MapRect(x: 0, y: 0, w: 720, h: 240),
      nextZone: MapRect(x: 0, y: 0, w: 720, h: 240),
      ticksToNextShrink: BrRotateLeadTicks + 1,
      zonePhase: 1,
      zoneDps: 1,
      idleAimCenterBrads: 32,
      coverGoal: none(ValidatedGoal)))

suite "jackal reference play":
  test "manifest bytes match the golden and parse in production":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.jackalModule()
    defer: module.close()
    var instance = engine.newJackalInstance(module, (100, 80))
    defer: instance.close()

    let manifestResult = instance.invokeManifest()
    check not manifestResult.faulted
    check manifestResult.manifestBytes ==
      readFile(FixtureDir / "manifest_jackal.golden.json").strip
    let parsed = parseManifest(manifestResult.manifestBytes, hasRetune = true)
    check parsed.name == "jackal"
    check parsed.playClass == mcController
    check parsed.modes == @["br"]

  test "params decode defaults and reject invalid enum, bounds, and union":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.jackalModule()
    defer: module.close()
    var defaults = engine.newJackalInstance(module, (100, 80))
    defer: defaults.close()
    defaults.initOk("{}")
    let defaultStep = defaults.invokeStep(viewFor((100, 80), 3, 10,
      tracks = @[track(2, Rust, (220, 80))],
      killFeed = @[kill(1, 10, Rust, 7)]), 10, (100, 80))
    check not defaultStep.faulted
    check defaultStep.reasonOf == "jackal:join"

    for params in ["{\"earshot\":99}", "{\"earshot\":1201}",
                   "{\"joinWhen\":\"now\"}", "{\"exitAfter\":{\"kills\":5}}",
                   "{\"exitAfter\":{\"kills\":1,\"hpFloor\":2}}"]:
      var rejected = engine.newJackalInstance(module, (100, 80))
      defer: rejected.close()
      let init = rejected.invokeInit(params, contextBytes())
      check init.faulted
      check init.reason == "play_init returned nonzero"

  test "afterKill requires a public kill and a fog-visible location":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.jackalModule()
    defer: module.close()

    block noLocation:
      var instance = engine.newJackalInstance(module, (100, 80))
      defer: instance.close()
      instance.initOk("{\"earshot\":300,\"exitAfter\":{\"kills\":1},\"joinWhen\":\"afterKill\"}")
      let step = instance.invokeStep(viewFor((100, 80), 3, 10,
        killFeed = @[kill(1, 10, Rust, 7)]), 10, (100, 80))
      check not step.faulted
      check step.reasonOf == "jackal:hold"

    block killAndLocation:
      var instance = engine.newJackalInstance(module, (100, 80))
      defer: instance.close()
      instance.initOk("{\"earshot\":300,\"exitAfter\":{\"kills\":1},\"joinWhen\":\"afterKill\"}")
      let step = instance.invokeStep(viewFor((100, 80), 3, 10,
        tracks = @[track(2, Rust, (220, 80))],
        killFeed = @[kill(1, 10, Rust, 7)]), 10, (100, 80))
      check not step.faulted
      check step.reasonOf == "jackal:join"
      check step.pointOf == (220, 80)

  test "bothWeakened joins only known weak fights and otherwise loiters":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.jackalModule()
    defer: module.close()

    block loiter:
      var instance = engine.newJackalInstance(module, (100, 80))
      defer: instance.close()
      instance.initOk("{\"earshot\":200,\"exitAfter\":{\"hpFloor\":0},\"joinWhen\":\"bothWeakened\"}")
      let step = instance.invokeStep(viewFor((100, 80), 3, 10,
        tracks = @[track(2, Rust, (200, 80), hp = some(3))]), 10, (100, 80))
      check not step.faulted
      check step.reasonOf == "jackal:loiter"
      check step.pointOf == (6, 80)

    block join:
      var instance = engine.newJackalInstance(module, (100, 80))
      defer: instance.close()
      instance.initOk("{\"earshot\":300,\"exitAfter\":{\"hpFloor\":0},\"joinWhen\":\"bothWeakened\"}")
      let step = instance.invokeStep(viewFor((100, 80), 3, 10,
        tracks = @[track(2, Rust, (200, 80), hp = some(1), tick = 1),
          track(3, Rust, (240, 80), hp = some(1), tick = 2)]), 10,
        (100, 80))
      check not step.faulted
      check step.reasonOf == "jackal:join"
      check step.pointOf == (240, 80)

    block knownStrongPreventsJoin:
      var instance = engine.newJackalInstance(module, (100, 80))
      defer: instance.close()
      instance.initOk("{\"earshot\":300,\"exitAfter\":{\"hpFloor\":0},\"joinWhen\":\"bothWeakened\"}")
      let step = instance.invokeStep(viewFor((100, 80), 3, 10,
        tracks = @[track(2, Rust, (200, 80), hp = some(1), tick = 1),
          track(3, Rust, (240, 80), hp = some(1), tick = 2),
          track(4, Rust, (260, 80), hp = some(3), tick = 3)]), 10,
        (100, 80))
      check not step.faulted
      check step.reasonOf == "jackal:loiter"

  test "exitAfter leaves by own-team profit rows or hp floor":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.jackalModule()
    defer: module.close()

    block profitExit:
      var instance = engine.newJackalInstance(module, (100, 80))
      defer: instance.close()
      instance.initOk("{\"earshot\":500,\"exitAfter\":{\"kills\":1},\"joinWhen\":\"afterKill\"}")
      discard instance.invokeStep(viewFor((100, 80), 3, 10,
        tracks = @[track(2, Rust, (220, 80))],
        killFeed = @[kill(1, 10, Rust, 7)]), 10, (100, 80))
      let exit = instance.invokeStep(viewFor((100, 80), 3, 11,
        tracks = @[track(2, Rust, (220, 80))],
        killFeed = @[kill(2, 11, Navy, 2)]), 11, (100, 80))
      check not exit.faulted
      check exit.reasonOf == "jackal:exit"
      check exit.pointOf == (6, 80)

    block hpExit:
      var instance = engine.newJackalInstance(module, (100, 80))
      defer: instance.close()
      instance.initOk("{\"earshot\":500,\"exitAfter\":{\"hpFloor\":2},\"joinWhen\":\"afterKill\"}")
      discard instance.invokeStep(viewFor((100, 80), 3, 10,
        tracks = @[track(2, Rust, (220, 80))],
        killFeed = @[kill(1, 10, Rust, 7)]), 10, (100, 80))
      let exit = instance.invokeStep(viewFor((100, 80), 1, 11,
        tracks = @[track(2, Rust, (220, 80))]), 11, (100, 80))
      check not exit.faulted
      check exit.reasonOf == "jackal:exit"

  test "live episode installs jackal join order from kill feed plus fog track":
    when ShellRuntimeAvailable:
      discard buildJackalWasm()
      let map = openMap()
      var episode = initFirstLightEpisode(true, true,
        [scPlay, scInput, scInput], map, 331, [Navy, Rust, Rust],
        "jackal-live", 6)
      defer: episode.closeFirstLightEpisode()
      let lines = episode.configureFirstLightPlay(FirstLightPlayConfig(
        modulePath: JackalWasm,
        playName: "jackal",
        paramsBytes: "{\"earshot\":300,\"exitAfter\":{\"kills\":1},\"joinWhen\":\"afterKill\"}",
        seats: @[0],
        uploadIdBase: 230_000,
        proposalIdBase: 231_000,
        originGeneration: 1))
      check lines.anyIt(it.contains("FIRST_LIGHT_PLAY_CALL") and
        it.contains("accepted=true"))
      let output = episode.step([liveFrame((100, 80), 10)], 10)
      check output.installs.anyIt(it.provenance == "entry:jackal" and
        it.bytes.contains("jackal:join"))

  test "realistic BR track and kill-feed view keeps twenty-percent headroom under sixty-percent fuel":
    let engine = newRuntimeEngine()
    defer: engine.close()
    let module = engine.jackalModule()
    defer: module.close()
    var instance = engine.newJackalInstance(module, (100, 80))
    defer: instance.close()
    instance.initOk("{\"earshot\":1200,\"exitAfter\":{\"kills\":4},\"joinWhen\":\"afterKill\"}")

    var tracks: seq[PlayTrack]
    var kills: seq[PlayKillFeedRow]
    tracks.add track(0, Navy, (110, 80), hp = some(3), tick = 0)
    for index in 0 ..< 31:
      tracks.add track(index + 1, Rust, (120 + index, 80 + index),
        hp = some(1), tick = index)
    for index in 0 ..< 32:
      kills.add kill(uint64(index + 1), 100 - index,
        if index mod 2 == 0: Rust else: Navy, index + 1)
    let frame = viewFor((100, 80), 3, 100, tracks = tracks, killFeed = kills)
    let step = instance.invokeStep(frame, 100, (100, 80))
    let consumed = step.fuelConsumed
    echo "JACKAL_BINARY_VIEW_FUEL view_len=", frame.len,
      " tracks=32 kill_feed=32 consumed=", consumed,
      " completed=", (not step.faulted and step.returned == 0),
      " fuel_remaining=", step.fuelRemaining,
      " spatial_calls=", step.counters.spatialCalls
    check not step.faulted
    check step.returned == 0
    check consumed <= JackalFuelGate

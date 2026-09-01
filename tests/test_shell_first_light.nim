## Phase P3-2/P3-FL: FIRST LIGHT lifecycle, gate, annotation, and mask handoff.

import std/[json, os, options, sequtils, strutils, unittest]
import bitworld/spriteprotocol
import ../src/ctf/[replays, sim_config, sim_types]
import ../src/shell/[binary_view, body, body_map, body_nav, body_planner,
  default_play, episode, standing_order, types]

proc controls(kind: SlotControl, count: int): seq[SlotControl] =
  result = newSeq[SlotControl](count)
  for control in result.mitems:
    control = kind

proc testBodyMap(): BodyMap =
  const Side = 128
  var walkable = newSeq[bool](Side * Side)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, Side, Side, 1, @[(10, 10)])

proc openBodyMap(width = 384, height = 160): BodyMap =
  var walkable = newSeq[bool](width * height)
  for value in walkable.mitems:
    value = true
  newBodyMap(walkable, width, height, 1, @[(32, 80)])

proc dangerChoiceMap(): BodyMap =
  const
    Width = 384
    Height = 160
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      let wall = x in 184 .. 200 and
        y notin 24 .. 40 and y notin 72 .. 88
      walkable[y * Width + x] = not wall
  newBodyMap(walkable, Width, Height, 1, @[(32, 80)])

proc fallback(map: BodyMap, seat: int): BrDefaultFallbacks =
  BrDefaultFallbacks(
    currentZone: MapRect(x: 0, y: 0, w: 400, h: 400),
    nextZone: MapRect(x: 50, y: 50, w: 200, h: 200),
    ticksToNextShrink: BrRotateLeadTicks + 1,
    zonePhase: 2,
    zoneDps: 1,
    idleAimCenterBrads: seat mod 256,
    coverGoal: none(ValidatedGoal))

proc frame(map: BodyMap, seat: int, pos: BodyPoint = (0, 0), alive = true,
           playing = true): FirstLightSeatFrame =
  let selfPos = if pos == (0, 0): (10 + seat, 10) else: pos
  let hp = if alive: 4 else: 0
  let hpFrac = if alive: 1.0 else: 0.0
  FirstLightSeatFrame(
    seat: uint8(seat),
    playerIndex: seat,
    present: true,
    playing: playing,
    alive: alive,
    aliveTeams: 2,
    bodyInputs: BodyTickInputs(
      self: BodySelfState(pos: selfPos, hp: hp, hpFrac: hpFrac,
        lives: some(1), aimBrads: seat mod 256, fireCooldown: 0,
        fireWindup: 0, windup: none(int), hasGrenade: false,
        hasShield: false, shieldHp: 0, hasSprayPaint: false,
        arcTicksLeft: 0, alive: alive, carrying: false),
      partner: some(PartnerSample(seat: uint8(seat xor 1),
        pos: (20 + seat, 20), alive: true))),
    defaultFallbacks: fallback(map, seat))

proc rotateFrame(map: BodyMap, seat: int, self, target: BodyPoint,
                 tick: int, threat = none(BodyPoint)): FirstLightSeatFrame =
  result = frame(map, seat, self)
  result.bodyInputs.partner = none(PartnerSample)
  result.bodyInputs.visibleTracks.setLen(0)
  if threat.isSome:
    for seat in 8 .. 15:
      result.bodyInputs.visibleTracks.add(BodyTrackUpdate(
        seat: seat,
        pos: threat.get,
        team: Blue,
        aimBrads: some(0),
        hpKnown: some(3),
        shielded: false,
        weapon: some(bwGun),
        veteranMarker: false,
        tick: uint32(tick)))
  result.defaultFallbacks.ticksToNextShrink = BrRotateLeadTicks
  result.defaultFallbacks.rotateTarget = some(target)

proc applyMask(pos: var BodyPoint, input: InputState) =
  let bits = input.encodeInputMask()
  if (bits and ButtonLeft) != 0:
    dec pos.x, 4
  if (bits and ButtonRight) != 0:
    inc pos.x, 4
  if (bits and ButtonUp) != 0:
    dec pos.y, 4
  if (bits and ButtonDown) != 0:
    inc pos.y, 4

proc pathDanger(map: BodyMap, danger: BodyDangerField,
                path: openArray[BodyPoint]): float =
  for point in path:
    result += danger.sample(map, point)

proc recordMasks(path: string, masks: openArray[InputState],
                 configJson = "{}") =
  var writer = openReplayWriter(path, configJson)
  writer.lastMasks = newSeq[uint8](masks.len)
  for index in 0 ..< writer.lastMasks.len:
    writer.lastMasks[index] = ButtonA
  for index, input in masks:
    writer.writeInputMaskChange(0, index, input.encodeInputMask())
  writer.closeReplayWriter()

suite "shell FIRST LIGHT":
  test "checked-in fixture is a 32-seat BR play episode":
    let testsDir = currentSourcePath.parentDir
    var merged = parseFile(testsDir.parentDir / "config.practice.json")
    let firstLight = parseFile(testsDir /
      "fixtures/shell/first_light_config.json")
    for key, value in firstLight.pairs:
      if value.kind == JNull:
        merged.delete(key)
      else:
        merged[key] = value
    var config = defaultGameConfig()
    config.update($merged)
    check config.season2Shell
    check config.brMode
    check config.teams == 2
    check config.mapPath == "gen"
    check config.mapSpec.len > 0
    check parseJson(config.mapSpec)["name"].getStr() == "first-light-open-br"
    check config.minPlayers == 32
    check config.slots.len == 32
    for slot in config.slots:
      check slot.control == scPlay

  test "configured play seats parse strictly instead of inventing seat zero":
    let map = testBodyMap()
    for spec in [
        ("[\"oops\"]", "parse_error",
          "firstLightPlay.seats entries must be integers"),
        ("[-1]", "parse_error", "firstLightPlay.seats entry out of range"),
        ("[32]", "parse_error", "firstLightPlay.seats entry out of range"),
        ("[1]", "parse_error", "firstLightPlay.seats entry outside roster"),
        ("[0,0]", "parse_error", "firstLightPlay.seats entry duplicated")]:
      var episode = initFirstLightEpisode(true, true, controls(scPlay, 1),
        map, 331)
      let lines = episode.configureFirstLightDemoPlayFromJson(
        "{\"firstLightPlay\":{\"modulePath\":\"missing.wasm\"," &
        "\"playName\":\"missing\",\"params\":{},\"seats\":" & spec[0] & "}}")
      check lines.len == 1
      check ("reason=" & spec[1]) in lines[0]
      check ("detail=" & spec[2]) in lines[0]
      check "seat=0" notin lines[0]

  test "valid configured play reaches runtime gate after config validation":
    let map = testBodyMap()
    var episode = initFirstLightEpisode(true, true, controls(scPlay, 1),
      map, 331)
    let lines = episode.configureFirstLightDemoPlayFromJson(
      "{\"firstLightPlay\":{\"modulePath\":\"missing.wasm\"," &
      "\"playName\":\"missing\",\"params\":{},\"seats\":[0]}}")
    check lines.len == 1
    when ShellRuntimeAvailable:
      check "reason=module_missing" in lines[0]
    else:
      check "reason=runtime_unavailable" in lines[0]

  test "first-light binary view carries truthful hp count and fraction":
    let map = testBodyMap()
    let liveFrame = frame(map, 0, alive = true)
    let deadFrame = frame(map, 0, alive = false)
    check (liveFrame.bodyInputs.self.hp > 0) ==
      (liveFrame.bodyInputs.self.hpFrac > 0.0)
    check (deadFrame.bodyInputs.self.hp > 0) ==
      (deadFrame.bodyInputs.self.hpFrac > 0.0)
    when ShellRuntimeAvailable:
      var episode = initFirstLightEpisode(true, true, controls(scPlay, 1),
        map, 331)
      discard episode.step([liveFrame], 12)
      let bytes = episode.firstLightViewBytes(0, 12)
      check bytes[0 .. 3] == "PV1\0"
      let sectionCount = ord(bytes[7])
      var selfOffset = -1
      for index in 0 ..< sectionCount:
        let entry = BinaryFrameHeaderBytes + index * BinarySectionEntryBytes
        let kind = ord(bytes[entry]) or (ord(bytes[entry + 1]) shl 8)
        if kind == int(BvSelf):
          selfOffset = ord(bytes[entry + 8]) or
            (ord(bytes[entry + 9]) shl 8) or
            (ord(bytes[entry + 10]) shl 16) or
            (ord(bytes[entry + 11]) shl 24)
      check selfOffset >= 0
      let hpOffset = selfOffset + 12
      let hp = ord(bytes[hpOffset]) or (ord(bytes[hpOffset + 1]) shl 8) or
        (ord(bytes[hpOffset + 2]) shl 16) or
        (ord(bytes[hpOffset + 3]) shl 24)
      check hp == liveFrame.bodyInputs.self.hp

  test "activation installs safe hold then the epoch-zero default same tick":
    let map = testBodyMap()
    var episode = initFirstLightEpisode(true, true, controls(scPlay, 1),
      map, 331)
    let output = episode.step([frame(map, 0)], 7)
    check output.annotations.len == 2
    check output.annotations[0].kind == akInstallSafeIntent
    check output.annotations[0].installGeneration == 0
    check output.annotations[0].installReason == "activation"
    check output.annotations[1].kind == akAcceptedIntentChange
    check output.annotations[1].effectiveEpoch == 0
    check output.annotations[1].provenance.base.kind == pbDefault
    check output.installs.len == 2
    check output.installs[0].rule == "safe_hold"
    check output.installs[1].rule == "brHold"
    check output.installs[0].bytes ==
      "{\"arrive_radius\":0.0,\"idle_aim_center_brads\":0," &
      "\"kind\":\"hold\",\"reason\":\"first_light:safe_activation\"," &
      "\"schema\":\"intent\",\"v\":1}"
    check output.installs[1].bytes ==
      "{\"arrive_radius\":0.0,\"idle_aim_center_brads\":0," &
      "\"kind\":\"hold\",\"reason\":\"default:hold\"," &
      "\"schema\":\"intent\",\"v\":1}"
    check output.masks.len == 1

  test "death clears cache and BR never respawns":
    let map = testBodyMap()
    var episode = initFirstLightEpisode(true, true, controls(scPlay, 1),
      map, 331)
    discard episode.step([frame(map, 0)], 1)
    let death = episode.observeDeaths([frame(map, 0, alive = false)], 2)
    check death.len == 1
    check death[0].kind == akClearOnDeath
    check death[0].clearGeneration == 0
    check not episode.seats[0].active
    check episode.seats[0].eliminated
    check not episode.seats[0].standing.hasStanding

    let impossibleRespawn = episode.step([frame(map, 0)], 3)
    check impossibleRespawn.annotations.len == 0
    check impossibleRespawn.installs.len == 0
    check not episode.seats[0].active

  test "shared respawn installs fresh safe and default bytes":
    let map = testBodyMap()
    var episode = initFirstLightEpisode(true, false, controls(scPlay, 1),
      map, 331)
    let first = episode.step([frame(map, 0)], 1)
    let firstDefault = first.installs[^1].bytes
    discard episode.observeDeaths([frame(map, 0, alive = false)], 2)
    let respawn = episode.step([frame(map, 0)], 3)
    check respawn.annotations.len == 2
    check respawn.annotations[0].kind == akInstallSafeIntent
    check respawn.annotations[0].installReason == "respawn"
    check respawn.annotations[1].kind == akAcceptedIntentChange
    check respawn.annotations[1].effectiveEpoch == 0
    check respawn.installs[0].bytes ==
      "{\"arrive_radius\":0.0,\"idle_aim_center_brads\":0," &
      "\"kind\":\"hold\",\"reason\":\"first_light:safe_respawn\"," &
      "\"schema\":\"intent\",\"v\":1}"
    check respawn.installs[^1].bytes == firstDefault

  test "32 real bodies hand movement masks through the ordinary replay path":
    let map = testBodyMap()
    var episode = initFirstLightEpisode(true, true, controls(scPlay, 32),
      map, 331)
    var positions: array[32, BodyPoint]
    for seat in 0 ..< 32:
      positions[seat] = (10 + seat, 10)
    var output: FirstLightTickResult
    var sawMovement = false
    for tick in 1 .. 400:
      var frames: seq[FirstLightSeatFrame]
      for seat in 0 ..< 32:
        var row = frame(map, seat, positions[seat])
        row.defaultFallbacks.ticksToNextShrink = BrRotateLeadTicks
        row.defaultFallbacks.rotateTarget = some((100, 100))
        frames.add(row)
      output = episode.step(frames, uint32(tick))
      if output.masks.anyIt((it.input.encodeInputMask() and
          (ButtonUp or ButtonDown or ButtonLeft or ButtonRight)) != 0):
        sawMovement = true
      for mask in output.masks:
        positions[mask.seat.int].applyMask(mask.input)
    check output.masks.len == 32
    check sawMovement

    let path = getTempDir() / "shell-first-light-masks.bitreplay"
    defer:
      if fileExists(path):
        removeFile(path)
    var masks: seq[InputState]
    for mask in output.masks:
      masks.add(mask.input)
    recordMasks(path, masks)
    let replay = parseReplayBytes(readFile(path))
    check replay.inputs.len == 32
    for index, input in replay.inputs:
      check input.player == uint8(index)

  test "playback over shell-on recording constructs zero SeatBody instances":
    let path = getTempDir() / "shell-on-playback-no-bodies.bitreplay"
    defer:
      if fileExists(path):
        removeFile(path)
    recordMasks(path, [InputState(up: true)],
      "{\"season2Shell\":true,\"brMode\":true}")
    let replay = parseReplayBytes(readFile(path))
    check parseJson(replay.configJson)["season2Shell"].getBool()

    let map = testBodyMap()
    var playback = initFirstLightPlaybackEpisode(true, true,
      controls(scPlay, 1), map, 331)
    check not playback.enabled
    check playback.nav == nil
    check playback.seats.len == 0
    check playback.bodyActivationCount == 0
    discard playback.step([frame(map, 0)], 1)
    check playback.bodyActivationCount == 0

  test "gate-off hook is byte-identical and runtime inventory is compile-time":
    var episode = initFirstLightEpisode(false, true, controls(scInput, 2))
    let before = @[InputState(up: true, attack: true), InputState(left: true)]
    let map = testBodyMap()
    let output = episode.step([frame(map, 0), frame(map, 1)], 1)
    check not episode.enabled
    check output.masks.len == 0
    check output.annotations.len == 0
    check output.installs.len == 0

    var after = before
    for mask in output.masks:
      after[mask.playerIndex] = mask.input
    var beforeBytes, afterBytes: string
    for input in before:
      beforeBytes.add(char(input.encodeInputMask()))
    for input in after:
      afterBytes.add(char(input.encodeInputMask()))
    check beforeBytes == "\x21\x04"
    check afterBytes == beforeBytes

    let inventory = firstLightInventory()
    when ShellRuntimeAvailable:
      check inventory.wasmtime
      check inventory.uploads
      check inventory.calls
      check inventory.stores
      check inventory.ladder
    else:
      check not inventory.wasmtime
      check not inventory.uploads
      check not inventory.calls
      check not inventory.stores
      check not inventory.ladder

  test "episode rebuilds scheduled danger before cold planning":
    let map = dangerChoiceMap()
    let start: BodyPoint = (32, 80)
    let target: BodyPoint = (352, 80)

    proc run(threats: bool): tuple[path: seq[BodyPoint],
                                   dangerMaximum: float32,
                                   pathDanger: float,
                                   dangerSources: seq[int]] =
      var episode = initFirstLightEpisode(true, true, controls(scPlay, 1),
        map, 32)
      var pos = start
      for tick in 1 .. 160:
        let threat =
          if threats: some((192, 80)) else: none(BodyPoint)
        let output = episode.step([
          rotateFrame(map, 0, pos, target, tick, threat)], uint32(tick))
        for mask in output.masks:
          pos.applyMask(mask.input)
      result.path = episode.nav.seats[0].activePath
      result.dangerMaximum = episode.nav.seats[0].danger.maximum
      result.pathDanger = pathDanger(map, episode.nav.seats[0].danger,
        result.path)
      result.dangerSources = episode.nav.seats[0].selectedDangerSourceSeats

    let baseline = run(false)
    let threatened = run(true)
    check baseline.dangerMaximum == 0.0'f32
    check threatened.dangerMaximum > 0.0'f32
    check threatened.dangerSources == @[8, 9, 10, 11, 12, 13, 14, 15]
    check threatened.path.len > 0
    check baseline.path.len > 0
    check baseline.pathDanger == 0.0
    check threatened.pathDanger > baseline.pathDanger

  test "episode reset after sim replacement reruns safe activation boundary":
    let oldMap = openBodyMap()
    let newMap = openBodyMap(512, 192)
    var episode = initFirstLightEpisode(true, true, controls(scPlay, 1),
      oldMap, 331)
    let oldOutput = episode.step([
      rotateFrame(oldMap, 0, (32, 80), (300, 80), 1)], 1)
    let oldStandingBytes = oldOutput.installs[^1].bytes

    episode.resetFirstLightEpisode(true, true, controls(scPlay, 1), newMap, 331)
    let resetOutput = episode.step([
      rotateFrame(newMap, 0, (40, 96), (420, 96), 2)], 2)

    check resetOutput.installs.len == 2
    check resetOutput.annotations[0].kind == akInstallSafeIntent
    check resetOutput.annotations[0].installReason == "activation"
    check resetOutput.installs[0].rule == "safe_hold"
    check resetOutput.installs[0].bytes ==
      "{\"arrive_radius\":0.0,\"idle_aim_center_brads\":0," &
      "\"kind\":\"hold\",\"reason\":\"first_light:safe_activation\"," &
      "\"schema\":\"intent\",\"v\":1}"
    check resetOutput.installs.allIt(it.bytes != oldStandingBytes)
    check episode.seats[0].body.map == newMap

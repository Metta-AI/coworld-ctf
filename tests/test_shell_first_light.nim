## Phase P3-2/P3-FL: FIRST LIGHT lifecycle, gate, annotation, and mask handoff.

import std/[json, os, options, sequtils, unittest]
import bitworld/spriteprotocol
import ../src/ctf/[replays, sim_config, sim_types]
import ../src/shell/[body, body_map, default_play, episode,
  standing_order, types]

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

proc fallback(map: BodyMap, seat: int): BrDefaultFallbacks =
  BrDefaultFallbacks(
    currentZone: MapRect(x: 0, y: 0, w: 400, h: 400),
    nextZone: MapRect(x: 50, y: 50, w: 200, h: 200),
    ticksToNextShrink: BrRotateLeadTicks + 1,
    zoneDps: 1,
    idleAimCenterBrads: seat mod 256,
    coverGoal: none(ValidatedGoal))

proc frame(map: BodyMap, seat: int, pos: BodyPoint = (0, 0), alive = true,
           playing = true): FirstLightSeatFrame =
  let selfPos = if pos == (0, 0): (10 + seat, 10) else: pos
  FirstLightSeatFrame(
    seat: uint8(seat),
    playerIndex: seat,
    present: true,
    playing: playing,
    alive: alive,
    bodyInputs: BodyTickInputs(
      self: BodySelfState(pos: selfPos, hpFrac: 1.0,
        aimBrads: seat mod 256, alive: alive, carrying: false),
      partner: some(PartnerSample(seat: uint8(seat xor 1),
        pos: (20 + seat, 20), alive: true))),
    defaultFallbacks: fallback(map, seat))

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

proc recordMasks(path: string, masks: openArray[InputState]) =
  var writer = openReplayWriter(path, "{}")
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

  test "gate-off hook is byte-identical and constructs no guest inventory":
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
    check not inventory.wasmtime
    check not inventory.uploads
    check not inventory.calls
    check not inventory.stores
    check not inventory.ladder

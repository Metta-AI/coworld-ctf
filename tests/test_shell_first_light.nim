## Phase P3-2: FIRST LIGHT lifecycle, gate, annotation, and mask handoff.

import std/[json, os, unittest]
import bitworld/spriteprotocol
import ../src/ctf/[replays, sim_config, sim_types]
import ../src/shell/[default_play, episode, standing_order, types]

proc controls(kind: SlotControl, count: int): seq[SlotControl] =
  result = newSeq[SlotControl](count)
  for control in result.mitems:
    control = kind

proc frame(seat: int, alive = true, playing = true): FirstLightSeatFrame =
  FirstLightSeatFrame(
    seat: uint8(seat),
    playerIndex: seat,
    present: true,
    playing: playing,
    alive: alive,
    snapshot: LaneABrSnapshot(
      selfPos: MapPoint(x: 10 + seat, y: 10),
      currentZone: MapRect(x: 0, y: 0, w: 400, h: 400),
      nextZone: MapRect(x: 50, y: 50, w: 200, h: 200),
      ticksToNextShrink: BrRotateLeadTicks + 1,
      zoneDps: 1,
      idleAimCenterBrads: seat mod 256),
    partner: PartnerTelemetry(
      identity: SeatRef(uint8(seat xor 1)),
      pos: MapPoint(x: 20 + seat, y: 20),
      alive: true))

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
      merged[key] = value
    var config = defaultGameConfig()
    config.update($merged)
    check config.season2Shell
    check config.brMode
    check config.minPlayers == 32
    check config.slots.len == 32
    for slot in config.slots:
      check slot.control == scPlay

  test "activation installs safe hold then the epoch-zero default same tick":
    var episode = initFirstLightEpisode(true, true, controls(scPlay, 1))
    let output = episode.step([frame(0)], 7)
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
    check output.masks[0].input.encodeInputMask() == 0

  test "death clears cache and BR never respawns":
    var episode = initFirstLightEpisode(true, true, controls(scPlay, 1))
    discard episode.step([frame(0)], 1)
    let death = episode.observeDeaths([frame(0, alive = false)], 2)
    check death.len == 1
    check death[0].kind == akClearOnDeath
    check death[0].clearGeneration == 0
    check not episode.seats[0].active
    check episode.seats[0].eliminated
    check not episode.seats[0].standing.hasStanding

    let impossibleRespawn = episode.step([frame(0)], 3)
    check impossibleRespawn.annotations.len == 0
    check impossibleRespawn.installs.len == 0
    check not episode.seats[0].active

  test "shared respawn installs fresh safe and default bytes":
    var episode = initFirstLightEpisode(true, false, controls(scPlay, 1))
    let first = episode.step([frame(0)], 1)
    let firstDefault = first.installs[^1].bytes
    discard episode.observeDeaths([frame(0, alive = false)], 2)
    let respawn = episode.step([frame(0)], 3)
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
    check episode.seats[0].body.installCount == 2

  test "32 placeholder bodies hand zero masks through the ordinary replay path":
    var episode = initFirstLightEpisode(true, true, controls(scPlay, 32))
    var frames: seq[FirstLightSeatFrame]
    for seat in 0 ..< 32:
      frames.add(frame(seat))
    let output = episode.step(frames, 1)
    check output.masks.len == 32
    check output.annotations.len == 64
    check output.installs.len == 64

    let path = getTempDir() / "shell-first-light-masks.bitreplay"
    defer:
      if fileExists(path):
        removeFile(path)
    var masks: seq[InputState]
    for mask in output.masks:
      check mask.input.encodeInputMask() == 0
      masks.add(mask.input)
    recordMasks(path, masks)
    let replay = parseReplayBytes(readFile(path))
    check replay.inputs.len == 32
    for index, input in replay.inputs:
      check input.player == uint8(index)
      check input.keys == 0

  test "gate-off hook is byte-identical and constructs no guest inventory":
    var episode = initFirstLightEpisode(false, true, controls(scInput, 2))
    let before = @[InputState(up: true, attack: true), InputState(left: true)]
    let output = episode.step([frame(0), frame(1)], 1)
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

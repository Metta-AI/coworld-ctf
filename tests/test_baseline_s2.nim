## The baseline's Season 2 half: the wire codec (against the SAME checked-in
## byte goldens `tests/test_shell_packets.nim` proves the production
## `src/shell/packets.nim` codec against, so this independently-written
## client codec is asserted byte-identical to the server's own, not merely
## self-consistent) and the gated play-calling loop (`s2play.nim`).
##
## What this suite does NOT cover: the live `S2Seat`/`runS2Session` socket
## machinery, which needs a real websocket and is exercised instead by
## actually running a local `battle-royale-s2` episode (see the branch's PR
## description for the recorded evidence: 16/16 seats detect Season 2,
## upload the reference playbook, call plays, and the match completes with
## real kills; the forced-failure counterpart with the pre-change baseline
## reproduces PR #524's "Malformed sprite protocol packet" crash).

import std/[json, os, strutils, unittest]
import ../players/baseline/baseline/s2wire
import ../players/baseline/baseline/s2play

const FixtureDir = "tests" / "fixtures" / "shell" / "packets"

suite "baseline S2 wire codec matches the production byte goldens":
  test "encodeModuleUpload matches module_upload.bin":
    check encodeModuleUpload(0x0102030405060708'u64, "\0asm\1\0\0\0") ==
      readFile(FixtureDir / "module_upload.bin")

  test "encodePlayCall matches play_call.bin":
    check encodePlayCall(0x8877665544332211'u64, "{\"plays\":[]}") ==
      readFile(FixtureDir / "play_call.bin")

  test "encodeStatusAck matches status_ack.bin":
    check encodeStatusAck(0x0102030405060708'u64) ==
      readFile(FixtureDir / "status_ack.bin")

  test "decodeServerPacket parses play_context.bin":
    let packet = decodeServerPacket(readFile(FixtureDir / "play_context.bin"))
    check packet.kind == spkPlayContext
    check packet.control == "{\"gen\":\"1\"}"
    check packet.context == "{\"mode\":\"br\"}"

  test "decodeServerPacket parses play_view.bin":
    let packet = decodeServerPacket(readFile(FixtureDir / "play_view.bin"))
    check packet.kind == spkPlayView
    check packet.tick == 0x01020304'u32
    check packet.viewControl == "{\"gen\":\"2\"}"
    check packet.view == "{\"self\":{}}"

  test "decodeServerPacket parses a control-only (viewLen=0) play_view":
    let packet = decodeServerPacket(
      readFile(FixtureDir / "play_view_control_only.bin"))
    check packet.kind == spkPlayView
    check packet.tick == 37'u32
    check packet.view.len == 0

  test "decodeServerPacket parses lobby_chat_broadcast.bin":
    let packet = decodeServerPacket(
      readFile(FixtureDir / "lobby_chat_broadcast.bin"))
    check packet.kind == spkLobbyChat
    check packet.ordinal == 0x0102030405060708'u64
    check packet.chatTick == 99'u32
    check packet.seat == 3'u8
    check packet.team == 12'u8
    check packet.text == "pact?"

  test "decodeServerPacket ignores a byte outside 0xB0/0xB1/0xB2":
    ## Per §4.3: a play socket may also carry the legacy Sprite v1 stream,
    ## so a conforming client ignores it rather than treating it as an error.
    let packet = decodeServerPacket("\x87")
    check packet.kind == spkIgnored

  test "isPlayContextOpcode is the exact dispatch predicate runBot uses":
    check isPlayContextOpcode(readFile(FixtureDir / "play_context.bin"))
    check not isPlayContextOpcode(readFile(FixtureDir / "play_view.bin"))
    check not isPlayContextOpcode("")

suite "baseline S2 canonical call encoding":
  test "canonicalEntry sorts keys alphabetically (entry_id < params < play)":
    check canonicalEntry("edge_ride", "base") ==
      "{\"entry_id\":\"base\",\"play\":\"edge_ride\"}"
    check canonicalEntry("target_law", "prefer", @["weakened", "isolated"]) ==
      "{\"entry_id\":\"prefer\",\"params\":{\"prefer\":[\"weakened\"," &
      "\"isolated\"]},\"play\":\"target_law\"}"

  test "canonicalLadder wraps entries in the {\"plays\":[...]} envelope":
    check canonicalLadder(@["A", "B"]) == "{\"plays\":[A,B]}"
    check canonicalLadder(@[]) == "{\"plays\":[]}"

suite "baseline S2 gated play loop (ported from starter_harness.py)":
  test "the wanted ladder with no view is just the overlay plus the base":
    let ladder = encodeLadder(buildLadder(nil, nil))
    check "target_law" in ladder
    check "edge_ride" in ladder
    check "supply_run" notin ladder
    check "loot" notin ladder

  test "supply_run gates open when wounded with a medkit in reach":
    let view = %*{
      "tick": 100,
      "self": {"pos": [100, 100], "hp": 1, "hp_frac": 0.33},
      "items": [{"kind": "medkit", "pos": [150, 100], "present": true}]
    }
    check supplyRunGateOpen(view, nil)
    let ladder = encodeLadder(buildLadder(view, nil))
    check "supply_run" in ladder

  test "supply_run stays closed when full health even with a medkit close":
    let view = %*{
      "tick": 100,
      "self": {"pos": [100, 100], "hp": 6, "hp_frac": 1.0},
      "items": [{"kind": "medkit", "pos": [110, 100], "present": true}]
    }
    check not supplyRunGateOpen(view, nil)

  test "supply_run stays closed when wounded but no medkit is in reach":
    let view = %*{
      "tick": 100,
      "self": {"pos": [100, 100], "hp": 1, "hp_frac": 0.2},
      "items": newJArray()
    }
    check not supplyRunGateOpen(view, nil)

  test "loot gates open when clear of fresh enemies with an item in reach":
    let view = %*{
      "tick": 100,
      "self": {"pos": [100, 100]},
      "tracks": newJArray(),
      "items": [{"kind": "shield", "pos": [140, 100], "present": true}]
    }
    let ladder = encodeLadder(buildLadder(view, nil))
    check "loot" in ladder

  test "loot stays closed with a fresh enemy inside the clear radius":
    let view = %*{
      "tick": 100,
      "self": {"pos": [100, 100]},
      "tracks": [{"seat": 7, "team": "blue", "pos": [140, 100],
                  "fresh_tick": 99}],
      "items": [{"kind": "shield", "pos": [140, 100], "present": true}]
    }
    check not lootGateOpen(view, nil)

  test "loot ignores a stale (not-fresh) enemy track":
    let view = %*{
      "tick": 1000,
      "self": {"pos": [100, 100]},
      "tracks": [{"seat": 7, "team": "blue", "pos": [140, 100],
                  "fresh_tick": 1}],
      "items": [{"kind": "shield", "pos": [140, 100], "present": true}]
    }
    check lootGateOpen(view, nil)

  test "loot never substitutes for supply_run (medkits excluded)":
    let view = %*{
      "tick": 100,
      "self": {"pos": [100, 100]},
      "tracks": newJArray(),
      "items": [{"kind": "medkit", "pos": [110, 100], "present": true}]
    }
    check not lootGateOpen(view, nil)

  test "a duo partner's own track never counts as an enemy for loot's gate":
    let context = %*{"self": {"seat": 0, "team": "red", "duo_partner": 1}}
    let view = %*{
      "tick": 100,
      "self": {"pos": [100, 100]},
      "tracks": [{"seat": 1, "team": "red", "pos": [140, 100],
                  "fresh_tick": 99}],
      "items": [{"kind": "shield", "pos": [140, 100], "present": true}]
    }
    check lootGateOpen(view, context)

## GLORY GRADIENT S8 (GameVersion 63->64, epic 25d9108e): the game-side
## seat-identity consumer. Metta PR #22382 (`dispatcher: forward per-seat
## platform identity to the game runtime`) sets `COWORLD_SEAT_IDENTITY` on
## a platform-hosted episode's game container -- a JSON object keyed by
## seat position -> `{player_id, policy_version_id, policy_name, round_id,
## episode_id, is_filler?}`, any value possibly `null`. This suite proves
## both halves of the consumer: `parseSeatIdentity` (server.nim) turns that
## env var's JSON into `SeatIdentityEntry` rows, and `over.identity`
## (broadcast.nim) carries them on the wire when present, is ABSENT when
## not -- the two states GV63's own changelog scoped this batch to close
## (no inbound channel existed before this PR).

import
  helpers,
  std/[json, os, unittest],
  ctf/[broadcast, server, sim]

suite "parseSeatIdentity: COWORLD_SEAT_IDENTITY -> SeatIdentityEntry":
  test "empty string (env unset) parses to an empty seq":
    check parseSeatIdentity("").len == 0

  test "malformed JSON parses to an empty seq, does not raise":
    check parseSeatIdentity("not json").len == 0
    check parseSeatIdentity("[]").len == 0        # a JSON array, not object
    check parseSeatIdentity("""{"0": "not an object"}""").len == 0

  test "well-formed shape: every field, plus a filler seat and a null player_id":
    let raw = """{
      "0": {"player_id": "ply_abc", "policy_version_id": "pv_1",
             "policy_name": "monet", "round_id": "r4700",
             "episode_id": "ep_1", "is_filler": false},
      "1": {"player_id": null, "policy_version_id": "pv_baseline",
             "policy_name": "baseline", "round_id": null,
             "episode_id": "ep_1", "is_filler": true}
    }"""
    let entries = parseSeatIdentity(raw)
    check entries.len == 2
    let bySlot = block:
      var t: array[2, SeatIdentityEntry]
      for e in entries:
        t[e.slot] = e
      t
    check bySlot[0].playerId == "ply_abc"
    check bySlot[0].policyVersionId == "pv_1"
    check bySlot[0].policyName == "monet"
    check bySlot[0].roundId == "r4700"
    check bySlot[0].episodeId == "ep_1"
    check bySlot[0].isFiller == false
    # null player_id / round_id -> "" sentinel (SeatIdentityEntry's own
    # doc comment), never a crash or a literal "null" string.
    check bySlot[1].playerId == ""
    check bySlot[1].roundId == ""
    check bySlot[1].policyVersionId == "pv_baseline"
    check bySlot[1].isFiller == true

  test "a non-integer seat key is skipped, not fatal to the rest":
    let raw = """{"not-a-slot": {"player_id": "x"}, "2": {"player_id": "y"}}"""
    let entries = parseSeatIdentity(raw)
    check entries.len == 1
    check entries[0].slot == 2
    check entries[0].playerId == "y"

  test "reads through the real env var, end to end (putEnv -> getEnv -> parse)":
    putEnv("COWORLD_SEAT_IDENTITY", """{"0": {"player_id": "ply_env"}}""")
    let entries = parseSeatIdentity(getEnv("COWORLD_SEAT_IDENTITY"))
    delEnv("COWORLD_SEAT_IDENTITY")
    check entries.len == 1
    check entries[0].playerId == "ply_env"

suite "over.identity: present when sim.seatIdentity is set, absent when it is not":
  test "absent by default -- no seat identity, no key on the wire":
    var sim = twoTeamGame()
    sim.finishGame(Red)
    check sim.seatIdentity.len == 0    # unconditional empty seq idiom
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 1000, false, true, -1, -1
    ))
    check state["ph"].getStr == "gameover"
    check not state["over"].hasKey("identity")

  test "present when sim.seatIdentity is set (what a live process does from the env)":
    var sim = twoTeamGame()
    sim.seatIdentity = parseSeatIdentity("""{
      "0": {"player_id": "ply_red0", "policy_version_id": "pv_9",
             "policy_name": "monet", "round_id": "r4700",
             "episode_id": "ep_42", "is_filler": false},
      "1": {"player_id": null, "policy_version_id": "pv_baseline",
             "policy_name": "baseline", "is_filler": true}
    }""")
    sim.finishGame(Red)
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 1000, false, true, -1, -1
    ))
    require state["over"].hasKey("identity")
    let identity = state["over"]["identity"]
    check identity.len == 2
    var bySlot: array[2, JsonNode]
    for entry in identity:
      bySlot[entry["slot"].getInt] = entry
    check bySlot[0]["playerId"].getStr == "ply_red0"
    check bySlot[0]["policyVersionId"].getStr == "pv_9"
    check bySlot[0]["roundId"].getStr == "r4700"
    check bySlot[0]["episodeId"].getStr == "ep_42"
    check bySlot[0]["isFiller"].getBool == false
    check bySlot[1]["playerId"].getStr == ""     # null -> "" sentinel, on the wire too
    check bySlot[1]["isFiller"].getBool == true

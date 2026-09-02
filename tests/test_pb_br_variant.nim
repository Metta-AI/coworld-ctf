## The "battle-royale-s2" variant paintbot now ships: 8 duo teams, 2 agents
## each, 16 seats total -- the half-field rescale of the original
## 32-seat/16-duo shape (owner capacity ruling: we don't field 32 players),
## same rules and zone pacing on a half-area map. This is the manifest-plus-sim companion to
## two things that already exist and stay untouched:
##   - test_br_elim.nim, which already proves BR's elimination/tiebreak/zone
##     machinery is generic over team count and over seats-per-team (its
##     own `brGame`/`brDuoGame` builders cover both 1- and 2-per-team
##     shapes);
##   - test_pb_manifest.nim / test_manifest_schema.nim, which prove every
##     variant's game_config keys are covered by config_schema and that the
##     results_schema covers everything either results document writes.
##
## What neither of those pins is the property specific to THIS variant:
## that the shipped 16-seat roster pairs slot k with slot k+8 on the SAME
## team (the duo shape -- BR_MAPGEN.md's duo pocket, see arena.nim's
## spawnPosition/spawnGroupOffset; the duo offset is DERIVED, seats/teams,
## never a constant), across all 8 teams -- and that the results payload
## built from that 16-seat roster carries exactly one score entry per SEAT
## (16, not 8): the score-arity property a hosted recertify actually
## enforces. A paintbot recertify failed earlier the
## same day with "game returned 32 scores for 16 seats" on a CLASSIC
## config where one seat commands a squad of cogs (loadout: paintball,
## cogsPerTeam > 1) -- squadResultsJson's per-SEAT count there is 16.  BR
## is a different shape: each of the 32 duo SEATS is its own independent
## join (loadout stays the "ctf" default, never paintball), so
## ctfPlayerResultsJson's per-slot count is 32 -- this suite asserts that
## number directly rather than assuming it matches the other bug's shape
## just because 32 appears in both stories.
##
## A real bot-driven 32-seat (16-duo) episode -- baseline vs baseline, this
## exact variant's game_config and mapSpec -- was separately run end to end
## outside this suite and reached a real winner with this same 32-entry
## results shape; see the PR description for the observed numbers. The
## tests below are the fast, deterministic CI guard for that shape, in the
## same direct-kill style test_br_elim.nim already uses (no scripted
## combat needed to prove the win/results contract).

import
  helpers,
  std/[json, tables, unittest],
  ctf/sim

const
  ManifestPath = "coworld_manifest_paintbot.json"
  Teams = 8
  SeatsPerTeam = 2
  Seats = Teams * SeatsPerTeam
  VariantId = "battle-royale-s2"

proc findVariant(manifest: JsonNode): JsonNode =
  for variant in manifest["variants"]:
    if variant["id"].getStr() == VariantId:
      return variant
  doAssert false, ManifestPath & " has no " & VariantId & " variant"

suite "paintbot manifest, battle-royale-s2 variant":
  let
    manifest = parseJson(readFile(ManifestPath))
    variant = manifest.findVariant()
    gc = variant["game_config"]

  test "16 seats, 8 teams x 2 -- slot k paired with slot k+8 (the duo shape)":
    check gc["players"].len == Seats
    check gc["slots"].len == Seats
    check gc["num_agents"].getInt() == Seats
    check gc["minPlayers"].getInt() == Seats
    check gc["teams"].getInt() == Teams
    check gc["lives"].getInt() == 1
    check gc["maxGames"].getInt() == 1
    check gc["brMode"].getBool()
    check gc["season2Shell"].getBool()
    check gc["zonePhases"].len > 0
    var seen: seq[string]
    for i in 0 ..< Teams:
      let team = gc["slots"][i]["team"].getStr()
      check team notin seen        ## the first 8 slots are 8 DISTINCT teams.
      seen.add team
      ## slot k and slot k+8 are the SAME team -- the duo pairing this
      ## variant is now pinned to. The offset is seats/teams by derivation
      ## (teamForSlot deals order mod teamCount), so the 16-seat shape
      ## pairs at +8 exactly where the 32-seat one paired at +16.
      check gc["slots"][i + Teams]["team"].getStr() == team
    check seen.len == Teams

  test "every key this variant sets is declared in config_schema":
    let props = manifest["game"]["config_schema"]["properties"]
    for key, _ in gc:
      check props.hasKey(key)

  test "a REAL sim built from the variant's own game_config seats 16 duo seats across 8 teams":
    var config = defaultGameConfig()
    config.update($gc)
    check config.brMode
    check config.teams == Teams
    var sim = initCtfForTest(config)
    ## The variant's own "players" list binds each slot's NAME (see
    ## roster.nim's slotRestricted/matchingConfiguredSlot): a real join
    ## must use the configured "Player1".."Player16" identities to seat
    ## in order, exactly like a real episode's roster does.
    for i in 0 ..< Seats:
      discard sim.addPlayer("Player" & $(i + 1))
    sim.startGame()
    check sim.players.len == Seats
    check sim.gameMap.teamCount() == Teams
    var perTeam = initTable[Team, int]()
    for player in sim.players:
      perTeam[player.team] = perTeam.getOrDefault(player.team, 0) + 1
      check sim.config.seatLivesFor(player.team) == 0  ## brMode: no spares.
    check perTeam.len == Teams
    for team, count in perTeam:
      check count == SeatsPerTeam   ## every team fields exactly its duo.

  test "wiping 7 of 8 duo teams ends the round with ONE winning team and exactly 16 score entries":
    var config = defaultGameConfig()
    config.update($gc)
    var sim = initCtfForTest(config)
    for i in 0 ..< Seats:
      discard sim.addPlayer("Player" & $(i + 1))
    sim.startGame()
    let survivorTeam = sim.players[0].team
    check sim.players[Teams].team == survivorTeam  ## slot 0's duo partner is slot 8.
    ## Wipe every OTHER team's both seats (slots 1..7 and their partners
    ## 9..15), leaving team 0's duo (slots 0 and 8) as the sole survivor.
    ## This variant now arms downedMode (LOOT(s2)), so killPlayer's first
    ## call on an upright cog DOWNS it (a frozen, still-`alive` ghost) --
    ## src/ctf/sim.nim's killPlayer interception, `sim.downPlayer`. A second
    ## killPlayer call on that same (now downed) victim carries it past the
    ## interception guard (`not sim.players[targetIndex].downed` is false)
    ## and completes the permanent death, the same path a real splat or
    ## bleed-out finalization (`finalizeDowned`) takes. Two calls per
    ## victim is this test's from-outside-the-module equivalent of "down,
    ## then finish" -- the whole team must be genuinely dead, not merely
    ## downed, before checkWinCondition can end the round.
    for i in 1 ..< Teams:
      sim.killPlayer(i, 0)
      sim.killPlayer(i, 0)
      sim.killPlayer(i + Teams, 0)
      sim.killPlayer(i + Teams, 0)
    sim.checkWinCondition()
    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner == survivorTeam

    ## The score-arity property a hosted recertify actually enforces: BR's
    ## 16-SEAT roster (8 duo teams) must carry exactly 16 score entries --
    ## one per seat, never 8 (one per team/squad).
    let results = parseJson(sim.playerResultsJson())
    check results["scores"].len == Seats
    check results["names"].len == Seats
    check results["win"].len == Seats
    check results["team"].len == Seats
    check results["kills"].len == Seats
    check results["deaths"].len == Seats
    var winners = 0
    for w in results["win"]:
      if w.getBool():
        inc winners
    check winners == SeatsPerTeam   ## both seats of the winning duo score a win.

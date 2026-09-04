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
    # PERCEPTION (glory-2 §17): this variant ships ARMED, not dark -- the
    # owner's doctrine call. Frame loadout flags and duo held-state are
    # live on the flagship variant from day one.
    check config.frameLoadoutFlags
    # WIN-AS-MULTIPLIER (glory-2 A6/Amendment 7): ROLLED BACK 2026-09-04.
    # The dTagBack revive-loop (zone bleed re-downs partner ~every 9 ticks,
    # revive at 48 -> a 57-tick metronome minting x2 per Revived, 24-27x per
    # episode = 2^24+ overshoot; see glorybug 09:2x in the tg5 ledger) blew
    # the 28,311,552 ceiling by ~10^6. Flag stays false until repeatable
    # deeds get per-episode mint caps / diminishing rungs. v13 dVictory
    # economy is live again via this switch, exactly as designed.
    check config.gloryMultiplierRecut
    check not config.winAsMultiplier
    # PAINTDEATH (owner ruling 2026-09-03): the flagship ships the zone as
    # LETHAL GROUND -- paint damages you AND admits no rescue. Armed here,
    # not dark: it is the root fix for the revive-loop above, and the
    # precondition this variant's winAsMultiplier re-arm rides on.
    check config.zoneDamageByPaint
    check config.zoneBlocksRevive
    # MINTCAP: the OTHER half of the same re-arm gate. zoneBlocksRevive
    # above kills the revive loop MECHANICALLY on painted ground; the
    # caps bound any repeatable-deed composition, including the dry-ground
    # down/revive cycle that gate does not touch. ARMED 2026-09-04 (owner
    # ruling, tg5 18:2x): #402 (zoneBlocksRevive) + this cap table are both
    # landed, so the first half of the two-part re-arm gate is complete --
    # arming the caps DOES change ARMED-recut scoring from here on
    # (dDuoDown/dShieldSoak are priced under the live gloryMultiplierRecut
    # variant), which is the point: bound the composition before more
    # rounds bank under it. winAsMultiplier itself stays a SEPARATE owner
    # beat, staged until N>=3 caps-era rounds verify sane tops.
    check config.deedMintCaps
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

  test "the variant's items actually LAND: bandages placed, hoppers traffic-sited, every family inside the board's pool":
    ## ITEM COMPLETENESS (epic 1ef4f9d6 T3 + the hopper site-class spec):
    ## `bandagePickups` was absent from config_schema entirely, so a fully
    ## built item — placement path, touch pickup, +1 hp calm-clock apply,
    ## wire token, exchange whitelist, ground sprite — could not be reached
    ## from the platform at all (the #389 class of gap: armed in a variant,
    ## undeclared in the schema, except here it was armed nowhere either).
    ## The hopper fallback meanwhile inherited the med kits' RETREAT siting.
    ## Both are asserted on the REAL sim built from the variant's own
    ## game_config, not on the manifest's prose.
    check gc["bandagePickups"].getInt > 0
    check gc["hopperSiteTrafficPermille"].getInt > 0
    var config = defaultGameConfig()
    config.update($gc)
    var sim = initCtfForTest(config)
    for i in 0 ..< Seats:
      discard sim.addPlayer("Player" & $(i + 1))
    sim.startGame()
    check sim.bandageSpawns.len == gc["bandagePickups"].getInt
    check sim.weaponSpawns.len > 0
    check sim.hopperSpawns.len > 0
    ## Every neutral family must fit its object-id pool: a BR-pool map sizes
    ## its med-kit/spray pools at runtime, and the un-deduped hopper fallback
    ## used to place ~80 crates into a 64-wide pool — past the width the
    ## render loop clamps and its own doAssert fires, so this is the guard
    ## that keeps a live episode off that assert.
    for family in [sim.weaponSpawns, sim.hopperSpawns, sim.bandageSpawns,
                   sim.medKitSpawns, sim.sprayPaintSpawns, sim.shieldSpawns,
                   sim.grenadeSpawns]:
      check family.len <= NeutralPickupPoolWidth
    ## No family stacks two crates on one pixel (the taker's own carry gate
    ## walks it straight over the twin), and the gun's two halves never
    ## share one walk-over.
    proc distinctPixels(spawns: seq[PickupSpawn]): int =
      var seen: seq[tuple[x, y: int]]
      for spawn in spawns:
        if (spawn.x, spawn.y) notin seen:
          seen.add (spawn.x, spawn.y)
      seen.len
    check distinctPixels(sim.hopperSpawns) == sim.hopperSpawns.len
    check distinctPixels(sim.weaponSpawns) == sim.weaponSpawns.len
    check distinctPixels(sim.bandageSpawns) == sim.bandageSpawns.len
    ## The measurable: a MAJORITY of the fallback hoppers now sit on the
    ## traffic class. Counted as "not on any med-kit point's own walkable
    ## cell" — the retreat sites are exactly the points the fallback used to
    ## use for all of them.
    var kitPixels: seq[tuple[x, y: int]]
    for point in sim.gameMap.medKitSpawns & sim.gameMap.medKitCandidates:
      let spot = sim.nearestWalkable(point.x, point.y)
      if spot notin kitPixels:
        kitPixels.add spot
    var offRetreat = 0
    for spawn in sim.hopperSpawns:
      if (spawn.x, spawn.y) notin kitPixels:
        inc offRetreat
    check offRetreat * 2 > sim.hopperSpawns.len

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

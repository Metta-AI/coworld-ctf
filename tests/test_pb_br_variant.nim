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

  test "the variant's loot economy ships DARK (2026-09-04 owner simplification): bandages, hopper crates, gun crates all off":
    ## Owner simplification, 2026-09-04 (PKG-A, flags-off): battle-royale-s2
    ## went back to explicit bandagePickups: 0 / hopperSiteTrafficPermille: 0
    ## / lootStart: false. This test used to assert the loot economy (epic
    ## 1ef4f9d6 T3 + the hopper site-class spec) actually LANDED; it now
    ## asserts the opposite on purpose — that flipping the flags off really
    ## produces an empty item economy on the REAL sim built from the
    ## variant's own game_config, not a half-armed one. Every key stays
    ## PRESENT in the manifest at 0/false (one-token rollback) — see the PR
    ## body for the re-arm path (PR-body-half-life: this comment is the one
    ## that survives, not the PR description).
    check gc["bandagePickups"].getInt == 0
    check gc["hopperSiteTrafficPermille"].getInt == 0
    var config = defaultGameConfig()
    config.update($gc)
    var sim = initCtfForTest(config)
    for i in 0 ..< Seats:
      discard sim.addPlayer("Player" & $(i + 1))
    sim.startGame()
    check sim.bandageSpawns.len == 0    ## resetBandages no-ops at count <= 0.
    check sim.weaponSpawns.len == 0     ## resetLootCrates no-ops when lootStart is dark.
    check sim.hopperSpawns.len == 0
    ## Every neutral family (even empty ones) must still fit its object-id
    ## pool — a cheap regression guard against a future re-arm overshooting
    ## the board's 64-wide per-family pool.
    for family in [sim.weaponSpawns, sim.hopperSpawns, sim.bandageSpawns,
                   sim.medKitSpawns, sim.sprayPaintSpawns, sim.shieldSpawns,
                   sim.grenadeSpawns]:
      check family.len <= NeutralPickupPoolWidth
    ## medKitCount stays unset (-1): the map's own full med-kit set is the
    ## restored pre-S2 healing path now that bandages are off.
    check sim.medKitSpawns.len > 0

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
    ## Owner simplification, 2026-09-04 (PKG-A): this variant no longer
    ## arms downedMode, so killPlayer's first call on an upright cog is a
    ## genuine, permanent kill straight away -- no downed-ghost
    ## interception (`sim.downPlayer`) sits in front of it. One call per
    ## victim wipes the team, matching the pre-S2 (dark) killPlayer path.
    ## (Previously this needed two calls per victim to walk past the
    ## downed-ghost interception guard; re-arming downedMode would need
    ## that back — see the PR body for the re-arm path.)
    for i in 1 ..< Teams:
      sim.killPlayer(i, 0)
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

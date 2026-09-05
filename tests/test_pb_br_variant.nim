## The "battle-royale-s2" variant paintbot now ships: 16 SOLO teams, 1 agent
## each, 16 seats total (PKG-C, 2026-09-04 rework) -- superseding the prior
## 8-duo/2-agent shape. Owner capacity ruling stands unchanged (we don't
## field the classic 32-seat giant), but the seat/team ratio inside that
## 16-seat field flipped from 2 to 1: every policy now enters as its own
## team, no partner. This is the manifest-plus-sim companion to two things
## that already exist and stay untouched:
##   - test_br_elim.nim, which already proves BR's elimination/tiebreak/zone
##     machinery is generic over team count and over seats-per-team (its
##     own `brGame`/`brDuoGame` builders cover both 1- and 2-per-team
##     shapes);
##   - test_pb_manifest.nim / test_manifest_schema.nim, which prove every
##     variant's game_config keys are covered by config_schema and that the
##     results_schema covers everything either results document writes.
##
## What neither of those pins is the property specific to THIS variant:
## that the shipped 16-seat roster now seats 16 DISTINCT teams (slot i IS
## team i, no k/k+8 duo pairing left to assert) -- and that the results
## payload built from that 16-seat roster carries exactly one score entry
## per SEAT (16, not fewer): the score-arity property a hosted recertify
## actually enforces. A paintbot recertify failed earlier the same day
## (pre-rework) with "game returned 32 scores for 16 seats" on a CLASSIC
## config where one seat commands a squad of cogs (loadout: paintball,
## cogsPerTeam > 1) -- squadResultsJson's per-SEAT count there is 16. BR
## is a different shape: each seat is its own independent join (loadout
## stays the "ctf" default, never paintball), so ctfPlayerResultsJson's
## per-slot count matches the seat count directly -- this suite asserts
## that number directly rather than assuming it matches the other bug's
## shape just because a seat count appears in both stories.
##
## A real bot-driven 16-seat (16-solo) episode -- baseline vs baseline, this
## exact variant's game_config and mapSpec -- was separately run end to end
## outside this suite and reached a real winner with this same results
## shape; see the PR description for the observed numbers. The tests below
## are the fast, deterministic CI guard for that shape, in the same
## direct-kill style test_br_elim.nim already uses (no scripted combat
## needed to prove the win/results contract).

import
  helpers,
  std/[json, tables, unittest],
  ctf/sim

const
  ManifestPath = "coworld_manifest_paintbot.json"
  Teams = 16
  SeatsPerTeam = 1
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

  test "16 seats, 16 solo teams -- every slot is its own distinct team":
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
    ## No duo pairing left to pin: all 16 slots are 16 DISTINCT teams, one
    ## seat each. The engine's 16-color enum prefix, in the same order the
    ## classic 32-seat "battle-royale" variant uses for its own 16 teams.
    const ExpectedColors = ["red", "blue", "green", "yellow", "black",
      "silver", "ivory", "pink", "umber", "rust", "orange", "plum", "lime",
      "navy", "azure", "peach"]
    check ExpectedColors.len == Teams
    var seen: seq[string]
    for i in 0 ..< Teams:
      let team = gc["slots"][i]["team"].getStr()
      check team notin seen
      check team == ExpectedColors[i]
      seen.add team
    check seen.len == Teams

  test "every key this variant sets is declared in config_schema":
    let props = manifest["game"]["config_schema"]["properties"]
    for key, _ in gc:
      check props.hasKey(key)

  test "a REAL sim built from the variant's own game_config seats 16 solo seats across 16 teams":
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
      check count == SeatsPerTeam   ## every team fields exactly its one solo seat.

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

  test "OBJBALANCE (owner directive 2026-09-05): fewer spray cans, more grenades, on the REAL sim":
    ## Pre-pivot objbalance analysis, rec B: spray cans were the map's most
    ## plentiful pickup and grenades its scarcest disposable, the inversion
    ## of their intended rarity. The flagship variant ships both fixes at
    ## once -- sprayCount caps the cans, grenadeCount injects supply -- and
    ## this proves the manifest values AND the mechanism they drive on a
    ## real sim built from the variant's own game_config, not restated prose.
    check gc["sprayCount"].getInt == 6
    check gc["grenadeCount"].getInt == 22
    var config = defaultGameConfig()
    config.update($gc)
    check config.sprayCount == 6
    check config.grenadeCount == 22
    var sim = initCtfForTest(config)
    for i in 0 ..< Seats:
      discard sim.addPlayer("Player" & $(i + 1))
    sim.startGame()
    ## A cap can only shrink: the map's own BR-pool geometry authors far
    ## more than 6 spray sites, so this is the binding case, not a no-op.
    check sim.sprayPaintSpawns.len <= 6
    check sim.sprayPaintSpawns.len > 0
    ## grenadeCount is a TARGET, not a cap -- exactly 22 regardless of
    ## whether the generated map authored more or fewer than that.
    check sim.grenadeSpawns.len == 22
    for family in [sim.sprayPaintSpawns, sim.grenadeSpawns]:
      check family.len <= NeutralPickupPoolWidth

  test "OBJBALANCE is a per-variant knob: the plain battle-royale variant stays unchanged (-1 default)":
    ## Same rule medKitCount already proved (row above): a variant that
    ## never sets sprayCount/grenadeCount inherits the engine's -1 default,
    ## byte-identical to the pre-objbalance placement path.
    var otherVariant: JsonNode
    for variant in manifest["variants"]:
      if variant["id"].getStr() == "battle-royale":
        otherVariant = variant
    doAssert otherVariant != nil, "manifest has no battle-royale variant"
    let otherGc = otherVariant["game_config"]
    check not otherGc.hasKey("sprayCount")
    check not otherGc.hasKey("grenadeCount")
    var config = defaultGameConfig()
    config.update($otherGc)
    check config.sprayCount == -1
    check config.grenadeCount == -1
    var sim = initCtfForTest(config)
    for i in 0 ..< Teams:
      discard sim.addPlayer("Player" & $(i + 1))
    sim.startGame()
    ## Unbounded (-1): the map's own authored spray-can count, whatever it
    ## is, is never truncated to 6 on this variant.
    check sim.sprayPaintSpawns.len > 6

  test "wiping 15 of 16 solo teams ends the round with ONE winning team and exactly 16 score entries":
    var config = defaultGameConfig()
    config.update($gc)
    var sim = initCtfForTest(config)
    for i in 0 ..< Seats:
      discard sim.addPlayer("Player" & $(i + 1))
    sim.startGame()
    let survivorTeam = sim.players[0].team
    ## Wipe every OTHER team (slots 1..15 -- each its own solo team, no
    ## partner to also kill), leaving team 0's lone seat as the sole
    ## survivor. Owner simplification, 2026-09-04 (PKG-A): this variant no
    ## longer arms downedMode, so killPlayer's first call on an upright cog
    ## is a genuine, permanent kill straight away -- no downed-ghost
    ## interception (`sim.downPlayer`) sits in front of it. One call per
    ## victim wipes the team, matching the pre-S2 (dark) killPlayer path.
    ## (Re-arming downedMode would need the old two-calls-per-victim
    ## down-then-finish sequence back -- see the PR body for the re-arm
    ## path.)
    for i in 1 ..< Teams:
      sim.killPlayer(i, 0)
    sim.checkWinCondition()
    check sim.phase == GameOver
    check not sim.isDraw
    check sim.winner == survivorTeam

    ## The score-arity property a hosted recertify actually enforces: BR's
    ## 16-SEAT roster (16 solo teams) must carry exactly 16 score entries --
    ## one per seat, same as one per team now that every team is one seat.
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
    check winners == SeatsPerTeam   ## the winning solo team's one seat scores a win.

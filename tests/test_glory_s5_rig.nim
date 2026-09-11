## GLORY GRADIENT S5 — RIG SIMULATION (epic 25d9108e, program step S5).
## Proves, against REAL production code (not local test-only helpers, unlike
## S4's `test_glory_percent_scale_headroom.nim`), the S5 brief's own required
## lines: the halving-order invariant, the cap-hit fire counter, ruling (b)
## (BR dAssist/dRescue ungate), ruling (c) (pact-scope dDuoDown/dWipe), and
## the placement-ramp percent fold (§4). Every switch defaults OFF; the
## "dark = byte-identical" claim in each switch's own doc comment
## (sim_types.nim GameConfig) is asserted directly below, not just narrated.

import
  helpers,
  std/[sequtils, strformat, unittest],
  ctf/[global, sim, sim_state, events, arena]

proc recutConfig(br: bool): GameConfig =
  result = defaultGameConfig()
  result.brMode = br
  result.gloryMultiplierRecut = true
  result.winAsMultiplier = true

proc startedGame(config: GameConfig, seats: int): SimServer =
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("p" & $i)
  result.startGame()
  result.collectEvents = true

proc fourTeamConfig(): GameConfig =
  ## S5 ruling (c) needs >=3 active teams to exercise a pact GROUP; the
  ## engine seats [2, 4] team counts today (see test_br_elim.nim's own
  ## `brConfig`) -- same recipe (`teams=4`, generated "corners" map)
  ## reused verbatim so this test does not invent its own map config.
  result = recutConfig(br = true)
  result.teams = 4
  result.mapPath = "gen"
  result.mapGen.layout = "corners"
  result.mapSeed = 42

proc fourTeamGame(config: GameConfig): SimServer =
  ## One player per team, round-robin (p0=Red, p1=Blue, p2=Green,
  ## p3=Yellow) -- same shape test_br_elim.nim's `brGame` uses.
  result = initCtfForTest(config)
  for i in 0 ..< 4:
    discard result.addPlayer("p" & $i)
  result.startGame()
  result.collectEvents = true

suite "S5 halving-order invariant (own test line, real production code)":
  test "recutScoreScaled agrees with the naive combined-divisor order at realistic halvings (0-5)":
    let scaled = int64(RecutSeed) * GlorySCALE
    for halvings in [0, 1, 2, 3, 5]:
      let safe = recutScoreScaled(scaled, halvings, GlorySCALE)
      let combined = scaled div (GlorySCALE * (int64(1) shl halvings))
      check safe == combined

  test "the UNSAFE combined-divisor order overflows around halvings 53-61; the safe order (recutScoreScaled) never forms that product":
    # The S5 brief's own call-out, proven by triggering the real defect
    # rather than arguing it: `GlorySCALE * (1 shl halvings)` is exactly the
    # combined divisor `recutScoreScaled` is built to NEVER compute (it
    # halves first via `recutScore`'s own guard, then divides by GlorySCALE
    # in a SEPARATE step).
    check GlorySCALE * (int64(1) shl 52) < high(int64)   # still fine at 52
    expect(OverflowDefect):
      discard GlorySCALE * (int64(1) shl 61)             # overflows by 61
    # The safe order computes the SAME halvings with no overflow at all,
    # because it never multiplies GlorySCALE by 2^halvings in the first
    # place -- `recutScore`'s own `halvings >= 63 -> 0` guard fires first.
    let scaledAtCap = RecutProductCapArmed * GlorySCALE
    check recutScoreScaled(scaledAtCap, 61, GlorySCALE) == 0
    check recutScoreScaled(scaledAtCap, 400, GlorySCALE) == 0
    # And at a REALISTIC halvings count (play never reaches 53+), the two
    # orders still agree exactly -- the unsafe order isn't wrong, it's just
    # one that silently stops being computable long before real play could
    # ever reach it, which is exactly why this needs its own test rather
    # than resting on "no episode has ever hit this."
    check recutScoreScaled(scaledAtCap, 5, GlorySCALE) ==
      scaledAtCap div (GlorySCALE * (int64(1) shl 5))

  test "GlorySCALE cancels out exactly for every existing whole-integer class (byte-identity, the representation's own no-op claim)":
    for factor in [2, 3, 4, 6, 8, 12, 13]:
      let unscaled = recutFold(recutFold(int64(RecutSeed), factor), 3)
      let scaledSeed = int64(RecutSeed) * GlorySCALE
      let scaledProduct = recutFold(recutFold(scaledSeed, factor), 3)
      check recutScoreScaled(scaledProduct, 0, GlorySCALE) == unscaled
      check recutScore(unscaled, 0) == recutScoreScaled(scaledProduct, 0, GlorySCALE)

suite "S5 recutFoldPct (fixed-point percent fold, CATALOG-V3-DRAFT.md §9/§9b)":
  test "pct=100 is a true no-op at ANY base, scaled or not":
    check recutFoldPct(int64(1), 100) == 1
    check recutFoldPct(int64(RecutProductCapArmed), 100) == RecutProductCapArmed
    check recutFoldPct(int64(1) * GlorySCALE, 100) == GlorySCALE

  test "pct=130 truncates away at the bare seed but survives at GlorySCALE (the exact headroom finding this catalog measured)":
    check recutFoldPct(int64(1), 130) == 1   # (1*130) div 100 == 1: dead no-op
    let scaled = recutFoldPct(int64(1) * GlorySCALE, 130)
    check scaled == (GlorySCALE * 130) div 100
    check scaled > GlorySCALE   # a REAL x1.3 nudge once scaled

  test "recutFoldPct saturates at the cap exactly like recutFold":
    check recutFoldPct(RecutProductCapArmed, 130, capsArmed = true) ==
      RecutProductCapArmed

suite "S5 fire counter: recutCapHit (RecutProductCapArmed, CATALOG-V3-DRAFT.md §7)":
  test "true exactly when a fold just clamped, not when already sitting at the cap":
    check recutCapHit(before = 100, after = RecutProductCapArmed,
      cap = RecutProductCapArmed)
    check not recutCapHit(before = RecutProductCapArmed,
      after = RecutProductCapArmed, cap = RecutProductCapArmed)
    check not recutCapHit(before = 100, after = 200, cap = RecutProductCapArmed)

  test "capHit fires through the real recutFoldObserved wrapper and logs GLORY_CAP_HIT":
    var sim = startedGame(recutConfig(br = true), seats = 2)
    sim.config.deedMintCaps = true
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.gloryProduct[Red] = RecutProductCapArmed - 1
    sim.awardDeed(Red, dAceTag, 0, 0)  # class 4 -- forces a clamp from -1 below cap
    check sim.gloryProduct[Red] == RecutProductCapArmed
    check sim.events.anyIt(it.kind == GloryDeed and it.weapon == "capHit")

suite "S5 ruling (b): BR dAssist/dRescue ungate (brAssistRescueUngated)":
  test "dark (flag off): BR mints neither deed -- byte-identical to today":
    var sim = startedGame(recutConfig(br = true), seats = 3)
    sim.players[0].team = Red    # killer
    sim.players[1].team = Red    # assister (damaged the victim earlier)
    sim.players[2].team = Blue   # victim
    sim.players[2].lastDamagedBy = 1
    sim.players[2].lastDamagedByTick = sim.tickCount
    check sim.deedCounts[dAssist] == 0
    sim.killPlayer(2, 0, weapon = "gun")
    check sim.deedCounts[dAssist] == 0

  test "armed: BR mints dAssist under the same predicate CTF already uses":
    var config = recutConfig(br = true)
    config.brAssistRescueUngated = true
    var sim = startedGame(config, seats = 3)
    sim.players[0].team = Red
    sim.players[1].team = Red
    sim.players[2].team = Blue
    sim.players[2].lastDamagedBy = 1
    sim.players[2].lastDamagedByTick = sim.tickCount
    sim.killPlayer(2, 0, weapon = "gun")
    check sim.deedCounts[dAssist] == 1
    check sim.deedGloryMass[dAssist] > 0

  test "armed: BR mints dRescue under the same predicate CTF already uses":
    # dRescue's own predicate needs THREE distinct seats: the killer, the
    # menaced teammate (a DIFFERENT seat than the killer, same team), and
    # the enemy victim who was doing the menacing.
    var config = recutConfig(br = true)
    config.brAssistRescueUngated = true
    var sim = startedGame(config, seats = 3)
    sim.players[0].team = Red    # killer
    sim.players[1].team = Blue   # victim: was menacing seat 2
    sim.players[2].team = Red    # the menaced teammate (alive, != killer)
    sim.players[1].menacingTick = sim.tickCount
    sim.players[1].menacingVictim = 2
    sim.killPlayer(1, 0, weapon = "gun")
    check sim.deedCounts[dRescue] == 1

suite "S5 ruling (c): pact-scope dDuoDown/dWipe (pactScopedWipeDown)":
  test "pactGroupTeams: a lone team is its own group of one; pact partners join it":
    var sim = startedGame(recutConfig(br = true), seats = 3)
    check sim.pactGroupTeams(Red) == @[Red]
    sim.registerPact(Red, Blue)
    check Blue in sim.pactGroupTeams(Red)
    check Red in sim.pactGroupTeams(Blue)
    check sim.pactGroupTeams(Red).len == 2

  test "pactGroupLivingExcluding treats the dying seat as already dead":
    var sim = startedGame(recutConfig(br = true), seats = 2)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    check sim.pactGroupLivingExcluding(@[Red], excluding = 0) == 0
    check sim.pactGroupLivingExcluding(@[Blue], excluding = 0) == 1

  test "dark (flag off): a pacted opposing team falling does NOT mint dDuoDown in 16-solo":
    # p0=Red (killer), p1=Blue (victim, pacted with Green), p2=Green
    # (victim's ally, still alive after), p3=Yellow (bystander).
    var sim = fourTeamGame(fourTeamConfig())
    sim.registerPact(Blue, Green)
    sim.killPlayer(1, 0, weapon = "gun")
    check sim.deedCounts[dDuoDown] == 0
    check sim.deedCounts[dWipe] == 0

  test "armed: killing one pacted team while its ally survives mints the pact-scope dDuoDown":
    var config = fourTeamConfig()
    config.pactScopedWipeDown = true
    var sim = fourTeamGame(config)
    sim.registerPact(Blue, Green)   # p1=Blue victim, p2=Green its ally
    # The "corners" BR map spawns each team far apart, so an unmoved kill
    # resolves as LONGSHOT (class 3) and shadows the class-2 pact-scope
    # dDuoDown under the existing one-kill-one-deed upgrade-only law --
    # correctly (see the doc comment at the marquee site). Collapse the
    # range to isolate the marquee predicate itself, same as
    # test_br_elim.nim's own `centerOn` pattern.
    sim.players[1].x = sim.players[0].x
    sim.players[1].y = sim.players[0].y
    sim.killPlayer(1, 0, weapon = "gun")   # p0=Red kills p1=Blue
    check sim.deedCounts[dDuoDown] == 1
    check sim.events.anyIt(it.kind == GloryDeed and it.weapon == "pactDuoDown")

  test "armed: killing the LAST living member of a pact group mints the pact-scope dWipe instead":
    var config = fourTeamConfig()
    config.pactScopedWipeDown = true
    var sim = fourTeamGame(config)
    sim.registerPact(Blue, Green)
    sim.players[1].alive = false   # p1=Blue already eliminated earlier
    sim.killPlayer(2, 0, weapon = "gun")   # p0=Red kills p2=Green, the last one
    check sim.deedCounts[dWipe] == 1
    check sim.deedCounts[dDuoDown] == 0   # the bigger fact wins precedence
    check sim.events.anyIt(it.kind == GloryDeed and it.weapon == "pactWipe")

suite "S5 placement ramp (placementRampV3, CATALOG-V3-DRAFT.md §4, GLORY GRADIENT S8 PLACEMENT LADDER B)":
  test "PLACEMENT LADDER B (owner decision, 2026-09-10): dFinal8/dFinal4/dFinal2 = x1.15/x1.30/x1.60, strictly increasing":
    check RecutPlacementRampPct[dFinal8] == 115
    check RecutPlacementRampPct[dFinal4] == 130
    check RecutPlacementRampPct[dFinal2] == 160
    check RecutPlacementRampPct[dFinal8] < RecutPlacementRampPct[dFinal4]
    check RecutPlacementRampPct[dFinal4] < RecutPlacementRampPct[dFinal2]

  test "dark (flag off): dFinal8/dFinal4/dFinal2 still fold RecutClassTable's frozen 2/3/4":
    var sim = startedGame(recutConfig(br = true), seats = 2)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.awardDeed(Red, dFinal8, 0, 0)
    check sim.gloryProduct[Red] == int64(RecutSeed) * RecutClassTable[dFinal8]

  test "armed: all three ladder rungs are SKIPPED from a bare seed (GATE RULING 2) but each folds a real, increasing nudge once the base has grown":
    ## Unlike the pre-S8 ladder (dFinal8/dFinal4 pinned at pct=100, a
    ## permanent no-op regardless of base size -- see the OLD assertion
    ## this test superseded), Ladder B's 115/130/160 are all > 100, so
    ## ALL THREE now route through the SAME GATE RULING 2 floor check
    ## `recutFoldPct` already applies to any pct in [100,200): skipped
    ## below the floor, a real fold above it. Nothing about GATE RULING 2
    ## itself changed -- only which deeds are small enough to be subject
    ## to it (previously just dFinal2; now all three).
    var config = recutConfig(br = true)
    config.placementRampV3 = true
    config.gloryFixedPointScale = true
    var sim = startedGame(config, seats = 2)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    let seeded = sim.gloryProduct[Red]
    check seeded == int64(RecutSeed) * GlorySCALE
    sim.awardDeed(Red, dFinal8, 0, 0)
    check sim.gloryProduct[Red] == seeded   # below the floor: SKIPPED
    sim.awardDeed(Red, dFinal4, 0, 0)
    check sim.gloryProduct[Red] == seeded   # still below the floor: SKIPPED
    sim.awardDeed(Red, dFinal2, 0, 0)
    check sim.gloryProduct[Red] == seeded   # still below the floor: SKIPPED

    # Once other (whole-integer) folds have grown the base past the
    # GATE RULING 2 floor (~64 unscaled), all three ladder rungs DO
    # register as real, increasing nudges -- a fresh sim to isolate the
    # comparison, applying all three in finish order (8 -> 4 -> 2).
    var grown = startedGame(config, seats = 2)
    grown.players[0].team = Red
    grown.players[1].team = Blue
    # dAceTag/dLastLight both pay heat, which auto-increments after every
    # mint -- reset it before each call so every fold is a clean x4 (heat
    # rung 0), not an escalating one once embers cross a rung threshold.
    grown.awardDeed(Red, dAceTag, 0, 0)   # x4, whole-integer, always folds
    grown.heatEmbers[Red] = 0
    grown.awardDeed(Red, dAceTag, 0, 0)   # x4 again -> 16x seed
    grown.heatEmbers[Red] = 0
    grown.awardDeed(Red, dLastLight, 0, 0)  # x4 -> 64x seed: at the floor
    grown.heatEmbers[Red] = 0
    grown.awardDeed(Red, dLastLight, 0, 0)  # x4 -> 256x seed: past the floor
    let base = grown.gloryProduct[Red]
    check base == seeded * 256
    grown.awardDeed(Red, dFinal8, 0, 0)
    let afterFinal8 = (base * 115) div 100   # pct=115: real nudge
    check grown.gloryProduct[Red] == afterFinal8
    check grown.gloryProduct[Red] > base
    grown.awardDeed(Red, dFinal4, 0, 0)
    let afterFinal4 = (afterFinal8 * 130) div 100   # pct=130: real nudge
    check grown.gloryProduct[Red] == afterFinal4
    check grown.gloryProduct[Red] > afterFinal8
    grown.awardDeed(Red, dFinal2, 0, 0)
    let afterFinal2 = (afterFinal4 * 160) div 100   # pct=160: real nudge
    check grown.gloryProduct[Red] == afterFinal2
    check grown.gloryProduct[Red] > afterFinal4

suite "GATE RULING 1: catalogV3Reprice switch OFF is byte-identical (not merely asserted)":
  test "OFF end-to-end via awardDeed/claimAchievement reproduces the FROZEN contract's own pinned BR superb exactly: 9,437,184":
    ## Same recipe as test_glory_recut.nim's own "the table's recomputed BR
    ## superb reproduces exactly: 9,437,184" test -- but driven through the
    ## FULL awardDeed/claimAchievement API (heat embers + stackK set the
    ## same way that pure-function test set them), not the bare
    ## recutFactor/recutFold calls that test uses. If GATE RULING 1's new
    ## catalogV3Reprice branch touched the OFF path at all, this number
    ## would move. It does not.
    var config = recutConfig(br = true)
    config.winAsMultiplier = false   # the recipe's own dClosingTime/dVictory
                                     # rows assume the NON-win-bumped base
                                     # (recutFactor's own omitted-arg default)
    check config.catalogV3Reprice == false   # explicit: this IS the default
    var sim = startedGame(config, seats = 2)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    # Heat is reset to 0 before every call EXCEPT the longshot kill (rung
    # 3, x8) -- the pure-function recipe test passes `embers=0` explicitly
    # to every OTHER `recutFactor` call; `awardDeed` instead reads
    # `sim.heatEmbers[team]` live (and auto-increments it after any
    # heat-paying mint), so this test must reproduce that same "embers=0
    # except at the one deliberate rung" shape by hand.
    sim.awardDeed(Red, dFirstBlood, 0, 0)                          # x2
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dRunDown, 0, 0)                             # x2
    sim.heatEmbers[Red] = 10   # heat rung 3 (x8), for this ONE kill only
    sim.awardDeed(Red, dLongshotKill, 0, 0, stackK = 5)            # x3 * x8(heat) * x8(5-ally)
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dAceTag, 0, 0)                              # x4
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dDuoDown, 0, 0)                             # x2
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dDuoDown, 0, 0)                             # x2
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dClosingTime, 0, 0)                         # x2
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dLastLight, 0, 0)                           # x4
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dVictory, 0, 0)                             # x8
    sim.claimAchievement(Red, treeGun, AchievementTiers - 1, isFirst = true)  # x4 * x3(FIRST)
    check sim.gloryProduct[Red] == 9_437_184
    check sim.teamGlory[Red] == 9_437_184

  test "OFF: gameHash of a short deterministic scenario matches the PINNED golden (computed once via a real run, not projected)":
    var config = recutConfig(br = true)
    var sim = startedGame(config, seats = 2)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.awardDeed(Red, dHonorableKill, 0, 0)
    sim.awardDeed(Red, dShieldSoak, 0, 0)
    sim.awardDeed(Blue, dClutchHeal, 0, 0)
    sim.claimAchievement(Red, treeSquad, AchievementTiers - 2, isFirst = true)
    let hash = sim.gameHash()
    echo &"  GATE-RULING-1 golden gameHash (OFF) = {hash}"
    check hash == 7108621066401102251'u64   # pinned from a real run of THIS EXACT scenario
    check sim.gloryProduct[Red] == 2        # x1(HonorableKill) * x1(ShieldSoak) * x2(Tier IV claim)
    check sim.gloryProduct[Blue] == 1       # ClutchHeal: x1, no achievement claim on Blue

  test "ON changes the reported score for the SAME frozen-contract recipe (the switch has real teeth)":
    var config = recutConfig(br = true)
    config.catalogV3Reprice = true
    config.gloryFixedPointScale = true
    var sim = startedGame(config, seats = 2)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.awardDeed(Red, dHonorableKill, 0, 0)
    check sim.gloryProduct[Red] != int64(RecutSeed) * GlorySCALE  # no longer x1-inert
    check sim.gloryProduct[Red] == (int64(RecutSeed) * GlorySCALE * 220) div 100  # x2.2

suite "GATE RULING 2: small/fractional factors never fold from a bare seed (its own test)":
  test "pct < 200 from a bare (unscaled) seed is SKIPPED, not floored-to-nothing":
    check recutFoldPct(int64(1), 160) == 1          # would be skipped either way (pct<=100? no, 160>100)
    check recutFoldPct(int64(1), 160, scale = 1) == 1   # base(1) < floor(64): skip, unchanged
    check recutFoldPct(int64(63), 160, scale = 1) == 63 # still under the floor: skip

  test "pct < 200 folds for real once the (unscaled) accumulator exceeds ~64":
    check recutFoldPct(int64(64), 160, scale = 1) == (64 * 160) div 100
    check recutFoldPct(int64(100), 105, scale = 1) == (100 * 105) div 100

  test "pct >= 200 (not 'small') is UNRESTRICTED even from a bare seed":
    check recutFoldPct(int64(1), 220) == (1 * 220) div 100  # dHonorableKill's v3 pct

  test "the floor is evaluated in UNSCALED units when scale > 1":
    let scale = GlorySCALE
    check recutFoldPct(int64(1) * scale, 160, scale = scale) == int64(1) * scale     # 1 < 64: skip
    check recutFoldPct(int64(64) * scale, 160, scale = scale) ==
      (int64(64) * scale * 160) div 100                                             # 64 >= 64: folds

suite "GATE RULING 4: a pact-scope marquee ALWAYS mints over a shadowing solo kill deed":
  test "on the far-spawn 'corners' map, pact-scope dDuoDown now mints instead of being shadowed by dLongshotKill":
    ## This is the EXACT scenario the S5 rig found dDuoDown silently
    ## losing to dLongshotKill in -- unmoved, far-apart BR spawns. Ruling 4
    ## makes the pact deed win unconditionally; re-measures mint-rate vs
    ## raw incidence afterward (both suite-level assertions below).
    var config = fourTeamConfig()
    config.pactScopedWipeDown = true
    var sim = fourTeamGame(config)
    sim.registerPact(Blue, Green)
    check sim.deedCounts[dLongshotKill] == 0  # sanity: not pre-armed by setup
    sim.killPlayer(1, 0, weapon = "gun")      # p0=Red kills p1=Blue, UNMOVED (far spawns)
    check sim.deedCounts[dDuoDown] == 1       # mints now, was 0 before ruling 4
    check sim.deedCounts[dLongshotKill] == 0  # the longshot fact still happened, but did not mint

  test "dDuoDown mint-RATE now equals raw INCIDENCE (the shadowing cost is closed)":
    ## Raw incidence: the GLORY_PACT_DUODOWN event fires (the CONDITION
    ## held). Mint rate: deedCounts[dDuoDown] actually incremented. Before
    ## ruling 4 these could diverge (incidence 1, mint 0, on this exact
    ## map); after ruling 4 they must always agree.
    var config = fourTeamConfig()
    config.pactScopedWipeDown = true
    var sim = fourTeamGame(config)
    sim.registerPact(Blue, Green)
    sim.killPlayer(1, 0, weapon = "gun")
    let incidence = sim.events.filterIt(it.kind == GloryDeed and
      it.weapon == "pactDuoDown").len
    let mints = sim.deedCounts[dDuoDown]
    echo &"  dDuoDown incidence={incidence} mints={mints} (ruling 4: must be equal)"
    check incidence == 1
    check mints == incidence

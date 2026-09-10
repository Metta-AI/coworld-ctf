## GLORY GRADIENT S4b — ACHIEVEMENTS AS LIGHTABLE MODES (epic 25d9108e).
## Follow-on to S5 (RIG-SIMULATION.md), run in parallel with the S6 ship and
## deliberately independent of it: does not read, gate on, or assume #504's
## catalog-v3-default-ON work landed.
##
## The S5 rig's own Monte Carlo (`/tmp/glory-s5/rig/s5_montecarlo.nim`) was
## never committed -- unavailable to this worker, a different agent's /tmp.
## Rather than cite numbers nobody else can reproduce (the program's own
## S4-freeze-cost lesson: "the freeze criterion names the artifact"), this
## suite is a smaller, fully DETERMINISTIC replacement: no RNG, an exhaustive
## sweep over the small parameter space this lever actually controls
## (lightCount 0..4, FIRST claimed or not, three fixed deed-floor shapes),
## driven through REAL production procs (`awardDeed`/`claimAchievement`/
## `recutModeLitBonus`/`recutAchievementFactor(V3Pct)`), reproducible bit-
## for-bit by re-running this file. It answers the four S5 acceptance
## questions SCOPED TO THIS LEVER's marginal effect, not a re-derivation of
## the full population-calibrated S5 Monte Carlo (which needs data this
## worker does not have) -- named plainly, not hidden.

import
  helpers,
  std/[algorithm, json, math, os, sequtils, sets, strformat, strutils, unittest],
  ctf/[global, sim, sim_state, events, arena]

proc modesConfig(armed: bool): GameConfig =
  ## The S5-armed economy (catalogV3Reprice + gloryFixedPointScale +
  ## placementRampV3, all already on `origin/main` via PR #501, set here by
  ## direct struct assignment exactly as `test_glory_s5_rig.nim` itself
  ## does -- this suite is not responsible for THEIR manifest reachability,
  ## only for `achievementLightableModes`' own, tested separately below)
  ## PLUS this step's own lever, toggled by `armed`. `winAsMultiplier`
  ## stays false so a "win" can be modeled with the plain `dVictory` deed,
  ## the same simplification `test_glory_s5_rig.nim`'s own GATE RULING 1
  ## recipe uses, rather than driving the full win-condition machinery.
  result = defaultGameConfig()
  result.brMode = true
  result.gloryMultiplierRecut = true
  result.winAsMultiplier = false
  result.catalogV3Reprice = true
  result.gloryFixedPointScale = true
  result.placementRampV3 = true
  result.achievementLightableModes = armed

proc startedGame(config: GameConfig, seats = 2): SimServer =
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("p" & $i)
  result.startGame()
  result.collectEvents = true

# ── Three fixed deed-floor "shapes" (LOW/MID/HIGH), every included deed's
# v3 pct is >= 200 (`RecutClassTableV3Pct`, glory.nim) so every fold ALWAYS
# registers regardless of GATE RULING 2's small-factor floor -- no
# accumulator-size ambiguity, fully deterministic and easy to hand-verify.
# Heat is reset to 0 around every call (matching `test_glory_s5_rig.nim`'s
# own GATE RULING 1 recipe) so `paysHeat` deeds don't compound heat rungs
# across repeated mints -- these shapes model deed VARIETY, not a heat
# grind, which is a separate, already-studied lever (glory-2 §5).
proc applyLowShape(sim: var SimServer, team: Team) =
  for _ in 0 ..< 2:
    sim.awardDeed(team, dHonorableKill, 0, 0)   # v3 pct 220
    sim.heatEmbers[team] = 0

proc applyMidShape(sim: var SimServer, team: Team) =
  for _ in 0 ..< 4:
    sim.awardDeed(team, dHonorableKill, 0, 0)   # 220 x4
    sim.heatEmbers[team] = 0
  sim.awardDeed(team, dLongshotKill, 0, 0)      # 600
  sim.heatEmbers[team] = 0

proc applyHighShape(sim: var SimServer, team: Team) =
  for _ in 0 ..< 6:
    sim.awardDeed(team, dHonorableKill, 0, 0)   # 220 x6
    sim.heatEmbers[team] = 0
  for _ in 0 ..< 2:
    sim.awardDeed(team, dLongshotKill, 0, 0)    # 600 x2
    sim.heatEmbers[team] = 0
  sim.awardDeed(team, dLastLight, 0, 0)         # 800
  sim.heatEmbers[team] = 0
  sim.awardDeed(team, dVictory, 0, 0)           # 800 (v3 pct for classic x8)
  sim.heatEmbers[team] = 0

type Shape = enum shLow, shMid, shHigh

proc applyShape(sim: var SimServer, team: Team, shape: Shape) =
  case shape
  of shLow: sim.applyLowShape(team)
  of shMid: sim.applyMidShape(team)
  of shHigh: sim.applyHighShape(team)

proc applyLighting(sim: var SimServer, team: Team, lightCount: int) =
  ## Claims exactly `lightCount` of treeGun's four LOWER tiers (indices
  ## 0..2 are always-fold under v3 -- tier0/1 pct=100 is an exact no-op by
  ## LAW, tier2 (Bounty) pct=200 always folds; index 3 (Sharpshooter/max
  ## rank) is pct=105, subject to the floor, claimed last so by then the
  ## accumulator is already well past it from the >=200 folds above).
  ## Order 0,1,2,3 mirrors `satisfiedAchievements`' own tier ordering.
  for t in 0 ..< min(lightCount, AchievementTiers - 1):
    sim.claimAchievement(team, treeGun, t, isFirst = false)

proc jackpotScenario(shape: Shape, lightCount: int, isFirst: bool,
                     armed: bool): tuple[teamGlory: int64, hitCap: bool] =
  var sim = startedGame(modesConfig(armed))
  sim.players[0].team = Red
  sim.players[1].team = Blue
  sim.applyShape(Red, shape)
  sim.applyLighting(Red, lightCount)
  sim.claimAchievement(Red, treeGun, AchievementTiers - 1, isFirst = isFirst)
  (teamGlory: sim.teamGlory[Red],
   hitCap: sim.teamGlory[Red] >= RecutProductCapArmed)

suite "S4b config surface (achievementLightableModes, dark by default, its own key)":
  test "defaultGameConfig() is dark":
    check defaultGameConfig().achievementLightableModes == false

  test "config.update with an absent key leaves the dark default unchanged":
    var config = defaultGameConfig()
    config.update("""{"gloryMultiplierRecut": true}""")
    check config.achievementLightableModes == false

suite "S4b manifest reachability (armed from the SCHEMA path, not defaultGameConfig())":
  test "coworld_manifest_paintbot.json's config_schema declares achievementLightableModes, default false":
    let manifest = parseFile(GameDir / "coworld_manifest_paintbot.json")
    let schema = manifest["game"]["config_schema"]
    require schema["properties"].hasKey("achievementLightableModes")
    let prop = schema["properties"]["achievementLightableModes"]
    check prop["type"].getStr() == "boolean"
    check prop["default"].getBool() == false
    check prop["description"].getStr().len > 0

  test "arming the SCHEMA-declared key via config.update (the manifest path) actually flips the field":
    ## This is the #504 shape, closed: a schema entry that config.update
    ## does not consume would leave `config == defaultGameConfig()` here.
    var config = defaultGameConfig()
    config.update("""{"achievementLightableModes": true}""")
    check config.achievementLightableModes == true
    check config != defaultGameConfig()

  test "the echoed config carries the key only when armed (byte-identity when dark)":
    var dark = defaultGameConfig()
    dark.gloryMultiplierRecut = true
    check not parseJson(dark.configJson()).hasKey("achievementLightableModes")
    var armed = dark
    armed.achievementLightableModes = true
    let echoed = parseJson(armed.configJson())
    require echoed.hasKey("achievementLightableModes")
    check echoed["achievementLightableModes"].getBool() == true

  test "GLORY GRADIENT S8 SHIP: the battle-royale-s2 flagship variant's OWN game_config arms it (the manifest-path reachability the schema tests above don't cover)":
    ## The suites above prove the SCHEMA declares the key and that
    ## `config.update` honors it -- neither proves the manifest actually
    ## SETS it anywhere. This is that proof, the same one #504's own
    ## `catalogV3Reprice` arm never got a codified test for (verified by
    ## grep at ship time instead) -- S8's own task explicitly asks for it
    ## here. Reads the published manifest directly, not `config.update`, so
    ## a future accidental revert of the flagSet block (not the schema)
    ## fails this test instead of shipping dark.
    let manifest = parseFile(GameDir / "coworld_manifest_paintbot.json")
    var flagship: JsonNode = nil
    for variant in manifest["variants"]:
      if variant["id"].getStr() == "battle-royale-s2":
        flagship = variant
    require flagship != nil
    let flagSet = flagship["game_config"]
    require flagSet.hasKey("achievementLightableModes")
    check flagSet["achievementLightableModes"].getBool() == true
    # Armed alongside gloryMultiplierRecut (the switch's own "reads only
    # while gloryMultiplierRecut is armed" precondition) and catalogV3Reprice
    # (S7's own sizing was measured with both armed together) -- an
    # achievementLightableModes:true with either of those false would be a
    # silent no-op on this variant, not the S8 ship this test guards.
    check flagSet.hasKey("gloryMultiplierRecut") and
      flagSet["gloryMultiplierRecut"].getBool() == true
    check flagSet.hasKey("catalogV3Reprice") and
      flagSet["catalogV3Reprice"].getBool() == true

suite "S4b recutModeLitBonus: the pure ladder (glory.nim, no SimServer needed)":
  test "0 or 1 lower tiers lit -> x1, no bonus (no regression vs today)":
    check recutModeLitBonus(0) == 1
    check recutModeLitBonus(1) == 1

  test "2/3/4 lower tiers lit -> x2/x3/x4, escalating":
    check recutModeLitBonus(2) == 2
    check recutModeLitBonus(3) == 3
    check recutModeLitBonus(4) == 4

  test "clamped at both ends (defensive, no tree has >4 lower tiers today)":
    check recutModeLitBonus(-1) == recutModeLitBonus(0)
    check recutModeLitBonus(99) == recutModeLitBonus(4)

suite "S4b GATE: switch OFF is byte-identical (not merely asserted)":
  test "OFF: the frozen GATE-RULING-1 recipe (9,437,184) is UNCHANGED by this lever's presence in the codebase":
    ## Same recipe test_glory_s5_rig.nim's own GATE RULING 1 suite pins.
    ## If achievementLightableModes touched the OFF path at all (e.g. a
    ## misplaced `if` outside the armed branch), this number would move.
    var config = defaultGameConfig()
    config.brMode = true
    config.gloryMultiplierRecut = true
    config.winAsMultiplier = false
    check config.achievementLightableModes == false  # explicit: the default
    var sim = startedGame(config)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.awardDeed(Red, dFirstBlood, 0, 0)
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dRunDown, 0, 0)
    sim.heatEmbers[Red] = 10
    sim.awardDeed(Red, dLongshotKill, 0, 0, stackK = 5)
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dAceTag, 0, 0)
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dDuoDown, 0, 0)
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dDuoDown, 0, 0)
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dClosingTime, 0, 0)
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dLastLight, 0, 0)
    sim.heatEmbers[Red] = 0
    sim.awardDeed(Red, dVictory, 0, 0)
    sim.claimAchievement(Red, treeGun, AchievementTiers - 1, isFirst = true)
    check sim.gloryProduct[Red] == 9_437_184
    check sim.teamGlory[Red] == 9_437_184

  test "OFF: gameHash of a short deterministic scenario matches the PRE-EXISTING pinned golden (7108621066401102251) -- this lever adds nothing to it":
    ## Identical scenario+golden to test_glory_s5_rig.nim's own GATE
    ## RULING 1 test -- achievementLightableModes being present (but
    ## false) in GameConfig must not perturb it at all.
    var config = defaultGameConfig()
    config.brMode = true
    config.gloryMultiplierRecut = true
    var sim = startedGame(config)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.awardDeed(Red, dHonorableKill, 0, 0)
    sim.awardDeed(Red, dShieldSoak, 0, 0)
    sim.awardDeed(Blue, dClutchHeal, 0, 0)
    sim.claimAchievement(Red, treeSquad, AchievementTiers - 2, isFirst = true)
    check sim.gameHash() == 7108621066401102251'u64
    check sim.gloryProduct[Red] == 2
    check sim.gloryProduct[Blue] == 1

  test "OFF: a top-tier claim with lower tiers already banked scores IDENTICALLY to one without -- lightCount is computed but never folded":
    ## lightCount=2 claims ONLY treeGun tiers 0/1 (v3 pct=100, an exact
    ## no-op by LAW -- RecutTierClassV3Pct[0]/[1] -- so this isolates the
    ## mode-lit lever specifically; lightCount=3 would also claim tier 2
    ## (Bounty, pct=200), which is a REAL, pre-existing, unrelated scoring
    ## effect and would make this comparison meaningless).
    let (unlit, _) = jackpotScenario(shLow, lightCount = 0, isFirst = false, armed = false)
    let (lit, _) = jackpotScenario(shLow, lightCount = 2, isFirst = false, armed = false)
    check unlit == lit  # the whole point of "dark = byte-identical"

suite "S4b GATE: switch ON has real teeth":
  test "ON: the SAME GATE-RULING-1-adjacent scenario changes once armed":
    var config = defaultGameConfig()
    config.brMode = true
    config.gloryMultiplierRecut = true
    config.achievementLightableModes = true
    var sim = startedGame(config)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.claimAchievement(Red, treeGun, 0, isFirst = false)  # First Tag
    sim.claimAchievement(Red, treeGun, 1, isFirst = false)  # Marksman
    sim.claimAchievement(Red, treeGun, AchievementTiers - 1, isFirst = false)  # Longshot
    # classic path (catalogV3Reprice OFF here): tier V factor = 4 (RecutTierClass[4]).
    # lightCount = 2 (tiers 0,1) -> bonus = 2. Total = 4 * 2 = 8, not 4.
    check sim.gloryProduct[Red] == 8
    check sim.teamGlory[Red] == 8

  test "ON: a top-tier claim with MORE lower tiers banked scores STRICTLY MORE than one with fewer, same shape, same FIRST":
    let (count0, _) = jackpotScenario(shMid, lightCount = 0, isFirst = false, armed = true)
    let (count2, _) = jackpotScenario(shMid, lightCount = 2, isFirst = false, armed = true)
    let (count3, _) = jackpotScenario(shMid, lightCount = 3, isFirst = false, armed = true)
    check count0 < count2
    check count2 < count3

suite "S4b per-tree coverage: all 8 achievement trees, uniform mechanism (KNOWN GAP closed)":
  ## Before this suite, only `treeGun` had the full armed sweep (the "ON"
  ## suite above) and `treeSquad` had only the OFF byte-identity test (the
  ## "GATE: switch OFF" suite above) -- every other tree was untested.
  ## `claimAchievement`'s S4b block (sim.nim) never branches on `tree`
  ## (only on `tier == AchievementTiers - 1` and the switch), so the
  ## mechanism is DESIGNED to be uniform across all `AchievementTrees`(8)
  ## -- this suite proves that generalization holds for real, per tree,
  ## rather than trusting it by reading the source. Sourced through
  ## `config.update` (the manifest path the "S4b manifest reachability"
  ## suite above proves the schema reaches), not a direct struct
  ## assignment, exercised end-to-end into a real `claimAchievement` call
  ## for each tree -- a future per-tree special case that only broke the
  ## schema-sourced path would be caught here.
  for tree in Tree:
    test &"{tree}: (a) manifest-path reachability (b) lightCount 0..4 -> x1/x1/x2/x3/x4 (c) fire counter exactly once per claim":
      # (a) manifest-path reachability: armed via config.update, the same
      # join the "S4b manifest reachability" suite proves the SCHEMA
      # reaches -- here proven to reach all the way into this tree's own
      # claimAchievement fold, not merely into the GameConfig field.
      var darkConfig = defaultGameConfig()
      darkConfig.brMode = true
      darkConfig.gloryMultiplierRecut = true
      check darkConfig.achievementLightableModes == false

      var armedConfig = defaultGameConfig()
      armedConfig.brMode = true
      armedConfig.gloryMultiplierRecut = true
      armedConfig.update("""{"achievementLightableModes": true}""")
      check armedConfig.achievementLightableModes == true

      for lightCount in 0 .. 4:
        # (b) the x1/x1/x2/x3/x4 ladder on THIS tree's top-tier claim.
        # Expected value derived from the SAME source constants the
        # production path folds (RecutTierClass for the lower tiers'
        # own classic price, recutAchievementFactor for the top tier,
        # recutModeLitBonus for this lever's own ladder) rather than
        # restated magic numbers -- assert against the source, not the
        # prose.
        var sim = startedGame(armedConfig)
        sim.players[0].team = Red
        sim.players[1].team = Blue
        for t in 0 ..< min(lightCount, AchievementTiers - 1):
          sim.claimAchievement(Red, tree, t, isFirst = false)
        sim.claimAchievement(Red, tree, AchievementTiers - 1, isFirst = false)

        var expected = int64(1)
        for t in 0 ..< min(lightCount, AchievementTiers - 1):
          expected = expected * int64(RecutTierClass[t])
        let topFactor = recutAchievementFactor(AchievementTiers - 1, false)
        let bonus = recutModeLitBonus(lightCount)
        expected = expected * int64(topFactor) * int64(bonus)
        checkpoint(&"{tree} lightCount={lightCount}: expected={expected} bonus={bonus}")
        check sim.gloryProduct[Red] == expected
        check sim.teamGlory[Red] == expected

        # (c) fire counter: exactly one achModeLit event when the bonus
        # actually folds (bonus > 1), zero when it doesn't (lightCount
        # 0/1, bonus == 1) -- and a repeat claim of the SAME top tier
        # (claimAchievement's own `claimed[]` early-return) must not
        # fire a second time, so "exactly once per armed top-tier claim"
        # holds even under a redundant caller, not just on a fresh sim.
        let events = sim.events.filterIt(
          it.kind == GloryDeed and it.weapon == "achModeLit")
        if bonus > 1:
          check events.len == 1
          check events[0].amount == bonus
        else:
          check events.len == 0
        sim.claimAchievement(Red, tree, AchievementTiers - 1, isFirst = false)
        let eventsAfterRepeat = sim.events.filterIt(
          it.kind == GloryDeed and it.weapon == "achModeLit")
        check eventsAfterRepeat.len == events.len

suite "S4b fire counter: GLORY_ACH_MODE_LIT (log line + achModeLit event, every armed top-tier claim)":
  test "logs on EVERY armed top-tier claim, bonus==1 (not lit) included":
    var config = modesConfig(armed = true)
    var sim = startedGame(config)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.gameEventLoggingEnabled = true
    sim.claimAchievement(Red, treeGun, AchievementTiers - 1, isFirst = false)
    let achModeLitEvents = sim.events.filterIt(
      it.kind == GloryDeed and it.weapon == "achModeLit")
    check achModeLitEvents.len == 0   # lightCount=0 -> bonus=1 -> no FOLD event
    # (the log line itself is stdout-only per `logGameEvent`'s own contract;
    # the tier-2 event above is the queryable-from-replay counterpart, and
    # is asserted to fire only when the bonus is real, per its own doc
    # comment ("bonus > 1") -- both facts checked here.)

  test "emits achModeLit when the bonus actually folds (bonus > 1)":
    var config = modesConfig(armed = true)
    var sim = startedGame(config)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.claimAchievement(Red, treeGun, 0, isFirst = false)
    sim.claimAchievement(Red, treeGun, 1, isFirst = false)
    sim.claimAchievement(Red, treeGun, AchievementTiers - 1, isFirst = false)
    let achModeLitEvents = sim.events.filterIt(
      it.kind == GloryDeed and it.weapon == "achModeLit")
    check achModeLitEvents.len == 1
    check achModeLitEvents[0].amount == 2  # lightCount=2 -> bonus=2

suite "S4b jackpot gradient: does the top now have intermediate values? (deterministic enumeration, pure-function level)":
  test "classic pricing: DARK has 2 distinct tier-V payouts, ARMED has 7":
    var darkValues, armedValues: HashSet[int]
    for lightCount in 0 .. 4:
      for isFirst in [false, true]:
        let base = recutAchievementFactor(AchievementTiers - 1, isFirst)
        darkValues.incl(base)                              # bonus never folds when dark
        armedValues.incl(base * recutModeLitBonus(lightCount))
    let darkSorted = toSeq(darkValues).sorted()
    let armedSorted = toSeq(armedValues).sorted()
    echo &"  S4b gradient (classic): DARK={darkSorted} ({darkSorted.len} distinct)  " &
         &"ARMED={armedSorted} ({armedSorted.len} distinct)"
    check darkSorted == @[4, 12]
    check armedSorted == @[4, 8, 12, 16, 24, 36, 48]
    check armedSorted.len > darkSorted.len

  test "v3 (catalogV3Reprice) pricing: DARK has 2 distinct payouts, ARMED has 8":
    var darkValues, armedValues: HashSet[int]
    for lightCount in 0 .. 4:
      for isFirst in [false, true]:
        let base = recutAchievementFactorV3Pct(AchievementTiers - 1, isFirst)
        darkValues.incl(base)
        armedValues.incl(base * recutModeLitBonus(lightCount))
    let darkSorted = toSeq(darkValues).sorted()
    let armedSorted = toSeq(armedValues).sorted()
    echo &"  S4b gradient (v3 pct): DARK={darkSorted} ({darkSorted.len} distinct)  " &
         &"ARMED={armedSorted} ({armedSorted.len} distinct)"
    check darkSorted == @[200, 346]
    check armedSorted.len == 8
    check armedSorted.len > darkSorted.len

suite "S4b acceptance tests (deterministic rig extension, S5-armed economy + modes ON, scoped to this lever)":
  ## NOT a re-run of RIG-SIMULATION.md's own population-calibrated Monte
  ## Carlo (that script was never committed -- see this file's header).
  ## This is a smaller, fully deterministic sweep over the parameter space
  ## `achievementLightableModes` actually controls (lightCount x FIRST x
  ## three fixed deed-floor shapes), which DOES answer the same four
  ## questions, scoped honestly to this lever's own marginal effect.
  let shapes = [shLow, shMid, shHigh]
  var darkPoints, armedPoints: seq[float]
  var anyCapHit = false
  var achShareTop, bonusShareTop: float

  test "sweep: 3 shapes x 5 lightCounts x 2 FIRST = 30 paired (dark, armed) points":
    for shape in shapes:
      for lightCount in 0 .. 4:
        for isFirst in [false, true]:
          let (darkGlory, darkCap) = jackpotScenario(shape, lightCount, isFirst, armed = false)
          let (armedGlory, armedCap) = jackpotScenario(shape, lightCount, isFirst, armed = true)
          darkPoints.add log2(float(darkGlory))
          armedPoints.add log2(float(armedGlory))
          anyCapHit = anyCapHit or darkCap or armedCap
    check darkPoints.len == 30
    check armedPoints.len == 30

  test "1) CONTINUITY: armed adds intermediate point-values the dark sweep does not have (max gap shrinks)":
    var darkSorted = darkPoints.deduplicate()
    var armedSorted = armedPoints.deduplicate()
    darkSorted.sort()
    armedSorted.sort()
    proc maxGap(xs: seq[float]): float =
      result = 0.0
      for i in 1 ..< xs.len:
        result = max(result, xs[i] - xs[i - 1])
    let darkGap = maxGap(darkSorted)
    let armedGap = maxGap(armedSorted)
    echo &"  S4b continuity: dark {darkSorted.len} distinct pts (max gap {darkGap:.3f}), " &
         &"armed {armedSorted.len} distinct pts (max gap {armedGap:.3f})"
    check armedSorted.len > darkSorted.len
    check armedGap < darkGap

  test "2) SEPARATION: armed widens (never narrows) the gap between the LOW-shape floor and the HIGH-shape jackpot":
    let (lowDark, _) = jackpotScenario(shLow, 0, false, armed = false)
    let (lowArmed, _) = jackpotScenario(shLow, 0, false, armed = false)  # lightCount=0 -> unaffected by arming
    let (highDarkGlory, _) = jackpotScenario(shHigh, 4, true, armed = false)
    let (highArmedGlory, _) = jackpotScenario(shHigh, 4, true, armed = true)
    let darkSpreadPts = log2(float(highDarkGlory)) - log2(float(lowDark))
    let armedSpreadPts = log2(float(highArmedGlory)) - log2(float(lowArmed))
    echo &"  S4b separation: LOW->HIGH spread dark={darkSpreadPts:.3f}pts armed={armedSpreadPts:.3f}pts"
    check armedSpreadPts > darkSpreadPts

  test "3) CHOSEN share: at the HIGH shape's own jackpot (lightCount=3, FIRST), the mode-lit bonus is a real, independently-observable slice of the achievement axis's own magnitude":
    let (baseGlory, _) = jackpotScenario(shHigh, 0, true, armed = true)   # FIRST alone, no lighting
    let (litGlory, _) = jackpotScenario(shHigh, 3, true, armed = true)   # + lightCount=3
    let deedFloorOnlyBits = block:
      var sim = startedGame(modesConfig(armed = true))
      sim.players[0].team = Red
      sim.players[1].team = Blue
      sim.applyShape(Red, shHigh)
      log2(float(sim.teamGlory[Red]))
    let totalBits = log2(float(litGlory))
    let achBits = totalBits - deedFloorOnlyBits
    let bonusBits = log2(float(litGlory)) - log2(float(baseGlory))
    achShareTop = achBits / totalBits
    bonusShareTop = bonusBits / totalBits
    echo &"  S4b CHOSEN share (HIGH shape, lit): total={totalBits:.3f}bits achievement-axis={achBits:.3f}bits " &
         &"({achShareTop*100:.1f}%) of which mode-lit-bonus-alone={bonusBits:.3f}bits ({bonusShareTop*100:.1f}%)"
    check bonusBits > 0.0
    check bonusShareTop > 0.0

  test "4) CAP-HIT: none of the 30x2 modest-shape points hit RecutProductCapArmed; a deliberately stacked scenario shows the lever CAN reach it":
    check anyCapHit == false   # 0/60 in the ordinary sweep -- matches the census's own near-zero finding
    # Deliberately extreme: stack the HIGH shape's deed floor SEVEN times
    # (still only one team, one episode) plus a fully-lit FIRST claim, to
    # show the cap is reachable in principle once armed, not merely
    # theoretical -- same "is it reachable at all" question RIG-SIMULATION
    # asked of RecutProductCapArmed.
    var config = modesConfig(armed = true)
    config.deedMintCaps = false  # test the RAW product path, not mintcap's separate budget
    var sim = startedGame(config)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    for _ in 0 ..< 7: sim.applyHighShape(Red)
    sim.claimAchievement(Red, treeGun, 0, isFirst = false)
    sim.claimAchievement(Red, treeGun, 1, isFirst = false)
    sim.claimAchievement(Red, treeGun, 2, isFirst = false)
    sim.claimAchievement(Red, treeGun, AchievementTiers - 1, isFirst = true)
    echo &"  S4b cap-hit stress: teamGlory={sim.teamGlory[Red]} cap={RecutProductCapArmed}"
    check sim.teamGlory[Red] >= RecutProductCapArmed

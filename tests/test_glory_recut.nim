## GLORY v13 — THE MULTIPLIER RECUT (frozen 2026-09-02 contract; built
## verbatim from ~/.ctf/handoff/2026-09-02-multiplier-recut-table.md +
## -directive.md; glory-2 lead holds conformance review).
##
## Two proof obligations, per the increment contract:
##   * DARK (flag off): today's scoring EXACTLY — the additive v12 ledger,
##     no new config keys in the echo, no new deeds minting. The committed
##     replay fixtures passing unchanged (test_replay / test_glory_sim /
##     test_policy_page, this same CI run) is the byte-identity proof; the
##     suite below adds the direct additive-path assertions.
##   * ARMED: the pure-product economy — log-space sum property, the
##     per-duo single-walk (one product per team/duo, never per seat), the
##     FF division shapes per mode, seed handling, the territory rung
##     shift, the Fibonacci stack, and the table's own recomputed BR superb
##     (9,437,184) reproduced from the contract's §1b recipe.

import
  helpers,
  std/[json, math, unittest],
  ctf/[sim, events, arena]

proc recutConfig(br: bool): GameConfig =
  result = defaultGameConfig()
  result.brMode = br
  result.gloryMultiplierRecut = true

proc startedGame(config: GameConfig, seats: int): SimServer =
  result = initCtfForTest(config)
  for i in 0 ..< seats:
    discard result.addPlayer("p" & $i)
  result.startGame()
  result.collectEvents = true

suite "recut config surface (dark by default, per-flag)":
  test "defaults are dark and the default echo carries none of the keys":
    let config = defaultGameConfig()
    check config.gloryMultiplierRecut == false
    check config.stampRealizedConfig == false
    check config.variantId == ""
    let echoed = parseJson(config.configJson())
    for key in ["gloryMultiplierRecut", "stampRealizedConfig", "variantId"]:
      check not echoed.hasKey(key)

  test "each flag arms independently and round-trips through the echo":
    # PER-FLAG ACTIVATION (contract Amendment 2 §1): the recut, the stamp
    # and the variant label are three independent keys — arming one never
    # drags another.
    var recut = defaultGameConfig()
    recut.update("""{"gloryMultiplierRecut": true}""")
    check recut.gloryMultiplierRecut
    check not recut.stampRealizedConfig
    check parseJson(recut.configJson()).hasKey("gloryMultiplierRecut")
    check not parseJson(recut.configJson()).hasKey("stampRealizedConfig")
    var stamp = defaultGameConfig()
    stamp.update("""{"stampRealizedConfig": true, "variantId": "battle-royale-s2"}""")
    check stamp.stampRealizedConfig
    check not stamp.gloryMultiplierRecut
    check stamp.variantId == "battle-royale-s2"

  test "the realized-config stamp pins the flag family, sorted, false included":
    var config = defaultGameConfig()
    config.update("""{"brMode": true, "downedMode": true, "variantId": "battle-royale-s2", "stampRealizedConfig": true}""")
    let stamp = parseJson(config.realizedConfigStampJson())
    check stamp["stampVersion"].getInt == 1
    check stamp["variantId"].getStr == "battle-royale-s2"
    check stamp["realizedBuild"]["gameVersion"].getStr == GameVersion
    check stamp["realizedBuild"]["gloryVersion"].getInt == GloryVersion
    var flags: seq[string]
    for f in stamp["flagSet"]:
      flags.add f.getStr
    # sorted, and a dark flag positively records its darkness.
    for i in 1 ..< flags.len:
      check flags[i - 1] < flags[i]
    check "downedMode=true" in flags
    check "gloryMultiplierRecut=false" in flags
    check "lootStart=false" in flags

suite "recut integer map (table §1, verbatim)":
  test "the ruled class map, row by row":
    # ×1 — commons.
    for deed in [dHonorableKill, dSprayKill, dGrenadeKill, dPointBlankKill,
        dClutchHeal, dShieldSoak, dLevelUp]:
      check RecutClassTable[deed] == 1
    # ×2.
    for deed in [dFirstBlood, dEscortKill, dAssist, dRunDown, dRevengeKill,
        dRescue, dDuoDown, dClosingTime]:
      check RecutClassTable[deed] == 2
    # ×3.
    for deed in [dLongshotKill, dSplashMultiKill]:
      check RecutClassTable[deed] == 3
    # ×4.
    for deed in [dAceTag, dFlagSteal, dCarrierKill, dLastLight]:
      check RecutClassTable[deed] == 4
    # ×6 / ×8 (the ruled bumps).
    check RecutClassTable[dDenial] == 6
    check RecutClassTable[dCapture] == 8
    check RecutClassTable[dWipe] == 8
    check RecutClassTable[dVictory] == 8

  test "tier conversion I/II ×1, III/IV ×2, V ×4; FIRST ×3 survives":
    check RecutTierClass == [1, 1, 2, 2, 4]
    check recutAchievementFactor(4, isFirst = true) == 12   # Tier V FIRST
    check recutAchievementFactor(4, isFirst = false) == 4
    check recutAchievementFactor(2, isFirst = false) == 2
    # A weightless tier stays weightless even claimed first (§5.8: ×1
    # carries no score weight — no live-state factor can attach to it).
    check recutAchievementFactor(0, isFirst = true) == 1

  test "territory rung shift: +1 on enemy ground, above-×1 only (table §3)":
    check recutShiftedClass(dRunDown, SiteMultEnemyPct) == 3     # ×2→×3
    check recutShiftedClass(dLongshotKill, SiteMultEnemyPct) == 4 # ×3→×4
    check recutShiftedClass(dAceTag, SiteMultEnemyPct) == 5      # ×4→×5
    check recutShiftedClass(dDenial, SiteMultEnemyPct) == 7      # ×6→×7
    check recutShiftedClass(dCapture, SiteMultEnemyPct) == 9     # ×8→×9
    # home/neutral: unchanged.
    check recutShiftedClass(dCapture, SiteMultHomePct) == 8
    check recutShiftedClass(dCapture, SiteMultNeutralPct) == 8
    # commons NEVER shift, on any ground — load-bearing.
    check recutShiftedClass(dHonorableKill, SiteMultEnemyPct) == 1
    check recutShiftedClass(dPointBlankKill, SiteMultEnemyPct) == 1

  test "Fibonacci stack ladder (table §2) with clamped ends":
    check RecutStackLadder == [1, 2, 3, 5, 8, 13]
    for k, want in [(1, 1), (2, 2), (3, 3), (4, 5), (5, 8), (6, 13)].items:
      check recutStackMult(k) == want
    check recutStackMult(0) == 1
    check recutStackMult(-3) == 1
    check recutStackMult(7) == 13   # past the last column: holds, no invention

  test "×1 commons take NO live-state factor at all (§5.8)":
    # heat lit, carrying, enemy ground, 5-ally context — a common still
    # contributes exactly 1 (identity: it mints, it pops, it scores nothing).
    check recutFactor(dHonorableKill, embers = 11,
      sitePct = SiteMultEnemyPct, carrying = true, stackK = 5) == 1

  test "an above-×1 factor composes class × heat × carry × stack":
    # LONGSHOT (×3) at max heat (×8), carrying (×2), 4 teammates (×5).
    check recutFactor(dLongshotKill, embers = 11,
      sitePct = SiteMultHomePct, carrying = true, stackK = 4) == 3 * 8 * 2 * 5

suite "recut product algebra":
  test "log-space sum property: the score is exactly Σ log2 on pow2 factors":
    let factors = [2, 8, 4, 2, 8]   # every factor a power of two
    var product = int64(RecutSeed)
    var logSum = 0.0
    for f in factors:
      product = recutFold(product, f)
      logSum += log2(float(f))
    check product == int64(2) ^ 10   # 1+3+2+1+3 doublings
    check log2(float(product)) == logSum

  test "constant factors commute: any fold order lands on one product":
    let factors = [3, 2, 8, 5, 13, 2]
    var forward = int64(RecutSeed)
    var backward = int64(RecutSeed)
    for i in 0 ..< factors.len:
      forward = recutFold(forward, factors[i])
      backward = recutFold(backward, factors[factors.len - 1 - i])
    check forward == backward
    check forward == 3 * 2 * 8 * 5 * 13 * 2

  test "FF halvings per mode: BR ÷2/incident, CTF ÷2 per TWO (table §4)":
    for incidents, wantBr, wantCtf in [(0, 0, 0), (1, 1, 0), (2, 2, 1),
        (3, 3, 1), (4, 4, 2), (5, 5, 2), (22, 22, 11)].items:
      check recutFfHalvings(incidents, brMode = true) == wantBr
      check recutFfHalvings(incidents, brMode = false) == wantCtf

  test "the reported int score floors the uncapped division (§4's 1.125 row)":
    # CTF max-FF median-win: 2,304 ÷ 2^11 = 1.125 — the table accepts the
    # non-integer tail; the int wire floors it. The canonical pair keeps
    # the exact value; the floor is flagged, not hidden.
    check recutScore(2304, 11) == 1
    check recutScore(2304, 0) == 2304
    check recutScore(73728, 7) == 576    # CTF p90 FF=15 strong row
    check recutScore(9437184, 2) == 2359296  # BR median FF=2 superb row
    check recutScore(1, 63) == 0
    check recutScore(1, 400) == 0

  test "the fold saturates instead of wrapping (overflow guard, not a cap)":
    var product = int64(RecutSeed)
    for _ in 0 ..< 64:
      product = recutFold(product, 13)
    check product == RecutProductCap
    check recutFold(RecutProductCap, 8) == RecutProductCap

  test "the table's recomputed BR superb reproduces exactly: 9,437,184":
    # §1b, verbatim recipe: FIRST! + CHASE + LONGSHOT + BOUNTY + 2×dDuoDown
    # + Closing Time + Last Light + dVictory + Tier V claimed FIRST + heat
    # rung 3 + 5-ally stack. Heat rung 3 (×8) and the 5-ally Fibonacci (×8)
    # ride ONE event each (the LONGSHOT here), exactly one live-state
    # factor apiece — the recipe's own arithmetic.
    var product = int64(RecutSeed)
    let home = SiteMultHomePct
    product = recutFold(product,
      recutFactor(dFirstBlood, 0, home, false))          # ×2
    product = recutFold(product,
      recutFactor(dRunDown, 0, home, false))             # ×2
    product = recutFold(product,
      recutFactor(dLongshotKill, 10, home, false, 5))    # ×3×8×8 (heat rung 3, 5-ally)
    product = recutFold(product,
      recutFactor(dAceTag, 0, home, false))              # ×4
    product = recutFold(product,
      recutFactor(dDuoDown, 0, home, false))             # ×2
    product = recutFold(product,
      recutFactor(dDuoDown, 0, home, false))             # ×2
    product = recutFold(product,
      recutFactor(dClosingTime, 0, home, false))         # ×2
    product = recutFold(product,
      recutFactor(dLastLight, 0, home, false))           # ×4
    product = recutFold(product,
      recutFactor(dVictory, 0, home, false))             # ×8
    product = recutFold(product,
      int64(recutAchievementFactor(4, isFirst = true)))  # ×12
    check heatMult(10) == 8   # rung 3 really is ×8 at 10 embers
    check product == 9_437_184
    # and the guard: not cheaper than CTF's ratified superb ceiling.
    check product > 7_077_888

suite "recut armed sim: per-duo single walk, seed, FF, dark parity":
  test "dark path is the additive v12 ledger, to the gram":
    var sim = startedGame(defaultGameConfig(), 4)
    let team = sim.players[0].team
    let before = sim.teamGlory[team]
    check before == 0   # dark ledger opens at 0, not at the seed
    sim.awardDeed(team, dLongshotKill, 300, 300)
    # additive: base 30 × the site gradient — never a bare ×3 factor.
    check sim.teamGlory[team] - before ==
      mintGlory(dLongshotKill, 0, sim.deedSitePct(team, 300, 300), false)
    check sim.gloryProduct[team] == RecutSeed   # armed state never moves dark

  test "armed: a no-deed episode scores exactly the seed (directive §2)":
    var sim = startedGame(recutConfig(br = false), 4)
    for team in sim.teams():
      check sim.teamGlory[team] == RecutSeed

  test "armed: ONE de-duplicated mint moves the duo product ONCE (contract §7a)":
    # Two seats on one team = the duo. The shared fact mints once through
    # the single mint; the product takes ONE ×3 factor (never ×3 per seat =
    # ×9 — the double-count the field intelligence flagged), and both
    # seats' displayed score IS the same team-keyed value by construction.
    var sim = startedGame(recutConfig(br = false), 4)
    let team = sim.players[0].team
    let sitePct = sim.deedSitePct(team, 300, 300)
    let factor = recutFactor(dLongshotKill, 0, sitePct, false, 1)
    sim.awardDeed(team, dLongshotKill, 300, 300)
    check sim.gloryProduct[team] == int64(factor)
    check sim.teamGlory[team] == factor
    var seatsOnTeam = 0
    for p in sim.players:
      if p.team == team:
        inc seatsOnTeam
    check seatsOnTeam == 2   # a real duo shape, and still one product

  test "armed CTF: the FF division is ÷2 per TWO incidents (penalty case)":
    var sim = startedGame(recutConfig(br = false), 4)
    let team = sim.players[0].team
    sim.awardDeed(team, dCapture, 300, 300)   # some product to divide
    let full = sim.teamGlory[team]
    check full >= 8
    sim.awardDeed(team, dTeamKill, 300, 300)
    check sim.teamGlory[team] == full         # first incident: no halving yet
    check sim.gloryFfIncidents[team] == 1
    sim.awardDeed(team, dTeamKill, 300, 300)
    check sim.teamGlory[team] == full div 2   # second completes the pair
    check sim.gloryFfIncidents[team] == 2

  test "armed BR: the FF division is ÷2 per incident, uncapped":
    var config = recutConfig(br = true)
    var sim = startedGame(config, 4)
    let team = sim.players[0].team
    sim.awardDeed(team, dFlagSteal, 300, 300)   # ×4 (mode-agnostic mint site)
    let full = sim.teamGlory[team]
    check full >= 4
    sim.awardDeed(team, dTeamKill, 300, 300)
    check sim.teamGlory[team] == full div 2
    sim.awardDeed(team, dTeamKill, 300, 300)
    check sim.teamGlory[team] == full div 4
    sim.awardDeed(team, dTeamKill, 300, 300)
    check sim.teamGlory[team] == full div 8    # no cap, keeps compounding

  test "armed: the marquee deeds never mint dark or classic":
    var dark = startedGame(defaultGameConfig(), 4)
    var classic = startedGame(recutConfig(br = false), 4)
    for s in [dark, classic]:
      check s.deedCounts[dDuoDown] == 0
      check s.deedCounts[dClosingTime] == 0
      check s.deedCounts[dLastLight] == 0
      check s.deedCounts[dVictory] == 0

  test "armed BR: dVictory (×8) mints at the decisive finish, winner only":
    var sim = startedGame(recutConfig(br = true), 4)
    let winner = sim.players[0].team
    let before = sim.gloryProduct[winner]
    sim.finishGame(winner)
    check sim.deedCounts[dVictory] == 1
    # On the armed path deedGloryMass records the FOLDED FACTOR (the audit
    # accumulator, awardDeed's own comment): dVictory contributed exactly
    # ×8 — the v12 conclusion sweep may fold its own achievement factors
    # on top (it runs for both teams, unchanged by this increment), so the
    # assertion isolates the victory deed's factor rather than assuming a
    # bare product.
    check sim.deedGloryMass[dVictory] == 8
    check sim.gloryProduct[winner] mod (before * 8) == 0

  test "recutZonePhase: closing and final track the authored schedule":
    var config = recutConfig(br = true)
    config.update("""{"brMode": true, "gloryMultiplierRecut": true,
      "zonePhases": [
        {"z": 0.7, "waitTicks": 100, "shrinkTicks": 50, "dps": 1},
        {"z": 0.3, "waitTicks": 100, "shrinkTicks": 50, "dps": 2}
      ]}""")
    let sim = startedGame(config, 4)
    check sim.recutZonePhase(10) == (closing: false, final: false)
    check sim.recutZonePhase(120) == (closing: true, final: false)  # phase-0 shrink
    check sim.recutZonePhase(200) == (closing: false, final: true)  # last wait
    check sim.recutZonePhase(260) == (closing: true, final: true)   # last shrink
    check sim.recutZonePhase(10_000) == (closing: false, final: true) # hold

  test "recutContextK: CTF counts same-team participants; BR adds allied duos":
    var sim = startedGame(recutConfig(br = false), 8)
    # Seats deal round-robin on two teams: 0,2,4,6 vs 1,3,5,7.
    let victim = 1
    # killer 0's teammates 2 and 4 both hit the victim inside the window.
    discard sim.absorbDamage(victim, 1, attackerIndex = 2, weapon = "gun")
    discard sim.absorbDamage(victim, 1, attackerIndex = 4, weapon = "gun")
    check sim.recutContextK(0, victim) == 3   # killer + two teammates
    check sim.recutContextK(0, 3) == 1        # untouched victim: no context
    # the victim's own teammate hitting it (friendly fire) never counts.
    discard sim.absorbDamage(victim, 1, attackerIndex = 3, weapon = "gun")
    check sim.recutContextK(0, victim) == 3
    # a friendly kill takes no stack at all.
    check sim.recutContextK(3, victim) == 1

  test "recutContextK: the window expires with the incident (120 ticks)":
    var sim = startedGame(recutConfig(br = false), 4)
    let victim = 1
    discard sim.absorbDamage(victim, 1, attackerIndex = 2, weapon = "gun")
    check sim.recutContextK(0, victim) == 2
    sim.tickCount += AssistWindowTicks + 1
    check sim.recutContextK(0, victim) == 1

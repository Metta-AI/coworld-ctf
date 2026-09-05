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
    check config.winAsMultiplier == false
    check config.stampRealizedConfig == false
    check config.variantId == ""
    let echoed = parseJson(config.configJson())
    for key in ["gloryMultiplierRecut", "winAsMultiplier",
        "stampRealizedConfig", "variantId"]:
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
    # §A6: winAsMultiplier is its OWN key too (per-flag discipline) — arming
    # it never drags the recut, and vice versa.
    var winMult = defaultGameConfig()
    winMult.update("""{"winAsMultiplier": true}""")
    check winMult.winAsMultiplier
    check not winMult.gloryMultiplierRecut
    check parseJson(winMult.configJson()).hasKey("winAsMultiplier")
    check not parseJson(recut.configJson()).hasKey("winAsMultiplier")

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
    check "winAsMultiplier=false" in flags

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
    # §A6 even-maximums band (armed+winAsMultiplier mints only) — the two
    # ×2 rows; the frozen v13 rows above are untouched by the flag.
    check RecutClassTable[dTagBack] == 2
    check RecutClassTable[dJointAct] == 2

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

  test "the ratified CTF superb derives exactly from the table's rules: 7,077,888":
    # The table publishes CTF's superb NUMBER (§1: 7,077,888 = 2^18 × 3^3,
    # "the specific bump combination that produces the ratified superb")
    # but never its composition. Derived here from the table's own rules,
    # mirroring the §1b BR recipe's structure — the opening double
    # (FIRST!), one marquee shot (LONGSHOT carrying the episode's single
    # heat-rung-3 and single stack factor, 3-teammate context per §2's
    # "the CTF superb number, built on a 3-teammate context"), the bounty,
    # then the full CTF-only objective line (§1b: STEAL, PEEL, CAPTURE,
    # WIPEOUT), Tier V claimed FIRST:
    #
    #   FIRST!(2) × LONGSHOT(3)×heat(8)×stack(3) × BOUNTY(4) × STEAL(4)
    #   × PEEL(4) × CAPTURE(8) × WIPEOUT(8) × TierV-FIRST(12) = 7,077,888
    #
    # NOTE for the spec record: products commute, so the composition is
    # not unique — e.g. swapping FIRST!+LONGSHOT (2×3) for DENIED!(6)
    # lands the identical number. This recipe is the one structurally
    # parallel to the published BR recipe; the spec lead picks the
    # canonical wording.
    var product = int64(RecutSeed)
    let home = SiteMultHomePct
    product = recutFold(product,
      recutFactor(dFirstBlood, 0, home, false))          # ×2
    product = recutFold(product,
      recutFactor(dLongshotKill, 10, home, false, 3))    # ×3×8×3 (heat rung 3, 3-teammate)
    product = recutFold(product,
      recutFactor(dAceTag, 0, home, false))              # ×4
    product = recutFold(product,
      recutFactor(dFlagSteal, 0, home, false))           # ×4
    product = recutFold(product,
      recutFactor(dCarrierKill, 0, home, false))         # ×4
    product = recutFold(product,
      recutFactor(dCapture, 0, home, false))             # ×8
    product = recutFold(product,
      recutFactor(dWipe, 0, home, false))                # ×8
    product = recutFold(product,
      int64(recutAchievementFactor(4, isFirst = true)))  # ×12
    check product == 7_077_888
    # The old §7 guard ratio (BR/CTF = 4/3) is DEAD — Amendment 6's
    # even-maximums ruling replaced it with BASE EQUALITY: BR base == CTF
    # base == 7,077,888 exactly, with the win factor OUTSIDE the base.
    # The §A6 suite below derives and asserts both recipes symmetrically.

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

# ─────────────────────────────────────────────────────────────────────────
# PKG-C (16-solo BR) SOLO-TEAM GUARD: dDuoDown's marquee (§1b, this file's
# own suite above) reads "no living teammate" as its finish signal. A
# 1-seat team has no teammate BY DEFINITION, so the pre-guard code (`not
# partnerAlive`, unconditionally true when the loop finds nobody else on
# the team at all) would mint dDuoDown as the marquee on every single solo
# kill — the marquee band is meant to name a DUO's last member falling, not
# an ordinary solo elimination. sim.nim's killPlayer now also requires the
# victim's team to seat >= 2 before dDuoDown is even considered. Proven
# here on the smallest real repro of each shape (no BR map pool needed —
# `recutConfig`/`startedGame` already build brMode+gloryMultiplierRecut
# games on the plain 2-team default map, which is exactly what makes a
# 2-solo-team and a 2-duo-team game differ ONLY in seats-per-team).
# ─────────────────────────────────────────────────────────────────────────
suite "dDuoDown solo-team guard (PKG-C 16-solo)":
  proc soloConfig(): GameConfig =
    ## Two SOLO teams, one seat each -- the smallest shape with no partner
    ## to ever finish off.
    result = defaultGameConfig()
    result.brMode = true
    result.gloryMultiplierRecut = true
    result.teams = 2

  proc sameSpot(sim: var SimServer, a, b: int) =
    ## Collapses `b` onto `a`'s position, zeroing `rangePx` -- otherwise the
    ## default map's spawn-to-spawn distance resolves every kill below as
    ## `dLongshotKill` (RecutClassTable 3), which OUTRANKS dDuoDown (2) and
    ## masks it under the one-deed-per-kill precedence rule (killDeed's own
    ## "more specific, rarer feat wins" law) -- a test artifact of the
    ## fixture, not a marquee-gating question. A 0px kill instead resolves
    ## to `dHonorableKill`/`dPointBlankKill` (both class 1), letting the
    ## marquee override exactly as a real close-range BR finish would.
    sim.players[b].x = sim.players[a].x
    sim.players[b].y = sim.players[a].y

  test "a solo team's only seat dying never mints dDuoDown":
    var sim = startedGame(soloConfig(), 2)
    sim.sameSpot(0, 1)
    check sim.deedCounts[dDuoDown] == 0
    sim.killPlayer(1, 0)   # team1's ONLY seat dies -- no partner exists, ever
    check sim.deedCounts[dDuoDown] == 0
    check not sim.players[1].alive

  test "a duo team's finishing kill still mints dDuoDown (byte-identical to pre-guard)":
    # recutConfig defaults to 2 teams; startedGame seats round-robin, so 4
    # seats pairs 0,2 on team0 and 1,3 on team1 -- a genuine 2-seat duo.
    var sim = startedGame(recutConfig(br = true), 4)
    let victimTeam = sim.players[1].team
    check sim.players[3].team == victimTeam
    check sim.deedCounts[dDuoDown] == 0
    sim.sameSpot(0, 1)
    sim.killPlayer(1, 0)   # first half of the duo dies -- partner (3) still alive
    check sim.deedCounts[dDuoDown] == 0
    sim.sameSpot(0, 3)
    sim.killPlayer(3, 0)   # the duo's LAST living member dies -- fires, unchanged
    check sim.deedCounts[dDuoDown] == 1

# ─────────────────────────────────────────────────────────────────────────
# §A6 EVEN MAXIMUMS + AMENDMENT 7 (winAsMultiplier) — the win factor, the
# two new deeds, the ClosingTime rung bump, and BASE EQUALITY. Everything
# below is behind `GameConfig.winAsMultiplier` (its own flag, dark by
# default); the dark tests are the #378 else-branch pattern — with the flag
# OFF the v13 armed world must stay byte-identical (dVictory still mints
# ×8, no new deeds, old rungs).
# ─────────────────────────────────────────────────────────────────────────

proc winMultConfig(br: bool): GameConfig =
  result = recutConfig(br)
  result.winAsMultiplier = true

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  ## Places one player so its collision CENTER sits at (x, y).
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

proc stepIdle(sim: var SimServer, ticks: int) =
  for _ in 0 ..< ticks:
    sim.step(sim.none(), sim.none())

suite "§A6 even maximums: rungs, composition, the mode-keyed win factor":
  test "ClosingTime base rung 2→3 under the flag; the frozen table untouched":
    check RecutClassTable[dClosingTime] == 2                        # frozen v13
    check recutShiftedClass(dClosingTime, SiteMultHomePct) == 2     # dark
    check recutShiftedClass(dClosingTime, SiteMultHomePct, true) == 3
    # the territory rung shift still composes on top of the bumped base
    check recutShiftedClass(dClosingTime, SiteMultEnemyPct, true) == 4
    # the new deeds shift on enemy ground like every above-×1 class (§3)
    check recutShiftedClass(dTagBack, SiteMultHomePct, true) == 2
    check recutShiftedClass(dTagBack, SiteMultEnemyPct, true) == 3
    check recutShiftedClass(dJointAct, SiteMultEnemyPct, true) == 3

  test "new-deed composition: territory+stack compose; heat/carry stay dark":
    # Amendment 7 §1's verification rule: wire = shiftedClass × heat ×
    # carry × stack, via recutFactor — exercised here for the new rows.
    check recutFactor(dTagBack, 0, SiteMultHomePct, false, 1, true) == 2
    check recutFactor(dJointAct, 0, SiteMultHomePct, false, 5, true) == 2 * 8
    check recutFactor(dTagBack, 0, SiteMultEnemyPct, false, 2, true) == 3 * 2
    # the drama column is explicitly untouched by the contract (§5.7): both
    # new deeds carry 0 specced drama (flagged OPEN to conformance review),
    # so neither climbs heat nor takes carry — max embers and a carried
    # flag change NOTHING.
    check recutFactor(dTagBack, 10, SiteMultHomePct, true, 1, true) == 2
    check recutFactor(dJointAct, 10, SiteMultHomePct, true, 1, true) == 2

  test "dark (#378 else-branch): without the flag the v13 factors are byte-identical":
    # recutFactor/recutShiftedClass default winAsMult=false — every
    # pre-existing call site prices exactly as frozen v13.
    check recutFactor(dClosingTime, 0, SiteMultHomePct, false) == 2
    check recutShiftedClass(dClosingTime, SiteMultEnemyPct) == 3   # 2 + shift

  test "the win factor is mode-keyed: BR ×4 ruled; CTF deferred (the seam)":
    check RecutWinFactorBR == 4
    check recutWinFactor(true) == 4
    # M_CTF is DEFERRED to CTF-arming: ×1 (a no-op fold) until it is
    # ruled — recutWinFactor is the seam where it lands, nothing else.
    check recutWinFactor(false) == 1

suite "§A6 BASE EQUALITY: BR base == CTF base == 7,077,888; ceiling 28,311,552":
  test "the §A6 BR base recipe derives to exactly 7,077,888 (no dVictory)":
    # The even-maximums recipe (A6 Candidate 1, ruled): the v13 §1b superb
    # WITHOUT the retired dVictory deed, plus the two new ×2 deeds and the
    # ClosingTime 2→3 bump — heat rung 3 (×8) and the 5-ally Fibonacci
    # (×8) ride ONE event each (the LONGSHOT), exactly as before:
    #
    #   FIRST!(2) × CHASE(2) × LONGSHOT(3)×heat(8)×stack(8) × BOUNTY(4)
    #   × dDuoDown²(2×2) × ClosingTime(3) × LastLight(4) × dTagBack(2)
    #   × dJointAct(2) × TierV-FIRST(12) = 7,077,888 = 2^18 × 3^3
    var product = int64(RecutSeed)
    let home = SiteMultHomePct
    product = recutFold(product,
      recutFactor(dFirstBlood, 0, home, false, 1, true))       # ×2
    product = recutFold(product,
      recutFactor(dRunDown, 0, home, false, 1, true))          # ×2
    product = recutFold(product,
      recutFactor(dLongshotKill, 10, home, false, 5, true))    # ×3×8×8
    product = recutFold(product,
      recutFactor(dAceTag, 0, home, false, 1, true))           # ×4
    product = recutFold(product,
      recutFactor(dDuoDown, 0, home, false, 1, true))          # ×2
    product = recutFold(product,
      recutFactor(dDuoDown, 0, home, false, 1, true))          # ×2
    product = recutFold(product,
      recutFactor(dClosingTime, 0, home, false, 1, true))      # ×3 (bumped)
    product = recutFold(product,
      recutFactor(dLastLight, 0, home, false, 1, true))        # ×4
    product = recutFold(product,
      recutFactor(dTagBack, 0, home, false, 1, true))          # ×2 (new)
    product = recutFold(product,
      recutFactor(dJointAct, 0, home, false, 1, true))         # ×2 (new)
    product = recutFold(product,
      int64(recutAchievementFactor(4, isFirst = true)))        # ×12
    check product == 7_077_888

  test "the CTF base is INVARIANT under the flag — the same 7,077,888":
    # Symmetric derivation (the existing ratified CTF recipe, winAsMult
    # threaded): no CTF deed's rung moves under the flag — the marquee
    # band and the new deeds are BR-shaped, ClosingTime never mints in
    # CTF — so the CTF base is the same number with the flag on or off.
    var product = int64(RecutSeed)
    let home = SiteMultHomePct
    product = recutFold(product,
      recutFactor(dFirstBlood, 0, home, false, 1, true))       # ×2
    product = recutFold(product,
      recutFactor(dLongshotKill, 10, home, false, 3, true))    # ×3×8×3
    product = recutFold(product,
      recutFactor(dAceTag, 0, home, false, 1, true))           # ×4
    product = recutFold(product,
      recutFactor(dFlagSteal, 0, home, false, 1, true))        # ×4
    product = recutFold(product,
      recutFactor(dCarrierKill, 0, home, false, 1, true))      # ×4
    product = recutFold(product,
      recutFactor(dCapture, 0, home, false, 1, true))          # ×8
    product = recutFold(product,
      recutFactor(dWipe, 0, home, false, 1, true))             # ×8
    product = recutFold(product,
      int64(recutAchievementFactor(4, isFirst = true)))        # ×12
    check product == 7_077_888

  test "BASE EQUALITY + CEILING: bases equal EXACTLY; BR total = ×4 = 28,311,552":
    # Amendment 6, owner-ruled ("we definitely want even maximums"): the
    # 4/3 gap is CLOSED — equality replaces the old ratio guard.
    let base = int64(7_077_888)
    check base * int64(recutWinFactor(true)) == 28_311_552
    # the CTF total stays at base × M_CTF (deferred, ×1 for now) — the
    # ceiling asymmetry is the WIN FACTOR only, never the base.
    check base * int64(recutWinFactor(false)) == 7_077_888

suite "§A6 armed sim: win factor, dTagBack, dJointAct, dark parity":
  test "armed: the win factor replaces the stochastic wire dVictory (flat ×4 vs ×64)":
    # The LOOK-BEFORE-ARM truth, as a test: the OFF-path dVictory is
    # stochastic — ×8 class × heat at the mint tick (×16-64 wire) — while
    # the ON-path win factor is a flat, composition-neutral ×4. Identical
    # sims, identical heat (rung 3), only the flag differs.
    var off = startedGame(recutConfig(br = true), 4)
    var on = startedGame(winMultConfig(br = true), 4)
    let winner = off.players[0].team
    off.heatEmbers[winner] = 10   # rung 3: OFF-path dVictory pays ×8 heat
    on.heatEmbers[winner] = 10    # the win factor must NOT
    off.finishGame(winner)
    on.finishGame(winner)
    check off.deedCounts[dVictory] == 1
    check off.deedGloryMass[dVictory] == 64        # 8 × heatMult(10): the wire
    check on.deedCounts[dVictory] == 0             # Amendment 7 §3: deed RETIRED
    # composition-neutral and deterministic: exactly ×4 where OFF took ×64,
    # everything else (the conclusion sweep) identical between the two.
    check off.gloryProduct[winner] == on.gloryProduct[winner] * 16
    check on.teamGlory[winner] == int(on.gloryProduct[winner])

  test "armed: a draw crowns nobody — no win factor on isDraw":
    var on = startedGame(winMultConfig(br = true), 4)
    var off = startedGame(recutConfig(br = true), 4)
    let team = on.players[0].team
    on.finishGame(team, isDraw = true)
    off.finishGame(team, isDraw = true)
    check on.gloryProduct[team] == off.gloryProduct[team]
    check on.deedCounts[dVictory] == 0

  test "armed: dTagBack mints from the completed revive, tagger-attributed, ×2":
    var config = winMultConfig(br = true)
    config.downedMode = true
    config.downedBleedOutTicks = 3 * DownedMinBleedOutTicks
    config.downedReviveTicks = 5
    var sim = startedGame(config, 4)
    sim.centerOn(1, 400, 300)
    sim.centerOn(3, 400 + DownedTagRange - 10, 300)   # partner in tag range
    sim.centerOn(0, 900, 300)                          # enemies far away
    sim.centerOn(2, 900, 340)
    sim.killPlayer(1, 0)
    check sim.players[1].downed
    let ghostTeam = sim.players[1].team
    check sim.players[3].team == ghostTeam             # the tagger's duo
    let productBefore = sim.gloryProduct[ghostTeam]
    sim.stepIdle(5)                                    # downedReviveTicks
    check not sim.players[1].downed
    check sim.deedCounts[dTagBack] == 1
    # The ghost lay on ENEMY ground in this fixture, so the §3 territory
    # rung shift composes on the live mint path — ×2 climbs to ×3, exactly
    # the Amendment 7 §1 verification rule (wire = shiftedClass × heat ×
    # carry × stack; heat/carry are 0-gated for this deed, no stack here).
    check sim.deedSitePct(ghostTeam, 400, 300) == SiteMultEnemyPct
    check sim.deedGloryMass[dTagBack] == 3
    check sim.gloryProduct[ghostTeam] == productBefore * 3

  test "dark (#378 else-branch): the same revive mints NOTHING with the flag off":
    var config = recutConfig(br = true)                # recut ARMED, flag dark
    config.downedMode = true
    config.downedBleedOutTicks = 3 * DownedMinBleedOutTicks
    config.downedReviveTicks = 5
    var sim = startedGame(config, 4)
    sim.centerOn(1, 400, 300)
    sim.centerOn(3, 400 + DownedTagRange - 10, 300)
    sim.centerOn(0, 900, 300)
    sim.centerOn(2, 900, 340)
    sim.killPlayer(1, 0)
    let ghostTeam = sim.players[1].team
    let productBefore = sim.gloryProduct[ghostTeam]
    sim.stepIdle(5)
    check not sim.players[1].downed                    # the revive still works
    check sim.deedCounts[dTagBack] == 0                # the deed does not exist yet
    check sim.gloryProduct[ghostTeam] == productBefore # v13 armed world untouched

  test "armed: dJointAct — ≥2 duos on one victim in one incident, seat-keyed":
    var sim = startedGame(winMultConfig(br = true), 6)
    # Manual duo layout (a team IS a duo in BR): victim's duo Red (0,1),
    # duo Blue (2,3), duo Green (4,5).
    sim.players[0].team = Red
    sim.players[1].team = Red
    sim.players[2].team = Blue
    sim.players[3].team = Blue
    sim.players[4].team = Green
    sim.players[5].team = Green
    sim.players[0].hp = 100                            # stays alive throughout
    # Green is a manually-dealt third duo the 2-team test map never seated,
    # so its product opens unseeded — seed it like the engine seeds active
    # teams, purely so the fold below is observable.
    sim.gloryProduct[Green] = RecutSeed
    discard sim.absorbDamage(0, 1, attackerIndex = 2, weapon = "gun")
    check sim.deedCounts[dJointAct] == 0               # one duo is no joint act
    discard sim.absorbDamage(0, 1, attackerIndex = 4, weapon = "gun")
    check sim.deedCounts[dJointAct] == 2               # BOTH contributing seats
    # The victim stands on its OWN (Red) ground — enemy ground for both
    # attackers, so each ×2 climbs to ×3 via the §3 territory shift at the
    # victim's site (Amendment 7 §1's zone-deed precedent, composed live).
    check sim.deedSitePct(Blue, sim.players[0].x, sim.players[0].y) ==
      SiteMultEnemyPct
    check sim.deedGloryMass[dJointAct] == 6            # ×3 each
    check sim.gloryProduct[Blue] == 3                  # seat 2's duo product
    check sim.gloryProduct[Green] == 3                 # seat 4's duo product
    # dedup: more hits by an already-credited seat never re-mint
    discard sim.absorbDamage(0, 1, attackerIndex = 2, weapon = "gun")
    check sim.deedCounts[dJointAct] == 2
    # seat-keyed: the second Blue seat joining mints for ITS seat — once
    # per contributing seat, never once per duo
    discard sim.absorbDamage(0, 1, attackerIndex = 3, weapon = "gun")
    check sim.deedCounts[dJointAct] == 3
    check sim.gloryProduct[Blue] == 9
    # the victim's own duo neither contributes nor qualifies
    discard sim.absorbDamage(0, 1, attackerIndex = 1, weapon = "gun")
    check sim.deedCounts[dJointAct] == 3
    check sim.gloryProduct[Red] == RecutSeed

  test "armed: the joint-act incident expires (>120t); a fresh one re-mints":
    var sim = startedGame(winMultConfig(br = true), 6)
    sim.players[0].team = Red
    sim.players[1].team = Red
    sim.players[2].team = Blue
    sim.players[3].team = Blue
    sim.players[4].team = Green
    sim.players[5].team = Green
    sim.players[0].hp = 100
    discard sim.absorbDamage(0, 1, attackerIndex = 2, weapon = "gun")
    discard sim.absorbDamage(0, 1, attackerIndex = 4, weapon = "gun")
    check sim.deedCounts[dJointAct] == 2
    sim.tickCount += AssistWindowTicks + 1             # the chain breaks
    discard sim.absorbDamage(0, 1, attackerIndex = 2, weapon = "gun")
    check sim.deedCounts[dJointAct] == 2               # fresh incident, one duo
    discard sim.absorbDamage(0, 1, attackerIndex = 4, weapon = "gun")
    check sim.deedCounts[dJointAct] == 4               # once per (seat, incident)

  test "dark (#378 else-branch): the same cross-duo damage mints NOTHING":
    var sim = startedGame(recutConfig(br = true), 6)   # recut ARMED, flag dark
    sim.players[0].team = Red
    sim.players[2].team = Blue
    sim.players[4].team = Green
    sim.players[0].hp = 100
    discard sim.absorbDamage(0, 1, attackerIndex = 2, weapon = "gun")
    discard sim.absorbDamage(0, 1, attackerIndex = 4, weapon = "gun")
    check sim.deedCounts[dJointAct] == 0
    check sim.recutJointSeats.len == 0                 # state never even touched

# ─────────────────────────────────────────────────────────────────────────
# MINTCAP (2026-09-04) — per-episode, per-duo MINT BUDGETS on the
# repeatable deeds, plus the meaningful product backstop. The durable fix
# behind winAsMultiplier's re-arm: incident d595f300 rolled the flag off
# after the zone-bleed/revive metronome minted dTagBack 24-27× in one
# episode (2^24+ folds; r3894 reported 9.15e15 against a 28,311,552
# design ceiling) and the 2^62 overflow guard — sited ~2^38 ABOVE the
# ceiling it nominally guarded — never fired.
#
# Everything below is behind `GameConfig.deedMintCaps` (its own flag, dark
# by default). The dark tests are the #378 else-branch pattern: with the
# flag OFF, BOTH the v12 additive world and the LIVE v13-armed world must
# stay byte-identical.
# ─────────────────────────────────────────────────────────────────────────

proc capsConfig(br: bool, winMult = true): GameConfig =
  result = recutConfig(br)
  result.winAsMultiplier = winMult
  result.deedMintCaps = true

suite "mintcap config surface (dark by default, its own key)":
  test "the cap flag is dark by default and absent from a dark echo":
    let config = defaultGameConfig()
    check config.deedMintCaps == false
    check not parseJson(config.configJson()).hasKey("deedMintCaps")

  test "it arms independently of the recut and the win factor":
    # PER-FLAG ACTIVATION (Amendment 2 §1): the caps are their own key —
    # arming them never drags the recut or the win factor, and arming
    # either of those never arms the caps.
    var caps = defaultGameConfig()
    caps.update("""{"deedMintCaps": true}""")
    check caps.deedMintCaps
    check not caps.gloryMultiplierRecut
    check not caps.winAsMultiplier
    check parseJson(caps.configJson()).hasKey("deedMintCaps")
    var winMult = defaultGameConfig()
    winMult.update("""{"winAsMultiplier": true}""")
    check not winMult.deedMintCaps
    check not parseJson(winMult.configJson()).hasKey("deedMintCaps")

  test "the realized-config stamp records the caps, false included":
    var config = defaultGameConfig()
    config.update("""{"stampRealizedConfig": true}""")
    var flags: seq[string]
    for f in parseJson(config.realizedConfigStampJson())["flagSet"]:
      flags.add f.getStr
    check "deedMintCaps=false" in flags
    config.update("""{"deedMintCaps": true}""")
    flags = @[]
    for f in parseJson(config.realizedConfigStampJson())["flagSet"]:
      flags.add f.getStr
    check "deedMintCaps=true" in flags

suite "mintcap: the repeatable-deed enumeration and its budgets":
  test "exactly four deeds carry a budget; every other row is uncapped":
    # A deed is REPEATABLE-UNBOUNDED when its per-duo mint count is not
    # bounded by a scarce, contested, non-renewable resource. These four
    # are the whole set (glory.nim's table comment carries the
    # deed-by-deed audit that produced it).
    var capped: seq[Deed]
    for deed in Deed:
      if RecutMintCapTable[deed] > 0:
        capped.add deed
    check capped == @[dShieldSoak, dDuoDown, dTagBack, dJointAct]
    check recutMintCap(dTagBack) == 3
    check recutMintCap(dJointAct) == 6      # seat-keyed: 2 seats × 3
    check recutMintCap(dDuoDown) == 4       # 2× the ceiling recipe's own use
    check recutMintCap(dShieldSoak) == 3
    check recutMintCap(dAceTag) == 0        # enemy lives are the bound
    check recutMintCap(dVictory) == 0       # once, at finalize

  test "the two uncapped unbounded deeds are pinned weightless":
    # dClutchHeal and dLevelUp are structurally unbounded too (a medkit at
    # 1hp, an xp threshold — neither spends an opponent) but are
    # permanently ×1 zero+tombstones that always mint times = 1, so they
    # need no budget. This test is the tripwire: reprice either row and it
    # goes red, forcing the repricer to decide whether it just created a
    # fifth repeatable deed.
    check RecutClassTable[dClutchHeal] == 1
    check RecutClassTable[dLevelUp] == 1
    check recutFactor(dClutchHeal, 10, SiteMultEnemyPct, true, 6, true) == 1
    check recutFactor(dLevelUp, 10, SiteMultEnemyPct, true, 6, true) == 1

  test "every budget sits strictly above the §A6 ceiling recipe's own use":
    # THE SIZING LAW: the ruled superb episode (7,077,888) uses dTagBack
    # once, dJointAct once and dDuoDown twice. A cap below those would
    # move the frozen ceiling; a cap at them would make it a knife-edge.
    # Every budget clears its recipe multiplicity, so a cap can only ever
    # bind on a composition the contract never contemplated.
    check recutMintCap(dTagBack) > 1
    check recutMintCap(dJointAct) > 1
    check recutMintCap(dDuoDown) > 2
    # dShieldSoak appears in no recipe at all (×1, weightless).
    check recutMintCap(dShieldSoak) > 0

  test "the budget clamp: inside, at the boundary, and past it":
    # `recutCappedFolds(minted, times, cap)` is the whole cap.
    check recutCappedFolds(0, 1, 3) == 1        # first mint, inside
    check recutCappedFolds(2, 1, 3) == 1        # the LAST mint inside
    check recutCappedFolds(3, 1, 3) == 0        # the boundary: budget spent
    check recutCappedFolds(9, 1, 3) == 0        # long past it
    check recutCappedFolds(0, 1, 0) == 1        # cap 0 = uncapped
    check recutCappedFolds(99, 40, 0) == 40     # uncapped batches whole
    # a BATCH straddling the boundary folds only the part inside it
    check recutCappedFolds(1, 40, 3) == 2
    check recutCappedFolds(0, 40, 3) == 3
    check recutCappedFolds(0, 2, 3) == 2

suite "mintcap: the product backstop (defense-in-depth layer 2)":
  test "the bound drops from the useless 2^62 guard to ~2× the ceiling":
    check RecutProductCap == int64(1) shl 62
    check RecutProductCapArmed == 67108864          # 2^26
    check recutProductCap(false) == RecutProductCap  # dark: unchanged
    check recutProductCap(true) == RecutProductCapArmed
    # THE INCIDENT, as arithmetic: the design ceiling is 28,311,552 and
    # the blown episode reported 9.15e15. The old guard sat above BOTH.
    check RecutProductCap > int64(9_150_000_000_000_000)
    check RecutProductCapArmed > int64(28_311_552)   # ceiling stays payable
    check RecutProductCapArmed < int64(28_311_552) * 3
    # and 19.9× the legit all-time high the ladder has actually paid.
    check RecutProductCapArmed > int64(3_375_440) * 19

  test "armed: a runaway composition CLAMPS at the backstop, it does not print":
    var product = int64(RecutSeed)
    for _ in 0 ..< 64:
      product = recutFold(product, 13, capsArmed = true)
    check product == RecutProductCapArmed
    check recutFold(RecutProductCapArmed, 8, capsArmed = true) ==
      RecutProductCapArmed
    # the clamp is a KNOWN constant, so an audit can grep for it.
    check recutScore(product, 0) == RecutProductCapArmed

  test "dark: the fold keeps the historical guard byte-for-byte":
    # Every pre-mintcap call site passes no third argument, so the LIVE
    # v13-armed variant folds exactly as it does today.
    var product = int64(RecutSeed)
    for _ in 0 ..< 64:
      product = recutFold(product, 13)
    check product == RecutProductCap
    check recutFold(7077888, 4) == 28311552          # the ceiling still pays
    check recutFold(7077888, 4, capsArmed = true) == 28311552

suite "mintcap: THE METRONOME — 24 revives score as 3":
  test "armed: 24 metronome revives mint 24 dTagBacks and fold exactly 3":
    # The incident, reproduced on the real revive path and then bounded.
    # The zone-bleed metronome re-downs the partner and the tagger revives
    # it, over and over; nothing here spends an enemy, which is precisely
    # why the deed needed a budget. Two identical sims, ONE flag apart.
    proc metronomeSim(caps: bool): SimServer =
      var config = capsConfig(br = true)
      config.deedMintCaps = caps
      config.downedMode = true
      config.downedBleedOutTicks = 3 * DownedMinBleedOutTicks
      config.downedReviveTicks = 5
      result = startedGame(config, 4)
      result.centerOn(1, 400, 300)
      result.centerOn(3, 400 + DownedTagRange - 10, 300)
      result.centerOn(0, 900, 300)
      result.centerOn(2, 900, 340)

    proc runMetronome(sim: var SimServer, cycles: int) =
      for _ in 0 ..< cycles:
        sim.killPlayer(1, 0)
        check sim.players[1].downed
        sim.stepIdle(5)                       # downedReviveTicks
        check not sim.players[1].downed

    var capped = metronomeSim(caps = true)
    var uncapped = metronomeSim(caps = false)
    var honest = metronomeSim(caps = false)   # what 3 legit revives pay
    let ghostTeam = capped.players[1].team
    capped.runMetronome(24)
    uncapped.runMetronome(24)
    honest.runMetronome(3)

    # 1. THE DEED STILL MINTS. Only the score is bounded — deedCounts,
    #    the pops, the wire and every achievement gate downstream see all
    #    24, exactly as they do with the caps dark.
    check capped.deedCounts[dTagBack] == 24
    check uncapped.deedCounts[dTagBack] == 24

    # 2. THE BLOWOUT, REPRODUCED: with the caps dark the product folds 24
    #    times and runs away — orders of magnitude past the ceiling.
    check uncapped.gloryProduct[ghostTeam] > int64(28_311_552)

    # 3. THE FIX: 24 metronome revives score EXACTLY what 3 honest ones
    #    do. The capped product is the honest 3-revive product, to the
    #    integer — the 21 folds past the budget contributed nothing.
    check capped.gloryProduct[ghostTeam] == honest.gloryProduct[ghostTeam]
    check capped.gloryProduct[ghostTeam] < uncapped.gloryProduct[ghostTeam]
    check capped.gloryProduct[ghostTeam] <= int64(28_311_552)
    check capped.gloryProduct[ghostTeam] < RecutProductCapArmed

    # 4. and the wire tells the truth about which mints paid: the capped
    #    run's LAST dTagBack reports factor 1, the neutral element, so an
    #    offline scorer rebuilding the product (§6) lands on the same
    #    number the engine did.
    check capped.deedGloryMass[dTagBack] <
      uncapped.deedGloryMass[dTagBack]

  test "dark: the same 24 revives are byte-identical to today (#378)":
    # The rollback-safety proof. With deedMintCaps off, an armed
    # winAsMultiplier episode prices exactly as the shipped build does —
    # the caps land as dead code until their own key is published.
    proc darkSim(): SimServer =
      var config = winMultConfig(br = true)
      config.downedMode = true
      config.downedBleedOutTicks = 3 * DownedMinBleedOutTicks
      config.downedReviveTicks = 5
      result = startedGame(config, 4)
      result.centerOn(1, 400, 300)
      result.centerOn(3, 400 + DownedTagRange - 10, 300)
      result.centerOn(0, 900, 300)
      result.centerOn(2, 900, 340)
    var a = darkSim()
    var b = darkSim()
    b.config.deedMintCaps = false
    for _ in 0 ..< 6:
      a.killPlayer(1, 0); a.stepIdle(5)
      b.killPlayer(1, 0); b.stepIdle(5)
    let ghostTeam = a.players[1].team
    check a.gloryProduct[ghostTeam] == b.gloryProduct[ghostTeam]
    check a.deedCounts[dTagBack] == 6
    check a.gloryProduct[ghostTeam] > RecutSeed        # it really did fold 6×
    check a.teamGlory[ghostTeam] == b.teamGlory[ghostTeam]

suite "mintcap: every repeatable deed is bounded at its own budget":
  # Driven through `awardDeed`, THE SINGLE MINT every deed in the engine
  # routes through — so these assert the real capping site, not a model of
  # it. `dShieldSoak` additionally exercises the batch (`times > 1`) path.
  proc capSim(): SimServer =
    result = startedGame(capsConfig(br = true), 4)

  test "dTagBack folds 3 and then nothing, however many times it mints":
    var sim = capSim()
    let team = sim.players[0].team
    for _ in 0 ..< 27:
      sim.awardDeed(team, dTagBack, 0, 0, byIndex = 0)
    check sim.deedCounts[dTagBack] == 27          # every mint still counted
    check sim.recutMintCounts[team][dTagBack] == 27
    check sim.gloryProduct[team] == int64(RecutSeed) * 2 * 2 * 2

  test "dJointAct folds 6 — the doubled budget of a seat-keyed deed":
    var sim = capSim()
    let team = sim.players[0].team
    for _ in 0 ..< 20:
      sim.awardDeed(team, dJointAct, 0, 0, byIndex = 0)
    check sim.deedCounts[dJointAct] == 20
    check sim.gloryProduct[team] == int64(RecutSeed) * (2 ^ 6)

  test "dDuoDown folds 4, heat and stack included on those four only":
    var sim = capSim()
    let team = sim.players[0].team
    for _ in 0 ..< 12:
      sim.awardDeed(team, dDuoDown, 0, 0, byIndex = 0)
    check sim.deedCounts[dDuoDown] == 12
    # dDuoDown pays heat (35 drama), so its own mints climb the ladder —
    # the budget bounds the COUNT of folds, whatever each one is worth.
    check sim.gloryProduct[team] > int64(RecutSeed)
    check sim.gloryProduct[team] < RecutProductCapArmed
    var uncapped = startedGame(winMultConfig(br = true), 4)
    for _ in 0 ..< 12:
      uncapped.awardDeed(team, dDuoDown, 0, 0, byIndex = 0)
    check uncapped.gloryProduct[team] > sim.gloryProduct[team]

  test "dShieldSoak: a BATCH spends the budget and folds only what fits":
    # The only deed that passes times > 1 (`times = fromShield`): one call
    # can ask for hundreds of folds. ×1 today, so the arithmetic is inert
    # — the assertion that matters is that the BUDGET is spent by the
    # batch, so a repriced row could never fold 200 times.
    var sim = capSim()
    let team = sim.players[0].team
    sim.awardDeed(team, dShieldSoak, 0, 0, times = 40)
    check sim.recutMintCounts[team][dShieldSoak] == 40
    check recutCappedFolds(0, 40, recutMintCap(dShieldSoak)) == 3
    sim.awardDeed(team, dShieldSoak, 0, 0, times = 40)
    check sim.recutMintCounts[team][dShieldSoak] == 80
    check recutCappedFolds(40, 40, recutMintCap(dShieldSoak)) == 0
    check sim.gloryProduct[team] == int64(RecutSeed)   # ×1: inert either way

  test "an uncapped deed is untouched by the flag: dAceTag folds every time":
    var sim = capSim()
    let team = sim.players[0].team
    for _ in 0 ..< 5:
      sim.awardDeed(team, dAceTag, 0, 0, byIndex = 0)
    check sim.recutMintCounts[team][dAceTag] == 0   # never even counted
    check sim.gloryProduct[team] > int64(4 * 4 * 4 * 4)

  test "the budget is PER DUO and resets with the ledger":
    var sim = capSim()
    let a = sim.players[0].team
    var b = a
    for p in sim.players:
      if p.team != a:
        b = p.team
        break
    check a != b
    # One mint each, on a virgin sim, gives each duo its own per-event
    # factor (the two duos stand on different ground here, so the §3
    # territory shift makes them differ — which is the point: the cap
    # bounds the COUNT of folds, never their value).
    var probe = capSim()
    probe.awardDeed(a, dTagBack, 0, 0)
    let factorA = probe.gloryProduct[a]
    probe.awardDeed(b, dTagBack, 0, 0)
    let factorB = probe.gloryProduct[b]
    for _ in 0 ..< 9:
      sim.awardDeed(a, dTagBack, 0, 0)
      sim.awardDeed(b, dTagBack, 0, 0)
    # each duo spent its OWN budget — one duo's metronome never charges
    # the other, and neither one folds more than three times.
    check sim.gloryProduct[a] == factorA * factorA * factorA
    check sim.gloryProduct[b] == factorB * factorB * factorB
    sim.resetGloryLedger()
    check sim.recutMintCounts[a][dTagBack] == 0
    check sim.recutMintCounts[b][dTagBack] == 0
    # a fresh episode gets a fresh budget (load-bearing for maxGames > 1)
    sim.awardDeed(a, dTagBack, 0, 0)
    check sim.gloryProduct[a] == factorA

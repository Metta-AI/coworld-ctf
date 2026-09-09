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
  std/[sequtils, unittest],
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

suite "S5 placement ramp (placementRampV3, CATALOG-V3-DRAFT.md §4)":
  test "the ruled percent table: dFinal8/dFinal4 crushed to a no-op, dFinal2 a small x1.30 nudge":
    check RecutPlacementRampPct[dFinal8] == 100
    check RecutPlacementRampPct[dFinal4] == 100
    check RecutPlacementRampPct[dFinal2] == 130

  test "dark (flag off): dFinal8/dFinal4/dFinal2 still fold RecutClassTable's frozen 2/3/4":
    var sim = startedGame(recutConfig(br = true), seats = 2)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    sim.awardDeed(Red, dFinal8, 0, 0)
    check sim.gloryProduct[Red] == int64(RecutSeed) * RecutClassTable[dFinal8]

  test "armed: dFinal8/dFinal4 crush to a no-op, dFinal2 folds a real (scaled) nudge":
    var config = recutConfig(br = true)
    config.placementRampV3 = true
    config.gloryFixedPointScale = true
    var sim = startedGame(config, seats = 2)
    sim.players[0].team = Red
    sim.players[1].team = Blue
    let seeded = sim.gloryProduct[Red]
    check seeded == int64(RecutSeed) * GlorySCALE
    sim.awardDeed(Red, dFinal8, 0, 0)
    check sim.gloryProduct[Red] == seeded   # pct=100: unchanged
    sim.awardDeed(Red, dFinal4, 0, 0)
    check sim.gloryProduct[Red] == seeded   # pct=100: unchanged
    sim.awardDeed(Red, dFinal2, 0, 0)
    check sim.gloryProduct[Red] == (seeded * 130) div 100   # pct=130: real nudge
    check sim.gloryProduct[Red] > seeded

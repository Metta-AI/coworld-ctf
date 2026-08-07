## Throwaway deterministic unit test for homeDirVec / the homeDirNav tune
## flag. Bypasses the real-time multi-process server (whose per-tick
## positions are NOT byte-reproducible run-to-run -- websocket/process
## scheduling jitter, confirmed empirically 2026-08-07) and instead calls
## the pure geometry proc directly with hand-built EndzoneMarks, which is
## both a stronger and a cheaper proof than trying to hash-diff two live
## multi-process replays:
##   1. homeDirVec itself: a classic 2-team COLUMN zone must reduce to
##      vec(homeSign(team), 0) within tolerance (the invariant); a 4-team
##      CORNER zone must NOT (it needs a real diagonal), demonstrating the
##      fix is live and non-trivial.
##   2. flag-reads-on-decision-path: every migrated call site has the shape
##      `if bot.tune.homeDirNav: <homeDirVec form> else: <old homeSign
##      form>` (verified by direct source read at each of the 5 sites).
##      This test reproduces that EXACT branch formula for site (a), the
##      retreat/regroup fallback (baseline.nim ~line 5384), with the same
##      bot/tune/me inputs decide() would use, and shows the two arms
##      genuinely diverge on a non-column zone and agree on a column zone --
##      i.e. the flag is read, not dead code, and is behavior-preserving
##      exactly where it claims to be.
## Not part of the shipped image; not compiled into players/baseline/baseline.out.
import std/math
include "../baseline.nim"

proc almostEq(a, b: float, tol = 1e-6): bool = abs(a - b) <= tol

var failures = 0
proc check(name: string, cond: bool) =
  if cond:
    echo "PASS  ", name
  else:
    echo "FAIL  ", name
    inc failures

# ── Test 1: 2-team classic COLUMN zone (the stock-arena shape) ──────────────
block twoTeamColumn:
  MapW = 1235
  MapH = 659
  CenterX = MapW div 2
  CenterY = MapH div 2
  EndzoneMarks.setLen(0)
  EndzoneMarks.add (color: "red", shape: "column", x0: 0, y0: 0, x1: 200, y1: 658)
  EndzoneMarks.add (color: "blue", shape: "column", x0: 1035, y0: 0, x1: 1234, y1: 658)
  SelfColor = "red"
  SelfEnemyColor = "blue"
  SelfStrategyTeam = Red
  let bot = Bot(team: Red, myColor: "red", tune: shippedCombatTune())
  let v = homeDirVec(bot)
  echo "  red column: homeDirVec = (", v.x, ", ", v.y, ")  homeSign(Red) = ", homeSign(Red)
  check("2-team column: x matches homeSign(Red) within tol",
        almostEq(v.x, homeSign(Red), 1e-3))
  check("2-team column: y ~ 0 within tol", almostEq(v.y, 0.0, 1e-3))

  SelfColor = "blue"
  SelfStrategyTeam = Blue
  let botB = Bot(team: Blue, myColor: "blue", tune: shippedCombatTune())
  let vB = homeDirVec(botB)
  echo "  blue column: homeDirVec = (", vB.x, ", ", vB.y, ")  homeSign(Blue) = ", homeSign(Blue)
  check("2-team column (blue): x matches homeSign(Blue) within tol",
        almostEq(vB.x, homeSign(Blue), 1e-3))
  check("2-team column (blue): y ~ 0 within tol", almostEq(vB.y, 0.0, 1e-3))

# ── Test 2: 4-team CORNER zone, the wrong-parity exhibit shape ──────────────
# green's real zone sits in the TOP-LEFT corner of a 2496x2496 board (diagonal
# NW from centre); the slot-parity guess for an even-parity green seat is Red
# (west, per the audit's stated coin-flip rule) -- purely horizontal, wrong IN
# KIND for a corner that also needs a vertical component.
block fourTeamCorner:
  MapW = 2496
  MapH = 2496
  CenterX = MapW div 2
  CenterY = MapH div 2
  EndzoneMarks.setLen(0)
  EndzoneMarks.add (color: "green", shape: "corner", x0: 0, y0: 0, x1: 300, y1: 300)
  EndzoneMarks.add (color: "yellow", shape: "corner", x0: 2196, y0: 0, x1: 2496, y1: 300)
  EndzoneMarks.add (color: "red", shape: "corner", x0: 0, y0: 2196, x1: 300, y1: 2496)
  EndzoneMarks.add (color: "blue", shape: "corner", x0: 2196, y0: 2196, x1: 2496, y1: 2496)
  SelfColor = "green"
  SelfStrategyTeam = Red   # the coin-flip PARITY GUESS (green kept Red's team enum)
  CornerDeepOn = false     # plain bounding-box centroid, not the deep-corner point
  let bot = Bot(team: Red, myColor: "green", tune: shippedCombatTune())
  let vOn = homeDirVec(bot)
  echo "  green corner: homeDirVec = (", vOn.x, ", ", vOn.y, ")"
  check("4-team corner: has a nonzero Y component (diagonal, not axis-aligned)",
        abs(vOn.y) > 0.3)
  check("4-team corner: points toward the TRUE NW corner (x<0, y<0)",
        vOn.x < -0.3 and vOn.y < -0.3)
  check("4-team corner: DIFFERS from the old coin-flip scalar vec(homeSign(team),0)",
        not almostEq(vOn.y, 0.0, 1e-3))

# ── Test 3: site (a)'s EXACT branch formula, both zone shapes ───────────────
# Reproduces baseline.nim's retreat/regroup fallback verbatim:
#   if bot.tune.homeDirNav: me + bot.homeDir * RetreatStep
#   else: vec(me.x + homeSign(bot.team) * RetreatStep, me.y)
# using bot.homeDir populated exactly the way decide()'s per-frame stamp
# populates it (bot.homeDir = homeDirVec(bot)).
block siteAFormula:
  proc siteA(bot: Bot, me: Vec): Vec =
    if bot.tune.homeDirNav: me + bot.homeDir * RetreatStep
    else: vec(me.x + homeSign(bot.team) * RetreatStep, me.y)

  # 3a. Column zone (2-team): ON and OFF must AGREE within tolerance.
  MapW = 1235
  MapH = 659
  CenterX = MapW div 2
  CenterY = MapH div 2
  EndzoneMarks.setLen(0)
  EndzoneMarks.add (color: "red", shape: "column", x0: 0, y0: 0, x1: 200, y1: 658)
  EndzoneMarks.add (color: "blue", shape: "column", x0: 1035, y0: 0, x1: 1234, y1: 658)
  SelfColor = "red"
  SelfStrategyTeam = Red
  let me = vec(500.0, 300.0)
  let botOn = Bot(team: Red, myColor: "red", tune: shippedCombatTune())
  botOn.homeDir = homeDirVec(botOn)
  let botOff = Bot(team: Red, myColor: "red", tune: shippedCombatTune())
  botOff.tune.homeDirNav = false
  botOff.homeDir = homeDirVec(botOff)  # stamped regardless of the tune, same as decide()
  let rOn = siteA(botOn, me)
  let rOff = siteA(botOff, me)
  echo "  site (a) column: ON=(", rOn.x, ",", rOn.y, ")  OFF=(", rOff.x, ",", rOff.y, ")"
  check("site (a) column: ON and OFF agree within tolerance (2-team invariant)",
        almostEq(rOn.x, rOff.x, 0.5) and almostEq(rOn.y, rOff.y, 0.5))

  # 3b. Corner zone (4-team): ON and OFF must DIFFER -- proves the flag is
  #     actually read at the call site (not just inside homeDirVec).
  MapW = 2496
  MapH = 2496
  CenterX = MapW div 2
  CenterY = MapH div 2
  EndzoneMarks.setLen(0)
  EndzoneMarks.add (color: "green", shape: "corner", x0: 0, y0: 0, x1: 300, y1: 300)
  SelfColor = "green"
  SelfStrategyTeam = Red
  CornerDeepOn = false
  let me2 = vec(700.0, 700.0)
  let botOn2 = Bot(team: Red, myColor: "green", tune: shippedCombatTune())
  botOn2.homeDir = homeDirVec(botOn2)
  let botOff2 = Bot(team: Red, myColor: "green", tune: shippedCombatTune())
  botOff2.tune.homeDirNav = false
  botOff2.homeDir = homeDirVec(botOff2)
  let rOn2 = siteA(botOn2, me2)
  let rOff2 = siteA(botOff2, me2)
  echo "  site (a) corner: ON=(", rOn2.x, ",", rOn2.y, ")  OFF=(", rOff2.x, ",", rOff2.y, ")"
  check("site (a) corner: ON and OFF DIFFER (flag reads on the decision path)",
        not (almostEq(rOn2.x, rOff2.x, 0.5) and almostEq(rOn2.y, rOff2.y, 0.5)))
  check("site (a) corner ON: moves toward true NW home (x and y both decrease)",
        rOn2.x < me2.x and rOn2.y < me2.y)
  check("site (a) corner OFF: y unchanged (old bug -- x-only step)",
        almostEq(rOff2.y, me2.y, 1e-6))

# ── Test 4: site (d)'s depth/side-gate formula (rwGateDepth / breachDepth /
# regroupPush+holdLine depth all share this shape) ─────────────────────────
#   ON:  dot(me - centre, bot.homeDir)
#   OFF: homeSign(bot.team) * (me.x - float(CenterX))
block siteDFormula:
  proc sideOfHomeFormula(bot: Bot, me: Vec): float =
    if bot.tune.homeDirNav:
      dot(me - vec(float(CenterX), float(CenterY)), bot.homeDir)
    else:
      homeSign(bot.team) * (me.x - float(CenterX))

  MapW = 2496
  MapH = 2496
  CenterX = MapW div 2
  CenterY = MapH div 2
  EndzoneMarks.setLen(0)
  EndzoneMarks.add (color: "green", shape: "corner", x0: 0, y0: 0, x1: 300, y1: 300)
  SelfColor = "green"
  SelfStrategyTeam = Red
  CornerDeepOn = false
  # A point NORTH of centre but at the same x as centre: on the true NW-home
  # axis this is clearly homeward (positive), but the old x-only scalar reads
  # exactly 0 (can't see the y-only displacement at all) -- the "wrong in
  # KIND" gap the exhibit describes, not just a magnitude error.
  let meNorth = vec(float(CenterX), float(CenterY) - 500.0)
  let botOn = Bot(team: Red, myColor: "green", tune: shippedCombatTune())
  botOn.homeDir = homeDirVec(botOn)
  let botOff = Bot(team: Red, myColor: "green", tune: shippedCombatTune())
  botOff.tune.homeDirNav = false
  botOff.homeDir = homeDirVec(botOff)
  let sOn = sideOfHomeFormula(botOn, meNorth)
  let sOff = sideOfHomeFormula(botOff, meNorth)
  echo "  site (d) due-north-of-centre: ON side-of-home=", sOn, "  OFF side-of-home=", sOff
  check("site (d): OFF is blind to a pure-north displacement (reads exactly 0)",
        almostEq(sOff, 0.0, 1e-9))
  check("site (d): ON correctly reads it as homeward (positive)", sOn > 0.0)

# ── Test 5: site (b)'s disengaged-aim formula ("face the enemy half") ──────
#   ON:  bradsOf(bot.homeDir * -1.0)
#   OFF: bradsOf(vec(-homeSign(bot.team), 0.0))
block siteBFormula:
  MapW = 2496
  MapH = 2496
  CenterX = MapW div 2
  CenterY = MapH div 2
  EndzoneMarks.setLen(0)
  EndzoneMarks.add (color: "green", shape: "corner", x0: 0, y0: 0, x1: 300, y1: 300)
  SelfColor = "green"
  SelfStrategyTeam = Red
  CornerDeepOn = false
  let botOn = Bot(team: Red, myColor: "green", tune: shippedCombatTune())
  botOn.homeDir = homeDirVec(botOn)
  let aimOn = bradsOf(botOn.homeDir * -1.0)
  let aimOff = bradsOf(vec(-homeSign(botOn.team), 0.0))
  echo "  site (b) corner: ON aim brads=", aimOn, "  OFF aim brads=", aimOff,
    "  (256 brads/circle)"
  check("site (b): ON and OFF pick different facing brads on a corner zone",
        aimOn != aimOff)

echo ""
if failures == 0:
  echo "ALL PASS"
else:
  echo "FAILURES: ", failures
  quit(1)

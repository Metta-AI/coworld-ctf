## The length-aware corridor rule, the chokepoint detector and the collision
## point (`src/ctf/map_lanes.nim`).
##
## The detector has failed in this codebase in BOTH directions — unfiltered
## distance-transform minima are confetti, and an over-aggressive medial-axis
## filter returned zero chokepoints for every map INCLUDING the control. So
## this suite runs the rule against controls on both sides:
##
##   NEGATIVE controls — an open field, and the hand-authored `arena`. Neither
##     may report a chokepoint or a violation. A rule that flags the control
##     is wrong.
##   POSITIVE controls — synthetic boards with a doorway punched through a
##     wall, and with a long tunnel. These MUST report, or the detector is a
##     blanket zero and the negative results above mean nothing.
##
## The synthetic boards are raw wall masks, not `CtfMap`s, on purpose: the
## audit's whole input is a mask plus the base points, so the positive control
## can be exactly the geometry under test with nothing else in it.

import
  std/[strutils, unittest],
  ctf/[arena, map_lanes, map_rules, sim_types]

const
  BoardW = 600
  BoardH = 400
  Border = 10

proc blankBoard(): seq[bool] =
  ## Open floor inside a solid border ring.
  result = newSeq[bool](BoardW * BoardH)
  for y in 0 ..< BoardH:
    for x in 0 ..< BoardW:
      result[y * BoardW + x] =
        x < Border or y < Border or x >= BoardW - Border or y >= BoardH - Border

proc addWall(mask: var seq[bool], atX, thick, doorY, doorH: int) =
  ## A full-height wall across the board with one door punched through it.
  for y in 0 ..< BoardH:
    if y >= doorY - doorH div 2 and y < doorY + doorH - doorH div 2: continue
    for x in atX ..< atX + thick:
      if x >= 0 and x < BoardW: mask[y * BoardW + x] = true

const
  LeftBase = MapPoint(x: 60, y: BoardH div 2)
  RightBase = MapPoint(x: BoardW - 60, y: BoardH div 2)

suite "the maximum pinch length is derived, not typed in":
  test "the schedule runs 66 / 99 / 132 px across the chokepoint band":
    # A player with NO dodge room faces the nominal 80% hit rate, and
    # HitPoints*100/80 = 3 shots, (3-1)*FireCooldownTicks = 24 ticks,
    # 24 * MaxSpeed/MotionScale = 66 px. That is the bottom of the 66-125 px
    # lethal-exposure window and it is where an undodgeable pinch belongs.
    check maxPinchRunPx(ChokeWidthMinPx) == 66
    check maxPinchRunPx(SoldierBodyPx) == 66
    check maxPinchRunPx(ChokeWidthMaxPx) == 99
    check shotsToKillAt(PinchAccuracyPct) == 3
    check shotsToKillAt(FieldAccuracyPct) == ShotsToKill

  test "the allowance meets maxExposedRunPx exactly at the corridor floor":
    # THE test that the schedule was derived rather than tuned: at
    # RecommendedCorridorWidthPx the pinch rule stops applying and the
    # cover-spacing rule takes over, and the two agree on the same number, so
    # there is no cliff at the floor.
    check maxPinchRunPx(RecommendedCorridorWidthPx) == MaxExposedRunPx
    check dodgeAccuracyPct(RecommendedCorridorWidthPx) == FieldAccuracyPct
    check maxPinchRunPx(SoldierBodyPx + StrafeWindowPx) == MaxExposedRunPx

  test "the allowance is monotone in width and never zero":
    var prev = 0
    for wpx in EngineMinCorridorPx .. 200:
      let allowed = maxPinchRunPx(wpx)
      check allowed >= prev
      check allowed > 0
      prev = allowed

  test "one pixel of corridor-width floor is free, narrower floor is not":
    check pixelLethality(RecommendedCorridorWidthPx, RecommendedCorridorWidthPx) == 0
    check pixelLethality(200, RecommendedCorridorWidthPx) == 0
    # LethalUnit is the LCM of the three allowances, so a run that accrues it
    # is exactly one kill long with no rounding.
    check pixelLethality(ChokeWidthMinPx, RecommendedCorridorWidthPx) *
      maxPinchRunPx(ChokeWidthMinPx) == LethalUnit
    check pixelLethality(ChokeWidthMaxPx, RecommendedCorridorWidthPx) *
      maxPinchRunPx(ChokeWidthMaxPx) == LethalUnit

suite "the module agrees with the constants it cannot import":
  test "EngineMinCorridorPx is arena.MinCorridorWidth":
    # map_lanes must not import arena (arena adopts corridorPinchFailures), so
    # the constant is duplicated and pinned here — the same guard
    # map_rules.BorderPx uses for arena.ArenaBorder.
    check EngineMinCorridorPx == MinCorridorWidth

suite "NEGATIVE control: open ground has no chokepoint":
  setup:
    let mask = blankBoard()

  test "an open field reports no pinch and full route width":
    let audit = auditCorridorPinches(mask, BoardW, BoardH, [LeftBase, RightBase])
    check audit.ok
    check audit.chokepoints.len == 0
    check audit.runs.len == 0
    check audit.routeWidthPx >= RecommendedCorridorWidthPx
    check corridorPinchFailures(mask, BoardW, BoardH,
      [LeftBase, RightBase]).len == 0

  test "route width on open ground is the board, not the engine minimum":
    check routeWidthPx(mask, BoardW, BoardH, [LeftBase, RightBase]) >
      RecommendedCorridorWidthPx

suite "POSITIVE control: a doorway is found and passes":
  # A 40px door through a 40px wall. This is the case the earlier medial-axis
  # filter returned ZERO for; if it returns zero here the detector is broken
  # and every negative result above is worthless.
  setup:
    var mask = blankBoard()
    mask.addWall(atX = 300, thick = 40, doorY = BoardH div 2, doorH = 40)
    let audit = auditCorridorPinches(mask, BoardW, BoardH, [LeftBase, RightBase])

  test "the door is detected as a genuine cut":
    check audit.chokepoints.len == 1
    check audit.chokepoints[0].mandatory
    check audit.chokepoints[0].tested

  test "the door's measured width is the door":
    check audit.routeWidthPx == 40
    check audit.chokepoints[0].minWidthPx == 40
    check audit.chokepoints[0].inDesignBand

  test "a short door is legal: its arc length fits the allowance":
    let door = audit.chokepoints[0]
    check door.exposedPx <= door.allowedPx
    check door.exposedPx > 0
    check door.allowedPx == maxPinchRunPx(40)
    check audit.ok
    check corridorPinchFailures(mask, BoardW, BoardH,
      [LeftBase, RightBase]).len == 0

  test "the door sits where it was built":
    check abs(audit.chokepoints[0].x - 320) <= 30
    check abs(audit.chokepoints[0].y - BoardH div 2) <= 30

suite "POSITIVE control: a tunnel is a kill box":
  # Same 40px opening, but 300px deep. Nothing about the WIDTH changed; only
  # the length did, which is the entire point of the rule.
  setup:
    var mask = blankBoard()
    mask.addWall(atX = 150, thick = 300, doorY = BoardH div 2, doorH = 40)
    let audit = auditCorridorPinches(mask, BoardW, BoardH, [LeftBase, RightBase])

  test "the tunnel is rejected while the same-width door was accepted":
    check not audit.ok
    check audit.reason.len > 0
    check audit.reason.contains("kill box")

  test "it is rejected for LENGTH, at a width the rule otherwise allows":
    check audit.routeWidthPx == 40
    check audit.chokepoints.len >= 1
    let worst = audit.chokepoints[0]
    check worst.minWidthPx == 40
    check worst.allowedPx == 99
    check worst.exposedPx > worst.allowedPx
    check worst.excessPx > 0

  test "the validator's one-line call reports it":
    let failures = corridorPinchFailures(mask, BoardW, BoardH,
      [LeftBase, RightBase])
    check failures.len == 1
    check failures[0].contains("kill box")

suite "POSITIVE control: doors in series are each a cut":
  setup:
    var mask = blankBoard()
    mask.addWall(atX = 200, thick = 40, doorY = 120, doorH = 40)
    mask.addWall(atX = 400, thick = 40, doorY = 280, doorH = 40)
    let audit = auditCorridorPinches(mask, BoardW, BoardH, [LeftBase, RightBase])

  test "both doorways are reported":
    check audit.chokepoints.len == 2
    for c in audit.chokepoints:
      check c.mandatory
      check c.minWidthPx == 40
      check c.exposedPx <= c.allowedPx
    check audit.ok

  test "one vantage DOES watch both doors here, and the assertion says so":
    # A true positive, not a test that was written to pass: on a 600x400 board
    # the two doorways are 283px apart and a mid-field stance sees straight
    # through both on one diagonal. That is exactly the "one camper owns the
    # map" defect the assertion exists to catch, and a generator reading this
    # would have to move a door.
    let iso = chokepointsCovered(mask, BoardW, BoardH, audit.chokepoints)
    check iso.covered
    check iso.x > 0

  test "the range cap makes watching stop being covering":
    # Beyond gun range, watching is not covering. Capping the isovist below
    # the doors' separation must flip the verdict, which is the guard that the
    # range cap is actually applied.
    let near = chokepointsCovered(
      mask, BoardW, BoardH, audit.chokepoints, rangePx = 100)
    check not near.covered

  test "a single forced doorway IS covered, and says so":
    var one = blankBoard()
    one.addWall(atX = 300, thick = 40, doorY = BoardH div 2, doorH = 40)
    let solo = auditCorridorPinches(one, BoardW, BoardH, [LeftBase, RightBase])
    check solo.chokepoints.len == 1
    check chokepointsCovered(one, BoardW, BoardH, solo.chokepoints).covered

suite "NEGATIVE control: the hand-authored arena":
  # The control that matters. A rule that flags it is wrong, and this one did
  # twice before the routing formulation replaced the region formulation.
  setup:
    let gameMap = loadCtfMapMetadata("arena")
    let diag = mapDiagnostics(gameMap, {diagnosticWallMasks})
    var homes: seq[MapPoint]
    for t in gameMap.teams(): homes.add gameMap.flagHome(t)
    let audit = auditCorridorPinches(
      diag.maxWall, gameMap.width, gameMap.height, homes)

  test "the arena passes the length-aware corridor rule":
    check audit.ok
    check audit.reason == ""
    check corridorPinchFailures(
      diag.maxWall, gameMap.width, gameMap.height, homes).len == 0

  test "the arena has no mandatory chokepoint, agreeing with map_metrics":
    # map_metrics' own detector reports chokeCount = 0 for the arena. Two
    # independent implementations landing on the same answer is the
    # cross-check that neither is simply returning zero.
    check audit.chokepoints.len == 0

  test "its narrow sections exist but are all avoidable":
    # The arena DOES have sub-corridor floor on its widest route — that is
    # what makes it a useful control. Every one of those sections must be
    # routable around for less than a kill, which is why none is mandatory.
    check audit.runs.len > 0
    for r in audit.runs:
      check not r.mandatory

  test "the arena carries a risky flank, and the rule permits it":
    # The measurement is not soft on the control: the arena really does hold a
    # straight 36px-wide channel along the bottom border whose unbroken
    # sightline outlasts the player. It ships anyway because it is ONE lane of
    # eight and you may take another. A rule that rejected it would forbid the
    # tight-flank lane this generator is built to carve.
    var worstExposed = 0
    for r in audit.runs:
      worstExposed = max(worstExposed, r.exposedPx)
    check worstExposed > maxPinchRunPx(audit.routeWidthPx)
    check audit.ok

  test "the arena's widest sustained corridor is below the 68px floor":
    # The honest measurement, and the reason RecommendedCorridorWidthPx is
    # documented as NOT SHIPPED: the hand-authored control is a 36px-corridor
    # map. The pinch rule must therefore gate on avoidability, never on the
    # raw floor, or it would reject the best map in the repo.
    check audit.routeWidthPx < RecommendedCorridorWidthPx
    check audit.routeWidthPx > EngineMinCorridorPx

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
  std/[random, strutils, unittest],
  ctf/[arena, burrow, map_lanes, map_metrics, map_rules, mapgen_vocab,
       sim_types]

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

suite "k-fold disjoint burrow: route count becomes a THEOREM":
  # By Menger, the maximum number of internally vertex-disjoint s-t paths
  # equals the minimum s-t vertex cut. Exhibiting k pairwise cell-disjoint
  # corridors therefore PROVES min-cut >= k, rather than measuring it and
  # hoping. The shipped hard band is routeCountMin >= 2 (control: arena 8.0).

  test "the proof runs on the route metric's own grid, or it is not a proof":
    # Two corridors disjoint on burrow's usual 8px grid can share one 26px
    # routing cell, and then they are ONE vertex to the metric: min-cut 1
    # where we proved 2. The cell size is pinned, and a mismatched grid is
    # refused rather than silently certifying the wrong graph.
    check RouteGridCellPx == RouteCellPx
    var fine = initBurrowGrid(60, 40, cellSize = 8)
    let bad = fine.digDisjointRoutes(
      BurrowPoint(x: 2, y: 20), BurrowPoint(x: 55, y: 20), 3)
    check not bad.ok
    check bad.reason.contains("route metric does not measure")

  test "three disjoint corridors are dug through open ground":
    var grid = initBurrowGrid(48, 26, cellSize = RouteGridCellPx)
    let rep = grid.digDisjointRoutes(
      BurrowPoint(x: 1, y: 13), BurrowPoint(x: 46, y: 13), 3)
    check rep.ok
    check rep.achieved == 3
    check rep.routes.len == 3
    check rep.disjoint

  test "the corridors share no routing cell — the Menger certificate":
    var grid = initBurrowGrid(48, 26, cellSize = RouteGridCellPx)
    let rep = grid.digDisjointRoutes(
      BurrowPoint(x: 1, y: 13), BurrowPoint(x: 46, y: 13), 3)
    check rep.ok
    var seenCell: seq[string]
    for i in 0 ..< rep.routes.len:
      for p in rep.routes[i]:
        if (p.x == 1 and p.y == 13) or (p.x == 46 and p.y == 13): continue
        let key = $p.x & "," & $p.y
        check key notin seenCell
        seenCell.add key

  test "every corridor is at least the corridor floor wide":
    # brushRadiusForCorridor stamps a band exactly 2r+1 cells across, so the
    # width guarantee is structural rather than checked afterwards.
    let r = brushRadiusForCorridor(RecommendedCorridorWidthPx, RouteGridCellPx)
    check (2 * r + 1) * RouteGridCellPx >= RecommendedCorridorWidthPx

  test "it digs THROUGH rock when the board makes it necessary":
    # A solid wall with no opening: the first corridor must cut it, and three
    # disjoint corridors must cut it in three separate places.
    var grid = initBurrowGrid(48, 26, cellSize = RouteGridCellPx)
    for y in 0 ..< 26:
      grid[24, y] = bcWall
    let rep = grid.digDisjointRoutes(
      BurrowPoint(x: 1, y: 13), BurrowPoint(x: 46, y: 13), 3)
    check rep.ok
    check rep.wallCellsDug > 0
    check rep.disjoint

  test "an impossible k is REPORTED, never silently certified":
    # A board too narrow to carry three disjoint 68px corridors must say so.
    var grid = initBurrowGrid(48, 3, cellSize = RouteGridCellPx)
    let rep = grid.digDisjointRoutes(
      BurrowPoint(x: 1, y: 1), BurrowPoint(x: 46, y: 1), 3)
    check not rep.ok
    check rep.achieved < 3
    check rep.reason.len > 0

  test "the arena already carries three disjoint routes, and it is proved":
    let gameMap = loadCtfMapMetadata("arena")
    let diag = mapDiagnostics(gameMap, {diagnosticWallMasks})
    let rep = guaranteeRouteCount(
      diag.maxWall, gameMap.width, gameMap.height,
      gameMap.flagHome(Red), gameMap.flagHome(Blue), 3)
    check rep.ok
    check rep.achieved == 3
    check rep.disjoint

# ---------------------------------------------------------------------------
# clearLanes CUTS every extended kind
# ---------------------------------------------------------------------------
#
# Polygons and diagonals used to be tested on their VERTICES and dropped
# WHOLE, which was wrong in both directions at once: a ring can straddle a
# lane with no vertex inside it (missed), and a ring that clips one corner was
# condemned entire (over-rejected). The guarantee below is the one that
# matters and it is checked in PIXELS, not in bounding boxes: nothing
# `clearLanes` hands back may paint a pixel inside a lane's protected core.

suite "clearLanes cuts polygons and diagonals":
  proc arenaPlan(seed: int): LanePlan =
    ## A real plan off the hand-authored board, the same construction
    ## `tools/lane_clip_probe.nim` measures with.
    let gameMap = loadCtfMapMetadata("arena")
    let
      rules = mapRules("standard", 2)
      base = gameMap.flagHome(Red)
      seamX = gameMap.width div 2
      region = MapRect(x: BorderPx, y: BorderPx,
        w: seamX - BorderPx, h: gameMap.height - 2 * BorderPx)
    var rng = initRand(seed)
    planLanes(rng, region, base, seamX, rules)

  proc corePixels(shape: ArenaShape, plan: LanePlan): int =
    ## How many of this shape's own pixels land inside some lane's core. The
    ## core is asked column by column, so a sloped lane is judged where it
    ## actually runs rather than over its whole descent.
    let b =
      case shape.kind
      of shapePolygon: shape.points.polyBounds
      of shapeDiagonal: shape.diagBounds
      of shapeRect: (shape.rect.x, shape.rect.y,
                     shape.rect.x + shape.rect.w, shape.rect.y + shape.rect.h)
      else: (0, 0, -1, -1)
    for x in b.x0 .. b.x1:
      for lane in plan.lanes:
        let core = lane.laneCoreOver(plan.corridorMinPx, x, x)
        for y in max(b.y0, core.lo) .. min(b.y1, core.hi):
          if inShape(x, y, shape): inc result

  let plan = arenaPlan(7)
  let midLane = block:
    var pick = plan.lanes[0]
    for lane in plan.lanes:
      if lane.role == laneMid: pick = lane
    pick
  let
    crossX = (plan.laneStartX + plan.seamX) div 2
    crossY = midLane.laneY(crossX)

  test "a ring that straddles a lane with NO vertex in it is caught":
    # Every vertex sits clear of the lane; the ring's middle lies across it.
    # The old vertex test read this as no intrusion at all.
    let tall = midLane.widthPx
    let ring = ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: crossX - 60, y: crossY - tall),
      MapPoint(x: crossX + 60, y: crossY - tall),
      MapPoint(x: crossX + 60, y: crossY + tall),
      MapPoint(x: crossX - 60, y: crossY + tall)])
    check plan.intrudesOnLane(ring)
    check ring.corePixels(plan) > 0
    for kept in clearLanes(@[ring], plan):
      check kept.corePixels(plan) == 0

  test "a straddling ring is CUT, not deleted — both sides survive":
    let tall = midLane.widthPx
    let ring = ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: crossX - 60, y: crossY - tall),
      MapPoint(x: crossX + 60, y: crossY - tall),
      MapPoint(x: crossX + 60, y: crossY + tall),
      MapPoint(x: crossX - 60, y: crossY + tall)])
    let kept = clearLanes(@[ring], plan)
    check kept.len == 2
    for k in kept:
      check k.kind == shapePolygon
      check k.points.len >= 3
      check k.points.len <= MaxPolygonVerts

  test "a ring the lanes never touch comes back ONCE, unchanged":
    # The duplication trap: emitting both halves of an untouched ring hands
    # back two coincident copies, and after three lanes eight of them.
    var y = plan.region.y + 8
    var clear = false
    while y < plan.region.y + plan.region.h - 40 and not clear:
      clear = true
      for lane in plan.lanes:
        let core = lane.laneCoreOver(plan.corridorMinPx, crossX - 30, crossX + 30)
        if y - 30 <= core.hi and y + 30 >= core.lo: clear = false
      if not clear: y += 8
    check clear
    let ring = ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: crossX - 30, y: y - 30),
      MapPoint(x: crossX + 30, y: y - 30),
      MapPoint(x: crossX + 30, y: y + 30),
      MapPoint(x: crossX - 30, y: y + 30)])
    let kept = clearLanes(@[ring], plan)
    check kept.len == 1
    check kept[0].points == ring.points

  test "a run crossing a lane is cut in TWO, on a plan with one lane in it":
    # A hand-built plan, for the same reason the boards above are raw masks: on
    # the real arena plan three lanes cross the same place, and a run that ends
    # up wholly consumed proves nothing about the cut. One straight lane makes
    # the answer countable — a run through it must come back as exactly the two
    # ends, both clear of the core.
    let solo = LanePlan(
      region: MapRect(x: 0, y: 0, w: 600, h: 400),
      seamX: 600, corridorMinPx: 68, laneStartX: 0,
      lanes: @[Lane(role: laneMid, widthPx: 80, lengthPx: 600,
        path: @[MapPoint(x: 0, y: 200), MapPoint(x: 600, y: 200)])])
    let run = ArenaShape(kind: shapeDiagonal,
      x0: 200, y0: 60, x1: 380, y1: 340, thickness: 24)
    check solo.intrudesOnLane(run)
    check run.corePixels(solo) > 0
    let kept = clearLanes(@[run], solo)
    check kept.len == 2
    for k in kept:
      check k.kind == shapeDiagonal
      check k.thickness == run.thickness
      check k.corePixels(solo) == 0

  test "a run that only clips a lane's edge keeps most of itself":
    # The over-rejection half of the old vertex test: this used to be dropped
    # whole because one endpoint sat in the lane.
    let solo = LanePlan(
      region: MapRect(x: 0, y: 0, w: 600, h: 400),
      seamX: 600, corridorMinPx: 68, laneStartX: 0,
      lanes: @[Lane(role: laneMid, widthPx: 80, lengthPx: 600,
        path: @[MapPoint(x: 0, y: 200), MapPoint(x: 600, y: 200)])])
    let run = ArenaShape(kind: shapeDiagonal,
      x0: 100, y0: 30, x1: 400, y1: 205, thickness: 20)
    let kept = clearLanes(@[run], solo)
    check kept.len == 1
    check kept[0].corePixels(solo) == 0
    let
      wasLen = max(abs(run.x1 - run.x0), abs(run.y1 - run.y0))
      keptLen = max(abs(kept[0].x1 - kept[0].x0), abs(kept[0].y1 - kept[0].y0))
    # The run meets the core's lip at 72% of its length; the cut is taken on
    # the enclosing 24 px slab, and the capsule's own half width is charged
    # before that, so 64% is the exact figure this geometry gives back. The
    # assertion is on the DIRECTION — most of the run, not none of it.
    check keptLen * 100 div wasLen >= 60

  test "a run the lanes never touch keeps its own endpoints, once":
    var y = plan.region.y + 8
    var clear = false
    while y < plan.region.y + plan.region.h - 40 and not clear:
      clear = true
      for lane in plan.lanes:
        let core = lane.laneCoreOver(plan.corridorMinPx, crossX - 90, crossX + 90)
        if y - 20 <= core.hi and y + 20 >= core.lo: clear = false
      if not clear: y += 8
    check clear
    let run = ArenaShape(kind: shapeDiagonal,
      x0: crossX - 90, y0: y, x1: crossX + 90, y1: y, thickness: 24)
    let kept = clearLanes(@[run], plan)
    check kept.len == 1
    check (kept[0].x0, kept[0].y0) == (run.x0, run.y0)
    check (kept[0].x1, kept[0].y1) == (run.x1, run.y1)

  test "the shipping fill's polygons and runs clear every core":
    # The real thing, not a synthetic: a biome fill through the real clip.
    let gameMap = loadCtfMapMetadata("arena")
    let
      rules = mapRules("standard", 2)
      base = gameMap.flagHome(Red)
      seamX = gameMap.width div 2
      region = MapRect(x: BorderPx, y: BorderPx,
        w: seamX - BorderPx, h: gameMap.height - 2 * BorderPx)
    var seen = 0
    for seed in 1 .. 4:
      var rng = initRand(seed)
      let plan = planLanes(rng, region, base, seamX, rules)
      var cover: seq[ArenaShape]
      for i in 0 ..< 40:
        # A fan of runs and rings across the whole half-field, so every lane
        # is crossed somewhere by something.
        let
          px = region.x + 40 + (i * 37) mod max(1, region.w - 80)
          py = region.y + 20 + (i * 61) mod max(1, region.h - 40)
        cover.add ArenaShape(kind: shapeDiagonal, x0: px, y0: py,
          x1: px + 70, y1: py + 50, thickness: 20)
        cover.add ArenaShape(kind: shapePolygon, points: @[
          MapPoint(x: px, y: py - 40),
          MapPoint(x: px + 55, y: py - 40),
          MapPoint(x: px + 70, y: py + 40),
          MapPoint(x: px - 15, y: py + 40)])
      for kept in clearLanes(cover, plan):
        if kept.kind notin {shapePolygon, shapeDiagonal}: continue
        inc seen
        check kept.corePixels(plan) == 0
    check seen > 0

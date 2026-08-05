## Static map-quality metrics: the measuring stick, built before anything
## changes what it measures.
##
## Every number here is a PURE function of one `CtfMap`. Like
## `tools/map_render.nim`, this module never installs a map and never reads
## the process-global arena (`MapWidth`, `ArenaObstacles`, `obstacleWallAtF`,
## ...) — the map editor serves renders from a mummy thread pool, the future
## best-of-K ranking loop scores candidates that were never selected, and
## both would be corrupted by a process-wide install.
##
## What is measured and why (the calibration source is the MW2 study; the
## default `arena` is the control in every batch — see tools/map_eval.nim):
##
##   * enclosure / interior fraction — floor with >= 6 of 8 directions
##     blocked within 120px. The architecture-vs-scatter discriminator, and
##     the single highest-value static number. Ported from mw2_structure.py's
##     `enclosure`, sweep-for-roll (same semantics, O(n) per direction).
##   * P95 open run over the distance transform. TTK is 1.0-1.9s at 66px/s,
##     so lethal exposure distance is 66-125px: a field whose free space is
##     wider than that everywhere is a shooting gallery.
##   * vertex-disjoint route count per base pair, by unit-capacity max-flow
##     on the node-split grid. Flow = independent flank routes; min-cut x
##     cell size = the tightest bottleneck in px. k = 1 is a fatal CTF map.
##   * chokepoints: distance-transform minima on the medial axis, FILTERED
##     TO GENUINE CUT VERTICES. The unfiltered version produces confetti;
##     the filter is Togelius' own documented fix. Both counts are reported,
##     because a filtered count alone hides how hard the filter worked.
##   * the collision point: the equidistant frontier of a multi-source BFS
##     from all N bases — where the fight will actually happen. Its cover
##     density and clearance are reported against the map average, because
##     the documented failure is a collision point in a cover-free area.
##   * stand-side cover fraction within 200px of each pedestal (the
##     conversion invariant: 6-12% never converted, 10-25% always did) and
##     stand ring openness, WITH the arc count beside the fraction.
##   * midfield crossings, as a count AND the open fraction beside it. A
##     count cannot tell one narrow doorway from one enormous gap.
##
## Rule followed throughout: never a count without its fraction, and never a
## threshold that was not picked against the control.
import std/[algorithm, math], ../src/ctf/sim

const
  AnalysisCell* = FovCellSize
    ## 8px, the fog grid the sim already keeps. Fine enough to resolve a
    ## 26px corridor, coarse enough that a full max-flow is milliseconds.
  EnclosureReach* = 120
    ## px, mw2_structure.enclosure's `reach`: a room is a LOCAL property.
  StandRadius* = 200
    ## px, the conversion-invariant annulus around a pedestal.
  StandRingFallbackRadius* = 64
    ## px, mw2_playtest.stand_exposure's fallback when a map keeps the
    ## legacy full-height column and has no compact endzone radius.
  StandRingPad* = 30
    ## px added to the endzone radius to get the ring sampled.
  LongSightPx* = 600
    ## px, "a gallery shot" in the MW2 report.
  IsovistRange* = GunRange
    ## px, the range cap on the "no single point covers all chokepoints"
    ## assertion. GunRange is 1050 and does not scale with the map.
  MaxRoutesProbed* = 8
    ## Flow search cap. An open field has dozens of disjoint routes and the
    ## exact number is noise; what matters is telling 1 and 2 from "many".
  ChokeMaxHalfWidthPx* = 56
    ## px, the widest half-width (distance transform value) a passage may
    ## have and still be called a chokepoint. Above this it is a lane.

type
  MapMasks* = object
    ## The two masks every metric reads, plus the analysis grid.
    ##
    ## They are NOT the same mask and using one for the other's job is a
    ## real error: a bullet is stopped by `wallPix`, but a player needs the
    ## whole 13px footprint clear, so `freeCell` is `wallPix` dilated by
    ## PlayerHalf. Sightlines are a wall question; routes are a footprint
    ## question.
    width*, height*: int          ## px
    wallPix*: seq[bool]           ## per pixel: a shot is stopped here.
    cell*: int
    gw*, gh*: int                 ## analysis grid size, in cells.
    wallCell*: seq[bool]          ## the cell's centre pixel is wall.
    freeCell*: seq[bool]          ## a player can stand at the cell centre.

  StandMetric* = object
    ## One pedestal's surroundings. `coverFrac` is the conversion invariant;
    ## `ringOpen` is the complementary "open AT the stand" rule. The arc
    ## count is reported only next to the fraction — alone it called an
    ## 81%-open ring "1 approach, a turkey shoot".
    team*: int
    x*, y*: int
    coverFrac*: float             ## wall fraction within StandRadius.
    protectedFrac*: float         ## ...of that annulus that is PROTECTED
                                  ## floor, where terrain may not be built.
                                  ## On a legacy column endzone this is most
                                  ## of it, which is why `coverFrac` reads
                                  ## structurally low there.
    ringRadius*: int              ## px the ring was sampled at.
    ringOpen*: float              ## fraction of the ring that is walkable.
    ringArcs*: int                ## distinct arcs wide enough to walk.

  RouteMetric* = object
    ## Vertex-disjoint routes between one ordered base pair.
    a*, b*: int                   ## team ordinals.
    routes*: int                  ## unit-capacity max flow.
    capped*: bool                 ## routes hit MaxRoutesProbed.
    minCutPx*: int                ## routes * cell; meaningless when capped.
    pathPx*: float                ## geodesic base-to-base distance.
    straightPx*: float            ## straight-line base-to-base distance.
    detour*: float                ## pathPx / straightPx.

  CollisionMetric* = object
    ## Where the fight will happen: the equidistant frontier of a
    ## multi-source BFS from every base.
    cells*: int
    frac*: float                  ## frontier cells / free cells.
    x*, y*: int                   ## frontier centroid, px.
    coverFrac*: float             ## wall fraction within 100px of frontier.
    mapCoverFrac*: float          ## the same measure over the whole map.
    clearancePx*: float           ## mean distance-to-wall on the frontier.
    mapClearancePx*: float

  CrossingMetric* = object
    ## Ways across one midfield line. The count and the fraction are always
    ## reported together: low count + low fraction is a corridor, low count
    ## + high fraction is a field, and they play nothing alike.
    axis*: string                 ## "vertical" (crossing x = centre) or
                                  ## "horizontal".
    count*: int                   ## at the most divided midfield line.
    medianCount*: int             ## across the whole midfield band.
    linePx*: int                  ## where the reported line sits.
    openFrac*: float              ## of that line.
    widestPx*: int
    narrowestPx*: int

  MapMetrics* = object
    ## One map's complete static evidence set.
    name*, path*: string
    width*, height*: int
    teamCount*: int
    cell*: int
    genSeed*: int
    compactEndzone*: bool         ## capture AT the stand (disc/square) as
                                  ## opposed to the legacy home column. The
                                  ## MW2 stand rules were measured on
                                  ## capture-at-the-stand maps and only
                                  ## govern conversion there.
    validationReason*: string     ## "" when the shipped validators pass.
    freeCells*, wallCells*: int
    wallFrac*: float              ## wall pixels / interior pixels.
    interiorFrac*: float          ## enclosure >= 6 of 8 (the room test).
    coveredFrac*: float           ## enclosure >= 3.
    exposedFrac*: float           ## enclosure <= 1 (wide open).
    p95OpenRunPx*: float          ## P95 free-space diameter (2 x dist. tr.).
    p95ClearancePx*: float        ## P95 distance transform itself.
    medianSightPx*: float         ## median unbroken axis run.
    p95SightPx*: float
    longSightFrac*: float         ## axis runs over LongSightPx.
    stands*: seq[StandMetric]
    standCoverMin*, standCoverMax*: float
    standRingMin*, standRingMax*: float
    standRingDelta*: float        ## max inter-team ring gap.
    routes*: seq[RouteMetric]
    minRoutes*: int
    minCutPx*: int
    detourMean*: float
    chokeCandidates*: int         ## medial-axis minima before filtering.
    chokepoints*: int             ## ...that are genuine cut vertices.
    chokeCoveredByOnePoint*: bool ## a single isovist sees them all.
    collision*: CollisionMetric
    crossings*: seq[CrossingMetric]
    rectShapeFrac*: float         ## share of obstacles that are plain bars
                                  ## (GV38 `shapeBar` subsumes the old
                                  ## `shapeRect`/`shapeDiamond` pair exactly).
    shapeCount*: int
    trenchCount*: int

# ---------------------------------------------------------------- masks ----

proc buildMapMasks*(gameMap: CtfMap, cell = AnalysisCell): MapMasks =
  ## Rasterizes both masks once. `wallPix` comes from the same
  ## `rasterizeRestWallMask` the art bake and `dump_map_mask --raw` use, so
  ## the terrain measured here is the terrain a bullet meets.
  let
    w = gameMap.width
    h = gameMap.height
    obstacles = buildArenaObstacles(gameMap)
  result.width = w
  result.height = h
  result.cell = cell
  result.wallPix = rasterizeRestWallMask(gameMap, obstacles,
    proc (x, y: int): bool = mapProtectedFloorAt(gameMap, x, y))

  ## An integral image answers "is any pixel in this box a wall?" in O(1),
  ## which is what the 13x13 footprint test needs at every cell centre.
  var integral = newSeq[int32]((w + 1) * (h + 1))
  for y in 0 ..< h:
    var rowSum = 0'i32
    for x in 0 ..< w:
      if result.wallPix[y * w + x]:
        rowSum += 1
      integral[(y + 1) * (w + 1) + x + 1] =
        integral[y * (w + 1) + x + 1] + rowSum

  proc boxHasWall(x0, y0, x1, y1: int): bool =
    ## Any wall pixel in the inclusive box? Off-map reads as wall: a
    ## footprint hanging off the board is not a place a player can stand.
    if x0 < 0 or y0 < 0 or x1 >= w or y1 >= h:
      return true
    let stride = w + 1
    integral[(y1 + 1) * stride + x1 + 1] - integral[y0 * stride + x1 + 1] -
      integral[(y1 + 1) * stride + x0] + integral[y0 * stride + x0] > 0

  result.gw = (w + cell - 1) div cell
  result.gh = (h + cell - 1) div cell
  result.wallCell = newSeq[bool](result.gw * result.gh)
  result.freeCell = newSeq[bool](result.gw * result.gh)
  for cy in 0 ..< result.gh:
    for cx in 0 ..< result.gw:
      let
        px = min(cx * cell + cell div 2, w - 1)
        py = min(cy * cell + cell div 2, h - 1)
        i = cy * result.gw + cx
      result.wallCell[i] = result.wallPix[py * w + px]
      result.freeCell[i] = not boxHasWall(
        px - PlayerHalf, py - PlayerHalf, px + PlayerHalf, py + PlayerHalf)

proc cellIndex(masks: MapMasks, x, y: int): int {.inline.} =
  ## The analysis cell containing map pixel (x, y).
  clamp(y div masks.cell, 0, masks.gh - 1) * masks.gw +
    clamp(x div masks.cell, 0, masks.gw - 1)

proc cellCentrePx(masks: MapMasks, i: int): tuple[x, y: int] {.inline.} =
  ((i mod masks.gw) * masks.cell + masks.cell div 2,
   (i div masks.gw) * masks.cell + masks.cell div 2)

proc nearestFreeCell(masks: MapMasks, x, y: int): int =
  ## The occupiable cell nearest a map pixel, by expanding ring. A pedestal
  ## sits on protected floor so its own cell is normally free, but a metric
  ## that silently returns "no routes" because one seed cell rounded into a
  ## wall would be a metric that flags the map for the grid's mistake.
  let start = masks.cellIndex(x, y)
  if masks.freeCell[start]:
    return start
  let
    sx = start mod masks.gw
    sy = start div masks.gw
  for r in 1 ..< max(masks.gw, masks.gh):
    for dy in -r .. r:
      for dx in -r .. r:
        if abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = sx + dx
          ny = sy + dy
        if nx < 0 or ny < 0 or nx >= masks.gw or ny >= masks.gh:
          continue
        if masks.freeCell[ny * masks.gw + nx]:
          return ny * masks.gw + nx
  -1

# ----------------------------------------------------------- enclosure ----

proc enclosure*(
  masks: MapMasks, reach = EnclosureReach
): tuple[interior, covered, exposed: float] =
  ## Of the 8 directions, how many are blocked by wall within `reach` px —
  ## computed at PIXEL resolution, on the bare wall mask, exactly like
  ## mw2_structure.enclosure.
  ##
  ## Connectivity is the wrong tool for this and produced a number that
  ## flagged the control: floor inside a building is still perfectly
  ## REACHABLE through its door, and the map's own border frame makes every
  ## open pixel unable to reach the image edge, so a flood-based measure
  ## reported one room covering the whole playfield on every map, arena
  ## included. Being surrounded at SHORT RANGE is a local property.
  ##
  ## Reading the score: 0-2 open field, 3-5 cover or a corridor, 6+ means
  ## walled on nearly every side — a room, an alcove, an interior.
  ##
  ## The reference rolls the whole wall mask `reach` times per direction.
  ## This sweeps a running "steps to the next wall" counter instead: same
  ## answer, one pass per direction instead of 120.
  let
    w = masks.width
    h = masks.height
    big = reach + 1
  var blocked = newSeq[uint8](w * h)
  const Dirs = [(0, 1), (0, -1), (1, 0), (-1, 0),
                (1, 1), (1, -1), (-1, 1), (-1, -1)]
  var steps = newSeq[int32](w * h)
  for (dy, dx) in Dirs:
    ## Walk against the direction so `p + d` is always already solved.
    for yi in 0 ..< h:
      let y = if dy > 0: h - 1 - yi else: yi
      for xi in 0 ..< w:
        let
          x = if dx > 0: w - 1 - xi else: xi
          ny = y + dy
          nx = x + dx
        var value = int32(big)
        if ny >= 0 and ny < h and nx >= 0 and nx < w:
          if masks.wallPix[ny * w + nx]:
            value = 1
          else:
            let next = steps[ny * w + nx]
            value = if next >= int32(big): int32(big) else: next + 1
        steps[y * w + x] = value
        if value <= int32(reach):
          blocked[y * w + x] += 1
  var floor6, floor3, floor1, floorAll = 0
  for i in 0 ..< w * h:
    if masks.wallPix[i]:
      continue
    inc floorAll
    if blocked[i] >= 6: inc floor6
    if blocked[i] >= 3: inc floor3
    if blocked[i] <= 1: inc floor1
  let denominator = max(floorAll, 1).float
  (floor6.float / denominator, floor3.float / denominator,
   floor1.float / denominator)

# ------------------------------------------------- distances / geodesic ----

const
  StepAxis = 3     ## chamfer(3, 4): 3 for an axis step,
  StepDiag = 4     ## 4 for a diagonal one, so distance/3 ~ euclidean.
  Unreached = high(int32).int

proc dialDistance(masks: MapMasks, sources: openArray[int]): seq[int] =
  ## Chamfer(3,4) distance in thirds of a cell, relaxed only THROUGH free
  ## cells. Dial's algorithm: integer weights bounded by 4 mean a monotone
  ## frontier spans at most 5 cost values, so 5 circular buckets replace the
  ## heap and the whole board costs O(n).
  ##
  ## The seeds do not have to be free cells, and that is the whole reason
  ## this serves two callers. Seed one pedestal and it is a geodesic from
  ## that base; seed every BLOCKED cell and it is the distance transform,
  ## because the relaxation never steps back into a wall.
  let n = masks.gw * masks.gh
  result = newSeq[int](n)
  for i in 0 ..< n:
    result[i] = Unreached
  var
    buckets: array[StepDiag + 1, seq[int]]
    pending = 0
  for s in sources:
    if s >= 0 and s < n and result[s] != 0:
      result[s] = 0
      buckets[0].add s
      inc pending
  var d = 0
  while pending > 0:
    while buckets[d mod (StepDiag + 1)].len == 0:
      inc d
    let bucket = buckets[d mod (StepDiag + 1)]
    buckets[d mod (StepDiag + 1)] = @[]
    pending -= bucket.len
    for i in bucket:
      if result[i] != d:
        continue                       ## a stale copy of an improved node.
      let
        cx = i mod masks.gw
        cy = i div masks.gw
      for (dx, dy, cost) in [(1, 0, StepAxis), (-1, 0, StepAxis),
                             (0, 1, StepAxis), (0, -1, StepAxis),
                             (1, 1, StepDiag), (1, -1, StepDiag),
                             (-1, 1, StepDiag), (-1, -1, StepDiag)]:
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= masks.gw or ny >= masks.gh:
          continue
        let j = ny * masks.gw + nx
        if not masks.freeCell[j]:
          continue
        let candidate = d + cost
        if candidate < result[j]:
          result[j] = candidate
          buckets[candidate mod (StepDiag + 1)].add j
          inc pending

proc distanceTransform(masks: MapMasks): seq[int] =
  ## Distance from every free cell to the nearest non-free cell, in thirds
  ## of a cell, so a free cell touching wall reads 3 (one cell).
  var walls: seq[int]
  for i in 0 ..< masks.gw * masks.gh:
    if not masks.freeCell[i]:
      walls.add i
  masks.dialDistance(walls)

proc percentile(values: var seq[int], q: float): float =
  ## Linear-index percentile of an integer sample.
  if values.len == 0:
    return 0.0
  values.sort()
  let index = clamp(int(round(q * float(values.len - 1))), 0, values.len - 1)
  values[index].float

# ---------------------------------------------------------- sightlines ----

proc sightlineRuns(masks: MapMasks): seq[int] =
  ## Unbroken open-run lengths along both axes, in cells, from the WALL
  ## mask — how far a shot travels before geometry cuts the angle.
  for cy in 0 ..< masks.gh:
    var run = 0
    for cx in 0 ..< masks.gw:
      if masks.wallCell[cy * masks.gw + cx]:
        if run > 0: result.add run
        run = 0
      else:
        inc run
    if run > 0: result.add run
  for cx in 0 ..< masks.gw:
    var run = 0
    for cy in 0 ..< masks.gh:
      if masks.wallCell[cy * masks.gw + cx]:
        if run > 0: result.add run
        run = 0
      else:
        inc run
    if run > 0: result.add run

# --------------------------------------------------------------- stands ----

proc standMetric(
  gameMap: CtfMap, masks: MapMasks, team: Team
): StandMetric =
  ## Cover in the approach annulus, openness on the ring.
  ##
  ## Measured for EVERY map, including the ones on the legacy full-height
  ## column: the earlier version skipped those, so the control never scored,
  ## and an inverted reading survived because of it.
  let
    home = gameMap.flagHome(team)
    w = masks.width
    h = masks.height
  result.team = ord(team)
  result.x = home.x
  result.y = home.y

  var wallCount, protectedCount, total = 0
  for y in max(0, home.y - StandRadius) .. min(h - 1, home.y + StandRadius):
    for x in max(0, home.x - StandRadius) .. min(w - 1, home.x + StandRadius):
      let
        dx = x - home.x
        dy = y - home.y
      if dx * dx + dy * dy > StandRadius * StandRadius:
        continue
      inc total
      if masks.wallPix[y * w + x]:
        inc wallCount
      if mapProtectedFloorAt(gameMap, x, y):
        inc protectedCount
  result.coverFrac = wallCount.float / max(total, 1).float
  ## Protected floor is where the generator is FORBIDDEN to build, so an
  ## annulus that is mostly protected can never reach the 10-25% band no
  ## matter how the map is drawn. Reported so a low cover reading is never
  ## mistaken for a design choice.
  result.protectedFrac = protectedCount.float / max(total, 1).float

  let radius =
    if gameMap.endzoneRadius > 0:
      gameMap.endzoneRadius + StandRingPad
    else:
      StandRingFallbackRadius + StandRingPad
  result.ringRadius = radius
  const Steps = 180
  var ring = newSeq[bool](Steps)
  for i in 0 ..< Steps:
    let
      theta = 2.0 * PI * float(i) / float(Steps)
      x = int(round(float(home.x) + float(radius) * cos(theta)))
      y = int(round(float(home.y) + float(radius) * sin(theta)))
    ring[i] = x >= 0 and y >= 0 and x < w and y < h and
      not masks.wallPix[y * w + x]
  var open = 0
  for v in ring:
    if v: inc open
  result.ringOpen = open.float / float(Steps)
  if open == Steps:
    result.ringArcs = 1
    return
  if open == 0:
    result.ringArcs = 0
    return
  ## Rotate so an arc never straddles the seam, then count arcs wide enough
  ## to walk through (~25px of arc is a real doorway for a 13px body).
  var start = 0
  for i in 0 ..< Steps:
    if not ring[i]:
      start = i
      break
  let
    arcPx = 2.0 * PI * float(radius) / float(Steps)
    minSteps = max(2, int(25.0 / max(arcPx, 0.001)))
  var run = 0
  for k in 0 ..< Steps:
    if ring[(start + k) mod Steps]:
      inc run
    else:
      if run >= minSteps: inc result.ringArcs
      run = 0
  if run >= minSteps: inc result.ringArcs

# --------------------------------------------------------------- routes ----

type
  FlowEdge = object
    to, next, cap: int

  FlowGraph = object
    head: seq[int]
    edges: seq[FlowEdge]

proc addEdge(graph: var FlowGraph, a, b, cap: int) =
  graph.edges.add FlowEdge(to: b, next: graph.head[a], cap: cap)
  graph.head[a] = graph.edges.len - 1
  graph.edges.add FlowEdge(to: a, next: graph.head[b], cap: 0)
  graph.head[b] = graph.edges.len - 1

proc maxFlowUnit(graph: var FlowGraph, source, sink, limit: int): int =
  ## Edmonds-Karp with unit augmentation. Every non-terminal capacity is 1,
  ## so each BFS finds one more vertex-disjoint route and the flow value IS
  ## the route count; the search stops at `limit` because on an open field
  ## the exact number is dozens and is noise.
  var previous = newSeq[int](graph.head.len)
  while result < limit:
    for i in 0 ..< previous.len:
      previous[i] = -1
    previous[source] = -2
    var queue = @[source]
    var head = 0
    var reached = false
    while head < queue.len and not reached:
      let node = queue[head]
      inc head
      var e = graph.head[node]
      while e != -1:
        let next = graph.edges[e].to
        if graph.edges[e].cap > 0 and previous[next] == -1:
          previous[next] = e
          if next == sink:
            reached = true
            break
          queue.add next
        e = graph.edges[e].next
    if not reached:
      break
    var node = sink
    while node != source:
      let e = previous[node]
      graph.edges[e].cap -= 1
      graph.edges[e xor 1].cap += 1
      node = graph.edges[e xor 1].to
    inc result

proc routeMetric(
  gameMap: CtfMap, masks: MapMasks, distances: seq[seq[int]],
  a, b: Team
): RouteMetric =
  ## Vertex-disjoint routes between two bases: split every free cell into
  ## in/out nodes joined by a capacity-1 edge, so a route consumes the CELL,
  ## not just one of its sides. That is the difference between "independent
  ## flank routes" and "the same corridor counted four times".
  ##
  ## An earlier lane metric tried "find a path, wall it off, find another".
  ## At this cell scale blocking a path severs the map, so it reported ONE
  ## route for every layout including the arena. When a metric flags the
  ## control, the metric is wrong.
  let
    n = masks.gw * masks.gh
    source = 2 * n
    sink = 2 * n + 1
    homeA = gameMap.flagHome(a)
    homeB = gameMap.flagHome(b)
  result.a = ord(a)
  result.b = ord(b)
  var graph = FlowGraph(head: newSeq[int](2 * n + 2))
  for i in 0 ..< graph.head.len:
    graph.head[i] = -1
  const Infinite = 1_000_000
  ## The terminal pockets themselves must not be a bottleneck, so they bind
  ## straight to the OUT node, bypassing their own capacity-1 split.
  let
    pocket = 5 * masks.cell    ## ~40px: the pedestal's own clearing.
    seedA = masks.nearestFreeCell(homeA.x, homeA.y)
    seedB = masks.nearestFreeCell(homeB.x, homeB.y)
  for i in 0 ..< n:
    if not masks.freeCell[i]:
      continue
    graph.addEdge(2 * i, 2 * i + 1, 1)
    let (px, py) = masks.cellCentrePx(i)
    if i == seedA or
        (px - homeA.x) * (px - homeA.x) +
        (py - homeA.y) * (py - homeA.y) <= pocket * pocket:
      graph.addEdge(source, 2 * i + 1, Infinite)
    if i == seedB or
        (px - homeB.x) * (px - homeB.x) +
        (py - homeB.y) * (py - homeB.y) <= pocket * pocket:
      graph.addEdge(2 * i, sink, Infinite)
    let
      cx = i mod masks.gw
      cy = i div masks.gw
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= masks.gw or ny >= masks.gh:
        continue
      let j = ny * masks.gw + nx
      if masks.freeCell[j]:
        graph.addEdge(2 * i + 1, 2 * j, 1)
  result.routes = graph.maxFlowUnit(source, sink, MaxRoutesProbed)
  result.capped = result.routes >= MaxRoutesProbed
  result.minCutPx = result.routes * masks.cell

  if seedB >= 0 and distances[ord(a)][seedB] != Unreached:
    result.pathPx =
      distances[ord(a)][seedB].float / float(StepAxis) * float(masks.cell)
  result.straightPx = hypot(float(homeA.x - homeB.x), float(homeA.y - homeB.y))
  result.detour =
    if result.straightPx > 0 and result.pathPx > 0:
      result.pathPx / result.straightPx
    else:
      0.0

# ---------------------------------------------------------- chokepoints ----

proc lineOfSight(masks: MapMasks, i, j: int): bool =
  ## Bresenham over the WALL mask between two cell centres.
  var
    x0 = i mod masks.gw
    y0 = i div masks.gw
  let
    x1 = j mod masks.gw
    y1 = j div masks.gw
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    sx = if x0 < x1: 1 else: -1
    sy = if y0 < y1: 1 else: -1
  var error = dx + dy
  while true:
    if masks.wallCell[y0 * masks.gw + x0]:
      return false
    if x0 == x1 and y0 == y1:
      return true
    let doubled = 2 * error
    if doubled >= dy:
      error += dy
      x0 += sx
    if doubled <= dx:
      error += dx
      y0 += sy

proc severedArea(masks: MapMasks, plugged: seq[bool]): int =
  ## Free cells left OUTSIDE the largest surviving component once `plugged`
  ## is removed — i.e. how much of the map this plug actually cuts off.
  ##
  ## A component COUNT is not enough. Plugging a nook between two pebbles
  ## seals a handful of cells and raises the count by one, which reported
  ## the arena as having 29 chokepoints when it has no bottleneck at all.
  ## What matters is whether a real piece of the map came away.
  let n = masks.gw * masks.gh
  var
    seen = newSeq[bool](n)
    largest = 0
    total = 0
  for start in 0 ..< n:
    if not masks.freeCell[start] or plugged[start] or seen[start]:
      continue
    var queue = @[start]
    seen[start] = true
    var head = 0
    while head < queue.len:
      let
        i = queue[head]
        cx = i mod masks.gw
        cy = i div masks.gw
      inc head
      for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= masks.gw or ny >= masks.gh:
          continue
        let j = ny * masks.gw + nx
        if masks.freeCell[j] and not plugged[j] and not seen[j]:
          seen[j] = true
          queue.add j
    total += queue.len
    largest = max(largest, queue.len)
  total - largest

proc chokepoints(
  masks: MapMasks, dt: seq[int]
): tuple[candidates, genuine: seq[int]] =
  ## Distance-transform local minima on the medial axis, then filtered to
  ## GENUINE CUT VERTICES.
  ##
  ## The unfiltered version produces confetti — every notch between two
  ## pebbles reads as a doorway. Plugging the passage and asking whether the
  ## free space actually falls apart is Togelius' own documented fix, and it
  ## is what makes a zero honest: an open field HAS no chokepoints, and
  ## saying so is information.
  let
    n = masks.gw * masks.gh
    maxHalfWidth = ChokeMaxHalfWidthPx * StepAxis div masks.cell
  var ridge = newSeq[bool](n)
  for i in 0 ..< n:
    if not masks.freeCell[i] or dt[i] == Unreached or dt[i] == 0:
      continue
    let
      cx = i mod masks.gw
      cy = i div masks.gw
    var isRidge = true
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1),
                     (1, 1), (1, -1), (-1, 1), (-1, -1)]:
      let
        nx = cx + dx
        ny = cy + dy
      if nx < 0 or ny < 0 or nx >= masks.gw or ny >= masks.gh:
        continue
      let j = ny * masks.gw + nx
      if masks.freeCell[j] and dt[j] > dt[i]:
        isRidge = false
        break
    ridge[i] = isRidge and dt[i] <= maxHalfWidth

  ## Non-maximum suppression along the ridge: keep only the narrowest cell
  ## in each 5-cell neighbourhood, or one passage reports as a dozen.
  for i in 0 ..< n:
    if not ridge[i]:
      continue
    let
      cx = i mod masks.gw
      cy = i div masks.gw
    var isMinimum = true
    for dy in -2 .. 2:
      for dx in -2 .. 2:
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= masks.gw or ny >= masks.gh:
          continue
        let j = ny * masks.gw + nx
        if j != i and ridge[j] and
            (dt[j] < dt[i] or (dt[j] == dt[i] and j < i)):
          isMinimum = false
    if isMinimum:
      result.candidates.add i

  var freeCells = 0
  for i in 0 ..< n:
    if masks.freeCell[i]: inc freeCells
  let
    alreadySevered = masks.severedArea(newSeq[bool](n))
    minSevered = max(25, freeCells div 100)
      ## 1% of the floor, or 25 cells (~1600px²) on a small board: below
      ## that the "severed" piece is an alcove, not a wing of the map.
  for i in result.candidates:
    ## Plug the passage: everything within its own half-width plus a cell.
    var plugged = newSeq[bool](n)
    let
      radius = dt[i] div StepAxis + 1
      cx = i mod masks.gw
      cy = i div masks.gw
    for dy in -radius .. radius:
      for dx in -radius .. radius:
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= masks.gw or ny >= masks.gh:
          continue
        if dx * dx + dy * dy <= radius * radius:
          plugged[ny * masks.gw + nx] = true
    if masks.severedArea(plugged) - alreadySevered >= minSevered:
      result.genuine.add i

# ------------------------------------------------------ collision point ----

proc collisionMetric(
  masks: MapMasks, distances: seq[seq[int]], dt: seq[int], teams: int
): CollisionMetric =
  ## The equidistant frontier of the multi-source BFS from all N bases: the
  ## place every team reaches at the same moment, i.e. where the fight will
  ## happen. Its cover density is reported against the map average because
  ## the documented failure this catches is a collision point that lands in
  ## a cover-free area.
  ##
  ## The brief also asks for "route count" at the frontier. A route count is
  ## a property of a base PAIR, not of a point, so what stands in for it
  ## here is mean clearance — the distance transform averaged over the
  ## frontier against the map average. High clearance at the collision point
  ## is the same defect stated the other way: nothing to fight from.
  let
    n = masks.gw * masks.gh
    tolerance = 2 * StepAxis        ## within two cells of a tie.
  var
    frontier: seq[int]
    sumX, sumY = 0
    clearanceSum = 0
  for i in 0 ..< n:
    if not masks.freeCell[i]:
      continue
    var best, second = Unreached
    for t in 0 ..< teams:
      let d = distances[t][i]
      if d < best:
        second = best
        best = d
      elif d < second:
        second = d
    if best == Unreached or second == Unreached:
      continue
    if second - best <= tolerance:
      frontier.add i
      let (px, py) = masks.cellCentrePx(i)
      sumX += px
      sumY += py
      clearanceSum += dt[i]
  result.cells = frontier.len
  var freeCells = 0
  var mapClearance = 0
  for i in 0 ..< n:
    if masks.freeCell[i]:
      inc freeCells
      mapClearance += dt[i]
  result.frac = frontier.len.float / max(freeCells, 1).float
  result.mapClearancePx =
    mapClearance.float / max(freeCells, 1).float / float(StepAxis) *
      float(masks.cell)
  if frontier.len == 0:
    return
  result.x = sumX div frontier.len
  result.y = sumY div frontier.len
  result.clearancePx =
    clearanceSum.float / frontier.len.float / float(StepAxis) *
      float(masks.cell)

  ## Cover density: wall pixels within 100px of the frontier, against the
  ## whole map's wall fraction.
  const Near = 100
  let nearCells = Near div masks.cell
  var nearFrontier = newSeq[bool](n)
  for i in frontier:
    let
      cx = i mod masks.gw
      cy = i div masks.gw
    for dy in -nearCells .. nearCells:
      for dx in -nearCells .. nearCells:
        let
          nx = cx + dx
          ny = cy + dy
        if nx < 0 or ny < 0 or nx >= masks.gw or ny >= masks.gh:
          continue
        if dx * dx + dy * dy <= nearCells * nearCells:
          nearFrontier[ny * masks.gw + nx] = true
  var nearWall, nearTotal, allWall = 0
  for i in 0 ..< n:
    if masks.wallCell[i]:
      inc allWall
    if nearFrontier[i]:
      inc nearTotal
      if masks.wallCell[i]:
        inc nearWall
  result.coverFrac = nearWall.float / max(nearTotal, 1).float
  result.mapCoverFrac = allWall.float / max(n, 1).float

# ------------------------------------------------------------ crossings ----

proc lineCrossings(
  masks: MapMasks, vertical: bool, line: int
): tuple[count, widest, narrowest: int, openFrac: float] =
  ## Ways across ONE midfield line: runs of at least 30px where a five-cell
  ## band around the line is clear. Blocked when ANY cell of the band is
  ## blocked, so a one-cell notch through an otherwise solid line does not
  ## register as a way across.
  ##
  ## Read on `freeCell`, not `wallCell`: a way across is somewhere a PLAYER
  ## fits, and the 13px footprint eats 6px off each side of every gap. The
  ## wall-mask reading gave the control 9 crossings at a 73%-open line where
  ## the footprint reading gives 6 at 33% — two different numbers for one
  ## question, and the Python report (which has always measured occupancy on
  ## the footprint mask) printed the second while this printed the first.
  let
    span = if vertical: masks.gh else: masks.gw
    minRun = max(3, (30 + masks.cell - 1) div masks.cell)
  var
    run = 0
    openCells = 0
    count = 0
    widest = 0
    narrowest = high(int)
  for k in 0 .. span:
    ## One step past the end so a run touching the far edge still closes.
    var blocked = true
    if k < span:
      blocked = false
      for offset in -2 .. 2:
        let
          cx = if vertical: clamp(line + offset, 0, masks.gw - 1) else: k
          cy = if vertical: k else: clamp(line + offset, 0, masks.gh - 1)
        if not masks.freeCell[cy * masks.gw + cx]:
          blocked = true
          break
    if blocked:
      if run >= minRun:
        inc count
        widest = max(widest, run * masks.cell)
        narrowest = min(narrowest, run * masks.cell)
      run = 0
    else:
      inc run
      inc openCells
  result.count = count
  result.widest = widest
  result.narrowest = if narrowest == high(int): 0 else: narrowest
  result.openFrac = openCells.float / float(span)

proc crossingMetric(
  masks: MapMasks, axis: string
): CrossingMetric =
  ## Distinct ways across midfield, WITH the open fraction beside the count.
  ## A count alone cannot tell one narrow doorway from one enormous gap —
  ## both score 1, and a 73%-open midfield divided into 5 ways across plays
  ## nothing like the same 73% arriving as a single 486px span.
  ##
  ## Midfield is a BAND, not a line. The first version of this sampled the
  ## exact centre column and reported ONE crossing for every layout
  ## including the arena — because the arena's centre is inside `flagRing`,
  ## a disc of protected floor the generator is forbidden to build in, so
  ## the centre column is open on every map by construction. Measuring the
  ## flag ring and calling it the midfield structure is how a metric comes
  ## to flag its own control. The scan runs over the middle 25% of the board
  ## and reports the most divided line, with the band's median beside it so
  ## one lucky picket row cannot pass for structure.
  result.axis = axis
  let
    vertical = axis == "vertical"
    across = if vertical: masks.gw else: masks.gh
    centre = across div 2
    half = max(1, across div 8)
  var counts: seq[int]
  var best = -1
  for line in max(0, centre - half) .. min(across - 1, centre + half):
    let probe = masks.lineCrossings(vertical, line)
    counts.add probe.count
    if best < 0 or probe.count > result.count or
        (probe.count == result.count and probe.openFrac < result.openFrac):
      result.count = probe.count
      result.widestPx = probe.widest
      result.narrowestPx = probe.narrowest
      result.openFrac = probe.openFrac
      best = line
  result.linePx = max(best, 0) * masks.cell
  counts.sort()
  result.medianCount = if counts.len > 0: counts[counts.len div 2] else: 0

# ------------------------------------------------------------- assembly ----

proc computeMapMetrics*(
  gameMap: CtfMap, cell = AnalysisCell, withChokepoints = true
): MapMetrics =
  ## The full static evidence set for one map. `withChokepoints` is the one
  ## expensive stage (a flood per candidate); the ranking loop can drop it.
  let masks = buildMapMasks(gameMap, cell)
  result.name = gameMap.name
  result.path = gameMap.path
  result.width = gameMap.width
  result.height = gameMap.height
  result.teamCount = gameMap.teamCount()
  result.genSeed = gameMap.genSeed
  result.cell = cell
  result.compactEndzone = gameMap.endzoneRadius > 0
  result.validationReason = validateGeneratedMap(gameMap)
  result.trenchCount = gameMap.trenches.len

  var rects = 0
  for shape in gameMap.leftObstacles:
    if shape.kind == shapeBar:
      inc rects
  result.shapeCount = gameMap.leftObstacles.len
  result.rectShapeFrac = rects.float / max(result.shapeCount, 1).float

  ## Wall fraction over the INTERIOR only: the perimeter frame is not cover,
  ## and counting it makes a small map look denser than a large one.
  var wallPixels, interiorPixels = 0
  for y in ArenaBorder ..< gameMap.height - ArenaBorder:
    for x in ArenaBorder ..< gameMap.width - ArenaBorder:
      inc interiorPixels
      if masks.wallPix[y * gameMap.width + x]:
        inc wallPixels
  result.wallFrac = wallPixels.float / max(interiorPixels, 1).float

  for i in 0 ..< masks.freeCell.len:
    if masks.freeCell[i]: inc result.freeCells
    if masks.wallCell[i]: inc result.wallCells

  let enclosed = masks.enclosure()
  result.interiorFrac = enclosed.interior
  result.coveredFrac = enclosed.covered
  result.exposedFrac = enclosed.exposed

  let dt = masks.distanceTransform()
  var clearances: seq[int]
  for i in 0 ..< dt.len:
    if masks.freeCell[i] and dt[i] != Unreached:
      clearances.add dt[i]
  let scale = float(cell) / float(StepAxis)
  result.p95ClearancePx = percentile(clearances, 0.95) * scale
  result.p95OpenRunPx = 2.0 * result.p95ClearancePx

  var runs = masks.sightlineRuns()
  var long = 0
  for r in runs:
    if r * cell > LongSightPx: inc long
  result.longSightFrac = long.float / max(runs.len, 1).float
  result.medianSightPx = percentile(runs, 0.5) * float(cell)
  result.p95SightPx = percentile(runs, 0.95) * float(cell)

  result.standCoverMin = 1.0
  result.standRingMin = 1.0
  for team in gameMap.teams():
    let stand = standMetric(gameMap, masks, team)
    result.stands.add stand
    result.standCoverMin = min(result.standCoverMin, stand.coverFrac)
    result.standCoverMax = max(result.standCoverMax, stand.coverFrac)
    result.standRingMin = min(result.standRingMin, stand.ringOpen)
    result.standRingMax = max(result.standRingMax, stand.ringOpen)
  result.standRingDelta = result.standRingMax - result.standRingMin

  var distances: seq[seq[int]]
  for team in gameMap.teams():
    let
      home = gameMap.flagHome(team)
      seed = masks.nearestFreeCell(home.x, home.y)
    distances.add masks.dialDistance(
      if seed >= 0: @[seed] else: newSeq[int]())

  result.minRoutes = high(int)
  result.minCutPx = high(int)
  var detourSum = 0.0
  var detourCount = 0
  for a in gameMap.teams():
    for b in gameMap.teams():
      if ord(b) <= ord(a):
        continue
      let route = routeMetric(gameMap, masks, distances, a, b)
      result.routes.add route
      result.minRoutes = min(result.minRoutes, route.routes)
      if not route.capped:
        result.minCutPx = min(result.minCutPx, route.minCutPx)
      if route.detour > 0:
        detourSum += route.detour
        inc detourCount
  if result.minRoutes == high(int): result.minRoutes = 0
  if result.minCutPx == high(int):
    result.minCutPx = MaxRoutesProbed * cell     ## ">= this", never cut.
  result.detourMean = detourSum / max(detourCount, 1).float

  result.collision =
    collisionMetric(masks, distances, dt, gameMap.teamCount())
  result.crossings.add crossingMetric(masks, "vertical")
  if gameMap.layout != layoutHex2:
    ## `layoutHex2` is the left/right pair: the vertical midline is the only
    ## line a run home must cross. Every wider layout seats teams around the
    ## hex, so the horizontal midline is a real crossing too.
    result.crossings.add crossingMetric(masks, "horizontal")

  if withChokepoints:
    let (candidates, genuine) = masks.chokepoints(dt)
    result.chokeCandidates = candidates.len
    result.chokepoints = genuine.len
    ## No single point may command every chokepoint. Sampled on a stride so
    ## the assertion costs milliseconds; with fewer than two chokepoints it
    ## is vacuous and stays false.
    if genuine.len >= 2:
      let rangeCells = IsovistRange div cell
      var i = 0
      while i < masks.freeCell.len and not result.chokeCoveredByOnePoint:
        if masks.freeCell[i]:
          var seesAll = true
          for c in genuine:
            let
              dx = (i mod masks.gw) - (c mod masks.gw)
              dy = (i div masks.gw) - (c div masks.gw)
            if dx * dx + dy * dy > rangeCells * rangeCells or
                not masks.lineOfSight(i, c):
              seesAll = false
              break
          if seesAll:
            result.chokeCoveredByOnePoint = true
        i += 3

proc rawWallMaskBytes*(masks: MapMasks): string =
  ## The pixel wall mask as one byte per pixel (0 floor, 1 wall), for the
  ## numpy side to re-derive `enclosure` independently. Two implementations
  ## of the highest-value metric that agree is worth the twenty lines.
  result = newString(masks.width * masks.height)
  for i in 0 ..< masks.wallPix.len:
    result[i] = char(if masks.wallPix[i]: 1 else: 0)

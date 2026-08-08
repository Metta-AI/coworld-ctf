## Burrow — minimum-cost connectivity repair for generated maps.
##
## Ported from mettagrid's `mapgen/scenes/make_connected.py` (and its narrower
## sibling `ensure_hub_reachable_junction.py`), per
## `docs/plans/2026-08-04-map-generator-rebuild.md` §3.
##
## WHAT IT DOES
##   Guarantees a map's open space is exactly ONE connected component by
##   digging the cheapest possible tunnels: routing through existing corridors
##   where it can, punching walls only at their thinnest section, and
##   destroying placed objects only as an absolute last resort.
##
## COST MODEL — the entire tuning surface, and only the RATIO matters:
##   `WallCostRatio = 10`     walking 10 open cells == digging 1 wall
##   `ObjectCostRatio = 50`   removing 1 object == digging 5 walls
##   i.e. `reuse corridors >> dig rock >> bulldoze content`.
##
## ALGORITHM
##   Label components (4-connected) -> the largest becomes the anchor -> ONE
##   multi-source weighted BFS by DIAL'S ALGORITHM producing min-cost-to-anchor
##   plus a predecessor pointer for every cell -> for each orphan component
##   take the `argmin` of that cost over the WHOLE component (which is exactly
##   what produces "punch through at the thinnest wall section": the cheapest
##   cell of a component is by construction the one with the thinnest barrier
##   between it and the main body) -> walk predecessors back, digging.
##
##   Dial's works because with integer weights bounded by J a monotone Dijkstra
##   frontier spans at most J+1 distinct cost values, so J+1 circular FIFO
##   buckets suffice: O(n*J), no heap, no log n.
##
##   There is NO RNG anywhere in this module. Two runs on the same input
##   produce byte-identical output (pinned by tests/test_burrow.nim).
##
## THE FIVE CHANGES FROM THE REFERENCE IMPLEMENTATION
##   1. BRUSH RADIUS. Width-1 corridors are useless in a continuous-space
##      shooter where the player is 13 px solid / 34 px drawn. `brushRadius`
##      stamps an L2 disc along the tunnel centerline, so a dug corridor is
##      `2*brushRadius+1` cells wide. See "BRUSH VS COST MODEL" below — a wide
##      brush changes what "thinnest section" means and the step cost is
##      brush-aware to match.
##   2. AUDIT. `_dig_path` silently overwrote any non-empty cell on the path,
##      objectives included, and logged nothing. `BurrowReport.objectsDestroyed`
##      is always populated (never behind an artifact flag) and `summary()`
##      shouts about it.
##   3. WEDGE MASK. The pass is inherently global and asymmetric — it picks
##      THE largest component and `argmin`s a single cheapest cell — so running
##      it on an assembled symmetric map yields symmetric geometry with
##      ASYMMETRIC tunnels. `BurrowGrid.domain` restricts both traversal and
##      digging to a fundamental domain, so the caller burrows the wedge and
##      then lifts by the symmetry orbit. `params.anchors` pins the anchor
##      component (the G-invariant hub of plan §2.2) instead of "whichever
##      component happens to be biggest", which is the other half of making
##      this deterministic under a wedge.
##   4. PASSABLE SET, EXPLICIT. Their labeller only saw literal `"empty"`, so a
##      region whose only floor was an object tile was invisible to it. Ours:
##      `bcFloor` and `bcContent` are PASSABLE (`isPassable`), `bcWall` and
##      `bcObject` are not. `bcContent` is floor that carries placed content
##      which does not block movement — med kits, trench squares, flag
##      pedestals, spawn seats. It is passable, it counts toward connectivity,
##      and the burrow NEVER destroys it. `bcObject` is placed content that
##      does block — a building, an objective wall — impassable, removable at
##      `objectCost`, and every removal is audited.
##   5. FAILURE RESULT, NOT AN ASSERT. Their only recovery was a bare `assert`,
##      i.e. a crash mid-generation. `burrow` returns a `BurrowReport` whose
##      `status` the caller inspects; the generator has a 100-attempt budget
##      and a ranking loop, so reject-and-reroll is strictly better than dying.
##
## RESOLUTION — WHAT A "CELL" IS
##   Our maps are continuous pixel space with per-pixel wall queries, not a
##   tile grid, so the resolution is a decision rather than a given. The burrow
##   operates on a COARSE CELL GRID and `burrowGridFromPixels` rasterizes into
##   it. The recommended cell size is `FovCellSize` (8 px):
##
##   - COST. A giant board is 3211x1713 = 5.5 M pixels and `generateCtfMap`
##     runs its validator up to 100 times per map. At 8 px a giant board is
##     402x215 = 86 k cells, so Dial's is ~350 k relaxations — well under a
##     millisecond. At full pixel resolution the same pass is 64x the cells AND
##     needs a ~8x larger brush radius, i.e. ~500x the work, which would blow
##     the whole generation budget on one repair pass. The existing map
##     diagnostics are staged with early exit for exactly this reason; the
##     burrow must not undo that.
##   - MEANING. 8 px is already the engine's spatial quantum (`FovCellSize`,
##     the fog grid), so the burrow's notion of "connected" lines up with the
##     grid the sim already reasons on.
##   - CONSERVATISM. `burrowGridFromPixels` marks a cell passable only when
##     EVERY pixel in it is passable. That under-reports connectivity, so the
##     burrow may dig a tunnel that a pixel-exact pass would have skipped — but
##     it can never claim a passage the 13 px player footprint cannot use.
##     Digging clears a whole cell, so a dug corridor is genuinely open at
##     pixel resolution. Both errors point the safe way.
##
##   `cellSize = 1` gives the pixel-exact behaviour if a caller ever wants it;
##   nothing in the algorithm assumes a coarse grid.
##
## BRUSH VS COST MODEL
##   The naive port charges the centerline only. That is wrong twice over with
##   a brush: digging a wall actually costs a whole disc of cells, and a
##   building one cell OFF the centerline gets bulldozed for free — the exact
##   silent-destruction hole that change 2 exists to close.
##
##   So the step cost of entering a cell is the MEAN unit cost over the brush
##   footprint that entering it would stamp, rounded up:
##
##     stepCost(c) = ceil( sum(unitCost(b) for b in disc(c, r)) / |disc(c, r)| )
##
##   Properties that matter:
##   - `r = 0` reduces to the reference implementation exactly (asserted in the
##     tests), so the port is a strict generalization.
##   - The cost still lies in `[1, objectCost]`, so Dial's `objectCost + 1`
##     buckets remain valid and the pass stays O(n*J).
##   - "Thinnest section" survives. A brush multiplies the cost of crossing a
##     barrier by roughly the same constant everywhere, so the argmin still
##     lands on the thinnest barrier — but a route whose brush footprint is
##     mostly ALREADY OPEN now scores cheaper than one that must widen solid
##     rock, which is the corridor-hugging behaviour we wanted in the first
##     place, only now brush-aware.
##   - An object inside the brush footprint costs `objectCost` even when the
##     centerline misses it, so the planner routes around content it would
##     otherwise have quietly flattened.

import std/strutils

const
  WallCostRatio* = 10
    ## Walking 10 open cells costs the same as digging through 1 wall.
  ObjectCostRatio* = 50
    ## Removing 1 placed object costs the same as digging through 5 walls.

type
  BurrowCell* = enum
    ## The passable set is EXPLICIT (change 4). `isPassable` is the single
    ## definition; component labelling, flood fills and the junction pass all
    ## go through it.
    bcFloor    ## plain open floor. passable, unit cost 1.
    bcContent  ## floor carrying placed content that does NOT block movement
               ## (med kits, trench squares, pedestals, spawn seats).
               ## passable, unit cost 1, never destroyed.
    bcWall     ## impassable rock. diggable at `wallCost`.
    bcObject   ## impassable placed content (buildings, objectives).
               ## removable at `objectCost`, and every removal is audited.

  BurrowPoint* = object
    x*, y*: int   ## CELL coordinates. See `cellRectPx` for the pixel box.

  BurrowGrid* = object
    ## A coarse cell grid over the board. `cellSize` is only carried so
    ## callers can convert back to pixels; the algorithm never reads it.
    w*, h*: int
    cellSize*: int
    cells*: seq[BurrowCell]
    domain*: seq[bool]
      ## The FUNDAMENTAL DOMAIN mask (change 3). An empty seq means "the whole
      ## grid". Cells outside it are never traversed, never labelled, and
      ## never written — so a wedge-masked run leaves the rest of the board
      ## byte-identical and the caller can lift by the symmetry orbit
      ## afterwards.

  BurrowArtifact* = enum
    ## Opt-in full-board artifacts, mirroring `MapDiagnosticArtifact` in
    ## arena.nim: a giant board is 5.5 M pixels and the generator runs this up
    ## to 100 times per map, so per-cell sequences are not retained by default.
    ## The AUDIT is deliberately not on this list — `objectsDestroyed` is
    ## always populated, because "it silently deletes buildings" is the defect
    ## this port exists to fix.
    baPaths     ## retain `BurrowReport.paths`, the tunnel centerlines.
    baDugCells  ## retain `BurrowReport.dugCells`, every cell converted.

  BurrowParams* = object
    wallCost*: int      ## `WallCostRatio`.
    objectCost*: int    ## `ObjectCostRatio`. Also fixes the bucket count.
    brushRadius*: int   ## in CELLS. 0 = the reference 1-cell tunnel.
    anchors*: seq[BurrowPoint]
      ## Optional pinned anchor (plan §2.2's G-invariant hub). When empty the
      ## anchor is the largest component, exactly like the reference. When
      ## given, the anchor component is the one holding the most anchor cells
      ## (ties -> lowest label); any other component holding anchor cells is
      ## treated as an ordinary orphan and gets tunnelled to the anchor, so
      ## pinning several points can never fake connectivity between them.
    artifacts*: set[BurrowArtifact]

  BurrowStatus* = enum
    ## Change 5: a status the caller can branch on, never a crash.
    bsConnected          ## one component (already, or after digging). OK.
    bsEmpty              ## no passable cell in the domain at all.
    bsAnchorNotPassable  ## every pinned anchor is wall / outside the domain.
    bsUnreachable        ## an orphan had no finite-cost route to the anchor —
                         ## the domain itself is severed. Reject and reroll.
    bsStillDisconnected  ## the post-dig re-label found more than one
                         ## component. Reject and reroll.

  BurrowReport* = object
    status*: BurrowStatus
    componentsBefore*, componentsAfter*: int
    anchorCells*: int
    tunnels*: int
    wallCellsDug*: int
    objectsDestroyed*: seq[BurrowPoint]
      ## THE AUDIT (change 2). Always populated, never gated.
    totalCost*: int
      ## Sum of the tunnel path costs, in the cost model's own units. A useful
      ## scalar for the ranking loop: a map that needed an expensive burrow is
      ## a map whose layout stage did a poor job.
    paths*: seq[seq[BurrowPoint]]  ## retained by `baPaths`.
    dugCells*: seq[BurrowPoint]    ## retained by `baDugCells`.

func ok*(report: BurrowReport): bool {.inline.} =
  ## The single success test. Everything else is a reject-and-reroll.
  report.status == bsConnected

func isPassable*(cell: BurrowCell): bool {.inline.} =
  ## THE passable set (change 4). Content is floor with something standing on
  ## it, not an obstacle.
  cell == bcFloor or cell == bcContent

func `$`*(p: BurrowPoint): string = "(" & $p.x & "," & $p.y & ")"

func defaultBurrowParams*(brushRadius = 0): BurrowParams =
  BurrowParams(
    wallCost: WallCostRatio,
    objectCost: ObjectCostRatio,
    brushRadius: brushRadius,
    anchors: @[],
    artifacts: {},
  )

# ---------------------------------------------------------------------------
# Grid accessors
# ---------------------------------------------------------------------------

func initBurrowGrid*(w, h: int, cellSize = 1, fill = bcFloor): BurrowGrid =
  result = BurrowGrid(w: w, h: h, cellSize: max(1, cellSize),
    cells: newSeq[BurrowCell](max(0, w * h)), domain: @[])
  for i in 0 ..< result.cells.len:
    result.cells[i] = fill

func idx*(grid: BurrowGrid, x, y: int): int {.inline.} = y * grid.w + x

func onGrid*(grid: BurrowGrid, x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < grid.w and y < grid.h

func inDomain*(grid: BurrowGrid, i: int): bool {.inline.} =
  grid.domain.len == 0 or grid.domain[i]

func inDomain*(grid: BurrowGrid, x, y: int): bool {.inline.} =
  grid.onGrid(x, y) and grid.inDomain(grid.idx(x, y))

func `[]`*(grid: BurrowGrid, x, y: int): BurrowCell {.inline.} =
  grid.cells[grid.idx(x, y)]

proc `[]=`*(grid: var BurrowGrid, x, y: int, cell: BurrowCell) {.inline.} =
  grid.cells[grid.idx(x, y)] = cell

func isOpen*(grid: BurrowGrid, x, y: int): bool {.inline.} =
  ## Passable AND inside the fundamental domain: the predicate every traversal
  ## in this module uses.
  grid.onGrid(x, y) and grid.inDomain(grid.idx(x, y)) and
    grid.cells[grid.idx(x, y)].isPassable

func isOpen*(grid: BurrowGrid, i: int): bool {.inline.} =
  grid.inDomain(i) and grid.cells[i].isPassable

func cellRectPx*(grid: BurrowGrid, p: BurrowPoint):
    tuple[x, y, w, h: int] {.inline.} =
  ## The pixel box one cell covers — how a caller turns `dugCells` back into
  ## carve rectangles in the map's own continuous coordinates.
  (p.x * grid.cellSize, p.y * grid.cellSize, grid.cellSize, grid.cellSize)

func brushRadiusForCorridor*(minWidthPx, cellSize: int): int =
  ## Smallest brush radius (in cells) whose stamped disc yields a corridor at
  ## least `minWidthPx` wide. Stamping an L2 disc of radius r along a
  ## centerline unions to a band exactly `2r+1` cells across, in every
  ## direction, so the requirement is `(2r+1)*cellSize >= minWidthPx`.
  ##
  ## Sizing guidance: the player is 13 px solid (`PlayerHalf` = 6) and 34 px
  ## drawn, so `arena.MinPassableWidth` is 26 px and `arena.MinCorridorWidth`
  ## is 68 px (two drawn cog bodies abreast). Pass whichever the caller has
  ## decided on — this module does not pick for you.
  if minWidthPx <= 0 or cellSize <= 0: return 0
  let widthCells = (minWidthPx + cellSize - 1) div cellSize
  widthCells div 2

# ---------------------------------------------------------------------------
# Rasterization: continuous pixel space -> cell grid
# ---------------------------------------------------------------------------

proc burrowGridFromPixels*(
  pxW, pxH, cellSize: int,
  wall: seq[bool],
  objects: seq[bool] = @[],
  content: seq[bool] = @[],
  domainPx: seq[bool] = @[],
): BurrowGrid =
  ## Downsamples per-pixel masks (row-major, `pxW * pxH`, e.g. the `maxWall`
  ## output of `arena.rasterizeWallMasks`) into a burrow cell grid.
  ##
  ## The rules, all conservative in the safe direction (see "RESOLUTION"
  ## above):
  ##   passable  <- EVERY pixel in the cell is free of wall and object.
  ##               A cell straddling a wall edge counts as wall, so the burrow
  ##               never routes a tunnel through a gap the player cannot fit.
  ##   bcObject  <- not passable AND any pixel is object. Object beats wall so
  ##               the expensive cost protects the content.
  ##   bcContent <- passable AND any pixel carries content.
  ##   domain    <- EVERY pixel in the cell is inside `domainPx`. Strict, so a
  ##               wedge-masked run provably never writes a pixel outside the
  ##               wedge; the cost is a seam up to one cell wide at the wedge
  ##               boundary, which the symmetry lift covers from the other
  ##               side.
  ##
  ## `objects`, `content` and `domainPx` may be empty, meaning "none" /
  ## "everywhere".
  let
    cs = max(1, cellSize)
    w = (pxW + cs - 1) div cs
    h = (pxH + cs - 1) div cs
  result = BurrowGrid(w: w, h: h, cellSize: cs,
    cells: newSeq[BurrowCell](w * h), domain: @[])
  if domainPx.len > 0:
    result.domain = newSeq[bool](w * h)
  for cy in 0 ..< h:
    for cx in 0 ..< w:
      var
        blocked = false
        anyObject = false
        anyContent = false
        allInDomain = true
      let
        y0 = cy * cs
        y1 = min(pxH - 1, y0 + cs - 1)
        x0 = cx * cs
        x1 = min(pxW - 1, x0 + cs - 1)
      if y0 > y1 or x0 > x1:
        ## A cell entirely past the board edge: treat as wall, outside the
        ## domain. Cannot happen with the ceil-divided dimensions above, but
        ## the classification must be total.
        result.cells[cy * w + cx] = bcWall
        if result.domain.len > 0: result.domain[cy * w + cx] = false
        continue
      for py in y0 .. y1:
        let base = py * pxW
        for px in x0 .. x1:
          let i = base + px
          if wall[i]: blocked = true
          if objects.len > 0 and objects[i]:
            blocked = true
            anyObject = true
          if content.len > 0 and content[i]: anyContent = true
          if domainPx.len > 0 and not domainPx[i]: allInDomain = false
      let ci = cy * w + cx
      result.cells[ci] =
        if not blocked:
          if anyContent: bcContent else: bcFloor
        elif anyObject: bcObject
        else: bcWall
      if result.domain.len > 0:
        result.domain[ci] = allInDomain

# ---------------------------------------------------------------------------
# Component labelling
# ---------------------------------------------------------------------------

proc labelComponents*(grid: BurrowGrid):
    tuple[labels: seq[int32], count: int] =
  ## 4-connected components of the passable set, restricted to the domain.
  ## Label 0 means "not part of any component" (impassable, or outside the
  ## fundamental domain); real labels run 1..count.
  let
    w = grid.w
    h = grid.h
    n = w * h
  var
    labels = newSeq[int32](n)
    stack: seq[int32]
    count = 0
  for start in 0 ..< n:
    if labels[start] != 0 or not grid.isOpen(start):
      continue
    inc count
    let label = int32(count)
    labels[start] = label
    stack.setLen(0)
    stack.add int32(start)
    while stack.len > 0:
      let i = int(stack.pop())
      let
        x = i mod w
        y = i div w
      if x > 0:
        let j = i - 1
        if labels[j] == 0 and grid.isOpen(j):
          labels[j] = label
          stack.add int32(j)
      if x < w - 1:
        let j = i + 1
        if labels[j] == 0 and grid.isOpen(j):
          labels[j] = label
          stack.add int32(j)
      if y > 0:
        let j = i - w
        if labels[j] == 0 and grid.isOpen(j):
          labels[j] = label
          stack.add int32(j)
      if y < h - 1:
        let j = i + w
        if labels[j] == 0 and grid.isOpen(j):
          labels[j] = label
          stack.add int32(j)
  (labels, count)

# ---------------------------------------------------------------------------
# Step costs (brush-aware)
# ---------------------------------------------------------------------------

func unitCost(cell: BurrowCell, params: BurrowParams): int {.inline.} =
  case cell
  of bcFloor, bcContent: 1
  of bcWall: params.wallCost
  of bcObject: params.objectCost

proc discHalfWidths(r: int): seq[int] =
  ## `half[dy]` = the largest dx with dx*dx + dy*dy <= r*r, i.e. the L2 disc's
  ## half-width on row dy. Shared by the cost precompute and the stamp so the
  ## two can never disagree about the brush's shape. Integer-only: a float
  ## `sqrt` would put a platform-dependent rounding decision inside a module
  ## whose determinism is a tested guarantee.
  result = newSeq[int](max(0, r) + 1)
  for dy in 0 .. max(0, r):
    var dx = r
    while dx > 0 and dx * dx + dy * dy > r * r:
      dec dx
    result[dy] = dx

proc brushStepCosts(grid: BurrowGrid, params: BurrowParams): seq[int32] =
  ## `stepCost[i]` = ceil(mean unit cost over the brush disc centered on i),
  ## clamped to [1, objectCost] so Dial's bucket count stays valid.
  ##
  ## Computed with per-row prefix sums, so the whole array costs
  ## O(n * (2r+1)) rather than O(n * r^2) — the difference between free and
  ## noticeable on a giant board.
  let
    w = grid.w
    h = grid.h
    n = w * h
    r = params.brushRadius
  result = newSeq[int32](n)
  if r <= 0:
    ## Exactly the reference implementation's three cost levels.
    for i in 0 ..< n:
      result[i] = int32(unitCost(grid.cells[i], params))
    return
  var
    prefCost = newSeq[int32]((w + 1) * h)
    prefCount = newSeq[int32]((w + 1) * h)
  for y in 0 ..< h:
    let base = y * (w + 1)
    for x in 0 ..< w:
      let i = y * w + x
      var
        c = 0'i32
        k = 0'i32
      if grid.inDomain(i):
        c = int32(unitCost(grid.cells[i], params))
        k = 1
      prefCost[base + x + 1] = prefCost[base + x] + c
      prefCount[base + x + 1] = prefCount[base + x] + k
  let half = discHalfWidths(r)
  for y in 0 ..< h:
    for x in 0 ..< w:
      var
        sum = 0'i32
        cnt = 0'i32
      for dy in -r .. r:
        let yy = y + dy
        if yy < 0 or yy >= h: continue
        let
          hw = half[abs(dy)]
          x0 = max(0, x - hw)
          x1 = min(w - 1, x + hw)
        if x0 > x1: continue
        let base = yy * (w + 1)
        sum += prefCost[base + x1 + 1] - prefCost[base + x0]
        cnt += prefCount[base + x1 + 1] - prefCount[base + x0]
      let cost =
        if cnt <= 0: int32(params.objectCost)  ## brush wholly out of domain
        else: (sum + cnt - 1) div cnt          ## ceil of the mean
      result[y * w + x] = clamp(cost, 1'i32, int32(params.objectCost))

# ---------------------------------------------------------------------------
# Dial's algorithm
# ---------------------------------------------------------------------------

const
  PredUnvisited = -1'i32
  PredSource = -2'i32

proc weightedDistances(
  grid: BurrowGrid, params: BurrowParams,
  sources: seq[int32], stepCost: seq[int32],
): tuple[dist: seq[int32], pred: seq[int32]] =
  ## Multi-source Dial's algorithm: min cost from the anchor component to
  ## every cell, plus a predecessor pointer to walk back along.
  ##
  ## `objectCost + 1` circular FIFO buckets suffice because every edge weight
  ## lies in [1, objectCost], so the live frontier only ever spans that many
  ## distinct cost values. A push always lands in a bucket other than the one
  ## being drained (step >= 1) and never behind the cursor (step <= objectCost
  ## = buckets - 1), which is what makes the circular reuse safe.
  let
    w = grid.w
    h = grid.h
    n = w * h
    bucketCount = params.objectCost + 1
  var
    dist = newSeq[int32](n)
    pred = newSeq[int32](n)
  for i in 0 ..< n:
    dist[i] = int32.high
    pred[i] = PredUnvisited
  var
    buckets = newSeq[seq[int32]](bucketCount)
    heads = newSeq[int](bucketCount)
    queued = 0
  for s in sources:
    dist[s] = 0
    pred[s] = PredSource
    buckets[0].add s
    inc queued
  var
    cost = 0
    idleAdvances = 0
  while queued > 0:
    let b = cost mod bucketCount
    if heads[b] >= buckets[b].len:
      buckets[b].setLen(0)
      heads[b] = 0
      inc cost
      inc idleAdvances
      ## Defensive: by the invariant above some bucket within the next
      ## `bucketCount` costs must be live, so this can only trip on a bug.
      if idleAdvances > bucketCount: break
      continue
    idleAdvances = 0
    let i = int(buckets[b][heads[b]])
    inc heads[b]
    dec queued
    if dist[i] < int32(cost):
      continue  ## a stale entry superseded by a cheaper push
    let
      x = i mod w
      y = i div w
    for k in 0 .. 3:
      var
        nx = x
        ny = y
      case k
      of 0: dec ny
      of 1: inc nx
      of 2: inc ny
      else: dec nx
      if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
      let j = ny * w + nx
      if not grid.inDomain(j): continue
      let nc = int32(cost) + stepCost[j]
      if nc < dist[j]:
        dist[j] = nc
        pred[j] = int32(i)
        buckets[int(nc) mod bucketCount].add int32(j)
        inc queued
  (dist, pred)

# ---------------------------------------------------------------------------
# Digging
# ---------------------------------------------------------------------------

proc stampBrush(
  grid: var BurrowGrid, cx, cy: int, half: seq[int],
  report: var BurrowReport, artifacts: set[BurrowArtifact],
) =
  ## Clears the L2 disc of radius `half.len - 1` centered on one path cell.
  ## Clipped to the board AND to the fundamental domain, so a wedge-masked run
  ## never writes outside its wedge. `bcContent` is left alone: it is already
  ## passable and destroying it would be gratuitous.
  let r = half.len - 1
  for dy in -r .. r:
    let y = cy + dy
    if y < 0 or y >= grid.h: continue
    let
      hw = half[abs(dy)]
      x0 = max(0, cx - hw)
      x1 = min(grid.w - 1, cx + hw)
    for x in x0 .. x1:
      let i = y * grid.w + x
      if not grid.inDomain(i): continue
      case grid.cells[i]
      of bcWall:
        grid.cells[i] = bcFloor
        inc report.wallCellsDug
        if baDugCells in artifacts:
          report.dugCells.add BurrowPoint(x: x, y: y)
      of bcObject:
        grid.cells[i] = bcFloor
        report.objectsDestroyed.add BurrowPoint(x: x, y: y)
        if baDugCells in artifacts:
          report.dugCells.add BurrowPoint(x: x, y: y)
      of bcFloor, bcContent:
        discard

proc digPath(
  grid: var BurrowGrid, startIdx: int, pred: seq[int32], half: seq[int],
  params: BurrowParams, report: var BurrowReport,
): bool =
  ## Walks predecessors from an orphan component's cheapest cell back to the
  ## anchor, stamping the brush at every step. Returns false only if the chain
  ## is malformed (which would be a bug, not a map defect).
  ##
  ## The terminal SOURCE cell is stamped too. A half-width tunnel mouth is
  ## exactly where a player gets stuck, and the mouth is created by this pass,
  ## so this pass owns making it brush-wide.
  let w = grid.w
  var
    i = startIdx
    path: seq[BurrowPoint]
    guard = 0
  while true:
    inc guard
    if guard > grid.cells.len:
      return false
    let
      x = i mod w
      y = i div w
    grid.stampBrush(x, y, half, report, params.artifacts)
    if baPaths in params.artifacts:
      path.add BurrowPoint(x: x, y: y)
    let p = pred[i]
    if p == PredSource:
      break
    if p == PredUnvisited:
      return false
    i = int(p)
  if baPaths in params.artifacts:
    report.paths.add path
  true

# ---------------------------------------------------------------------------
# The pass
# ---------------------------------------------------------------------------

proc burrow*(grid: var BurrowGrid,
    params = defaultBurrowParams()): BurrowReport =
  ## Digs the cheapest tunnels that make `grid`'s open space, restricted to
  ## `grid.domain`, exactly one connected component. Mutates `grid` in place;
  ## the report carries the audit and the status.
  ##
  ## Deterministic: no RNG, and every tie is broken by scan order.
  doAssert params.wallCost >= 1, "wallCost must be >= 1"
  doAssert params.objectCost >= params.wallCost,
    "objectCost must be >= wallCost — the ratio IS the tuning surface"
  doAssert params.brushRadius >= 0, "brushRadius must be >= 0"

  let (labels, count) = labelComponents(grid)
  result.componentsBefore = count
  result.componentsAfter = count
  if count == 0:
    result.status = bsEmpty
    return
  if count == 1:
    result.status = bsConnected
    for i in 0 ..< labels.len:
      if labels[i] == 1: inc result.anchorCells
    return

  ## Anchor selection. No pins -> the largest component, exactly like the
  ## reference. Pins -> the component holding the most pinned cells; any other
  ## component that also holds pins stays an orphan and gets tunnelled, so
  ## pinning can never fake connectivity.
  var
    sizes = newSeq[int](count + 1)
    votes = newSeq[int](count + 1)
  for i in 0 ..< labels.len:
    if labels[i] != 0: inc sizes[labels[i]]
  var anchorLabel = 0
  if params.anchors.len > 0:
    for a in params.anchors:
      if not grid.isOpen(a.x, a.y): continue
      inc votes[labels[grid.idx(a.x, a.y)]]
    for label in 1 .. count:
      if votes[label] > 0 and
          (anchorLabel == 0 or votes[label] > votes[anchorLabel]):
        anchorLabel = label
    if anchorLabel == 0:
      result.status = bsAnchorNotPassable
      return
  else:
    for label in 1 .. count:
      if anchorLabel == 0 or sizes[label] > sizes[anchorLabel]:
        anchorLabel = label
  result.anchorCells = sizes[anchorLabel]

  var sources: seq[int32]
  for i in 0 ..< labels.len:
    if labels[i] == int32(anchorLabel): sources.add int32(i)

  let
    stepCost = brushStepCosts(grid, params)
    (dist, pred) = weightedDistances(grid, params, sources, stepCost)
    half = discHalfWidths(params.brushRadius)

  ## One tunnel per orphan component, from the component's globally cheapest
  ## cell — which is precisely the cell with the thinnest barrier between it
  ## and the anchor. Distances are NOT recomputed after each dig (the
  ## reference does not either): every predecessor chain terminates in the
  ## anchor component, so each tunnel independently attaches its component,
  ## and later tunnels reusing earlier ones is a bonus rather than a hazard.
  for label in 1 .. count:
    if label == anchorLabel: continue
    var
      bestIdx = -1
      bestDist = int32.high
    for i in 0 ..< labels.len:
      if labels[i] != int32(label): continue
      if dist[i] < bestDist:
        bestDist = dist[i]
        bestIdx = i
    if bestIdx < 0 or bestDist == int32.high:
      ## The domain itself is severed — no route at any price. Reject and
      ## reroll rather than crashing mid-generation.
      result.status = bsUnreachable
      return
    result.totalCost += int(bestDist)
    inc result.tunnels
    if not grid.digPath(bestIdx, pred, half, params, result):
      result.status = bsUnreachable
      return

  let (_, finalCount) = labelComponents(grid)
  result.componentsAfter = finalCount
  result.status = if finalCount == 1: bsConnected else: bsStillDisconnected

proc summary*(report: BurrowReport): string =
  ## One line for the generator log. The destroyed-object list is spelled out
  ## rather than counted: silently bulldozing placed content is the defect
  ## this port exists to fix, so it gets to be loud.
  var parts: seq[string]
  parts.add(if report.ok: "burrow ok" else: "burrow FAILED " & $report.status)
  parts.add($report.componentsBefore & " components -> " &
    $report.componentsAfter)
  parts.add($report.tunnels & " tunnels")
  parts.add($report.wallCellsDug & " wall cells dug")
  parts.add("cost " & $report.totalCost)
  result = parts.join(", ")
  if report.objectsDestroyed.len > 0:
    var at: seq[string]
    for p in report.objectsDestroyed:
      at.add $p
    result.add "; DESTROYED " & $report.objectsDestroyed.len & " objects at " &
      at.join(" ")

# ---------------------------------------------------------------------------
# EnsureHubReachableJunction
# ---------------------------------------------------------------------------

type
  JunctionStatus* = enum
    ## The reference pass silently no-ops when it cannot serve a hub, which is
    ## a real quality hole: the map ships with an objective the hub cannot
    ## contest and nothing says so. Ours signals.
    jsSatisfied      ## every hub has a reachable junction in the band.
    jsNoHubs         ## caller passed no hubs — a caller bug, not a map defect.
    jsNoSite         ## at least one hub had no candidate cell in the band.

  JunctionParams* = object
    minDistance*: int
      ## In CELLS. Prevents gluing the junction to the hub wall and
      ## trivializing the objective — the reference's `min_distance = 4`.
    maxDistance*: int
      ## In CELLS. The reference's `max_distance = 15`.

  JunctionReport* = object
    status*: JunctionStatus
    placed*: seq[BurrowPoint]      ## junctions this pass created.
    satisfied*: seq[BurrowPoint]   ## hubs that already had one.
    unserved*: seq[BurrowPoint]    ## hubs with no site in the band.

func ok*(report: JunctionReport): bool {.inline.} =
  report.status == jsSatisfied

func defaultJunctionParams*(): JunctionParams =
  ## The reference's 4..15 tiles. On our recommended 8 px grid that is a
  ## 32..120 px band; scale it with `junctionParamsPx` if the caller thinks in
  ## pixels, which on a continuous-space map it probably should.
  JunctionParams(minDistance: 4, maxDistance: 15)

func junctionParamsPx*(cellSize, minPx, maxPx: int): JunctionParams =
  ## The distance band expressed in pixels, converted to the grid's cells.
  ## The minimum rounds UP and the maximum rounds DOWN, so the band a caller
  ## asks for is never exceeded in either direction.
  let cs = max(1, cellSize)
  JunctionParams(
    minDistance: (max(0, minPx) + cs - 1) div cs,
    maxDistance: max(0, maxPx) div cs,
  )

proc reachableFrom*(grid: BurrowGrid, start: BurrowPoint): seq[bool] =
  ## 4-connected flood over the passable set, restricted to the domain.
  ## Empty-equivalent (all false) when the start itself is not passable.
  result = newSeq[bool](grid.w * grid.h)
  if not grid.isOpen(start.x, start.y):
    return
  let
    w = grid.w
    h = grid.h
  var queue = @[grid.idx(start.x, start.y)]
  result[queue[0]] = true
  var head = 0
  while head < queue.len:
    let i = queue[head]
    inc head
    let
      x = i mod w
      y = i div w
    if x > 0 and not result[i - 1] and grid.isOpen(i - 1):
      result[i - 1] = true
      queue.add i - 1
    if x < w - 1 and not result[i + 1] and grid.isOpen(i + 1):
      result[i + 1] = true
      queue.add i + 1
    if y > 0 and not result[i - w] and grid.isOpen(i - w):
      result[i - w] = true
      queue.add i - w
    if y < h - 1 and not result[i + w] and grid.isOpen(i + w):
      result[i + w] = true
      queue.add i + w

proc ensureHubJunctions*(
  grid: var BurrowGrid,
  hubs: seq[BurrowPoint],
  junctions: seq[BurrowPoint] = @[],
  params = defaultJunctionParams(),
): JunctionReport =
  ## Guarantees every hub has at least one REACHABLE junction inside the
  ## distance band, placing one (as `bcContent`, i.e. passable floor carrying
  ## content) at the nearest legal site when it does not.
  ##
  ## Divergences from the reference, both deliberate:
  ##   - It signals. `jsNoSite` plus the offending hubs in `unserved`, instead
  ##     of returning quietly and shipping a map with an uncontestable
  ##     objective.
  ##   - Ties are broken deterministically by (distance, y, x) rather than by
  ##     an RNG draw. This module has no RNG at all — that is the property the
  ##     determinism test pins — and a caller who wants jitter can shift the
  ##     band or perturb its hub list.
  ##
  ## Junctions placed for an earlier hub are visible to later hubs, exactly
  ## like the reference.
  if hubs.len == 0:
    result.status = jsNoHubs
    return
  var known = junctions
  let
    minR2 = params.minDistance * params.minDistance
    maxR2 = params.maxDistance * params.maxDistance
  result.status = jsSatisfied
  for hub in hubs:
    let reachable = grid.reachableFrom(hub)
    var served = false
    for j in known:
      if not grid.onGrid(j.x, j.y): continue
      let
        dx = j.x - hub.x
        dy = j.y - hub.y
      if dx * dx + dy * dy <= maxR2 and reachable[grid.idx(j.x, j.y)]:
        served = true
        break
    if served:
      result.satisfied.add hub
      continue

    var
      bestIdx = -1
      bestD2 = 0
    let
      y0 = max(0, hub.y - params.maxDistance)
      y1 = min(grid.h - 1, hub.y + params.maxDistance)
      x0 = max(0, hub.x - params.maxDistance)
      x1 = min(grid.w - 1, hub.x + params.maxDistance)
    for y in y0 .. y1:
      for x in x0 .. x1:
        let i = grid.idx(x, y)
        ## Plain floor only: never convert existing content, never sit on a
        ## wall, never leave the fundamental domain.
        if grid.cells[i] != bcFloor: continue
        if not grid.inDomain(i): continue
        if not reachable[i]: continue
        let
          dx = x - hub.x
          dy = y - hub.y
          d2 = dx * dx + dy * dy
        if d2 < minR2 or d2 > maxR2: continue
        ## Scan order is row-major, so a strict `<` breaks ties by lowest
        ## (y, x) — deterministic, no RNG.
        if bestIdx < 0 or d2 < bestD2:
          bestD2 = d2
          bestIdx = i
    if bestIdx < 0:
      result.unserved.add hub
      result.status = jsNoSite
      continue
    let placed = BurrowPoint(x: bestIdx mod grid.w, y: bestIdx div grid.w)
    grid.cells[bestIdx] = bcContent
    known.add placed
    result.placed.add placed

proc summary*(report: JunctionReport): string =
  var parts: seq[string]
  parts.add(if report.ok: "junctions ok" else: "junctions FAILED " &
    $report.status)
  parts.add($report.satisfied.len & " already served")
  parts.add($report.placed.len & " placed")
  result = parts.join(", ")
  if report.unserved.len > 0:
    var at: seq[string]
    for p in report.unserved:
      at.add $p
    result.add "; UNSERVED hubs at " & at.join(" ")

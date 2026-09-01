## probekit — the measurement library behind tools/mapgen_defect_probe.nim.
##
## REBUILT 2026-08-31 against current arena.nim/sim.nim internals (the
## original lived on maxwell/mapgen-audit and read generator internals that
## no longer exist; see the DROPPED CHECKS block below). The design rules are
## inherited unchanged from the dead branch's map_eval lineage:
##
##  1. CONTROL-ANCHORED, NO STORED NUMBERS. The hand-authored `arena` /
##     `arena-large` (CTF class) and the shipping baked BR map (BR class) are
##     prepended to every batch as the CONTROL and measured under the
##     identical protocol. The report never stores a pass bar from a past
##     engine build: every judgment is "vs the control, measured now", so
##     engine drift re-baselines automatically. The only absolute constants
##     are STRUCTURAL, derived from live engine constants (MinPassableWidth,
##     the map's own gunRange).
##  2. No count without its denominator on the same line.
##  3. Distributions, not anecdotes.
##
## PURITY: nothing here installs a map or touches process globals. Every
## measurement is a pure function of a `CtfMap`.
##
## WHICH MASK (the two masks point in opposite directions):
##   * `maxWall` (swept union) for STRUCTURE.
##   * `minWall` (always-stone) to reproduce what the shipping validator sees.
##   * `vision` = minWall minus GLASS — what fog actually occludes. Glass sits
##     on the wall side of minWall, so the validator counts a pane as a vision
##     blocker when it is not one; `scanRows` measures exactly that gap.
##
## DROPPED CHECKS (old probe measurements whose substrate is gone on main —
## noted here rather than faked):
##   * PLUG PROVENANCE / plugSplit / blind-pane attribution: the old probe
##     recovered the generator's three construction phases from the bracket
##     feature's fixed x-anchor (`center.x - 138`) and the r28 sightline-repair
##     diamonds. Neither anchor exists in the current generator; obstacle
##     order no longer encodes the phase boundary. Everything downstream of it
##     (blindByPlug/Column/Feature, plugWallPx share, soleBlockerPlugs) is
##     dropped. The phase-free `soleBlocker` count survives.
##   * `plasmaArcSpawnPoints` (classic spray points): the proc is gone from
##     sim.nim. Spray checks now run only on maps that author `spraySpawns`
##     (the BR neutral pool).
##   * `mapSizeClassName`: gone; size class is re-derived from width, the same
##     way tools/gen_map_pool.nim does.
##   * map_metrics.nim itself: merged into arena.nim; `import ctf/sim` covers
##     everything.

import
  std/[algorithm, deques, math, strformat, strutils, tables],
  ../src/ctf/sim

const
  MinPassableWidth* = 26
    ## arena.nim:1609's own (unexported) constant: PHYSICS, the narrowest
    ## floor the 13px solid footprint can occupy. Mirrored here because
    ## arena.nim does not export it; test_defect_probe pins the two in sync
    ## by parsing the value out of the generator's own source text.
    ##
    ## RENAMED 2026-09-01 (54cb0c1a): this used to be arena.nim's
    ## `MinCorridorWidth`, which did double duty as a DESIGN-level corridor
    ## target too. arena.nim split that into this physics floor
    ## (`MinPassableWidth`, unchanged value 26) and a new, larger, differently
    ## MEANT `MinCorridorWidth` (68px, two drawn cog bodies abreast) — a
    ## different question this tool does not measure. Every use site below is
    ## about "can a body stand/pass here", i.e. the physics floor, so this
    ## mirror follows `MinPassableWidth`, not the new `MinCorridorWidth`.
  MarchStep* = 2
    ## px per sightline march step; finer than the thinnest wall feature.
  UsefulDepthPx* = 200
    ## The bar a window's free depth must clear on BOTH sides to be worth
    ## building. Structural, not a stored pass number: ~1.9 s of approach at
    ## 2.75 px/tick, and below every hand-authored control pane (the CONTROL
    ## block in the report re-verifies that on every run).
  DecorativeDepthPx* = 100
    ## Below this a pane looks into a pocket, not a lane.
  StandDepthPx* = MinPassableWidth
    ## Below the player footprint nobody can stand on that side: pane inert.

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc medianOf*(values: seq[int]): int =
  if values.len == 0: return 0
  var v = values
  v.sort()
  v[v.len div 2]

proc percentile*(values: seq[float], q: float): float =
  if values.len == 0: return 0.0
  var v = values
  v.sort()
  v[clamp(int(q * float(v.len - 1) + 0.5), 0, v.len - 1)]

proc meanOf*(values: seq[float]): float =
  if values.len == 0: return 0.0
  for x in values: result += x
  result /= float(values.len)

proc pct*(part, whole: int): string =
  if whole == 0: "n/a" else: &"{100.0 * float(part) / float(whole):.1f}%"

proc sizeClassOf*(width: int): string =
  ## Re-derived from the generator's drawable widths (mapSizeClassName is
  ## gone from main); anything else is labeled by its width.
  case width
  of 1050: "small"
  of 1235: "standard"
  of 1606: "large"
  of 2223: "huge"
  of 3211: "giant"
  else: "w" & $width

type Bounds* = tuple[x0, y0, x1, y1: int]

proc bboxOf*(shape: ArenaShape): Bounds =
  ## Inclusive integer bounding box of one obstacle (arena.nim's own bounds
  ## helper is unexported; this tool must not touch that file).
  case shape.kind
  of shapeRect:
    (shape.rect.x, shape.rect.y,
      shape.rect.x + shape.rect.w - 1, shape.rect.y + shape.rect.h - 1)
  of shapeDisc, shapeDiamond:
    (shape.cx - shape.radius, shape.cy - shape.radius,
      shape.cx + shape.radius, shape.cy + shape.radius)
  of shapeDiagonal:
    let t = shape.thickness
    (min(shape.x0, shape.x1) - t, min(shape.y0, shape.y1) - t,
      max(shape.x0, shape.x1) + t, max(shape.y0, shape.y1) + t)
  of shapePolygon:
    var b: Bounds = (int.high, int.high, int.low, int.low)
    for p in shape.points:
      b.x0 = min(b.x0, p.x); b.y0 = min(b.y0, p.y)
      b.x1 = max(b.x1, p.x); b.y1 = max(b.y1, p.y)
    b

# ---------------------------------------------------------------------------
# One map's rasterized context
# ---------------------------------------------------------------------------

type
  MapCtx* = object
    gameMap*: CtfMap
    obstacles*: seq[ArenaShape]
    maxWall*: seq[bool]         ## swept union — structure
    minWall*: seq[bool]         ## always-stone — the validator's own mask
    glass*: seq[bool]           ## wall pixels belonging to a window shape
    vision*: seq[bool]          ## minWall AND NOT glass — what fog occludes
    corridorOpen*: seq[bool]    ## player-width erosion (empty on BR maps —
                                ## see buildCtx; use isOpenFloor + clearanceBox)
    reachable*: seq[bool]       ## floor reachable from the anchor stand
    w*, h*: int
    gunRangePx*: int            ## the MAP's own engagement range

proc losClear*(mask: seq[bool], w, h, ax, ay, bx, by: int): bool =
  ## Bresenham over an occlusion mask (the old map_metrics.losClear is gone
  ## from main; sim.lineOfSightClear needs a live SimServer).
  var
    x = ax
    y = ay
  let
    dx = abs(bx - ax)
    dy = -abs(by - ay)
    sx = if ax < bx: 1 else: -1
    sy = if ay < by: 1 else: -1
  var err = dx + dy
  while true:
    if x < 0 or y < 0 or x >= w or y >= h: return false
    if mask[y * w + x]: return false
    if x == bx and y == by: return true
    let e2 = 2 * err
    if e2 >= dy:
      err += dy
      x += sx
    if e2 <= dx:
      err += dx
      y += sy

proc floodFrom(open: seq[bool], w, h: int, seeds: seq[MapPoint]): seq[bool] =
  ## Plain 4-connected flood over open floor. Used as the reachability mask
  ## on flagless maps, where the CTF diagnostics' Red-stand flood has no
  ## meaningful anchor.
  result = newSeq[bool](w * h)
  var q = initDeque[int]()
  for s in seeds:
    if s.x >= 0 and s.y >= 0 and s.x < w and s.y < h:
      let i = s.y * w + s.x
      if open[i] and not result[i]:
        result[i] = true
        q.addLast(i)
  while q.len > 0:
    let i = q.popFirst()
    let x = i mod w
    let y = i div w
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
      if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
      let j = ny * w + nx
      if open[j] and not result[j]:
        result[j] = true
        q.addLast(j)

proc walkDistances*(open: seq[bool], w, h: int, from0: MapPoint): seq[int] =
  ## BFS walk distance (in px-cells, 4-connected) from one point to every
  ## open cell; -1 = unreachable. brmapkit's own item-fairness gate uses
  ## walk distance for the same reason: Euclidean lies across walls.
  result = newSeq[int](w * h)
  for i in 0 ..< result.len: result[i] = -1
  if from0.x < 0 or from0.y < 0 or from0.x >= w or from0.y >= h: return
  var start = from0.y * w + from0.x
  if not open[start]:
    ## Items nudge to floor at spawn; mirror that by starting from the
    ## nearest open cell within a small ring.
    var found = false
    for r in 1 .. 40:
      if found: break
      for dy in -r .. r:
        for dx in -r .. r:
          if max(abs(dx), abs(dy)) != r: continue
          let (px, py) = (from0.x + dx, from0.y + dy)
          if px >= 0 and py >= 0 and px < w and py < h and open[py * w + px]:
            start = py * w + px
            found = true
            break
        if found: break
    if not found: return
  var q = initDeque[int]()
  result[start] = 0
  q.addLast(start)
  while q.len > 0:
    let i = q.popFirst()
    let x = i mod w
    let y = i div w
    for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]:
      if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
      let j = ny * w + nx
      if open[j] and result[j] < 0:
        result[j] = result[i] + 1
        q.addLast(j)

proc buildCtx*(gameMap: CtfMap): MapCtx =
  result.gameMap = gameMap
  result.w = gameMap.width
  result.h = gameMap.height
  result.gunRangePx =
    if gameMap.gunRange > 0: gameMap.gunRange else: GunRange
  result.obstacles = buildArenaObstacles(gameMap)
  let (mx, mn) = rasterizeWallMasks(gameMap, result.obstacles)
  result.maxWall = mx
  result.minWall = mn
  result.glass = newSeq[bool](result.w * result.h)
  for shape in result.obstacles:
    if not shape.window: continue
    let b = bboxOf(shape)
    for y in max(b.y0, 0) .. min(b.y1, result.h - 1):
      for x in max(b.x0, 0) .. min(b.x1, result.w - 1):
        let i = y * result.w + x
        ## Only pixels that survived the protected-floor carve are glass; a
        ## pane stamped over a protected ring renders nothing.
        if result.maxWall[i] and inShape(x, y, shape):
          result.glass[i] = true
  result.vision = newSeq[bool](result.w * result.h)
  for i in 0 ..< result.w * result.h:
    result.vision[i] = result.minWall[i] and not result.glass[i]
  if gameMap.flagless:
    ## CTF diagnostics anchor their erosion flood on Red's stand; a flagless
    ## map has none. corridorOpen stays EMPTY (callers fall back to
    ## isOpenFloor + clearanceBoxOpen) and reachability floods plainly from
    ## the authored spawn points.
    var open = newSeq[bool](result.w * result.h)
    for i in 0 ..< open.len: open[i] = not result.maxWall[i]
    result.reachable = floodFrom(open, result.w, result.h, gameMap.spawnPoints)
  else:
    let diag = mapDiagnostics(
      gameMap, {diagnosticCorridorOpen, diagnosticReachable})
    result.corridorOpen = diag.corridorOpen
    result.reachable = diag.reachable

proc inBounds*(c: MapCtx, x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < c.w and y < c.h

proc isOpenFloor*(c: MapCtx, x, y: int): bool {.inline.} =
  c.inBounds(x, y) and not c.maxWall[y * c.w + x]

proc isReachable*(c: MapCtx, x, y: int): bool {.inline.} =
  c.inBounds(x, y) and c.reachable.len > 0 and c.reachable[y * c.w + x]

proc clearanceBoxOpen*(c: MapCtx, x, y, half: int): bool =
  ## Is a (2*half+1)^2 box of open floor centered here? The flagless stand-in
  ## for the CTF diagnostics' corridor erosion at a single point.
  for yy in y - half .. y + half:
    for xx in x - half .. x + half:
      if not c.isOpenFloor(xx, yy): return false
  true

proc nearestOpenDist*(c: MapCtx, x, y: int, cap = 400): int =
  ## Chebyshev ring search for the nearest player-usable floor pixel — the
  ## pure twin of the sim's nearestWalkable nudge. Player-usable means
  ## corridorOpen where that mask exists (CTF), plain open floor otherwise.
  template usable(px, py: int): bool =
    (if c.corridorOpen.len > 0:
      c.inBounds(px, py) and c.corridorOpen[py * c.w + px]
    else:
      c.isOpenFloor(px, py))
  if usable(x, y): return 0
  for r in 1 .. cap:
    for dx in -r .. r:
      for dy in [-r, r]:
        if usable(x + dx, y + dy): return r
    for dy in -r + 1 .. r - 1:
      for dx in [-r, r]:
        if usable(x + dx, y + dy): return r
  cap

# ---------------------------------------------------------------------------
# WINDOWS
# ---------------------------------------------------------------------------

type
  WindowClass* = enum
    winDead      ## zero glass pixels survive: the pane does not exist
    winInert     ## a side has < MinPassableWidth free: nobody can stand
    winDecor     ## a side has < 100px free: looks into a pocket
    winShallow   ## a side has < 200px free
    winUseful    ## >= 200px free on BOTH sides

  WindowRow* = object
    mapName*: string
    seed*, teams*: int
    size*, sym*: string
    idx*: int
    kind*: string
    glassPx*: int
    axis*: string               ## "x" | "y" — the pane's through-direction
    depthA*, depthB*: int       ## median free vision depth each side, px
    minSide*, through*: int
    reachA*, reachB*: bool
    borderFlush*: bool
    facesGlass*: bool
    cls*: WindowClass
    cx*, cy*: int

proc classifyWindow*(glassPx, minSide: int): WindowClass =
  ## Pure classifier; boundaries are structural (see consts above).
  if glassPx == 0: winDead
  elif minSide < StandDepthPx: winInert
  elif minSide < DecorativeDepthPx: winDecor
  elif minSide < UsefulDepthPx: winShallow
  else: winUseful

proc marchDepth*(
  c: MapCtx, mask: seq[bool], sx, sy, dx, dy: int, shape: ArenaShape
): int =
  ## Free depth in px from the pane's outer FACE outward along (dx, dy),
  ## capped at the map's own gunRange: past it, seeing is not shooting.
  var (x, y) = (sx, sy)
  var guard = 0
  while c.inBounds(x, y) and inShape(x, y, shape) and guard < 400:
    x += dx; y += dy; inc guard
  var d = 0
  while d < c.gunRangePx:
    if not c.inBounds(x, y): break
    if mask[y * c.w + x]: break
    x += dx * MarchStep; y += dy * MarchStep; d += MarchStep
  d

proc firstHitIsGlass(c: MapCtx, sx, sy, dx, dy: int, shape: ArenaShape): bool =
  ## Marching with glass OPAQUE (minWall), is the first thing this pane looks
  ## at another pane?
  var (x, y) = (sx, sy)
  var guard = 0
  while c.inBounds(x, y) and inShape(x, y, shape) and guard < 400:
    x += dx; y += dy; inc guard
  var d = 0
  while d < c.gunRangePx:
    if not c.inBounds(x, y): return false
    let i = y * c.w + x
    if c.minWall[i]: return c.glass[i]
    x += dx * MarchStep; y += dy * MarchStep; d += MarchStep
  false

proc axisSamples(b: Bounds, alongY: bool): seq[tuple[x, y: int]] =
  ## Up to 9 evenly spaced samples on the pane's centre line, skipping the
  ## outer 10% so a corner pixel never speaks for the pane.
  let
    lo = if alongY: b.y0 else: b.x0
    hi = if alongY: b.y1 else: b.x1
    mid = if alongY: (b.x0 + b.x1) div 2 else: (b.y0 + b.y1) div 2
    span = hi - lo
    inset = max(0, span div 10)
    a = lo + inset
    z = hi - inset
    n = clamp(span div 6 + 1, 1, 9)
  for k in 0 ..< n:
    let t = if n == 1: (a + z) div 2 else: a + (z - a) * k div (n - 1)
    result.add(if alongY: (mid, t) else: (t, mid))

proc measureWindow*(
  c: MapCtx, shape: ArenaShape, idx: int
): tuple[axis: string, depthA, depthB, glassPx: int,
         reachA, reachB, facesGlass: bool] =
  let b = bboxOf(shape)
  var glassPx = 0
  for y in max(b.y0, 0) .. min(b.y1, c.h - 1):
    for x in max(b.x0, 0) .. min(b.x1, c.w - 1):
      if c.glass[y * c.w + x]: inc glassPx

  proc measureAxis(alongY: bool): tuple[a, b2: int, fg: bool] =
    let
      samples = axisSamples(b, alongY)
      (dx, dy) = if alongY: (1, 0) else: (0, 1)
    var ds1, ds2: seq[int]
    for s in samples:
      ds1.add c.marchDepth(c.vision, s.x, s.y, dx, dy, shape)
      ds2.add c.marchDepth(c.vision, s.x, s.y, -dx, -dy, shape)
    let mid = samples[samples.len div 2]
    let fg = c.firstHitIsGlass(mid.x, mid.y, dx, dy, shape) or
      c.firstHitIsGlass(mid.x, mid.y, -dx, -dy, shape)
    (medianOf(ds1), medianOf(ds2), fg)

  let
    bw = b.x1 - b.x0
    bh = b.y1 - b.y0
  var axis: string
  var m: tuple[a, b2: int, fg: bool]
  if bw < bh:
    axis = "x"; m = measureAxis(true)
  elif bh < bw:
    axis = "y"; m = measureAxis(false)
  else:
    ## Square silhouette (diamond/disc pane): no built-in normal; take the
    ## axis that serves it best — judging an isotropic shape on its worse
    ## axis scores it broken by construction.
    let mx = measureAxis(true)
    let my = measureAxis(false)
    if min(mx.a, mx.b2) >= min(my.a, my.b2):
      axis = "x"; m = mx
    else:
      axis = "y"; m = my

  let (dx, dy) = if axis == "x": (1, 0) else: (0, 1)
  let
    cx = (b.x0 + b.x1) div 2
    cy = (b.y0 + b.y1) div 2
    outA = clamp(m.a - 4, 2, 20)
    outB = clamp(m.b2 - 4, 2, 20)
    halfSpan = (if axis == "x": bw else: bh) div 2 + 2
  (axis, m.a, m.b2, glassPx,
    c.isReachable(cx + dx * (halfSpan + outA), cy + dy * (halfSpan + outA)),
    c.isReachable(cx - dx * (halfSpan + outB), cy - dy * (halfSpan + outB)),
    m.fg)

proc windowRows*(c: MapCtx, label: string, seed: int): seq[WindowRow] =
  let gameMap = c.gameMap
  for i, shape in c.obstacles:
    if not shape.window: continue
    let b = bboxOf(shape)
    var row = WindowRow(
      mapName: label, seed: seed, teams: gameMap.teamCount(),
      size: sizeClassOf(gameMap.width), sym: $gameMap.symmetry,
      idx: i, kind: $shape.kind,
      cx: (b.x0 + b.x1) div 2, cy: (b.y0 + b.y1) div 2)
    let m = c.measureWindow(shape, i)
    row.axis = m.axis
    row.depthA = m.depthA
    row.depthB = m.depthB
    row.glassPx = m.glassPx
    row.reachA = m.reachA
    row.reachB = m.reachB
    row.facesGlass = m.facesGlass
    row.minSide = min(m.depthA, m.depthB)
    row.through = m.depthA + m.depthB
    row.borderFlush =
      min(min(b.x0 - ArenaBorder, b.y0 - ArenaBorder),
        min(gameMap.width - ArenaBorder - b.x1,
          gameMap.height - ArenaBorder - b.y1)) < 24
    row.cls = classifyWindow(row.glassPx, row.minSide)
    result.add row

# ---------------------------------------------------------------------------
# Per-map measurement
# ---------------------------------------------------------------------------

type
  SpawnPointRow* = object
    idx*: int                  ## spawn-point index (== spawn group for 1/team)
    x*, y*: int
    inObstacleShape*: bool     ## the AUTHORED point sits inside a solid
                               ## obstacle's geometry. The rasterizer then
                               ## CARVES a spawn pocket straight through that
                               ## obstacle (measured 2026-08-31: the wall is
                               ## gone from maxWall), so the map "works" — but
                               ## the generator placed a spawn in stone and a
                               ## silent repair pass hid it, destroying
                               ## whatever cover that obstacle was for. The
                               ## same shape of defect the old probe's
                               ## sightline-repair-plug hunt existed to count.
    onOpenFloor*: bool
    hasClearance*: bool        ## MinPassableWidth box of open floor around it
    reachable*: bool           ## in the map's main flooded component
    nudgePx*: int              ## distance the sim must nudge to usable floor
    nnDistPx*: int             ## Euclidean distance to nearest other point
    centerDistPx*: int         ## Euclidean distance to MAP center (the static
                               ## half of the ring-bias question; the played
                               ## half needs zoneCenter, drawn per episode)
    shieldWalk*, sprayWalk*, grenadeWalk*, medKitWalk*: int
                               ## BFS walk distance to the nearest instance of
                               ## each item pool; -1 = none reachable

  MapRow* = object
    name*: string
    seed*, teams*: int
    size*, sym*, endz*, layout*: string
    w*, h*: int
    valid*: bool
    validReason*: string
    flagless*: bool
    spawnGroups*: int

    windows*, winDeadN*, winInertN*, winDecorN*, winShallowN*, winUsefulN*: int
    winMinSideMedian*: int

    ## sightline rows: the validator's 4px scan across [sightlineLoX..HiX]
    scanRows*, validatorOpenRows*, visionOpenRows*, glassOnlyRows*: int
    soleBlockerShapes*: int

    ## trenches
    trenches*: int
    trenchNearObstaclePx*: seq[int]
    trenchOpenRunPx*: seq[int]
    trenchInEndzone*: int
    trenchOnColumnX*: int

    ## pickups
    medKits*: int
    medKitPairPx*: int
    medKitPairLos*: bool
    medKitOneCovers*: bool
    medKitNudgePx*: seq[int]
    grenadePoints*: int
    grenadeBroken*: int
    grenadeUnreachable*: int
    shieldNudgePx*, sprayNudgePx*: seq[int]

    ## spawn vs stand (CTF only)
    respawnAreaPx*: int
    respawnWithin150*: int
    respawnMeanDistPx*: float
    captureAreaFrac*: float

    ## counterfactual: solid obstacles measured as if glass
    candidates*, candidatesUseful*: int

    ## lattice / architecture
    obstacleCount*: int
    distinctColumnXs*: int
    latticeFrac*: float

    ## BR spawn geometry (flagless / spawnGroups > 1 maps only)
    spawnRows*: seq[SpawnPointRow]

proc scanRowsOf*(c: MapCtx): tuple[scan, valOpen, visOpen, glassOnly: int] =
  ## The shipping validator's own 4px horizontal sightline scan, run twice:
  ## once on its mask (minWall) and once on what fog actually occludes
  ## (vision). Rows open only under vision are rows the validator wrongly
  ## counts as blocked — its measured blind spot on this map.
  let
    g = c.gameMap
    ax = g.sightlineLoX
    bx = g.sightlineHiX
  var y = ArenaBorder + 2
  while y < c.h - ArenaBorder:
    inc result.scan
    var blockedMin = false
    var blockedVis = false
    for x in ax .. bx:
      let i = y * c.w + x
      if c.minWall[i]: blockedMin = true
      if c.vision[i]:
        blockedVis = true
        break
    if not blockedMin: inc result.valOpen
    if not blockedVis:
      inc result.visOpen
      if blockedMin: inc result.glassOnly
    y += 4

proc measureSpawnGeometry*(c: MapCtx): seq[SpawnPointRow] =
  ## BR spawn-point geometry. All from persistent map data — no sim state.
  let g = c.gameMap
  if g.spawnPoints.len == 0: return
  var open = newSeq[bool](c.w * c.h)
  for i in 0 ..< open.len: open[i] = not c.maxWall[i]
  let half = MinPassableWidth div 2
  for i, p in g.spawnPoints:
    var row = SpawnPointRow(idx: i, x: p.x, y: p.y)
    for shape in c.obstacles:
      if not shape.window and inShape(p.x, p.y, shape):
        row.inObstacleShape = true
        break
    row.onOpenFloor = c.isOpenFloor(p.x, p.y)
    row.hasClearance = c.clearanceBoxOpen(p.x, p.y, half)
    row.reachable = c.isReachable(p.x, p.y)
    row.nudgePx = c.nearestOpenDist(p.x, p.y, 200)
    var nn = int.high
    for j, q in g.spawnPoints:
      if i == j: continue
      let d = int(sqrt(float((p.x - q.x) ^ 2 + (p.y - q.y) ^ 2)))
      nn = min(nn, d)
    row.nnDistPx = if nn == int.high: 0 else: nn
    row.centerDistPx = int(sqrt(
      float((p.x - g.center.x) ^ 2 + (p.y - g.center.y) ^ 2)))
    let dist = walkDistances(open, c.w, c.h, p)
    proc nearestWalk(points: seq[MapPoint]): int =
      result = -1
      for q in points:
        if q.x < 0 or q.y < 0 or q.x >= c.w or q.y >= c.h: continue
        var d = dist[q.y * c.w + q.x]
        if d < 0:
          ## Item in stone: charge the walk to its own nudge target.
          var best = -1
          for r in 1 .. 40:
            if best >= 0: break
            for dy in -r .. r:
              for dx in -r .. r:
                if max(abs(dx), abs(dy)) != r: continue
                let (px, py) = (q.x + dx, q.y + dy)
                if px >= 0 and py >= 0 and px < c.w and py < c.h and
                    dist[py * c.w + px] >= 0:
                  best = dist[py * c.w + px]
                  break
              if best >= 0: break
          d = best
        if d >= 0 and (result < 0 or d < result): result = d
    row.shieldWalk = nearestWalk(g.shieldSpawns)
    row.sprayWalk = nearestWalk(g.spraySpawns)
    row.grenadeWalk = nearestWalk(g.grenadeSpawns)
    row.medKitWalk = nearestWalk(g.medKitSpawns)
    result.add row

proc measureMap*(
  gameMap: CtfMap, label: string, seed: int, countCandidates = false
): MapRow =
  let c = buildCtx(gameMap)
  let g = gameMap
  result.name = label
  result.seed = seed
  result.teams = g.teamCount()
  result.size = sizeClassOf(g.width)
  result.sym = $g.symmetry
  result.endz = $g.endzone
  result.layout = $g.layout
  result.w = g.width
  result.h = g.height
  result.flagless = g.flagless
  result.spawnGroups = g.spawnGroups
  result.validReason = validateGeneratedMap(g)
  result.valid = result.validReason.len == 0

  # --- windows -------------------------------------------------------------
  var minSides: seq[int]
  for i, shape in c.obstacles:
    if not shape.window: continue
    inc result.windows
    let m = c.measureWindow(shape, i)
    let minSide = min(m.depthA, m.depthB)
    minSides.add minSide
    case classifyWindow(m.glassPx, minSide)
    of winDead: inc result.winDeadN
    of winInert: inc result.winInertN
    of winDecor: inc result.winDecorN
    of winShallow: inc result.winShallowN
    of winUseful: inc result.winUsefulN
  result.winMinSideMedian = medianOf(minSides)

  # --- sightline rows (the shipping validator's own scan geometry) ---------
  if not g.flagless:
    let rows = c.scanRowsOf()
    result.scanRows = rows.scan
    result.validatorOpenRows = rows.valOpen
    result.visionOpenRows = rows.visOpen
    result.glassOnlyRows = rows.glassOnly

    # --- sole blockers: obstacles the sightline invariant rests on ---------
    block soleBlockers:
      let
        ax = g.sightlineLoX
        bx = g.sightlineHiX
      var sole = newSeq[bool](c.obstacles.len)
      var y = ArenaBorder + 2
      while y < c.h - ArenaBorder:
        var hits: seq[int]
        for si, shape in c.obstacles:
          let b = bboxOf(shape)
          if y < b.y0 or y > b.y1: continue
          var found = false
          for x in max(b.x0, ax) .. min(b.x1, bx):
            if c.minWall[y * c.w + x] and inShape(x, y, shape):
              found = true
              break
          if found:
            hits.add si
            if hits.len > 1: break
        if hits.len == 1: sole[hits[0]] = true
        y += 4
      for si in 0 ..< c.obstacles.len:
        if sole[si]: inc result.soleBlockerShapes

  # --- trenches ------------------------------------------------------------
  result.trenches = g.trenches.len
  for t in g.trenches:
    let r = shapeAsRect(t)
    let (tx, ty) = (r.x + r.w div 2, r.y + r.h div 2)
    var nearest = 400
    block ring:
      for rad in 1 .. 400:
        for dx in -rad .. rad:
          for dy in [-rad, rad]:
            if c.inBounds(tx + dx, ty + dy) and
                c.maxWall[(ty + dy) * c.w + tx + dx]:
              nearest = rad; break ring
        for dy in -rad + 1 .. rad - 1:
          for dx in [-rad, rad]:
            if c.inBounds(tx + dx, ty + dy) and
                c.maxWall[(ty + dy) * c.w + tx + dx]:
              nearest = rad; break ring
    result.trenchNearObstaclePx.add nearest
    var run = 0
    var x = tx
    while x > 0 and not c.vision[ty * c.w + x]: dec x; inc run
    x = tx
    while x < c.w - 1 and not c.vision[ty * c.w + x]: inc x; inc run
    result.trenchOpenRunPx.add run
    if not g.flagless and mapProtectedFloorAt(g, tx, ty):
      inc result.trenchInEndzone
    for s in g.leftObstacles:
      let sb = bboxOf(s)
      if abs((sb.x0 + sb.x1) div 2 - tx) <= 16:
        inc result.trenchOnColumnX
        break

  # --- pickups -------------------------------------------------------------
  result.medKits = g.medKitSpawns.len
  for p in g.medKitSpawns:
    result.medKitNudgePx.add c.nearestOpenDist(p.x, p.y)
  if g.medKitSpawns.len == 2:
    let
      a = g.medKitSpawns[0]
      b = g.medKitSpawns[1]
      dx = float(a.x - b.x)
      dy = float(a.y - b.y)
    result.medKitPairPx = int(sqrt(dx * dx + dy * dy))
    result.medKitPairLos =
      losClear(c.vision, c.w, c.h, a.x, a.y, b.x, b.y)
    let (mx, my) = ((a.x + b.x) div 2, (a.y + b.y) div 2)
    var stance = (mx, my)
    if not c.isOpenFloor(mx, my):
      block findStance:
        for rad in 1 .. 120:
          for dxx in -rad .. rad:
            for dyy in [-rad, rad]:
              if c.isOpenFloor(mx + dxx, my + dyy):
                stance = (mx + dxx, my + dyy); break findStance
          for dyy in -rad + 1 .. rad - 1:
            for dxx in [-rad, rad]:
              if c.isOpenFloor(mx + dxx, my + dyy):
                stance = (mx + dxx, my + dyy); break findStance
    let
      d1 = sqrt(float((stance[0] - a.x) ^ 2 + (stance[1] - a.y) ^ 2))
      d2 = sqrt(float((stance[0] - b.x) ^ 2 + (stance[1] - b.y) ^ 2))
    result.medKitOneCovers =
      d1 <= float(c.gunRangePx) and d2 <= float(c.gunRangePx) and
      losClear(c.vision, c.w, c.h, stance[0], stance[1], a.x, a.y) and
      losClear(c.vision, c.w, c.h, stance[0], stance[1], b.x, b.y)

  ## Grenades: authored BR pool when present, else the classic formula (the
  ## one pickup family the sim never nudges to walkable floor).
  var grenadePts: seq[MapPoint]
  if g.grenadeSpawns.len > 0:
    grenadePts = g.grenadeSpawns
  else:
    for p in g.grenadeSpawnPoints():
      grenadePts.add MapPoint(x: p.x, y: p.y)
  result.grenadePoints = grenadePts.len
  for p in grenadePts:
    if not c.isOpenFloor(p.x, p.y): inc result.grenadeBroken
    if not c.isReachable(p.x, p.y): inc result.grenadeUnreachable
  let shieldPts =
    if g.shieldSpawns.len > 0: g.shieldSpawns
    else:
      var pts: seq[MapPoint]
      if not g.flagless:
        for p in g.shieldSpawnPoints(): pts.add MapPoint(x: p.x, y: p.y)
      pts
  for p in shieldPts:
    result.shieldNudgePx.add c.nearestOpenDist(p.x, p.y, 300)
  for p in g.spraySpawns:
    result.sprayNudgePx.add c.nearestOpenDist(p.x, p.y, 300)

  # --- respawn region vs the stand it defends (CTF only) -------------------
  if not g.flagless:
    let
      zone = g.captureZone(Red)
      home = g.flagHome(Red)
      x0 = max(zone.xLo, 0)
      x1 = min(zone.xHi, c.w - 1)
      y0 = max(zone.yLo, 0)
      y1 = min(zone.yHi, c.h - 1)
    var total = 0
    var near = 0
    var sum = 0.0
    var yy = y0
    while yy <= y1:
      var xx = x0
      while xx <= x1:
        if zone.inCaptureZone(xx, yy) and c.isOpenFloor(xx, yy):
          inc total
          let d = sqrt(float((xx - home.x) ^ 2 + (yy - home.y) ^ 2))
          sum += d
          if d <= 150.0: inc near
        xx += 2
      yy += 2
    result.respawnAreaPx = total * 4
    result.respawnWithin150 = near * 4
    result.respawnMeanDistPx = if total > 0: sum / float(total) else: 0.0
    result.captureAreaFrac =
      float(result.respawnAreaPx) / float(max(1, c.w * c.h))

  # --- counterfactual: where COULD a window have gone? ---------------------
  ## Every solid rect/diamond/disc obstacle measured as if it were glass —
  ## the ceiling a smarter pane selector could reach without changing the
  ## lattice. (The old probe restricted this to the column phase; provenance
  ## is unrecoverable on main, so the candidate set is every solid shape and
  ## the ceiling reads slightly HIGH. Reported, not hidden.)
  if countCandidates:
    for li, s in g.leftObstacles:
      if s.window: continue
      if s.kind notin {shapeRect, shapeDiamond, shapeDisc}: continue
      inc result.candidates
      let m = c.measureWindow(s, li)
      if min(m.depthA, m.depthB) >= UsefulDepthPx: inc result.candidatesUseful

  # --- architecture: is the cover a lattice? -------------------------------
  var xs = initCountTable[int]()
  for s in g.leftObstacles:
    let b = bboxOf(s)
    inc result.obstacleCount
    xs.inc((b.x0 + b.x1) div 8)
  result.distinctColumnXs = xs.len
  result.latticeFrac =
    if result.obstacleCount == 0: 0.0
    else: 1.0 - float(xs.len) / float(result.obstacleCount)

  # --- BR spawn geometry ---------------------------------------------------
  if g.flagless or g.spawnPoints.len > 0:
    result.spawnRows = c.measureSpawnGeometry()

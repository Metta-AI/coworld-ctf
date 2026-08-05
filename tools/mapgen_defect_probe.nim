## mapgen_defect_probe — measures whether each feature the generator PLACES
## actually does its job.
##
## The generator draws features by RNG and validates almost none of them. This
## probe is the counter-measurement: for every placed feature it asks "can this
## thing possibly function?" and reports the frequency and the severity.
##
## Rules this tool inherits from `tools/map_eval.nim` (they were learned the
## hard way and the harness enforces them structurally, not by discipline):
##
##  1. The hand-authored `arena` (and `arena-large`) are prepended to EVERY
##     batch as the CONTROL. A measurement that flags the control is wrong; a
##     measurement that skips the control is worse.
##  2. No count without its fraction. Every count printed carries its
##     denominator on the same line.
##  3. Distributions, not anecdotes: the defaults sweep hundreds of seeds
##     across every drawable size class.
##
## PURITY: like `map_metrics` and `tools/map_render.nim`, nothing here installs
## a map or reads the process globals (`MapWidth`, `ArenaObstacles`, ...).
## Every measurement is a pure function of a `CtfMap`.
##
## WHICH MASK (same convention as map_metrics, because the two masks point in
## opposite directions and a spinning diamond is not one shape):
##   * `maxWall` (swept union) for STRUCTURE — cover accounting, "does this
##     pixel exist as architecture".
##   * `minWall` (always-stone) for the VALIDATOR's own sightline test, so the
##     probe reproduces exactly what the generator checked.
##   * `visionMask` = `minWall` minus GLASS — what the FOG actually occludes.
##     This is the mask the window measurements need and the one the generator
##     never builds: glass sits on the wall side of `minWall`, so the sightline
##     validator counts a pane as a vision blocker when it is not one.
##
## Usage:
##   mapgen_defect_probe --seeds 1000-1299            # 2-team sweep + controls
##   mapgen_defect_probe --seeds 1000-1199 --teams 4
##   mapgen_defect_probe --seeds 1000-1099 --rows rows.tsv --maps maps.tsv
##   mapgen_defect_probe --seeds 1000-1299 --worst 12 # print the worst windows

import
  std/[algorithm, math, os, strformat, strutils, tables],
  ../src/ctf/[sim, map_metrics]

const
  MarchStep = 2
    ## px per step when marching a sightline. Finer than the thinnest wall
    ## feature (12px), the same rule `rectOnOpenFloor` samples by.
  UsefulDepthPx = 200
    ## The bar a window's free depth must clear on BOTH sides to be worth
    ## building. Calibrated, not asserted: it is below every one of the
    ## hand-authored arena's own panes (see the CONTROL block in the report).
    ## 200px is also `map_metrics.StandCoverRadiusPx`, the radius inside which
    ## cover decides a fight, and ~1.9 seconds of approach at 2.75px/tick.
  DecorativeDepthPx = 100
    ## Below this a pane looks through a pocket, not a lane.
  StandDepthPx = 26
    ## `MinCorridorWidth`. Below this nobody can stand on that side at all, so
    ## the glass has no viewer and no target: the pane is inert.

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

proc medianOf(values: seq[int]): int =
  if values.len == 0: return 0
  var v = values
  v.sort()
  v[v.len div 2]

proc percentile(values: seq[float], q: float): float =
  if values.len == 0: return 0.0
  var v = values
  v.sort()
  let idx = clamp(int(q * float(v.len - 1) + 0.5), 0, v.len - 1)
  v[idx]

proc meanOf(values: seq[float]): float =
  if values.len == 0: return 0.0
  var s = 0.0
  for x in values: s += x
  s / float(values.len)

proc pct(part, whole: int): string =
  if whole == 0: "n/a" else: &"{100.0 * float(part) / float(whole):.1f}%"

type Bounds = tuple[x0, y0, x1, y1: int]

proc bboxOf(shape: ArenaShape): Bounds =
  ## Inclusive integer bounding box of one obstacle. Local because arena.nim's
  ## own `shapeBounds` is not exported and this tool must not touch that file.
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

proc sameShape(a, b: ArenaShape): bool =
  if a.kind != b.kind: return false
  case a.kind
  of shapeRect: a.rect == b.rect
  of shapeDisc, shapeDiamond:
    a.cx == b.cx and a.cy == b.cy and a.radius == b.radius
  of shapeDiagonal:
    a.x0 == b.x0 and a.y0 == b.y0 and a.x1 == b.x1 and a.y1 == b.y1 and
      a.thickness == b.thickness
  of shapePolygon: a.points == b.points

# ---------------------------------------------------------------------------
# One map's rasterized context
# ---------------------------------------------------------------------------

type
  MapCtx = object
    gameMap: CtfMap
    obstacles: seq[ArenaShape]
    maxWall: seq[bool]          ## swept union — structure
    minWall: seq[bool]          ## always-stone — the validator's own mask
    glass: seq[bool]            ## wall pixels belonging to a window shape
    vision: seq[bool]           ## minWall AND NOT glass — what fog occludes
    corridorOpen: seq[bool]     ## the validator's player-width erosion
    reachable: seq[bool]        ## eroded floor reachable from Red's stand
    w, h: int
    symMult: int                ## images per seed shape (2 mirror/rot180, 4 rot90)

proc buildCtx(gameMap: CtfMap): MapCtx =
  result.gameMap = gameMap
  result.w = gameMap.width
  result.h = gameMap.height
  result.obstacles = buildArenaObstacles(gameMap)
  let (mx, mn) = rasterizeWallMasks(gameMap, result.obstacles)
  result.maxWall = mx
  result.minWall = mn
  result.symMult = if gameMap.symmetry == symRot90: 4 else: 2
  result.glass = newSeq[bool](result.w * result.h)
  for shape in result.obstacles:
    if not shape.window: continue
    let b = bboxOf(shape)
    for y in max(b.y0, 0) .. min(b.y1, result.h - 1):
      for x in max(b.x0, 0) .. min(b.x1, result.w - 1):
        let i = y * result.w + x
        ## Only pixels that actually survived the protected-floor carve are
        ## glass; a pane stamped over the flag ring renders nothing.
        if result.maxWall[i] and inShape(x, y, shape):
          result.glass[i] = true
  result.vision = newSeq[bool](result.w * result.h)
  for i in 0 ..< result.w * result.h:
    result.vision[i] = result.minWall[i] and not result.glass[i]
  let diag = mapDiagnostics(
    gameMap, {diagnosticCorridorOpen, diagnosticReachable})
  result.corridorOpen = diag.corridorOpen
  result.reachable = diag.reachable

proc inBounds(c: MapCtx, x, y: int): bool {.inline.} =
  x >= 0 and y >= 0 and x < c.w and y < c.h

proc isOpenFloor(c: MapCtx, x, y: int): bool {.inline.} =
  c.inBounds(x, y) and not c.maxWall[y * c.w + x]

proc isReachable(c: MapCtx, x, y: int): bool {.inline.} =
  c.inBounds(x, y) and c.reachable.len > 0 and c.reachable[y * c.w + x]

proc nearestOpenDist(c: MapCtx, x, y: int, cap = 400): int =
  ## Chebyshev ring search for the nearest player-usable floor pixel, the
  ## pure-function twin of the sim's `nearestWalkable` nudge. Returns `cap`
  ## when nothing usable is within range.
  if c.inBounds(x, y) and c.corridorOpen.len > 0 and
      c.corridorOpen[y * c.w + x]:
    return 0
  for r in 1 .. cap:
    for dx in -r .. r:
      for dy in [-r, r]:
        let (px, py) = (x + dx, y + dy)
        if c.inBounds(px, py) and c.corridorOpen[py * c.w + px]: return r
    for dy in -r + 1 .. r - 1:
      for dx in [-r, r]:
        let (px, py) = (x + dx, y + dy)
        if c.inBounds(px, py) and c.corridorOpen[py * c.w + px]: return r
  cap

# ---------------------------------------------------------------------------
# WINDOWS — the reported defect
# ---------------------------------------------------------------------------

type
  WindowClass = enum
    winDead      ## zero glass pixels survive: the pane does not exist
    winInert     ## a side has < 26px free: nobody can even stand and look
    winDecor     ## a side has < 100px free: it looks into a pocket
    winShallow   ## a side has < 200px free
    winUseful    ## >= 200px free on BOTH sides

  WindowRow = object
    mapName: string
    seed, teams: int
    size, sym, endz: string
    idx: int
    kind: string
    provenance: string          ## "bracket" (hand-placed) | "column" (RNG)
    glassPx: int
    axis: string                ## "x" | "y" — the pane's through-direction
    depthA, depthB: int         ## median free vision depth, each side, px
    minSide, through: int
    reachA, reachB: bool
    borderFlush: bool
    facesGlass: bool
    cls: WindowClass
    cx, cy: int

proc marchDepth(
  c: MapCtx, mask: seq[bool], sx, sy, dx, dy: int, shape: ArenaShape
): int =
  ## Free depth, in px, from the pane's outer FACE outward along (dx, dy):
  ## first step clear of the pane's own body, then march until `mask` blocks
  ## or the gun range runs out. Capped at GunRange because past it, seeing is
  ## not shooting.
  var (x, y) = (sx, sy)
  var guard = 0
  while c.inBounds(x, y) and inShape(x, y, shape) and guard < 400:
    x += dx; y += dy; inc guard
  var d = 0
  while d < GunRange:
    if not c.inBounds(x, y): break
    if mask[y * c.w + x]: break
    x += dx * MarchStep; y += dy * MarchStep; d += MarchStep
  d

proc firstHitIsGlass(c: MapCtx, sx, sy, dx, dy: int, shape: ArenaShape): bool =
  ## Marching with glass OPAQUE (`minWall`), is the first thing this pane
  ## looks at another pane?
  var (x, y) = (sx, sy)
  var guard = 0
  while c.inBounds(x, y) and inShape(x, y, shape) and guard < 400:
    x += dx; y += dy; inc guard
  var d = 0
  while d < GunRange:
    if not c.inBounds(x, y): return false
    let i = y * c.w + x
    if c.minWall[i]: return c.glass[i]
    x += dx * MarchStep; y += dy * MarchStep; d += MarchStep
  false

proc axisSamples(b: Bounds, alongY: bool): seq[tuple[x, y: int]] =
  ## Up to 9 evenly spaced sample points on the pane's centre line, skipping
  ## the outer 10% at each end so a corner pixel never speaks for the pane.
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

proc measureWindow(
  c: MapCtx, shape: ArenaShape, idx: int
): tuple[axis: string, depthA, depthB, glassPx: int,
         reachA, reachB, facesGlass: bool] =
  let b = bboxOf(shape)
  var glassPx = 0
  for y in max(b.y0, 0) .. min(b.y1, c.h - 1):
    for x in max(b.x0, 0) .. min(b.x1, c.w - 1):
      if c.glass[y * c.w + x]: inc glassPx

  proc measureAxis(alongY: bool): tuple[a, b2: int, fg: bool] =
    ## `alongY` = the pane's long axis is vertical, so the view is horizontal.
    let
      samples = axisSamples(b, alongY)
      (dx, dy) = if alongY: (1, 0) else: (0, 1)
    var ds1, ds2: seq[int]
    var fg = false
    for s in samples:
      ds1.add c.marchDepth(c.vision, s.x, s.y, dx, dy, shape)
      ds2.add c.marchDepth(c.vision, s.x, s.y, -dx, -dy, shape)
    let mid = samples[samples.len div 2]
    fg = c.firstHitIsGlass(mid.x, mid.y, dx, dy, shape) or
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
    ## Square silhouette (a diamond or disc pane): no built-in normal, so take
    ## whichever axis serves it best. Judging it on the worse axis would score
    ## an isotropic shape as broken by construction.
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
    ## Stand just clear of the pane but STRICTLY inside the free depth we
    ## measured, or the probe lands in the very occluder it is asking about.
    outA = clamp(m.a - 4, 2, 20)
    outB = clamp(m.b2 - 4, 2, 20)
    halfSpan = (if axis == "x": bw else: bh) div 2 + 2
  (axis, m.a, m.b2, glassPx,
    c.isReachable(cx + dx * (halfSpan + outA), cy + dy * (halfSpan + outA)),
    c.isReachable(cx - dx * (halfSpan + outB), cy - dy * (halfSpan + outB)),
    m.fg)

proc classifyWindow(r: WindowRow): WindowClass =
  if r.glassPx == 0: winDead
  elif r.minSide < StandDepthPx: winInert
  elif r.minSide < DecorativeDepthPx: winDecor
  elif r.minSide < UsefulDepthPx: winShallow
  else: winUseful

# ---------------------------------------------------------------------------
# Per-map measurement
# ---------------------------------------------------------------------------

type
  MapRow = object
    name: string
    seed, teams: int
    size, sym, endz, feature, layout: string
    w, h: int
    valid: bool

    windows, winDead, winInert, winDecor, winShallow, winUseful: int
    winMinSideMedian: int

    ## sightline rows: the validator's 4px scan across [sightlineLoX..HiX]
    scanRows, validatorOpenRows, visionOpenRows, glassOnlyRows: int

    ## sightline-repair plugs
    plugsResolved: bool
    plugsExact: bool
    columnShapes, featureShapes, plugShapes: int
    plugWallPx, interiorWallPx, interiorPx: int
    soleBlockerShapes, soleBlockerPlugs: int

    ## trenches
    trenches: int
    trenchNearObstaclePx: seq[int]
    trenchOpenRunPx: seq[int]
    trenchInEndzone: int
    trenchOnColumnX: int

    ## pickups
    medKits: int
    medKitPairPx: int
    medKitPairLos: bool
    medKitOneCovers: bool
    medKitNudgePx: seq[int]
    grenadeBroken: int
    grenadeUnreachable: int
    grenadeNudgeNeededPx: seq[int]
    shieldNudgePx, sprayNudgePx: seq[int]

    ## spawn vs stand
    respawnAreaPx: int
    respawnWithin150: int
    respawnMeanDistPx: float
    captureAreaFrac: float

    ## Counterfactual: how many of the COLUMN obstacles this map actually
    ## built would have made a useful window if the selector had checked?
    ## This is the ceiling the current generator could reach with nothing but
    ## a smarter pick — the number that decides "fixable" vs "structural".
    candidates, candidatesUseful: int

    ## lattice / architecture
    obstacleCount: int
    distinctColumnXs: int
    latticeFrac: float
    kindCounts: array[ArenaShapeKind, int]

proc scanRowsOf(c: MapCtx): tuple[scan, valOpen, visOpen, glassOnly: int] =
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

proc plugSplit(g: CtfMap): tuple[resolved, exact: bool, colN, featN, plugN: int] =
  ## Recovers the three construction phases from the ORDER of leftObstacles:
  ## columns are emitted first, then the centre feature, then the sightline
  ## repair plugs (arena.nim:1697-1988). The centre feature is exactly
  ## identifiable — every one of its rects sits at x = center.x - 138 — so on
  ## a "bracket" or "walls" map the boundary is EXACT. A "ring" map has no
  ## feature to anchor on and the answer is the longest trailing run of r28
  ## non-window diamonds, which is an UPPER BOUND (a final column of diamonds
  ## is absorbed into it). Both are reported separately, never merged.
  let bx = g.center.x - 138
  var lastFeature = -1
  var featN = 0
  for i, s in g.leftObstacles:
    if s.kind == shapeRect and s.rect.x == bx and not s.window:
      lastFeature = i
      inc featN
    elif s.kind == shapeRect and s.rect.x == bx and s.window:
      ## the bracket's glass pane, also part of the feature block
      lastFeature = i
      inc featN
  var plugStart: int
  var exact: bool
  if featN > 0:
    plugStart = lastFeature + 1
    exact = true
  else:
    plugStart = g.leftObstacles.len
    while plugStart > 0:
      let s = g.leftObstacles[plugStart - 1]
      if s.kind == shapeDiamond and s.radius == 28 and not s.window:
        dec plugStart
      else:
        break
    exact = false
  for i in plugStart ..< g.leftObstacles.len:
    let s = g.leftObstacles[i]
    if s.kind != shapeDiamond or s.radius != 28 or s.window:
      return (false, false, 0, 0, 0)
  (true, exact, plugStart - featN, featN, g.leftObstacles.len - plugStart)

proc measureMap(
  gameMap: CtfMap, label: string, seed: int, countCandidates = false
): MapRow =
  let c = buildCtx(gameMap)
  let g = gameMap
  result.name = label
  result.seed = seed
  result.teams = g.teamCount()
  result.size = g.mapSizeClassName()
  result.sym = $g.symmetry
  result.endz = $g.endzone
  result.layout = $g.layout
  result.w = g.width
  result.h = g.height
  result.valid = validateGeneratedMap(g).len == 0

  # --- windows -------------------------------------------------------------
  var minSides: seq[int]
  for i, shape in c.obstacles:
    if not shape.window: continue
    inc result.windows
    var row = WindowRow(idx: i, kind: $shape.kind)
    let m = c.measureWindow(shape, i)
    row.axis = m.axis
    row.depthA = m.depthA
    row.depthB = m.depthB
    row.glassPx = m.glassPx
    row.minSide = min(m.depthA, m.depthB)
    row.through = m.depthA + m.depthB
    row.cls = row.classifyWindow()
    minSides.add row.minSide
    case row.cls
    of winDead: inc result.winDead
    of winInert: inc result.winInert
    of winDecor: inc result.winDecor
    of winShallow: inc result.winShallow
    of winUseful: inc result.winUseful
  result.winMinSideMedian = medianOf(minSides)

  # --- sightline rows -------------------------------------------------------
  let rows = c.scanRowsOf()
  result.scanRows = rows.scan
  result.validatorOpenRows = rows.valOpen
  result.visionOpenRows = rows.visOpen
  result.glassOnlyRows = rows.glassOnly

  # --- plugs ---------------------------------------------------------------
  let split = g.plugSplit()
  result.plugsResolved = split.resolved
  result.plugsExact = split.exact
  result.columnShapes = split.colN
  result.featureShapes = split.featN
  result.plugShapes = split.plugN

  var plugIsPlug = newSeq[bool](c.obstacles.len)
  if split.resolved and split.plugN > 0:
    let plugStart = split.colN + split.featN
    for li in plugStart ..< g.leftObstacles.len:
      for k in 0 ..< c.symMult:
        plugIsPlug[li * c.symMult + k] = true
  var plugMask = newSeq[bool](c.w * c.h)
  for i, shape in c.obstacles:
    if not plugIsPlug[i]: continue
    let b = bboxOf(shape)
    for y in max(b.y0, 0) .. min(b.y1, c.h - 1):
      for x in max(b.x0, 0) .. min(b.x1, c.w - 1):
        let j = y * c.w + x
        if c.maxWall[j] and inShape(x, y, shape): plugMask[j] = true
  for y in ArenaBorder ..< c.h - ArenaBorder:
    for x in ArenaBorder ..< c.w - ArenaBorder:
      let j = y * c.w + x
      inc result.interiorPx
      if c.maxWall[j]: inc result.interiorWallPx
      if plugMask[j]: inc result.plugWallPx

  # --- sole blockers: obstacles the sightline invariant rests on -----------
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
      if sole[si]:
        inc result.soleBlockerShapes
        if plugIsPlug[si]: inc result.soleBlockerPlugs

  # --- trenches ------------------------------------------------------------
  result.trenches = g.trenches.len
  for t in g.trenches:
    let r = shapeAsRect(t)
    let (tx, ty) = (r.x + r.w div 2, r.y + r.h div 2)
    ## Distance to the nearest wall pixel: a trench that is "cover you stand
    ## in" is only worth anything where there is no cover to stand BEHIND.
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
    ## Horizontal open run through the trench — 70% of shots fly over a
    ## trench, so a trench is worth digging where shots actually travel.
    var run = 0
    var x = tx
    while x > 0 and not c.vision[ty * c.w + x]: dec x; inc run
    x = tx
    while x < c.w - 1 and not c.vision[ty * c.w + x]: inc x; inc run
    result.trenchOpenRunPx.add run
    if mapProtectedFloorAt(g, tx, ty): inc result.trenchInEndzone
    ## "Parasitic on column slots": does the dig sit on the same x line as an
    ## obstacle, i.e. in the picket lattice rather than on a crossing?
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
    ## One player covers both when a single stance sees each kit inside gun
    ## range. The midpoint is the strongest such stance on the segment; nudge
    ## it to usable floor before asking.
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
      d1 <= float(GunRange) and d2 <= float(GunRange) and
      losClear(c.vision, c.w, c.h, stance[0], stance[1], a.x, a.y) and
      losClear(c.vision, c.w, c.h, stance[0], stance[1], b.x, b.y)

  ## Grenades: the ONE pickup family the sim never nudges to walkable floor
  ## (sim.nim:106 "Grenade spawns keep their own placement"). A corner inset
  ## that lands in stone is a pickup that can never be taken.
  for p in g.grenadeSpawnPoints():
    let nudge = c.nearestOpenDist(p.x, p.y, 200)
    result.grenadeNudgeNeededPx.add nudge
    if not c.isOpenFloor(p.x, p.y): inc result.grenadeBroken
    if not c.isReachable(p.x, p.y): inc result.grenadeUnreachable
  for p in g.shieldSpawnPoints():
    result.shieldNudgePx.add c.nearestOpenDist(p.x, p.y, 300)
  for p in g.plasmaArcSpawnPoints():
    result.sprayNudgePx.add c.nearestOpenDist(p.x, p.y, 300)

  # --- respawn region vs the stand it defends ------------------------------
  block respawn:
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
  ## Every column obstacle is window-eligible (arena.nim:1777-1785 adds stubs,
  ## diamonds and discs to `eligible`); the selector just shuffles and takes
  ## the first 2-4. So measure every one of them as if it were glass. The
  ## marching already steps clear of the candidate's own body, so a solid
  ## obstacle and the same obstacle turned to glass measure identically.
  if countCandidates and split.resolved:
    for li in 0 ..< split.colN:
      let s = g.leftObstacles[li]
      if s.kind notin {shapeRect, shapeDiamond, shapeDisc}: continue
      inc result.candidates
      let m = c.measureWindow(s, li)
      if min(m.depthA, m.depthB) >= UsefulDepthPx: inc result.candidatesUseful

  # --- architecture: is the cover a lattice? -------------------------------
  var xs = initCountTable[int]()
  for s in g.leftObstacles:
    let b = bboxOf(s)
    inc result.obstacleCount
    inc result.kindCounts[s.kind]
    xs.inc((b.x0 + b.x1) div 8)     ## 8px buckets on the centre x
  result.distinctColumnXs = xs.len
  var onLattice = 0
  for _, v in xs: onLattice = max(onLattice, v)
  result.latticeFrac =
    if result.obstacleCount == 0: 0.0
    else: 1.0 - float(xs.len) / float(result.obstacleCount)

# ---------------------------------------------------------------------------
# Window row extraction (a second pass, only for the maps we report on)
# ---------------------------------------------------------------------------

proc windowRows(gameMap: CtfMap, label: string, seed: int): seq[WindowRow] =
  let c = buildCtx(gameMap)
  let bx = gameMap.center.x - 138
  for i, shape in c.obstacles:
    if not shape.window: continue
    let b = bboxOf(shape)
    var row = WindowRow(
      mapName: label, seed: seed, teams: gameMap.teamCount(),
      size: gameMap.mapSizeClassName(), sym: $gameMap.symmetry,
      endz: $gameMap.endzone, idx: i, kind: $shape.kind,
      cx: (b.x0 + b.x1) div 2, cy: (b.y0 + b.y1) div 2)
    row.provenance =
      if shape.kind == shapeRect and
          (shape.rect.x == bx or
           shape.rect.x == gameMap.width - bx - shape.rect.w): "bracket"
      else: "column"
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
    row.cls = row.classifyWindow()
    result.add row

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

type Args = object
  flags: Table[string, string]
  bools: seq[string]

proc parseArgs(argv: seq[string]): Args =
  result.flags = initTable[string, string]()
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a.startsWith("--"):
      let body = a[2 .. ^1]
      if body.contains('='):
        let kv = body.split('=', 1)
        result.flags[kv[0]] = kv[1]
      elif i + 1 < argv.len and not argv[i + 1].startsWith("--"):
        result.flags[body] = argv[i + 1]
        inc i
      else:
        result.bools.add body
    inc i

proc flag(a: Args, key, default: string): string =
  a.flags.getOrDefault(key, default)

proc main() =
  let a = parseArgs(commandLineParams())
  let teams = a.flag("teams", "2").parseInt
  let seedSpec = a.flag("seeds", "1000-1099")
  let sizeLock = a.flag("size", "")
  let counterfactual = "counterfactual" in a.bools
  var lo, hi: int
  if seedSpec.contains('-'):
    let parts = seedSpec.split('-', 1)
    lo = parts[0].parseInt
    hi = parts[1].parseInt
  else:
    lo = seedSpec.parseInt
    hi = lo

  var mapRows: seq[MapRow]
  var winRows: seq[WindowRow]

  ## Rule 1: the CONTROL is prepended to every batch, never optional.
  for ctrl in ["arena", "arena-large"]:
    let g = loadCtfMapMetadata(ctrl)
    mapRows.add measureMap(g, ctrl, -1, counterfactual)
    winRows.add windowRows(g, ctrl, -1)

  var overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
  if sizeLock.len > 0: overrides.size = sizeLock
  var generated = 0
  for seed in lo .. hi:
    var g: CtfMap
    try:
      g = generateCtfMap(seed, overrides, teams)
    except CatchableError as e:
      stderr.writeLine(&"seed {seed}: {e.msg}")
      continue
    inc generated
    let label = &"gen:{seed}"
    mapRows.add measureMap(g, label, seed, counterfactual)
    winRows.add windowRows(g, label, seed)
    if generated mod 25 == 0:
      stderr.writeLine(&"  ... {generated} maps")

  # --- optional per-row dumps ----------------------------------------------
  if a.flag("rows", "").len > 0:
    var s = "map\tseed\tteams\tsize\tsym\tendz\tkind\tprov\tglassPx\taxis\t" &
      "depthA\tdepthB\tminSide\tthrough\treachA\treachB\tborder\tfacesGlass\t" &
      "class\tcx\tcy\n"
    for r in winRows:
      s.add &"{r.mapName}\t{r.seed}\t{r.teams}\t{r.size}\t{r.sym}\t{r.endz}\t" &
        &"{r.kind}\t{r.provenance}\t{r.glassPx}\t{r.axis}\t{r.depthA}\t" &
        &"{r.depthB}\t{r.minSide}\t{r.through}\t{r.reachA}\t{r.reachB}\t" &
        &"{r.borderFlush}\t{r.facesGlass}\t{r.cls}\t{r.cx}\t{r.cy}\n"
    writeFile(a.flag("rows", ""), s)
  if a.flag("maps", "").len > 0:
    var s = "map\tseed\tteams\tsize\tsym\tendz\tlayout\tw\th\tvalid\t" &
      "windows\tdead\tinert\tdecor\tshallow\tuseful\tminSideMed\t" &
      "scanRows\tvalOpen\tvisOpen\tglassOnly\t" &
      "plugsExact\tcolShapes\tfeatShapes\tplugShapes\tplugWallPx\t" &
      "interiorWallPx\tinteriorPx\tsoleBlockers\tsoleBlockerPlugs\t" &
      "trenches\ttrenchInEz\tmedKitPairPx\tmedKitLos\tmedKitOneCovers\t" &
      "grenadeBroken\tgrenadeUnreach\trespawnAreaPx\trespawnNear150\t" &
      "respawnMeanDist\tcaptureAreaFrac\tobstacles\tdistinctXs\tlatticeFrac\tcandidates\tcandUseful\n"
    for m in mapRows:
      s.add &"{m.name}\t{m.seed}\t{m.teams}\t{m.size}\t{m.sym}\t{m.endz}\t" &
        &"{m.layout}\t{m.w}\t{m.h}\t{m.valid}\t{m.windows}\t{m.winDead}\t" &
        &"{m.winInert}\t{m.winDecor}\t{m.winShallow}\t{m.winUseful}\t" &
        &"{m.winMinSideMedian}\t{m.scanRows}\t{m.validatorOpenRows}\t" &
        &"{m.visionOpenRows}\t{m.glassOnlyRows}\t{m.plugsExact}\t" &
        &"{m.columnShapes}\t{m.featureShapes}\t{m.plugShapes}\t" &
        &"{m.plugWallPx}\t{m.interiorWallPx}\t{m.interiorPx}\t" &
        &"{m.soleBlockerShapes}\t{m.soleBlockerPlugs}\t{m.trenches}\t" &
        &"{m.trenchInEndzone}\t{m.medKitPairPx}\t{m.medKitPairLos}\t" &
        &"{m.medKitOneCovers}\t{m.grenadeBroken}\t{m.grenadeUnreachable}\t" &
        &"{m.respawnAreaPx}\t{m.respawnWithin150}\t" &
        &"{m.respawnMeanDistPx:.0f}\t{m.captureAreaFrac:.4f}\t" &
        &"{m.obstacleCount}\t{m.distinctColumnXs}\t{m.latticeFrac:.3f}\t" &
        &"{m.candidates}\t{m.candidatesUseful}\n"
    writeFile(a.flag("maps", ""), s)

  # --- report ---------------------------------------------------------------
  proc report(rows: seq[MapRow], wins: seq[WindowRow], title: string) =
    if rows.len == 0: return
    echo ""
    echo "=== ", title, "  (", rows.len, " maps, ", wins.len, " windows) ==="
    var tw, td, ti, tdec, tsh, tu = 0
    var minSides: seq[float]
    for r in wins:
      inc tw
      case r.cls
      of winDead: inc td
      of winInert: inc ti
      of winDecor: inc tdec
      of winShallow: inc tsh
      of winUseful: inc tu
      minSides.add float(r.minSide)
    echo &"WINDOWS  n={tw}"
    echo &"  dead   (0 glass px)      {td:>5}  {pct(td, tw)}"
    echo &"  inert  (<26px a side)    {ti:>5}  {pct(ti, tw)}"
    echo &"  decor  (<100px a side)   {tdec:>5}  {pct(tdec, tw)}"
    echo &"  shallow(<200px a side)   {tsh:>5}  {pct(tsh, tw)}"
    echo &"  USEFUL (>=200px both)    {tu:>5}  {pct(tu, tw)}"
    echo &"  min-side depth px  p10={percentile(minSides, 0.1):.0f} " &
      &"p50={percentile(minSides, 0.5):.0f} " &
      &"p90={percentile(minSides, 0.9):.0f} " &
      &"mean={meanOf(minSides):.0f}"
    var occl = 0
    var fg = 0
    var unreach = 0
    var bord = 0
    for r in wins:
      if r.minSide < UsefulDepthPx: inc occl
      if r.facesGlass: inc fg
      if not (r.reachA and r.reachB): inc unreach
      if r.borderFlush: inc bord
    echo &"  occluded (<200px a side) {occl:>5}  {pct(occl, tw)}"
    echo &"  faces another pane       {fg:>5}  {pct(fg, tw)}"
    echo &"  a side is UNREACHABLE    {unreach:>5}  {pct(unreach, tw)}"
    echo &"  flush to the border      {bord:>5}  {pct(bord, tw)}"

    var byProv = initTable[string, seq[float]]()
    for r in wins:
      byProv.mgetOrPut(r.provenance, @[]).add float(r.minSide)
    for k, v in byProv:
      echo &"  provenance {k:<8} n={v.len:<4} median min-side " &
        &"{percentile(v, 0.5):.0f}px"

    var mapsWithGlassHole = 0
    var glassRows, scanRows, valOpen, visOpen = 0
    var plugMaps, plugExactMaps, plugsTotal, colTotal = 0
    var plugFrac: seq[float]
    var soleTot, solePlug = 0
    var trMaps, trTotal, trEz, trCol = 0
    var trNear, trRun, trRunFrac: seq[float]
    var plugFracExact: seq[float]
    var kitPair: seq[float]
    var kitCover, kitLos, kitMaps = 0
    var grenMaps, grenBroken, grenPoints, grenUnreach = 0
    var shieldNudge, sprayNudge, kitNudge: seq[float]
    var respFrac: seq[float]
    var respMean: seq[float]
    var capFrac: seq[float]
    var lattice: seq[float]
    var winShort = 0
    for m in rows:
      scanRows += m.scanRows
      valOpen += m.validatorOpenRows
      visOpen += m.visionOpenRows
      glassRows += m.glassOnlyRows
      if m.glassOnlyRows > 0: inc mapsWithGlassHole
      if m.plugsResolved:
        inc plugMaps
        if m.plugsExact: inc plugExactMaps
        plugsTotal += m.plugShapes
        colTotal += m.columnShapes
        if m.interiorWallPx > 0:
          plugFrac.add float(m.plugWallPx) / float(m.interiorWallPx)
          if m.plugsExact:
            plugFracExact.add float(m.plugWallPx) / float(m.interiorWallPx)
      soleTot += m.soleBlockerShapes
      solePlug += m.soleBlockerPlugs
      if m.trenches > 0: inc trMaps
      trTotal += m.trenches
      trEz += m.trenchInEndzone
      trCol += m.trenchOnColumnX
      for v in m.trenchNearObstaclePx: trNear.add float(v)
      for v in m.trenchOpenRunPx:
        trRun.add float(v)
        trRunFrac.add float(v) / float(m.w)
      if m.medKits == 2:
        inc kitMaps
        kitPair.add float(m.medKitPairPx)
        if m.medKitOneCovers: inc kitCover
        if m.medKitPairLos: inc kitLos
      for v in m.medKitNudgePx: kitNudge.add float(v)
      grenPoints += m.grenadeNudgeNeededPx.len
      grenBroken += m.grenadeBroken
      grenUnreach += m.grenadeUnreachable
      if m.grenadeBroken > 0 or m.grenadeUnreachable > 0: inc grenMaps
      for v in m.shieldNudgePx: shieldNudge.add float(v)
      for v in m.sprayNudgePx: sprayNudge.add float(v)
      if m.respawnAreaPx > 0:
        respFrac.add float(m.respawnWithin150) / float(m.respawnAreaPx)
      respMean.add m.respawnMeanDistPx
      capFrac.add m.captureAreaFrac
      lattice.add m.latticeFrac
      if m.teams == 2 and m.seed >= 0 and m.windows < 4: inc winShort

    echo ""
    echo &"SIGHTLINE ROWS (validator's own 4px scan)  n={scanRows}"
    echo &"  open to the VALIDATOR (minWall)  {valOpen:>5}  {pct(valOpen, scanRows)}"
    echo &"  open to VISION (glass see-thru)  {visOpen:>5}  {pct(visOpen, scanRows)}"
    echo &"  rows the glass silently opens    {glassRows:>5}  {pct(glassRows, scanRows)}"
    echo &"  maps with >=1 such row           {mapsWithGlassHole:>5}  " &
      pct(mapsWithGlassHole, rows.len)

    echo ""
    echo &"SIGHTLINE-REPAIR PLUGS  (resolved on {plugMaps}/{rows.len} maps, " &
      &"{plugExactMaps} of them EXACTLY)"
    if plugMaps > 0:
      echo &"  plugs per half-map, mean         {plugsTotal / plugMaps:>5}  " &
        &"(vs {colTotal / plugMaps} column obstacles) = " &
        pct(plugsTotal, plugsTotal + colTotal) & " of seed shapes"
      echo &"  share of ALL interior wall px    " &
        &"p10={percentile(plugFrac, 0.1) * 100:.1f}% " &
        &"p50={percentile(plugFrac, 0.5) * 100:.1f}% " &
        &"p90={percentile(plugFrac, 0.9) * 100:.1f}% " &
        &"mean={meanOf(plugFrac) * 100:.1f}%"
      echo &"   ...EXACT-boundary maps only (n={plugFracExact.len}) " &
        &"p50={percentile(plugFracExact, 0.5) * 100:.1f}% " &
        &"p90={percentile(plugFracExact, 0.9) * 100:.1f}% " &
        &"mean={meanOf(plugFracExact) * 100:.1f}%"
    echo &"  obstacles that SOLELY hold a row {soleTot:>5}  " &
      &"of which plugs {solePlug} ({pct(solePlug, soleTot)})"

    echo ""
    echo &"TRENCHES  maps with >=1: {trMaps}/{rows.len} ({pct(trMaps, rows.len)})" &
      &"  total {trTotal}"
    if trNear.len > 0:
      echo &"  px to nearest wall  p10={percentile(trNear, 0.1):.0f} " &
        &"p50={percentile(trNear, 0.5):.0f} p90={percentile(trNear, 0.9):.0f}"
      echo &"  horizontal open run p10={percentile(trRun, 0.1):.0f} " &
        &"p50={percentile(trRun, 0.5):.0f} p90={percentile(trRun, 0.9):.0f}" &
        &" (as map width: p50={percentile(trRunFrac, 0.5) * 100:.0f}%)"
      echo &"  inside protected endzone floor  {trEz}  {pct(trEz, trTotal)}"
      echo &"  on an obstacle's own x line     {trCol}  {pct(trCol, trTotal)}" &
        "   <- parasitic on the column lattice"

    echo ""
    echo &"PICKUPS"
    if kitMaps > 0:
      echo &"  med-kit pair separation px  p10={percentile(kitPair, 0.1):.0f} " &
        &"p50={percentile(kitPair, 0.5):.0f} p90={percentile(kitPair, 0.9):.0f}" &
        &"  (GunRange {GunRange})"
      var within = 0
      for v in kitPair:
        if v <= float(GunRange): inc within
      echo &"  both kits inside ONE gun range   {within:>5}  {pct(within, kitMaps)}"
      echo &"  one stance sees & covers BOTH    {kitCover:>5}  {pct(kitCover, kitMaps)}"
      echo &"  the two kits see each other      {kitLos:>5}  {pct(kitLos, kitMaps)}"
    echo &"  grenade points in stone/unreachable {grenBroken}/{grenPoints} " &
      &"({pct(grenBroken, grenPoints)}) broken, {grenUnreach} unreachable; " &
      &"maps affected {grenMaps}/{rows.len} ({pct(grenMaps, rows.len)})"
    if shieldNudge.len > 0:
      echo &"  shield nudge px  p50={percentile(shieldNudge, 0.5):.0f} " &
        &"p90={percentile(shieldNudge, 0.9):.0f} " &
        &"max={percentile(shieldNudge, 1.0):.0f}"
      echo &"  spray  nudge px  p50={percentile(sprayNudge, 0.5):.0f} " &
        &"p90={percentile(sprayNudge, 0.9):.0f} " &
        &"max={percentile(sprayNudge, 1.0):.0f}"
      echo &"  medkit nudge px  p50={percentile(kitNudge, 0.5):.0f} " &
        &"p90={percentile(kitNudge, 0.9):.0f} " &
        &"max={percentile(kitNudge, 1.0):.0f}"

    echo ""
    echo &"RESPAWN REGION vs THE STAND IT DEFENDS"
    echo &"  respawn area as map fraction p50={percentile(capFrac, 0.5) * 100:.2f}%" &
      &"  (p10={percentile(capFrac, 0.1) * 100:.2f}% " &
      &"p90={percentile(capFrac, 0.9) * 100:.2f}%)"
    echo &"  share of respawn area within 150px of the stand " &
      &"p50={percentile(respFrac, 0.5) * 100:.1f}% " &
      &"p90={percentile(respFrac, 0.9) * 100:.1f}%"
    echo &"  mean respawn distance to the stand px p50={percentile(respMean, 0.5):.0f}" &
      &" (p10={percentile(respMean, 0.1):.0f} p90={percentile(respMean, 0.9):.0f})"

    var cand, candUse = 0
    for m in rows:
      cand += m.candidates
      candUse += m.candidatesUseful
    if cand > 0:
      echo ""
      echo &"COUNTERFACTUAL: could a SMARTER selector have done better?"
      echo &"  column obstacles measured as if glass  {cand}"
      echo &"  ...that would clear the useful bar     {candUse}  " &
        pct(candUse, cand) & "   <- the ceiling of the current lattice"

    echo ""
    echo &"ARCHITECTURE"
    echo &"  lattice frac (1 - distinct obstacle x / obstacles) " &
      &"p10={percentile(lattice, 0.1):.2f} p50={percentile(lattice, 0.5):.2f} " &
      &"p90={percentile(lattice, 0.9):.2f}"
    if winShort > 0:
      echo &"  2-team maps with < 4 windows placed {winShort}/{rows.len} " &
        pct(winShort, rows.len) & "  (draw is 2..4 per half => 4..8 total)"

  var ctrlRows: seq[MapRow]
  var ctrlWins: seq[WindowRow]
  var genRows: seq[MapRow]
  var genWins: seq[WindowRow]
  for m in mapRows:
    if m.seed < 0: ctrlRows.add m else: genRows.add m
  for r in winRows:
    if r.seed < 0: ctrlWins.add r else: genWins.add r
  report(ctrlRows, ctrlWins, "CONTROL: hand-authored arena + arena-large")
  report(genRows, genWins, &"GENERATED: seeds {lo}-{hi}, teams={teams}" &
    (if sizeLock.len > 0: ", size=" & sizeLock else: ""))

  ## Per-size-class breakdown of the headline window number, so a defect that
  ## only bites one visibility regime cannot hide inside the pooled mean.
  echo ""
  echo "=== windows by size class (generated only) ==="
  var bySize = initTable[string, seq[WindowRow]]()
  for r in genWins: bySize.mgetOrPut(r.size, @[]).add r
  for k, v in bySize:
    var occl = 0
    var ms: seq[float]
    for r in v:
      if r.minSide < UsefulDepthPx: inc occl
      ms.add float(r.minSide)
    echo &"  {k:<9} n={v.len:<5} occluded {occl:>4} {pct(occl, v.len):<7} " &
      &"median min-side {percentile(ms, 0.5):.0f}px"

  let worst = a.flag("worst", "0").parseInt
  if worst > 0:
    var sorted = genWins
    sorted.sort(proc (x, y: WindowRow): int = cmp(x.minSide, y.minSide))
    echo ""
    echo "=== worst windows (lowest free depth on a side) ==="
    for i in 0 ..< min(worst, sorted.len):
      let r = sorted[i]
      echo &"  {r.mapName:<12} {r.size:<9} {r.kind:<13} {r.provenance:<8} " &
        &"at ({r.cx},{r.cy}) axis={r.axis} depths {r.depthA}/{r.depthB} " &
        &"glassPx={r.glassPx} {r.cls}"
    echo ""
    echo "=== DEAD windows: a pane the protected-floor carve erased ==="
    var deadTotal = 0
    for r in genWins:
      if r.cls != winDead: continue
      inc deadTotal
      if deadTotal <= worst:
        echo &"  {r.mapName:<12} {r.size:<9} {r.kind:<13} {r.provenance:<8} " &
          &"at ({r.cx},{r.cy}) glassPx=0"
    echo &"  ({deadTotal} dead panes in this batch of {genWins.len})"

when isMainModule:
  main()

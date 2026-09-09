## mapgen_partition — Poisson-disk seeding and a convex Voronoi partition.
##
## The SKELETON half of the generator: it decides where the rooms are, and
## nothing here draws a pixel.
##
## WHY VORONOI, AND WHY IT IS CHEAP HERE
##
## A Voronoi cell is an intersection of half-planes, so it is convex, so every
## operation the generator needs is a half-plane operation:
##
##   * the cell itself   — clip the board rectangle by one bisector per site
##   * inward offsetting — re-intersect the SAME planes, each shifted by d
##   * "does this shape fit inside" — signed distance to each plane
##
## That is why there is no CGAL here and no straight-skeleton: the hard cases
## of polygon offsetting (self-intersection, topology changes) only exist for
## non-convex input. `insetCell` is twelve lines and exact enough that
## `fitsInside` can be used as a PRECONDITION rather than a validator.
##
## WHY NOT BOWYER-WATSON. The brief warns that symmetric seed sets are
## saturated with exact cocircularities — the adversarial input for Delaunay —
## and prescribes an int64-exact incircle. Computing the cells by direct
## half-plane clipping sidesteps the predicate entirely: a cocircular
## quadruple produces a zero-length Voronoi edge rather than an inconsistent
## triangulation, and `MinEdgePx` drops it. The one place a degeneracy could
## still bite is the ADJACENCY graph (is this a real neighbour or a
## coincidence?), and that is decided by shared-edge LENGTH, which is a
## quantity rather than a predicate. Fairness does not depend on any of this:
## the generator draws only inside the fundamental domain and `arena` lifts
## the integer shapes exactly, so a float wobble of 1e-9 in a cell boundary
## cannot make the two teams' walls differ.

import std/[math]
import sim_types

type
  PtF* = object
    x*, y*: float

  ConvexCell* = object
    ## One Voronoi cell, as a CCW convex ring plus, for each edge, the site
    ## index on the other side of it. `owner[i]` describes the edge that runs
    ## from `poly[i]` to `poly[i+1]`; -1 means the board boundary.
    ##
    ## Keeping the owner tag THROUGH the inset is the whole reason the room
    ## builder can say "this wall faces the cell next door, so it gets a
    ## doorway" without re-deriving adjacency from geometry.
    site*: MapPoint
    siteIndex*: int
    poly*: seq[PtF]
    owner*: seq[int]

const
  MinEdgePx* = 6.0
    ## Shorter than this and a shared edge is a degeneracy, not a doorway.
  Eps = 1e-9

func pt*(x, y: float): PtF {.inline.} = PtF(x: x, y: y)
func pt*(p: MapPoint): PtF {.inline.} = PtF(x: float(p.x), y: float(p.y))

func dist*(a, b: PtF): float {.inline.} =
  sqrt((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y))

func rectPoly*(r: MapRect): seq[PtF] =
  ## The board rectangle as a CCW ring (positive shoelace with y pointing
  ## down, which is the winding every routine below assumes).
  @[pt(float(r.x), float(r.y)),
    pt(float(r.x + r.w), float(r.y)),
    pt(float(r.x + r.w), float(r.y + r.h)),
    pt(float(r.x), float(r.y + r.h))]

# ---------------------------------------------------------------------------
# Half-plane clipping
# ---------------------------------------------------------------------------

proc clipHalfPlane*(poly: var seq[PtF], owner: var seq[int],
                    nx, ny, c: float, tag: int) =
  ## Sutherland-Hodgman against `nx*x + ny*y <= c`, carrying the per-edge
  ## owner tag through. The edge INTRODUCED by the cut is tagged `tag`; every
  ## surviving edge keeps the tag it had. A convex ring crosses a line at most
  ## twice, so exactly one new edge is ever created.
  if poly.len == 0: return
  var
    outPts: seq[PtF]
    outOwn: seq[int]
  let n = poly.len
  for i in 0 ..< n:
    let
      a = poly[i]
      b = poly[(i + 1) mod n]
      o = owner[i]
      da = nx * a.x + ny * a.y - c
      db = nx * b.x + ny * b.y - c
    if da <= Eps:
      outPts.add a
      outOwn.add o
      if db > Eps:
        let t = da / (da - db)
        outPts.add pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        outOwn.add tag
    elif db <= Eps:
      let t = da / (da - db)
      outPts.add pt(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
      outOwn.add o
  ## Drop vertices that collapsed onto their predecessor. Left in, they make
  ## zero-length edges whose normal is undefined, and every consumer here
  ## takes an edge normal.
  var
    keptPts: seq[PtF]
    keptOwn: seq[int]
  for i in 0 ..< outPts.len:
    let prev = if keptPts.len > 0: keptPts[^1] else: outPts[^1]
    if outPts.len > 1 and dist(prev, outPts[i]) < 1e-6:
      continue
    keptPts.add outPts[i]
    keptOwn.add outOwn[i]
  if keptPts.len < 3:
    poly.setLen(0)
    owner.setLen(0)
  else:
    poly = keptPts
    owner = keptOwn

func edgeNormal*(a, b: PtF): tuple[nx, ny, c: float] =
  ## Outward normal of the CCW edge a -> b, and the offset that puts the
  ## interior at `nx*x + ny*y <= c`.
  let
    dx = b.x - a.x
    dy = b.y - a.y
    len = sqrt(dx * dx + dy * dy)
  if len < 1e-9:
    return (0.0, 0.0, 0.0)
  let
    nx = dy / len
    ny = -dx / len
  (nx, ny, nx * a.x + ny * a.y)

# ---------------------------------------------------------------------------
# The partition
# ---------------------------------------------------------------------------

proc voronoiCells*(sites: openArray[MapPoint], bounds: MapRect): seq[ConvexCell] =
  ## Every site's cell, clipped to `bounds`. O(n^2) half-plane clips; n here
  ## is a few dozen sites, so the whole partition costs microseconds and the
  ## simplicity is worth far more than an O(n log n) sweep would be.
  for i in 0 ..< sites.len:
    var
      poly = rectPoly(bounds)
      owner = @[-1, -1, -1, -1]
    let si = sites[i]
    for j in 0 ..< sites.len:
      if j == i: continue
      let sj = sites[j]
      if sj.x == si.x and sj.y == si.y: continue
      ## Bisector: |z - si|^2 <= |z - sj|^2  <=>  2(sj - si).z <= |sj|^2 - |si|^2
      let
        nx = float(2 * (sj.x - si.x))
        ny = float(2 * (sj.y - si.y))
        c = float(sj.x * sj.x + sj.y * sj.y - si.x * si.x - si.y * si.y)
      clipHalfPlane(poly, owner, nx, ny, c, j)
      if poly.len == 0: break
    result.add ConvexCell(site: si, siteIndex: i, poly: poly, owner: owner)

proc insetCell*(cell: ConvexCell, d: float): ConvexCell =
  ## The cell shrunk by `d` on every side, owner tags preserved. Offsetting a
  ## convex polygon inward IS re-intersecting its own half-planes shifted by
  ## d — the operation that is genuinely hard on a non-convex ring and
  ## trivial here. Returns an empty poly when the cell is too small to
  ## survive, which is the signal to leave that cell as street.
  result.site = cell.site
  result.siteIndex = cell.siteIndex
  if cell.poly.len < 3: return
  var
    x0 = cell.poly[0].x
    x1 = cell.poly[0].x
    y0 = cell.poly[0].y
    y1 = cell.poly[0].y
  for p in cell.poly:
    x0 = min(x0, p.x); x1 = max(x1, p.x)
    y0 = min(y0, p.y); y1 = max(y1, p.y)
  var
    poly = rectPoly(MapRect(x: int(x0) - 4, y: int(y0) - 4,
                            w: int(x1 - x0) + 8, h: int(y1 - y0) + 8))
    owner = @[-2, -2, -2, -2]
  for i in 0 ..< cell.poly.len:
    let
      a = cell.poly[i]
      b = cell.poly[(i + 1) mod cell.poly.len]
      (nx, ny, c) = edgeNormal(a, b)
    if nx == 0.0 and ny == 0.0: continue
    clipHalfPlane(poly, owner, nx, ny, c - d, cell.owner[i])
    if poly.len == 0: return
  ## Any surviving `-2` edge is a bounding-box artefact, which can only
  ## happen if the source ring was degenerate. Treat it as boundary.
  for i in 0 ..< owner.len:
    if owner[i] == -2: owner[i] = -1
  result.poly = poly
  result.owner = owner

# ---------------------------------------------------------------------------
# Convex-cell queries
# ---------------------------------------------------------------------------

proc insetCellEdges*(cell: ConvexCell, dInner, dBoundary: float): ConvexCell =
  ## `insetCell` with a per-edge distance: `dInner` where the edge faces a
  ## neighbouring cell, `dBoundary` where it is the board border.
  ##
  ## The boundary case is not a detail. A cell inset on its border edge leaves
  ## a clear lane hugging the map edge — and the hard validator's very first
  ## horizontal scan row sits two pixels inside the border, so that lane is
  ## an instant rejection. Structures on the rim must run right up to it;
  ## there is no neighbour there to make room for.
  result.site = cell.site
  result.siteIndex = cell.siteIndex
  if cell.poly.len < 3: return
  var
    x0 = cell.poly[0].x
    x1 = cell.poly[0].x
    y0 = cell.poly[0].y
    y1 = cell.poly[0].y
  for p in cell.poly:
    x0 = min(x0, p.x); x1 = max(x1, p.x)
    y0 = min(y0, p.y); y1 = max(y1, p.y)
  var
    poly = rectPoly(MapRect(x: int(x0) - 4, y: int(y0) - 4,
                            w: int(x1 - x0) + 8, h: int(y1 - y0) + 8))
    owner = @[-1, -1, -1, -1]
  for i in 0 ..< cell.poly.len:
    let
      a = cell.poly[i]
      b = cell.poly[(i + 1) mod cell.poly.len]
      (nx, ny, c) = edgeNormal(a, b)
    if nx == 0.0 and ny == 0.0: continue
    let d = if cell.owner[i] < 0: dBoundary else: dInner
    clipHalfPlane(poly, owner, nx, ny, c - d, cell.owner[i])
    if poly.len == 0: return
  result.poly = poly
  result.owner = owner

func area*(cell: ConvexCell): float =
  if cell.poly.len < 3: return 0.0
  var s = 0.0
  for i in 0 ..< cell.poly.len:
    let
      a = cell.poly[i]
      b = cell.poly[(i + 1) mod cell.poly.len]
    s += a.x * b.y - b.x * a.y
  abs(s) * 0.5

func centroid*(cell: ConvexCell): PtF =
  if cell.poly.len == 0: return pt(float(cell.site.x), float(cell.site.y))
  var
    cx, cy, s = 0.0
  for i in 0 ..< cell.poly.len:
    let
      a = cell.poly[i]
      b = cell.poly[(i + 1) mod cell.poly.len]
      cross = a.x * b.y - b.x * a.y
    s += cross
    cx += (a.x + b.x) * cross
    cy += (a.y + b.y) * cross
  if abs(s) < 1e-9:
    return pt(float(cell.site.x), float(cell.site.y))
  pt(cx / (3.0 * s), cy / (3.0 * s))

func bbox*(cell: ConvexCell): MapRect =
  if cell.poly.len == 0: return MapRect()
  var
    x0 = cell.poly[0].x
    x1 = cell.poly[0].x
    y0 = cell.poly[0].y
    y1 = cell.poly[0].y
  for p in cell.poly:
    x0 = min(x0, p.x); x1 = max(x1, p.x)
    y0 = min(y0, p.y); y1 = max(y1, p.y)
  MapRect(x: int(floor(x0)), y: int(floor(y0)),
          w: int(ceil(x1)) - int(floor(x0)) + 1,
          h: int(ceil(y1)) - int(floor(y0)) + 1)

func clearance*(cell: ConvexCell, x, y: float): float =
  ## Signed distance from a point to the nearest edge: positive inside. This
  ## is what makes `fitsInside` a precondition instead of a rasterised test —
  ## a disc of radius R fits iff the clearance at its centre is >= R.
  if cell.poly.len < 3: return -1.0
  result = 1.0e9
  for i in 0 ..< cell.poly.len:
    let
      a = cell.poly[i]
      b = cell.poly[(i + 1) mod cell.poly.len]
      (nx, ny, c) = edgeNormal(a, b)
    if nx == 0.0 and ny == 0.0: continue
    result = min(result, c - (nx * x + ny * y))

func contains*(cell: ConvexCell, x, y: float, margin = 0.0): bool {.inline.} =
  cell.clearance(x, y) >= margin

func inradius*(cell: ConvexCell): float =
  ## Radius of the largest inscribed disc, approximated at the centroid. Good
  ## enough for "can this cell host a structure at all" and exact for the
  ## regular-ish cells maximal Poisson-disk sampling produces.
  let c = cell.centroid()
  max(0.0, cell.clearance(c.x, c.y))

func edgeCount*(cell: ConvexCell): int {.inline.} = cell.poly.len

func edge*(cell: ConvexCell, i: int): tuple[a, b: PtF, owner: int] =
  (cell.poly[i], cell.poly[(i + 1) mod cell.poly.len], cell.owner[i])

func edgeLen*(cell: ConvexCell, i: int): float {.inline.} =
  dist(cell.poly[i], cell.poly[(i + 1) mod cell.poly.len])

func neighbours*(cell: ConvexCell): seq[int] =
  ## Site indices sharing a REAL edge with this cell — the Delaunay dual,
  ## read off the partition rather than triangulated. An edge shorter than
  ## `MinEdgePx` is a cocircularity artefact and is not an adjacency.
  for i in 0 ..< cell.poly.len:
    if cell.owner[i] >= 0 and cell.edgeLen(i) >= MinEdgePx and
        cell.owner[i] notin result:
      result.add cell.owner[i]

func toShape*(cell: ConvexCell): ArenaShape =
  ## The cell as an integer-vertex polygon obstacle. Rounding happens HERE and
  ## nowhere else, so a shape and its mirror image rasterize to exactly
  ## mirrored masks (`arena.pointInPolygon` is integer even-odd).
  var pts: seq[MapPoint]
  for p in cell.poly:
    pts.add MapPoint(x: int(round(p.x)), y: int(round(p.y)))
  ArenaShape(kind: shapePolygon, points: pts)

func quadShape*(a, b, c, d: PtF, window = false): ArenaShape =
  ArenaShape(kind: shapePolygon, window: window, points: @[
    MapPoint(x: int(round(a.x)), y: int(round(a.y))),
    MapPoint(x: int(round(b.x)), y: int(round(b.y))),
    MapPoint(x: int(round(c.x)), y: int(round(c.y))),
    MapPoint(x: int(round(d.x)), y: int(round(d.y)))])

# ---------------------------------------------------------------------------
# Poisson-disk sampling (Bridson)
# ---------------------------------------------------------------------------

type
  PoissonRng* = object
    ## A tiny splitmix stream. The generator's real randomness comes from
    ## `map_seed`; this exists so the sampler can be tested in isolation and
    ## so it never has to know which scene it is running inside.
    state*: uint64

proc initPoissonRng*(seed: uint64): PoissonRng =
  PoissonRng(state: seed xor 0x9E3779B97F4A7C15'u64)

proc next*(r: var PoissonRng): uint64 =
  r.state = r.state + 0x9E3779B97F4A7C15'u64
  var z = r.state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc uniform*(r: var PoissonRng): float =
  float(r.next() shr 11) / float(1'u64 shl 53)

proc poissonDisk*(rng: var PoissonRng, region: MapRect, radius: float,
                  pre: openArray[MapPoint], k = 24): seq[MapPoint] =
  ## Bridson's maximal Poisson-disk sampling, seeded with points that are
  ## accepted UNCONDITIONALLY (`pre`).
  ##
  ## Maximality is the reason this and not jittered-grid or plain uniform: it
  ## bounds the partition from both sides at once. No two sites are closer
  ## than r, so every Voronoi cell contains a disc of radius r/2; and no point
  ## of the domain is further than r from a site, so no cell contains a disc
  ## of radius greater than r. ONE scalar therefore sets room scale, street
  ## length and the longest straight edge — which is what lets the room
  ## builder derive its wall thickness and door width from `lanePitchPx`
  ## instead of from taste.
  ##
  ## The pre-seeded points are exempt from the spacing rule on purpose: the
  ## mirror axis must be seeded at spacing BELOW r (see `mapgen_sym.axisX`),
  ## and a pedestal sits where it sits.
  let
    cellSize = radius / sqrt(2.0)
    cols = max(1, int(float(region.w) / cellSize) + 1)
    rows = max(1, int(float(region.h) / cellSize) + 1)
  ## A grid BUCKET, not a single slot. Pre-seeds are exempt from the spacing
  ## rule, so two of them can land in one accelerator cell — and a
  ## single-slot grid would silently forget one of them, which is a
  ## spacing violation the sampler could never see.
  var grid = newSeq[seq[int]](cols * rows)

  proc gridIndex(p: MapPoint): int =
    let
      c = clamp(int(float(p.x - region.x) / cellSize), 0, cols - 1)
      r = clamp(int(float(p.y - region.y) / cellSize), 0, rows - 1)
    r * cols + c

  proc farEnough(pts: seq[MapPoint], p: MapPoint): bool =
    let
      c = clamp(int(float(p.x - region.x) / cellSize), 0, cols - 1)
      r = clamp(int(float(p.y - region.y) / cellSize), 0, rows - 1)
    for rr in max(0, r - 2) .. min(rows - 1, r + 2):
      for cc in max(0, c - 2) .. min(cols - 1, c + 2):
        for idx in grid[rr * cols + cc]:
          let
            q = pts[idx]
            dx = float(q.x - p.x)
            dy = float(q.y - p.y)
          if dx * dx + dy * dy < radius * radius: return false
    true

  var active: seq[int]
  for p in pre:
    if p.x < region.x or p.y < region.y or
        p.x >= region.x + region.w or p.y >= region.y + region.h: continue
    result.add p
    grid[gridIndex(p)].add result.len - 1
    active.add result.len - 1
  if result.len == 0:
    let start = MapPoint(
      x: region.x + int(rng.uniform() * float(region.w)),
      y: region.y + int(rng.uniform() * float(region.h)))
    result.add start
    grid[gridIndex(start)].add 0
    active.add 0

  while active.len > 0:
    let
      pick = int(rng.uniform() * float(active.len))
      idx = active[min(pick, active.len - 1)]
      origin = result[idx]
    var placed = false
    for _ in 0 ..< k:
      let
        ang = rng.uniform() * 2.0 * PI
        rad = radius * (1.0 + rng.uniform())
        cand = MapPoint(x: origin.x + int(cos(ang) * rad),
                        y: origin.y + int(sin(ang) * rad))
      if cand.x < region.x or cand.y < region.y or
          cand.x >= region.x + region.w or cand.y >= region.y + region.h:
        continue
      if not farEnough(result, cand): continue
      result.add cand
      grid[gridIndex(cand)].add result.len - 1
      active.add result.len - 1
      placed = true
      break
    if not placed:
      let at = active.find(idx)
      if at >= 0: active.del at

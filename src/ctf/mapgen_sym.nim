## mapgen_sym — ONE definition of the symmetry a generated map is lifted by.
##
## Two of the three team-fairness bugs this session shipped were the SAME bug:
## a reflection written out by hand at a second site, `width - x` where the
## first site said `width - 1 - x`, and an anchor taken at `size div 2` whose
## mirror differs by one on an even-sided board. Both were silent until
## something landed on the boundary, and both were hidden by a green test.
##
## So this module exists to make that class of bug unwriteable. The reflection
## is defined EXACTLY ONCE (`reflectX`), everything else is expressed in terms
## of it, and `tests/test_mapgen_sym.nim` pins the point orbit against
## `arena`'s independently written SHAPE transforms — the two must agree on a
## 1x1 shape at every pixel of the boundary, on both parities of board size.
##
## It is also the seam the hex epic (`800a5789`) plugs into. The generator
## partitions a FUNDAMENTAL DOMAIN and lifts by an orbit; a D6 group is one
## more `SymGroupKind` here plus a domain rect, not a rewrite of the
## partitioner. That costs nothing today and is why the partition and lift
## stages take a `SymGroup` rather than a `MapSymmetry`.

import sim_types

type
  SymGroup* = object
    ## The symmetry group of one board, closed over its dimensions. Carrying
    ## width/height is the point: a reflection is not a property of a map
    ## symmetry, it is a property of a symmetry ON a board of a given size,
    ## and every off-by-one in this family came from separating the two.
    kind*: MapSymmetry
    width*, height*: int

func symGroup*(gameMap: CtfMap): SymGroup {.inline.} =
  SymGroup(kind: gameMap.symmetry, width: gameMap.width, height: gameMap.height)

func symGroup*(kind: MapSymmetry, width, height: int): SymGroup {.inline.} =
  SymGroup(kind: kind, width: width, height: height)

func reflectX*(g: SymGroup, x: int): int {.inline.} =
  ## THE definition of the horizontal reflection. Every mirror in this
  ## generator routes through this function; nothing else may spell it out.
  g.width - 1 - x

func reflectY*(g: SymGroup, y: int): int {.inline.} =
  g.height - 1 - y

func quarterTurn*(g: SymGroup, p: MapPoint): MapPoint {.inline.} =
  ## One clockwise quarter turn about the centre of a square board, matching
  ## `arena.rot90Point` exactly: (x, y) -> (side - 1 - y, x).
  MapPoint(x: g.width - 1 - p.y, y: p.x)

func orbitOrder*(g: SymGroup): int {.inline.} =
  ## How many images a GENERIC point has. Points on the fixed set have fewer,
  ## which is what `isFixed` reports and why `orbit` deduplicates.
  case g.kind
  of symMirror, symRot180: 2
  of symRot90: 4

func image*(g: SymGroup, p: MapPoint, k: int): MapPoint =
  ## The k-th image of a point; k = 0 is the identity.
  result = p
  case g.kind
  of symMirror:
    if k mod 2 != 0:
      result = MapPoint(x: g.reflectX(p.x), y: p.y)
  of symRot180:
    if k mod 2 != 0:
      result = MapPoint(x: g.reflectX(p.x), y: g.reflectY(p.y))
  of symRot90:
    for _ in 0 ..< (k mod 4):
      result = g.quarterTurn(result)

func orbit*(g: SymGroup, p: MapPoint): seq[MapPoint] =
  ## A point's full orbit, original first, deduplicated. A seed ON the fixed
  ## set therefore contributes ONE site, not two coincident ones — which
  ## matters, because two coincident Voronoi sites have an undefined bisector.
  for k in 0 ..< g.orbitOrder():
    let q = g.image(p, k)
    if q notin result:
      result.add q

func isFixed*(g: SymGroup, p: MapPoint): bool {.inline.} =
  ## True when the point sits on the group's fixed set (the mirror axis, the
  ## rotation centre). These are the points the partition MUST seed: see
  ## `axisSeeds`.
  g.orbit(p).len < g.orbitOrder()

func domain*(g: SymGroup): MapRect =
  ## The fundamental domain: the sub-board the generator writes into, whose
  ## orbit tiles the whole board. Half-open on the far side EXCEPT that an odd
  ## board's centre column/row belongs to it (it is its own image, so drawing
  ## it twice is idempotent and leaving it out would leave a 1px seam).
  case g.kind
  of symMirror, symRot180:
    MapRect(x: 0, y: 0, w: (g.width + 1) div 2, h: g.height)
  of symRot90:
    MapRect(x: 0, y: 0, w: (g.width + 1) div 2, h: (g.height + 1) div 2)

func inRectPt*(p: MapPoint, r: MapRect): bool {.inline.} =
  ## `arena.inRect` for a point. Spelled here so this module stays a LEAF —
  ## `arena` imports the generator, so the generator cannot import `arena`.
  p.x >= r.x and p.x < r.x + r.w and p.y >= r.y and p.y < r.y + r.h

func inDomain*(g: SymGroup, x, y: int): bool {.inline.} =
  inRectPt(MapPoint(x: x, y: y), g.domain())

func axisX*(g: SymGroup): int {.inline.} =
  ## The last column of the fundamental domain — the one the mirror axis runs
  ## through (odd board) or immediately beside (even board).
  ##
  ## ⚠️ This is the column the partition MUST seed. A mirror axis is a Voronoi
  ## EDGE unless a seed sits on it: every point of the axis is equidistant
  ## from a seed and its image, so an unseeded axis puts a perfectly straight
  ## full-board corridor down the middle of every 2-team map. Seeding it makes
  ## the axis interior to a cell instead, and the only Voronoi edges that meet
  ## it run PERPENDICULAR to it.
  let d = g.domain()
  d.x + d.w - 1

func axisSeeds*(g: SymGroup, spacingPx: int, y0, y1: int): seq[MapPoint] =
  ## Seeds along the axis column at spacing < r, which is what makes the
  ## on-axis cells provably cover the axis.
  let
    x = g.axisX()
    step = max(8, spacingPx)
  var y = y0
  while y <= y1:
    result.add MapPoint(x: x, y: y)
    y += step
  if result.len > 0 and result[^1].y < y1 - step div 2:
    result.add MapPoint(x: x, y: y1)

func liftSites*(g: SymGroup, domainSites: openArray[MapPoint]): seq[MapPoint] =
  ## The full board's site set: every domain seed's orbit, deduplicated. The
  ## partition is computed against THIS, so a cell's shape near the seam is
  ## the true one (bounded by the bisector against its own mirror image) and
  ## not an artefact of clipping to the domain rectangle.
  ##
  ## The domain's own seeds come FIRST and in order, so site index i < the
  ## domain seed count names domain seed i. The generator relies on that to
  ## know which cells it owns; interleaving the images (which the obvious
  ## `for p: for q in orbit(p)` does) silently makes every second cell someone
  ## else's, and the map draws its terrain into half the board.
  ##
  ## `domainSites` must already be duplicate-free — dedup here would shift the
  ## very indices the contract above is about.
  for p in domainSites:
    result.add p
  for p in domainSites:
    for k in 1 ..< g.orbitOrder():
      let q = g.image(p, k)
      if q notin result:
        result.add q

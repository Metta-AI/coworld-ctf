## mapgen_rooms — the ROOM generator: skeleton first, fill second, on disjoint
## pixel sets.
##
## This is the replacement for the column lattice, built as a parallel track:
## `arena.generateMapAttempt` still draws the shipping map, this module draws
## a candidate, and `tools/map_bench.nim` measures the two against the
## hand-authored `arena` control so the swap can be an EVIDENCE decision.
##
## ---------------------------------------------------------------------------
## THE ONE IDEA
## ---------------------------------------------------------------------------
##
## The invariants split into two families with OPPOSITE monotonicity:
##
##   * route count rises only when you OPEN floor
##   * cover and sightline-blocking rise only when you ADD walls
##
## The old pipeline oscillates between them — `burrow`'s cheapest-path dig is a
## straight-corridor generator (a sightline adversary), the plug pass narrows
## corridors (a route adversary), and nothing re-checks either. Here each
## family gets its own pixels:
##
##   STREETS  = the board MINUS the inset Voronoi cells. Never walled. Ever.
##   ROOMS    = the inset cells. Every wall this module writes lives inside
##              one, enforced by `fitsInCell`, which is a half-plane distance
##              test and therefore a PRECONDITION rather than a validator.
##
## Because the two sets are disjoint, adding cover cannot remove a route and
## opening a route cannot remove cover. Both hold with zero search.
##
## ---------------------------------------------------------------------------
## THE FUNDAMENTAL SET IS A SET OF CELLS, NOT A RECTANGLE
## ---------------------------------------------------------------------------
##
## The site set is closed under the symmetry group (`mapgen_sym.liftSites`), so
## the Voronoi diagram is too, so the GROUP PERMUTES THE CELLS. Drawing in the
## cell of every domain seed and letting `arena.buildArenaObstacles` add the
## images therefore covers every cell exactly once — even when a cell bulges
## across the seam, which rot180 cells routinely do and which clipping to a
## half-board rectangle would have mangled. Exact fairness is structural: the
## only integer rounding happens in `mapgen_partition.toShape`, and `arena`'s
## integer mirror is exact from there on.
##
## The one case that needs care is a cell that is its OWN image (an on-axis
## seed under mirror symmetry). Its ring would be unioned with the ring's
## mirror, and a doorway on one side would be sealed by wall from the other.
## So a self-image cell never gets a ring: it gets free-standing cover, either
## centred on the axis (its own mirror) or clear of it by half a corridor.
## That is also what finally puts architecture at midfield, which 52% of the
## old generator's 2-team maps had none of.
##
## ---------------------------------------------------------------------------
## WHY THE SIGHTLINE PROSTHETIC IS GONE
## ---------------------------------------------------------------------------
##
## `arena.nim`'s `block sightlineRepair` drops r28 diamonds at random column x
## until no 4px row is unblocked — 14-16% of a standard board's interior wall,
## placed with no regard for play. The constructive replacement is two facts:
##
##   1. A closed CONVEX ring covers every row of its own y-extent, because a
##      horizontal line meets a convex curve exactly twice.
##   2. Those two crossings sit on the ring's WEST-facing and EAST-facing
##      chains respectively. So a row is lost only if a west door and an east
##      door overlap in y — and `planDoorways` simply refuses that overlap.
##
## Room selection is then a 1-D greedy INTERVAL COVER over the validator's own
## scan band. Nothing is retried, nothing is guessed. `RoomStats.screenPx`
## reports what is left over; the acceptance bar is that it stays zero.

import std/[algorithm, math, random, sets, strutils]
import sim_types, arena, map_rules, map_seed, map_metrics,
       mapgen_sym, mapgen_partition, mapgen_vocab, mapgen_biomes

export mapgen_sym, mapgen_partition

# ---------------------------------------------------------------------------
# Style: the diversity engine
# ---------------------------------------------------------------------------

type
  RoomArchetype* = enum
    ## A whole-map character. The single most important lesson from the
    ## defect audit is that fifty maps drawn from one recipe are ONE map, so
    ## the recipe itself is a draw. Each archetype moves room scale, wall
    ## weight, door count and the fill vocabulary together, because moving one
    ## of them alone just re-skins the same slot.
    raCompound     ## few big fortress blocks, thick walls, few doors
    raWarrens      ## small cells, thin walls, many doors, dense
    raQuarry       ## organic masses, hardly any orthogonal wall
    raTerraces     ## halls that all open the same way + long screens
    raBazaar       ## plazas with clustered cover, a couple of rings

  CellRole* = enum
    crStreet       ## nothing; the cell IS street
    crApron        ## overlaps protected floor: light cover only
    crRing         ## closed ring with doorways — a room
    crHall         ## ring with one whole side missing — a U
    crBlocks       ## a few solid masses, enclosure from the gaps
    crPlaza        ## open, a little scattered cover
    crRubble       ## biome terrain, clipped to the cell

  RoomStyle* = object
    archetype*: RoomArchetype
    pitchPx*: int         ## Poisson radius: THE scale knob
    insetPx*: int         ## half the street width
    wallPx*: int          ## ring thickness
    doorPx*: int          ## doorway width
    coverPermille*: int   ## target, inside the validator's 40..170 band
    biome*: BiomeStyle
    vocab*: seq[VocabItem]
    ringBias*: int        ## percent of spare capable cells that get a ring
    hallBias*: int
    rubbleBias*: int
    glassPanes*: int
    trenchRuns*: int

  Placement* = object
    ## One obstacle plus the audit trail that justifies it. `serves` is
    ## mandatory at the call site: "placed but pointless" is the failure this
    ## generator exists to make unwriteable, and the ledger is what makes it
    ## auditable after the fact.
    shape*: ArenaShape
    cell*: int
    serves*: string
    screen*: bool         ## a pure sightline-cover piece; see RoomStats

  Post* = object
    claim*: string
    check*: proc(): bool {.closure.}

  RoomStats* = object
    cells*, rings*, halls*, blocks*, plazas*, rubble*, aprons*: int
    wallPx*, screenPx*: int
    coverPermille*: int
    doorways*: int
    skeletonRoutes*: int
    uncoveredRows*: int
    glassPanes*, glassRejected*: int
    brokenPosts*: seq[string]

  RoomBoard* = ref object
    gameMap*: CtfMap
    sym*: SymGroup
    style*: RoomStyle
    allCells*: seq[ConvexCell]      ## every site's cell, whole board
    allInset*: seq[ConvexCell]      ## the same, shrunk by insetPx
    mine*: seq[int]                 ## indices this domain owns (draws in)
    role*: seq[CellRole]            ## parallel to allCells
    placements*: seq[Placement]
    doorRects*: seq[MapRect]
    budgetPx*, spentPx*: int
    notes*: seq[string]
    posts*: seq[Post]
    stats*: RoomStats

const
  MinRingInradius = 62.0
    ## Below this a cell cannot hold a ring that leaves a walkable interior:
    ## wall + door clearance + a body's width on the inside.
  ScanStep = 4
    ## The validator's own horizontal-ray sampling period. Matching it exactly
    ## is deliberate — the interval cover must cover the rows that are checked,
    ## not a finer set nobody looks at.
  SkeletonCellPx = RouteCellPx
    ## ⚠️ 26, the METRIC's grid, not `burrow`'s 8px one. Two corridors disjoint
    ## in an 8px grid can share a 26px metric cell, and a disjointness proof on
    ## the wrong grid is a proof about a different graph.
  WantRoutes = 3
    ## The design intent. The validator only enforces `routeCountMin >= 2`;
    ## this generator rejects its own candidate below 3 rather than shipping
    ## the enforced floor.
  UsefulWindowPx = 200
    ## `tools/mapgen_defect_probe.nim`'s bar: a pane is worth building only if
    ## a shot through it reaches 200px of open ground on BOTH sides. Measured
    ## here BEFORE glazing rather than hoped for afterwards.

proc note(b: RoomBoard, text: string) = b.notes.add text

# ---------------------------------------------------------------------------
# Style draw
# ---------------------------------------------------------------------------

proc drawStyle*(rng: var MapRng, rules: MapRules, teams: int): RoomStyle =
  ## One map's whole character, drawn once. Every number is anchored to
  ## `map_rules` and then jittered, so a size class change moves the rooms and
  ## a taste change moves one multiplier.
  let arch = RoomArchetype(rng.pick(ord(RoomArchetype.high) + 1))
  result.archetype = arch
  let
    basePitch = rules.lanePitchPx
    pitchPct =
      case arch
      of raCompound: rng.pickRange(115, 145)
      of raWarrens: rng.pickRange(62, 80)
      of raQuarry: rng.pickRange(88, 115)
      of raTerraces: rng.pickRange(95, 125)
      of raBazaar: rng.pickRange(78, 100)
  result.pitchPx = max(96, basePitch * pitchPct div 100)
  result.insetPx =
    case arch
    of raWarrens: rng.pickRange(22, 30)
    of raCompound: rng.pickRange(30, 44)
    else: rng.pickRange(26, 38)
  result.wallPx =
    case arch
    of raCompound: rng.pickRange(16, 24)
    of raWarrens: rng.pickRange(10, 14)
    else: rng.pickRange(12, 18)
  result.doorPx = rng.pickRange(46, 76)
  ## Aim at the middle of the class's own cover band rather than the global
  ## 40..170: `map_rules` derives the band from the mean-free-sightline law,
  ## and the global constants are the standard class's answer to it.
  let
    lo = max(CoverPermilleMin + 10, rules.coverPermilleMin)
    hi = min(CoverPermilleMax - 10, rules.coverPermilleMax)
  result.coverPermille = rng.pickRange(min(lo, hi), max(lo, hi))
  result.biome =
    case arch
    of raQuarry: (if rng.coin(): biomeStyleCaves else: biomeStyleForest)
    of raCompound: biomeStyleCity
    of raWarrens: (if rng.coin(): biomeStyleCity else: biomeStyleDesert)
    of raTerraces: biomeStyleDesert
    of raBazaar: (if rng.coin(): biomeStylePlains else: biomeStyleForest)
  result.vocab =
    case arch
    of raCompound: @[viTemple, viBunker, viCan]
    of raWarrens: @[viCan, viDorito, viBeam]
    of raQuarry: @[viMassif, viCave, viCan]
    of raTerraces: @[viBeam, viSnake, viTemple]
    of raBazaar: @[viBunker, viDorito, viCan, viMassif]
  result.ringBias =
    case arch
    of raCompound: 70
    of raWarrens: 55
    of raQuarry: 15
    of raTerraces: 30
    of raBazaar: 35
  result.hallBias =
    case arch
    of raTerraces: 70
    of raCompound: 20
    else: 30
  result.rubbleBias =
    case arch
    of raQuarry: 70
    of raBazaar: 35
    else: 20
  result.glassPanes = rng.pickRange(2, 5)
  result.trenchRuns = if teams == 2: rng.pickRange(0, 3) else: rng.pickRange(0, 2)

# ---------------------------------------------------------------------------
# Placement primitives — every write goes through here
# ---------------------------------------------------------------------------

proc shapeAreaPx(s: ArenaShape): int =
  case s.kind
  of shapeRect: max(0, s.rect.w) * max(0, s.rect.h)
  of shapeDisc: int(PI * float(s.radius * s.radius))
  of shapeDiamond: 2 * s.radius * s.radius
  of shapeDiagonal:
    let
      dx = float(s.x1 - s.x0)
      dy = float(s.y1 - s.y0)
    int(sqrt(dx * dx + dy * dy) * float(max(1, s.thickness)))
  of shapePolygon:
    var a = 0.0
    for i in 0 ..< s.points.len:
      let
        p = s.points[i]
        q = s.points[(i + 1) mod s.points.len]
      a += float(p.x * q.y - q.x * p.y)
    int(abs(a) * 0.5)

proc fitsInCell*(cell: ConvexCell, s: ArenaShape, margin = 0.0): bool =
  ## Does this shape lie wholly inside a convex cell? Exact, because the cell
  ## is an intersection of half-planes: a point is inside iff its clearance is
  ## non-negative, and a convex hull is inside iff all its vertices are.
  ##
  ## This is the mechanism behind "walls only ever land on room pixels". It is
  ## checked BEFORE the write, so the disjointness of streets and walls is a
  ## precondition of every placement rather than a property somebody hopes for.
  if cell.poly.len < 3: return false
  case s.kind
  of shapeRect:
    let r = s.rect
    for (x, y) in [(r.x, r.y), (r.x + r.w, r.y),
                   (r.x + r.w, r.y + r.h), (r.x, r.y + r.h)]:
      if cell.clearance(float(x), float(y)) < margin: return false
    true
  of shapeDisc, shapeDiamond:
    cell.clearance(float(s.cx), float(s.cy)) >= float(s.radius) + margin
  of shapeDiagonal:
    cell.clearance(float(s.x0), float(s.y0)) >= float(s.thickness) + margin and
      cell.clearance(float(s.x1), float(s.y1)) >= float(s.thickness) + margin
  of shapePolygon:
    for p in s.points:
      if cell.clearance(float(p.x), float(p.y)) < margin: return false
    true

proc rectsOverlap(a, b: MapRect): bool {.inline.} =
  a.x < b.x + b.w and b.x < a.x + a.w and
    a.y < b.y + b.h and b.y < a.y + a.h

proc blocksADoor(b: RoomBoard, s: ArenaShape): bool =
  let (x0, y0, x1, y1) = shapeBounds(s)
  let box = MapRect(x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1)
  for d in b.doorRects:
    if rectsOverlap(box, d): return true
  false

proc place(b: RoomBoard, s: ArenaShape, cell: int, serves: string,
           screen = false): bool {.discardable.} =
  ## THE write. Refuses silently rather than corrupting an invariant, and
  ## every acceptance is one of the two disjoint pixel families by
  ## construction: `fitsInCell` was already checked by the caller for
  ## structural pieces, and the door test keeps a room's own entrances open.
  doAssert serves.len > 0, "every placement must name what it serves"
  let px = shapeAreaPx(s)
  if b.budgetPx > 0 and b.spentPx + px > b.budgetPx: return false
  if b.blocksADoor(s): return false
  b.placements.add Placement(shape: s, cell: cell, serves: serves,
                             screen: screen)
  b.spentPx += px
  if screen: b.stats.screenPx += px
  true

# ---------------------------------------------------------------------------
# Protected-floor probes
# ---------------------------------------------------------------------------

proc cellTouchesProtected(b: RoomBoard, cell: ConvexCell, step = 12): bool =
  ## Does any part of this cell sit on protected floor? A wall there is
  ## deleted by the engine's carve, so a room built on one cannot keep the
  ## sightline promise the interval cover makes on its behalf. Checked BEFORE
  ## the role is chosen, never after the wall is drawn.
  if cell.poly.len < 3: return true
  let bb = cell.bbox()
  var y = bb.y
  while y <= bb.y + bb.h:
    var x = bb.x
    while x <= bb.x + bb.w:
      if cell.contains(float(x), float(y)) and
          b.gameMap.mapProtectedFloorAt(x, y):
        return true
      x += step
    y += step
  ## The vertices too: a thin protected sliver can hide between samples.
  for p in cell.poly:
    if b.gameMap.mapProtectedFloorAt(int(p.x), int(p.y)): return true
  false

proc cellInBoard(b: RoomBoard, cell: ConvexCell): bool =
  let bb = cell.bbox()
  bb.x >= 0 and bb.y >= 0 and
    bb.x + bb.w <= b.gameMap.width and bb.y + bb.h <= b.gameMap.height

# ---------------------------------------------------------------------------
# Rooms: ring + doorways
# ---------------------------------------------------------------------------

type DoorPlan = object
  edge: int
  t0, t1: float      ## span along the edge, in px from its start vertex

proc planDoorways(cell: ConvexCell, style: RoomStyle, rng: var MapRng,
                  maxDoors: int): seq[DoorPlan] =
  ## Choose the openings. THE constraint that replaces the sightline
  ## prosthetic: a horizontal line meets a convex ring exactly twice, once on
  ## the WEST-facing chain and once on the EAST-facing chain, so a row can
  ## only escape if a west door and an east door overlap in y. This refuses
  ## that overlap, which makes "the ring blocks every row of its y-extent" a
  ## property of the geometry instead of a scan somebody runs afterwards.
  var
    westSpans: seq[(float, float)]
    eastSpans: seq[(float, float)]
    candidates: seq[int]
  for i in 0 ..< cell.edgeCount():
    let e = cell.edge(i)
    if e.owner < 0: continue                      ## board boundary: no door
    if cell.edgeLen(i) < float(style.doorPx + 2 * style.wallPx + 24): continue
    candidates.add i
  rng.shuffle(candidates)
  for i in candidates:
    if result.len >= maxDoors: break
    let
      e = cell.edge(i)
      len = cell.edgeLen(i)
      (nx, _, _) = edgeNormal(e.a, e.b)
      slack = len - float(style.doorPx) - 2.0 * float(style.wallPx) - 8.0
      t0 = float(style.wallPx) + 4.0 +
        (if slack > 1.0: float(rng.pick(int(slack))) else: 0.0)
      t1 = t0 + float(style.doorPx)
      ## The door's y-span, which is what the chain rule is about.
      ya = e.a.y + (e.b.y - e.a.y) * (t0 / len)
      yb = e.a.y + (e.b.y - e.a.y) * (t1 / len)
      ylo = min(ya, yb) - 2.0
      yhi = max(ya, yb) + 2.0
    if nx < -0.05:
      var clash = false
      for (a, c) in eastSpans:
        if ylo < c and a < yhi: clash = true
      if clash: continue
      westSpans.add (ylo, yhi)
    elif nx > 0.05:
      var clash = false
      for (a, c) in westSpans:
        if ylo < c and a < yhi: clash = true
      if clash: continue
      eastSpans.add (ylo, yhi)
    result.add DoorPlan(edge: i, t0: t0, t1: t1)

proc wallQuad(a, b: PtF, nx, ny, thick: float): ArenaShape =
  ## One wall segment: the strip of thickness `thick` lying INSIDE the edge
  ## a -> b (the interior is opposite the outward normal).
  let
    ix = -nx * thick
    iy = -ny * thick
  quadShape(a, b, pt(b.x + ix, b.y + iy), pt(a.x + ix, a.y + iy))

proc doorCorridor(mid: PtF, nx, ny: float, doorPx, wallPx: int): MapRect =
  ## The pixels a doorway must keep clear: the opening itself plus a stub of
  ## room on the inside, so the fill pass cannot park a block against a door
  ## it never knew about. Axis-aligned and therefore a conservative superset
  ## of the oriented opening, which is the right direction to be wrong in.
  let
    reach = float(wallPx) + 56.0
    half = float(doorPx) div 2.0 + 10.0
    cx = mid.x - nx * (reach * 0.4)
    cy = mid.y - ny * (reach * 0.4)
    ext = half + reach * 0.6
  MapRect(x: int(cx - ext), y: int(cy - ext),
          w: int(2.0 * ext), h: int(2.0 * ext))

proc buildRing(b: RoomBoard, ci: int, hall: bool, rng: var MapRng) =
  ## A room: thin wall quads along the inset cell's own edges, split around
  ## the doorways. Never fill — a filled cell can seal a pocket, and "thin
  ## borders only" is what makes reachability a property of the drawing rather
  ## than of a flood fill run afterwards.
  let
    cell = b.allInset[ci]
    style = b.style
    thick = float(style.wallPx)
  if cell.poly.len < 3: return
  let
    maxDoors =
      if hall: max(1, cell.edgeCount() - 1)
      else: max(2, min(4, cell.edgeCount() - 1))
    doors = planDoorways(cell, style, rng, maxDoors)
  ## A hall drops one whole side. It is chosen from the edges that face a
  ## NEIGHBOUR (never the board border, which would open the ring onto the
  ## map edge and hand the validator a clear border lane).
  var skipEdge = -1
  if hall:
    var facing: seq[int]
    for i in 0 ..< cell.edgeCount():
      if cell.owner[i] >= 0 and cell.edgeLen(i) >= 40.0: facing.add i
    if facing.len > 0: skipEdge = facing[rng.pick(facing.len)]

  var doorsOnEdge = newSeq[seq[DoorPlan]](cell.edgeCount())
  for d in doors: doorsOnEdge[d.edge].add d

  for i in 0 ..< cell.edgeCount():
    if i == skipEdge: continue
    let
      e = cell.edge(i)
      len = cell.edgeLen(i)
      (nx, ny, _) = edgeNormal(e.a, e.b)
    if len < 8.0 or (nx == 0.0 and ny == 0.0): continue
    let
      dx = (e.b.x - e.a.x) / len
      dy = (e.b.y - e.a.y) / len
    var cuts = doorsOnEdge[i]
    cuts.sort(proc(p, q: DoorPlan): int = cmp(p.t0, q.t0))
    ## Segments run from -thick to len+thick so consecutive walls overlap at
    ## the corners; a ring assembled from exactly-length segments leaves a
    ## mitre-shaped hole at every vertex.
    var cursor = -thick
    for d in cuts:
      if d.t0 - cursor > 6.0:
        let
          p0 = pt(e.a.x + dx * cursor, e.a.y + dy * cursor)
          p1 = pt(e.a.x + dx * d.t0, e.a.y + dy * d.t0)
        discard b.place(wallQuad(p0, p1, nx, ny, thick), ci, "room wall")
      let mid = pt(e.a.x + dx * (d.t0 + d.t1) * 0.5,
                   e.a.y + dy * (d.t0 + d.t1) * 0.5)
      b.doorRects.add doorCorridor(mid, nx, ny, b.style.doorPx, b.style.wallPx)
      inc b.stats.doorways
      cursor = d.t1
    if len + thick - cursor > 6.0:
      let
        p0 = pt(e.a.x + dx * cursor, e.a.y + dy * cursor)
        p1 = pt(e.a.x + dx * (len + thick), e.a.y + dy * (len + thick))
      discard b.place(wallQuad(p0, p1, nx, ny, thick), ci, "room wall")

# ---------------------------------------------------------------------------
# Fill: cover inside the cells, never outside them
# ---------------------------------------------------------------------------

proc clipToCell(b: RoomBoard, ci: int, shapes: seq[ArenaShape],
                serves: string, margin = 2.0): int =
  ## Accept only the pieces that FIT. The vocabulary and biome emitters are
  ## rectangle-shaped APIs — they fill a box — so the cell does the clipping
  ## by rejection. Rejection rather than truncation is deliberate: a truncated
  ## organic mass is a different (and usually worse) shape than the one the
  ## emitter designed.
  let cell = b.allInset[ci]
  for s in shapes:
    if not fitsInCell(cell, s, margin): continue
    if b.place(s, ci, serves): inc result

proc vocabRegion(cell: ConvexCell, shrink: float): MapRect =
  ## The largest axis-aligned box comfortably inside a convex cell: start at
  ## the bbox and pull it in until its corners clear. Cheap, and being a
  ## little small is free — the fitsInCell filter is the real gate.
  let
    c = cell.centroid()
    r = max(0.0, cell.inradius() - shrink)
    half = r * 0.80
  MapRect(x: int(c.x - half), y: int(c.y - half),
          w: max(8, int(2.0 * half)), h: max(8, int(2.0 * half)))

proc fillCell(b: RoomBoard, ci: int, role: CellRole, rules: MapRules,
              rng: var MapRng, vocabRng: var Rand) =
  let
    cell = b.allInset[ci]
    style = b.style
  if cell.poly.len < 3: return
  var vp = vocabParams(rules)
  case role
  of crRing, crHall:
    ## Inside a room: one or two masses, well clear of the walls and of every
    ## doorway (the door rects are checked by `place`). This is what makes the
    ## interior READ as a room rather than as an empty box.
    let region = vocabRegion(cell, float(style.wallPx) + 34.0)
    if region.w < 60 or region.h < 60: return
    let item = style.vocab[rng.pick(style.vocab.len)]
    vp.density = 0.45
    discard b.clipToCell(ci, emitVocab(item, vocabRng, region, vp),
                         "room interior mass")
  of crBlocks:
    let region = vocabRegion(cell, 10.0)
    vp.density = 0.85
    let item = style.vocab[rng.pick(style.vocab.len)]
    discard b.clipToCell(ci, emitVocab(item, vocabRng, region, vp),
                         "block mass")
  of crPlaza:
    ## A plaza earns a LITTLE cover: enough that crossing it is not naked,
    ## little enough that it still reads as open ground.
    let n = 1 + rng.pick(2)
    for _ in 0 ..< n:
      let
        rad = max(16, rules.coverSizePx div 2 - rng.pick(12))
        c = cell.centroid()
        ir = max(1.0, cell.inradius() - float(rad) - 6.0)
        ang = float(rng.pick(628)) / 100.0
        dist = float(rng.pick(max(1, int(ir))))
        cx = int(c.x + cos(ang) * dist)
        cy = int(c.y + sin(ang) * dist)
        s = ArenaShape(kind: shapeDisc, cx: cx, cy: cy, radius: rad)
      if fitsInCell(cell, s, 4.0): discard b.place(s, ci, "plaza cover")
  of crRubble:
    ## Biome terrain, clipped to the cell. Noise is a TEXTURE layer here and
    ## deliberately downstream of structure: a Gaussian excursion set has
    ## strictly positive Euler density at every threshold our cover cap
    ## permits, so it makes blobs, never rooms. Blobs are exactly what a
    ## quarry district wants.
    let bb = cell.bbox()
    if bb.w < 60 or bb.h < 60: return
    var bp = defaultBiomeParams(style.biome)
    bp.cell = max(BiomeCellPx, rules.coverSizePx div 3)
    let dom = FundamentalDomain(
      rect: bb, board: MapRect(x: 0, y: 0, w: b.gameMap.width,
                               h: b.gameMap.height), order: 2)
    discard b.clipToCell(ci, genBiome(vocabRng, style.biome, bb, bp, dom),
                         "rubble", 4.0)
  of crApron:
    ## Cover on the APPROACH to a pedestal. The engine protects the floor
    ## right around a stand, so the only place cover CAN go is the annulus
    ## just outside it — which is exactly where an attacker has to stand.
    ## Measured defect this exists to fix: pool standCover median 1.1%
    ## against the arena's 7.2%.
    var placed = 0
    for _ in 0 ..< 12:
      if placed >= 3: break
      let
        c = cell.centroid()
        rad = 22 + rng.pick(20)
        ir = max(1.0, cell.inradius() - float(rad) - 8.0)
        ang = float(rng.pick(628)) / 100.0
        dist = float(rng.pick(max(1, int(ir))))
        cx = int(c.x + cos(ang) * dist)
        cy = int(c.y + sin(ang) * dist)
        s = ArenaShape(kind: shapeDisc, cx: cx, cy: cy, radius: rad)
      if not fitsInCell(cell, s, 8.0): continue
      if b.gameMap.mapProtectedFloorAt(cx, cy): continue
      ## Keep a corridor between apron pieces, or an apron cell can pinch the
      ## street network it sits on. This is a CHECK, not a guarantee — stated
      ## plainly, and the validator's eroded flood is the backstop.
      var tooClose = false
      for p in b.placements:
        if p.cell != ci: continue
        if p.shape.kind == shapeDisc:
          let
            dx = p.shape.cx - cx
            dy = p.shape.cy - cy
          if dx * dx + dy * dy <
              (p.shape.radius + rad + rules.minCorridorWidthPx) *
              (p.shape.radius + rad + rules.minCorridorWidthPx):
            tooClose = true
      if tooClose: continue
      if b.place(s, ci, "cover on the stand approach"): inc placed
  of crStreet: discard

# ---------------------------------------------------------------------------
# The self-image cell: architecture ON the seam
# ---------------------------------------------------------------------------

proc fillSeamCell(b: RoomBoard, ci: int, rules: MapRules, rng: var MapRng) =
  ## A cell that is its own mirror image cannot host a ring (see the header),
  ## but it is the ONLY place a 2-team map can put a genuine central feature,
  ## and 52% of the old generator's 2-team maps had none.
  ##
  ## Every piece is either centred ON the axis — so it is its own mirror and
  ## the lift is idempotent — or clear of it by half a corridor, so the piece
  ## and its image leave a full corridor between them. Nothing in between,
  ## because in between is where a pair of images fuses into a plug.
  let
    cell = b.allInset[ci]
    axis = float(b.sym.axisX())
    keep = float(rules.minCorridorWidthPx) / 2.0 + 6.0
  if cell.poly.len < 3: return
  let c = cell.centroid()
  for k in 0 ..< 6:
    let
      onAxis = k mod 2 == 0
      rad = rules.coverSizePx div 2 + rng.pick(rules.coverSizePx div 3)
      ir = max(1.0, cell.inradius() - float(rad) - 6.0)
      dy = float(rng.pick(max(1, int(2.0 * ir)))) - ir
      cx =
        if onAxis: axis
        else: axis - keep - float(rad) - float(rng.pick(60))
      s =
        if onAxis and rng.coin():
          ArenaShape(kind: shapeDiamond, cx: int(cx), cy: int(c.y + dy),
                     radius: rad)
        else:
          ArenaShape(kind: shapeDisc, cx: int(cx), cy: int(c.y + dy),
                     radius: rad)
    if not fitsInCell(cell, s, 4.0): continue
    if b.gameMap.mapProtectedFloorAt(s.cx, s.cy): continue
    discard b.place(s, ci, "central feature on the seam")

# ---------------------------------------------------------------------------
# The 1-D interval cover: no cross-field horizontal sightline
# ---------------------------------------------------------------------------

proc scanRows(gameMap: CtfMap): seq[int] =
  var y = ArenaBorder + 2
  while y < gameMap.height - ArenaBorder:
    result.add y
    y += ScanStep

proc rowsCovered(b: RoomBoard, fromIndex = 0): seq[bool] =
  ## Which of the validator's scan rows the CURRENT wall set actually blocks,
  ## measured the way the validator measures: at least one wall pixel inside
  ## the sightline x-band that survives the protected-floor carve.
  ##
  ## Computed per SHAPE (bounding box, then a few samples per row) rather than
  ## by rasterising the board, because a giant board is 5.5M pixels and this
  ## runs on every candidate.
  let
    gameMap = b.gameMap
    rows = scanRows(gameMap)
    ax = gameMap.sightlineLoX
    bx = gameMap.sightlineHiX
  result = newSeq[bool](rows.len)
  let y0 = rows[0]
  for pi in fromIndex ..< b.placements.len:
    let
      s = b.placements[pi].shape
      (sx0, sy0, sx1, sy1) = shapeBounds(s)
    if sx1 < ax or sx0 > bx: continue
    var ri = max(0, (sy0 - y0 + ScanStep - 1) div ScanStep)
    while ri < rows.len and rows[ri] <= sy1:
      let y = rows[ri]
      if not result[ri]:
        var x = max(ax, sx0)
        let xe = min(bx, sx1)
        while x <= xe:
          if inShape(x, y, s) and not gameMap.mapProtectedFloorAt(x, y):
            result[ri] = true
            break
          x += 3
      inc ri
  ## The images the symmetry lift adds block rows too, and on a rot180 board
  ## they block DIFFERENT ones (row y maps to row h-1-y). Fold them in rather
  ## than pretending the domain has to carry the whole band alone.
  case b.sym.kind
  of symMirror: discard          ## same rows, nothing to add
  of symRot180, symRot90:
    var mirrored = newSeq[bool](rows.len)
    for i, y in rows:
      let my = b.sym.reflectY(y)
      let mi = (my - y0) div ScanStep
      if mi >= 0 and mi < rows.len and result[mi]: mirrored[i] = true
    for i in 0 ..< rows.len:
      if mirrored[i]: result[i] = true

proc coverGaps(b: RoomBoard): seq[int] =
  ## The scan rows nothing blocks, as ROW INDICES.
  let covered = b.rowsCovered()
  for i, ok in covered:
    if not ok: result.add i

# ---------------------------------------------------------------------------
# Skeleton route count — proved on the METRIC's grid
# ---------------------------------------------------------------------------

type
  FlowEdge = object
    to, rev, cap: int

proc addFlowEdge(g: var seq[seq[FlowEdge]], a, bIdx, cap: int) =
  g[a].add FlowEdge(to: bIdx, rev: g[bIdx].len, cap: cap)
  g[bIdx].add FlowEdge(to: a, rev: g[a].len - 1, cap: 0)

proc maxFlow(g: var seq[seq[FlowEdge]], s, t, cap: int): int =
  ## Edmonds-Karp, capped. `cap` is small (we only ever ask "are there 3?"),
  ## so this returns after at most `cap` augmenting BFS passes.
  let n = g.len
  while result < cap:
    var
      prevNode = newSeq[int](n)
      prevEdge = newSeq[int](n)
      queue = @[s]
    for i in 0 ..< n: prevNode[i] = -1
    prevNode[s] = s
    var head = 0
    while head < queue.len:
      let v = queue[head]
      inc head
      for ei, e in g[v]:
        if e.cap > 0 and prevNode[e.to] < 0:
          prevNode[e.to] = v
          prevEdge[e.to] = ei
          queue.add e.to
    if prevNode[t] < 0: break
    var v = t
    while v != s:
      let
        u = prevNode[v]
        ei = prevEdge[v]
      g[u][ei].cap -= 1
      g[v][g[u][ei].rev].cap += 1
      v = u
    inc result

proc skeletonRouteCount(b: RoomBoard): int =
  ## How many VERTEX-DISJOINT routes the street network carries between the
  ## two base approaches, on the 26px grid `map_metrics` itself measures on.
  ##
  ## This is the number the fill pass provably cannot reduce: every wall this
  ## generator writes lies inside an inset cell, and no inset-cell pixel is a
  ## street pixel. So checking it once, HERE, before a single cover piece is
  ## placed, bounds the finished map from below.
  let
    gameMap = b.gameMap
    cs = SkeletonCellPx
    cols = gameMap.width div cs
    rows = gameMap.height div cs
  if cols < 4 or rows < 4: return 0
  var open = newSeq[bool](cols * rows)
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let
        x = c * cs + cs div 2
        y = r * cs + cs div 2
      if x < ArenaBorder or y < ArenaBorder or
          x >= gameMap.width - ArenaBorder or
          y >= gameMap.height - ArenaBorder: continue
      if gameMap.mapProtectedFloorAt(x, y):
        open[r * cols + c] = true
        continue
      var inside = false
      for ci, cell in b.allInset:
        if b.role[ci] in {crStreet, crApron}: continue
        if cell.poly.len >= 3 and cell.contains(float(x), float(y)):
          inside = true
          break
      open[r * cols + c] = not inside

  ## Node splitting: each open cell becomes in -> out with capacity 1, so a
  ## max flow counts VERTEX-disjoint paths, which is what Menger's theorem
  ## bounds and what "independent route" means on a map.
  let n = 2 * cols * rows + 2
  var g = newSeq[seq[FlowEdge]](n)
  let
    src = 2 * cols * rows
    snk = src + 1
  template nodeIn(i: int): int = 2 * i
  template nodeOut(i: int): int = 2 * i + 1
  for i in 0 ..< cols * rows:
    if open[i]: addFlowEdge(g, nodeIn(i), nodeOut(i), 1)
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let i = r * cols + c
      if not open[i]: continue
      for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let
          nc = c + dc
          nr = r + dr
        if nc < 0 or nr < 0 or nc >= cols or nr >= rows: continue
        let j = nr * cols + nc
        if open[j]: addFlowEdge(g, nodeOut(i), nodeIn(j), 1)
  var attached = 0
  for team in gameMap.teams():
    let a = gameMap.teamAnchor(team)
    for r in 0 ..< rows:
      for c in 0 ..< cols:
        let i = r * cols + c
        if not open[i]: continue
        let
          x = c * cs + cs div 2
          y = r * cs + cs div 2
        if abs(x - a.x) + abs(y - a.y) > 3 * cs: continue
        if team == Red: addFlowEdge(g, src, nodeIn(i), 1)
        elif team == Blue: addFlowEdge(g, nodeOut(i), snk, 1)
        inc attached
  if attached == 0: return 0
  maxFlow(g, src, snk, 6)

# ---------------------------------------------------------------------------
# Features with reasons
# ---------------------------------------------------------------------------

proc rayOpenPx(b: RoomBoard, obstacles: seq[ArenaShape],
               x0, y0, dx, dy, limit: int): int =
  ## How far a shot travels from here before it meets stone. The measurement
  ## the glazier makes BEFORE it glazes — not after, and not assumed.
  var i = 1
  while i <= limit:
    let
      x = x0 + dx * i
      y = y0 + dy * i
    if x < 0 or y < 0 or x >= b.gameMap.width or y >= b.gameMap.height:
      return i
    if mapWallAt(b.gameMap, obstacles, x, y): return i
    i += 2
  limit

proc glazeWindows(b: RoomBoard, rng: var MapRng) =
  ## Glass ONLY where a sightline genuinely exists to see through.
  ##
  ## The measured defect: 27.8% of the old generator's panes clear 200px of
  ## open ground on both sides, against the hand-authored arena's 71.4%, and
  ## 41.7% of maps have no useful pane at all. The cause is not a bad
  ## selector — adjacent lattice columns sit 51-76px apart, so the spacing IS
  ## the occluder. Here the spacing is `2 * insetPx` of street on one side and
  ## a room's whole interior on the other, and the pane is only cut once a ray
  ## has been fired through the candidate wall and MEASURED on both sides.
  ##
  ## The promise outlives the pass: `postGlassStillSees` re-fires the same ray
  ## after everything else has rendered, so a later scene that blocks it fails
  ## the map by name instead of shipping a pointless window.
  var candidates: seq[int]
  for i, p in b.placements:
    if p.shape.kind != shapePolygon or p.shape.window: continue
    if p.serves != "room wall": continue
    if shapeAreaPx(p.shape) < 40 * b.style.wallPx: continue
    candidates.add i
  rng.shuffle(candidates)
  let obstacles = buildArenaObstacles(b.gameMap)
  var glazed = 0
  for idx in candidates:
    if glazed >= b.style.glassPanes: break
    let
      s = b.placements[idx].shape
      (x0, y0, x1, y1) = shapeBounds(s)
      cx = (x0 + x1) div 2
      cy = (y0 + y1) div 2
      wide = (x1 - x0) >= (y1 - y0)
      ## Fire ACROSS the wall: a tall thin wall is looked through sideways.
      (dx, dy) = if wide: (0, 1) else: (1, 0)
      span = if wide: (y1 - y0) else: (x1 - x0)
    let
      aOut = b.rayOpenPx(obstacles, cx - dx * (span div 2 + 2),
                         cy - dy * (span div 2 + 2), -dx, -dy, 420)
      bOut = b.rayOpenPx(obstacles, cx + dx * (span div 2 + 2),
                         cy + dy * (span div 2 + 2), dx, dy, 420)
    if aOut < UsefulWindowPx or bOut < UsefulWindowPx:
      inc b.stats.glassRejected
      continue
    ## Cut a pane out of the middle of the host wall rather than glazing the
    ## whole segment: a wall that is entirely glass is a window with no frame,
    ## and the frame is what makes it read as a building.
    let
      paneLen = min(96, max(48, (if wide: x1 - x0 else: y1 - y0) div 2))
      pane =
        if wide:
          MapRect(x: cx - paneLen div 2, y: y0, w: paneLen, h: y1 - y0 + 1)
        else:
          MapRect(x: x0, y: cy - paneLen div 2, w: x1 - x0 + 1, h: paneLen)
    b.placements.add Placement(
      shape: ArenaShape(kind: shapeRect, window: true, rect: pane),
      cell: b.placements[idx].cell,
      serves: "glass over a measured sightline")
    inc glazed
    inc b.stats.glassPanes
    let (px, py, pdx, pdy, pspan) = (cx, cy, dx, dy, span)
    b.posts.add Post(
      claim: "glass at " & $px & "," & $py & " still sees through",
      check: proc(): bool =
        let obs = buildArenaObstacles(b.gameMap)
        b.rayOpenPx(obs, px - pdx * (pspan div 2 + 2),
                    py - pdy * (pspan div 2 + 2), -pdx, -pdy, 300) >= 160 and
        b.rayOpenPx(obs, px + pdx * (pspan div 2 + 2),
                    py + pdy * (pspan div 2 + 2), pdx, pdy, 300) >= 160)

proc digTrenches(b: RoomBoard, rules: MapRules, rng: var MapRng) =
  ## Trenches go on EXPOSED crossings — a street stretch with no cover within
  ## a lethal envelope — and nowhere else. A trench with cover beside it is
  ## just decoration; a trench where you would otherwise be shot crossing is
  ## the mechanic doing its job.
  if b.style.trenchRuns <= 0: return
  let
    gameMap = b.gameMap
    obstacles = buildArenaObstacles(gameMap)
    size = rules.trenchSizePx
  var dug = 0
  for _ in 0 ..< 40:
    if dug >= b.style.trenchRuns: break
    let ci = b.mine[rng.pick(b.mine.len)]
    if b.role[ci] notin {crStreet, crPlaza}: continue
    let cell = b.allCells[ci]
    if cell.poly.len < 3: continue
    let
      c = cell.centroid()
      horizontal = rng.coin()
      w = if horizontal: 3 * size else: size
      h = if horizontal: size else: 3 * size
      r = MapRect(x: int(c.x) - w div 2, y: int(c.y) - h div 2, w: w, h: h)
    if r.x < ArenaBorder or r.y < ArenaBorder or
        r.x + r.w >= gameMap.width - ArenaBorder or
        r.y + r.h >= gameMap.height - ArenaBorder: continue
    if gameMap.mapProtectedFloorAt(r.x, r.y) or
        gameMap.mapProtectedFloorAt(r.x + r.w, r.y + r.h): continue
    ## The reason: this ground must actually be exposed.
    var exposed = true
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
      if b.rayOpenPx(obstacles, int(c.x), int(c.y), dx, dy,
                     LethalEnvelopePx) < LethalEnvelopePx div 2:
        exposed = false
    if not exposed: continue
    var clear = true
    for x in countup(r.x, r.x + r.w, 6):
      for y in countup(r.y, r.y + r.h, 6):
        if mapWallAt(gameMap, obstacles, x, y): clear = false
    if not clear: continue
    for img in gameMap.symmetryImages(r):
      b.gameMap.trenches.add ArenaShape(kind: shapeRect, rect: img)
    inc dug

proc placePickups(b: RoomBoard, rng: var MapRng) =
  ## Half safe, half contested — and put back on floor the terrain actually
  ## left open. A kit that spawns in stone is a kit nobody collects: measured
  ## at 5.0% in stone and 15.5% unreachable on the old generator's 4-team
  ## boards.
  let
    gameMap = b.gameMap
    obstacles = buildArenaObstacles(gameMap)
  var kits: seq[MapPoint]
  for i, ptt in gameMap.medKitCandidates:
    var best = ptt
    block find:
      for radius in countup(0, 260, 10):
        for a in 0 ..< 16:
          let
            ang = TAU * float(a) / 16.0
            x = ptt.x + int(cos(ang) * float(radius))
            y = ptt.y + int(sin(ang) * float(radius))
          if x < ArenaBorder or y < ArenaBorder or
              x >= gameMap.width - ArenaBorder or
              y >= gameMap.height - ArenaBorder: continue
          if mapWallAt(gameMap, obstacles, x, y): continue
          ## Even-index kits want SHELTER (inside a room, where taking one
          ## costs a detour off the street), odd-index kits want the street,
          ## where taking one costs exposure. Either is a real decision; a kit
          ## dropped wherever there was floor is not.
          var inRoom = false
          for ci, cell in b.allInset:
            if b.role[ci] in {crRing, crHall} and cell.poly.len >= 3 and
                cell.contains(float(x), float(y)):
              inRoom = true
              break
          if (i mod 2 == 0) != inRoom and radius < 220: continue
          best = MapPoint(x: x, y: y)
          break find
    kits.add best
  b.gameMap.medKitCandidates = kits
  b.gameMap.medKitSpawns = if kits.len >= 2: @[kits[0], kits[1]] else: kits

# ---------------------------------------------------------------------------
# The generator
# ---------------------------------------------------------------------------

proc generateRoomsBoard*(seed: int, overrides: MapGenOverrides, teams = 2,
                         attempt = 0, unitsPerTeam = 0): RoomBoard =
  ## Draw one candidate. Reuses `arena.generateMapAttempt` for the SHELL only
  ## — board size class, symmetry, endzone archetype, pedestals, capture
  ## geometry — then throws its terrain away and builds its own. Keeping the
  ## shell is what makes the A/B honest: for one seed both generators get the
  ## same board and differ only in what is drawn on it.
  var gameMap = generateMapAttempt(seed, overrides, teams, attempt, unitsPerTeam)
  gameMap.leftObstacles = @[]
  gameMap.trenches = @[]
  gameMap.name = "rooms-" & $seed

  let
    root = mapSeed(seed, attempt)
    sizeName = gameMap.mapSizeClassName()
    rules = mapRules(sizeName, teams)
  var
    layoutRng = root.stream(SceneLayout)
    terrainRng = root.stream(SceneTerrain)
    coverRng = root.stream(SceneCover)
    pickupRng = root.stream(ScenePickups)
    biomeRng = root.stream(SceneBiome)
  var vocabRng = initRand(int(biomeRng.next() and 0x7FFF_FFFF))

  let style = drawStyle(layoutRng, rules, teams)
  gameMap.biome =
    case style.biome
    of biomeStyleCaves: biomeCaves
    of biomeStyleForest: biomeForest
    of biomeStyleDesert: biomeDesert
    of biomeStyleCity: biomeCity
    of biomeStylePlains: biomePlains

  result = RoomBoard(gameMap: gameMap, sym: symGroup(gameMap), style: style)
  let
    sym = result.sym
    dom = sym.domain()

  # --- 1. SEED the fundamental domain -------------------------------------
  #
  # Poisson-disk at r = the class's lane pitch. Maximality bounds the
  # partition from both sides: no cell holds a disc bigger than r, every cell
  # holds one of r/2. One scalar therefore sets room scale, street length and
  # the longest straight wall.
  var pre: seq[MapPoint]
  ## ⚠️ The axis FIRST, at spacing below r. A mirror axis is a Voronoi edge
  ## unless a seed sits on it, and an unseeded axis is a perfectly straight
  ## full-board corridor down the middle of every 2-team map.
  for p in sym.axisSeeds(style.pitchPx * 3 div 4,
                         ArenaBorder + 40, gameMap.height - ArenaBorder - 40):
    pre.add p
  ## …and the pedestals, so a stand owns a cell instead of straddling four.
  for team in gameMap.teams():
    let a = gameMap.teamAnchor(team)
    if inRect(a.x, a.y, dom): pre.add a
  var prng = initPoissonRng(terrainRng.next())
  let
    region = MapRect(x: dom.x + ArenaBorder, y: dom.y + ArenaBorder,
                     w: max(32, dom.w - ArenaBorder), h: max(32, dom.h - 2 * ArenaBorder))
    domainSites = poissonDisk(prng, region, float(style.pitchPx), pre)

  # --- 2. LIFT by the symmetry orbit, then 3. PARTITION -------------------
  let sites = sym.liftSites(domainSites)
  result.allCells = voronoiCells(
    sites, MapRect(x: 0, y: 0, w: gameMap.width, h: gameMap.height))
  result.allInset = newSeq[ConvexCell](result.allCells.len)
  for i, c in result.allCells:
    ## Inset by the street half-width — EXCEPT against the board border,
    ## where there is no neighbour to make room for. Insetting there would
    ## leave a clear lane hugging the map edge, which is precisely the row the
    ## sightline validator rejects (and it is checked from y = border + 2).
    var cell = c
    var boundaryOnly: seq[int]
    for k in 0 ..< cell.owner.len:
      if cell.owner[k] < 0: boundaryOnly.add k
    result.allInset[i] = insetCell(cell, float(style.insetPx))
    if boundaryOnly.len > 0:
      ## Re-add the border edges at zero inset by re-clipping the ORIGINAL
      ## planes: cheapest correct way to get a per-edge inset distance.
      var poly = rectPoly(MapRect(x: -8, y: -8,
                                  w: gameMap.width + 16, h: gameMap.height + 16))
      var owner = @[-1, -1, -1, -1]
      for k in 0 ..< cell.poly.len:
        let
          a = cell.poly[k]
          bb = cell.poly[(k + 1) mod cell.poly.len]
          (nx, ny, cc) = edgeNormal(a, bb)
        if nx == 0.0 and ny == 0.0: continue
        let d = if cell.owner[k] < 0: 0.0 else: float(style.insetPx)
        clipHalfPlaneExported(poly, owner, nx, ny, cc - d, cell.owner[k])
        if poly.len == 0: break
      result.allInset[i] = ConvexCell(site: cell.site, siteIndex: i,
                                      poly: poly, owner: owner)

  # --- 4. ROLES: which cells are rooms ------------------------------------
  result.role = newSeq[CellRole](result.allCells.len)
  for i in 0 ..< result.role.len: result.role[i] = crStreet
  ## The domain owns the cell of every seed it drew. The group permutes the
  ## cells, so drawing here and lifting covers every cell exactly once.
  var owned: seq[int]
  for si, s in sites:
    if si < domainSites.len: owned.add si
  result.mine = owned

  let
    interiorPx = (gameMap.width - 2 * gameMap.captureClear) *
      (gameMap.height - 2 * ArenaBorder)
    orbit = max(2, sym.orbitOrder())
  result.budgetPx = style.coverPermille * interiorPx div 1000 div orbit

  var capable: seq[int]
  for ci in result.mine:
    let inset = result.allInset[ci]
    if inset.poly.len < 3:
      result.role[ci] = crStreet
      continue
    if not result.cellInBoard(inset):
      result.role[ci] = crStreet
      continue
    if result.cellTouchesProtected(inset):
      result.role[ci] = crApron
      continue
    if inset.inradius() < MinRingInradius:
      result.role[ci] = crPlaza
      continue
    capable.add ci

  ## THE INTERVAL COVER. Under the symmetry lift the domain's own structures
  ## must break every horizontal ray, so pick a set of cells whose y-extents
  ## COVER the validator's scan band, taking at each step the candidate that
  ## reaches FURTHEST rather than merely the next one that starts in time.
  ## Each chosen cell becomes a room because it covers rows nothing else
  ## covers — that is the reason, and it is why no repair pass is needed.
  let
    scanLo = ArenaBorder + 2
    scanHi = gameMap.height - ArenaBorder
    ax = gameMap.sightlineLoX
    bx = gameMap.sightlineHiX
  var
    yLo = newSeq[int](result.allCells.len)
    yHi = newSeq[int](result.allCells.len)
    inBand = newSeq[bool](result.allCells.len)
  for ci in capable:
    let bb = result.allInset[ci].bbox()
    yLo[ci] = bb.y
    yHi[ci] = bb.y + bb.h
    inBand[ci] = bb.x + bb.w >= ax and bb.x <= bx
  var
    chosen: HashSet[int]
    cursor = scanLo
  while cursor < scanHi:
    var best = -1
    for ci in capable:
      if ci in chosen or not inBand[ci]: continue
      if yLo[ci] <= cursor and yHi[ci] > cursor:
        if best < 0 or yHi[ci] > yHi[best]: best = ci
    if best < 0:
      result.note "y-cover incomplete from y=" & $cursor
      break
    chosen.incl best
    cursor = yHi[best]
  ## Under rot180 / rot90 the images cover the reflected rows, so the domain
  ## only has to reach the halfway point. Under mirror it must cover the lot.
  for ci in chosen:
    result.role[ci] = crRing

  ## Spend the rest of the roles on character, biggest cells first so the map
  ## gains architecture rather than confetti.
  var rest = capable.filterIt(it notin chosen)
  rest.sort(proc(p, q: int): int =
    cmp(area(result.allInset[q]), area(result.allInset[p])))
  for ci in rest:
    let roll = terrainRng.pick(100)
    result.role[ci] =
      if roll < style.ringBias: crRing
      elif roll < style.ringBias + style.hallBias: crHall
      elif roll < style.ringBias + style.hallBias + style.rubbleBias: crRubble
      elif terrainRng.coin(): crBlocks
      else: crPlaza

  # --- 5. BUILD: skeleton first ------------------------------------------
  result.stats.skeletonRoutes = result.skeletonRouteCount()

  for ci in result.mine:
    case result.role[ci]
    of crRing: result.buildRing(ci, hall = false, terrainRng)
    of crHall: result.buildRing(ci, hall = true, terrainRng)
    else: discard

  # --- 6. FILL: cover, on the other pixel family --------------------------
  for ci in result.mine:
    if sym.isFixed(result.allCells[ci].site):
      result.fillSeamCell(ci, rules, coverRng)
    else:
      result.fillCell(ci, result.role[ci], rules, coverRng, vocabRng)

  # --- 7. FEATURES WITH REASONS ------------------------------------------
  result.gameMap.leftObstacles = @[]
  for p in result.placements: result.gameMap.leftObstacles.add p.shape
  result.glazeWindows(coverRng)
  result.gameMap.leftObstacles = @[]
  for p in result.placements: result.gameMap.leftObstacles.add p.shape
  result.digTrenches(rules, coverRng)
  result.placePickups(pickupRng)

  # --- accounting ---------------------------------------------------------
  for ci in result.mine:
    inc result.stats.cells
    case result.role[ci]
    of crRing: inc result.stats.rings
    of crHall: inc result.stats.halls
    of crBlocks: inc result.stats.blocks
    of crPlaza: inc result.stats.plazas
    of crRubble: inc result.stats.rubble
    of crApron: inc result.stats.aprons
    of crStreet: discard
  result.stats.wallPx = result.spentPx
  result.stats.uncoveredRows = result.coverGaps().len
  for p in result.posts:
    if not p.check(): result.stats.brokenPosts.add p.claim

proc roomsCandidate*(seed: int, overrides: MapGenOverrides, teams = 2,
                     attempt = 0, unitsPerTeam = 0): CtfMap =
  ## The `arena.MapCandidateFn` shape: one unvalidated draw.
  generateRoomsBoard(seed, overrides, teams, attempt, unitsPerTeam).gameMap

proc generateRoomsMap*(seed: int,
                       overrides = MapGenOverrides(windows: -1, pits: -1,
                                                   pitDensity: -1),
                       teams = 2, k = 0): MapSelection =
  ## Best-of-K through `arena.selectBestMap`, which is generator-agnostic and
  ## therefore drives this one with no changes at all — the seam that made
  ## building a parallel generator possible without touching `arena.nim`.
  let
    first = generateMapAttempt(seed, overrides, teams, 0)
    want = if k > 0: k else: first.selectionK()
  selectBestMap(
    seed, want,
    produce = proc (s, attempt: int): CtfMap =
      roomsCandidate(s, overrides, teams, attempt))

proc roomsMap*(seed: int,
               overrides = MapGenOverrides(windows: -1, pits: -1,
                                           pitDensity: -1),
               teams = 2, k = 0): CtfMap =
  let selection = generateRoomsMap(seed, overrides, teams, k)
  if selection.valid == 0:
    raise newException(
      CtfError, "rooms generator found no valid layout for seed " & $seed)
  selection.gameMap

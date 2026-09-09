## mapgen_rooms — THE terrain pass. Skeleton first, fill second, on disjoint
## pixel sets.
##
## `arena.generateMapAttempt` calls `buildRoomTerrain` where it used to draw a
## column lattice, so this is the shipping generator, not a parallel track.
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
## The old pipeline oscillated between them — `burrow`'s cheapest-path dig is a
## straight-corridor generator (a sightline adversary), the plug pass narrows
## corridors (a route adversary), and nothing re-checked either. Here each
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
## WHY THIS ONE DOES NOT LOOK LIKE FIFTY COPIES OF ONE MAP
## ---------------------------------------------------------------------------
##
## The column lattice had four "families" — stubs, diamonds, discs, chevrons —
## which were four SKINS ON ONE SLOT. Swapping them changed what a pixel
## looked like, never what the map was, and fifty seeds rendered as one design.
##
## So the variety here lives in the SKELETON, above the skin:
##
##   * `SeedPattern` changes the site set itself — scatter, a jittered lattice,
##     a ring road, a spine with branches, clusters with wilderness between.
##     A different site set is a different Voronoi graph, which is a different
##     ROUTE GRAPH, not a different texture.
##   * `RoomArchetype` moves room scale, wall weight, door count and the fill
##     vocabulary TOGETHER, because moving one alone re-skins the same slot.
##   * cell count follows board AREA at fixed pitch, so a giant board gets
##     many more rooms rather than the same map photocopied at 260%.
##   * `CellRole` is drawn per cell, so one map holds rings, halls, block
##     masses, plazas and biome rubble at once.
##
## ---------------------------------------------------------------------------
## WHY THE SIGHTLINE PROSTHETIC IS GONE
## ---------------------------------------------------------------------------
##
## `arena.nim` used to drop r28 diamonds at random column x until no 4px row
## was unblocked — 14-16% of a standard board's interior wall, placed with no
## regard for play. The constructive replacement is two facts:
##
##   1. A closed CONVEX ring covers every row of its own y-extent, because a
##      horizontal line meets a convex curve exactly twice.
##   2. Those two crossings sit on the ring's WEST-facing and EAST-facing
##      chains. So a row is lost only if a west door and an east door overlap
##      in y — and `planDoorways` simply refuses that overlap.
##
## Room selection is then a 1-D greedy INTERVAL COVER over the validator's own
## scan band. Nothing is retried, nothing is guessed.

import std/[algorithm, math, random, sequtils, sets]
import sim_types, map_rules, map_seed, map_lanes,
       mapgen_sym, mapgen_partition, mapgen_vocab, mapgen_biomes

export mapgen_sym, mapgen_partition, mapgen_biomes, mapgen_vocab

# ---------------------------------------------------------------------------
# The host: everything `arena` owns, handed in explicitly
# ---------------------------------------------------------------------------

type
  TerrainHost* = object
    ## The board facts and the four geometry predicates this pass needs.
    ##
    ## Passed in rather than imported because `arena` owns all of them and
    ## `arena` imports THIS module: a terrain pass that reached back into
    ## `arena` would be a cycle, and the hook-installed alternative has a
    ## split-brain failure mode (a binary that imports `arena` alone silently
    ## gets no terrain) that this codebase has already been bitten by once.
    width*, height*: int
    border*: int
    symmetry*: MapSymmetry
    center*: MapPoint
    anchors*: seq[MapPoint]        ## every team's pedestal, red first
    scanLoX*, scanHiX*: int        ## the validator's horizontal-ray band
    buildRegion*: MapRect
      ## Where terrain may usefully go. NOT the same as the fundamental
      ## domain: on a column-endzone board the protected capture strip is a
      ## third of the half-field, and seeding Poisson across the whole domain
      ## put most sites inside it. Their cells then got carved down to
      ## slivers, and the interval cover ran out of rooms — measured at 12 of
      ## 16 seeds rejected for an open horizontal sightline.
    interiorPx*: int               ## the band cover permille is measured over
    coverPermilleMin*, coverPermilleMax*: int
    sizeClass*: MapSizeClass
    teams*: int
    kitCandidates*: seq[MapPoint]
    protectedAt*: proc (x, y: int): bool {.closure.}
    inShapeAt*: proc (x, y: int, s: ArenaShape): bool {.closure.}
    shapeBox*: proc (s: ArenaShape): tuple[x0, y0, x1, y1: int] {.closure.}
    wallAt*: proc (x, y: int, shapes: seq[ArenaShape]): bool {.closure.}
    lift*: proc (shapes: seq[ArenaShape]): seq[ArenaShape] {.closure.}
    liftRect*: proc (r: MapRect): seq[MapRect] {.closure.}

# ---------------------------------------------------------------------------
# Style: the diversity engine
# ---------------------------------------------------------------------------

type
  SeedPattern* = enum
    ## How the fundamental domain is SEEDED — the highest-leverage diversity
    ## knob there is, because the site set determines the Voronoi graph and
    ## the Voronoi graph IS the route graph. Changing this changes the map's
    ## topology; changing a shape vocabulary only changes its texture.
    spScatter      ## maximal Poisson: irregular organic districts
    spGrid         ## jittered lattice: a block grid with aligned streets
    spRing         ## concentric rings: a ring road around a central keep
    spSpine        ## a main street with lateral branches
    spClusters     ## tight clusters with open wilderness between them

  RoomArchetype* = enum
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
    pattern*: SeedPattern
    archetype*: RoomArchetype
    pitchPx*: int         ## Poisson radius: THE scale knob
    insetPx*: int         ## half the street width
    wallPx*: int          ## ring thickness
    doorPx*: int          ## doorway width
    coverPermille*: int
    biome*: BiomeStyle           ## the map's primary skin
    biomePalette*: seq[BiomeStyle]
    multiBiome*: bool
    vocab*: seq[VocabItem]
    ringBias*, hallBias*, rubbleBias*: int
    glassPanes*: int
    trenchRuns*: int

  Placement* = object
    ## One obstacle plus the audit trail that justifies it. `serves` is
    ## mandatory at the call site: "placed but pointless" is the failure this
    ## generator exists to make unwriteable.
    shape*: ArenaShape
    cell*: int
    serves*: string
    screen*: bool

  Post* = object
    claim*: string
    check*: proc(): bool {.closure.}

  RoomStats* = object
    sites*, cells*, rings*, halls*, blocks*, plazas*, rubble*, aprons*: int
    wallPx*, screenPx*: int
    doorways*: int
    skeletonRoutes*: int
    uncoveredRows*: int
    glassPanes*, glassRejected*: int
    biomesUsed*: int
    brokenPosts*: seq[string]

  RoomBoard* = ref object
    host*: TerrainHost
    sym*: SymGroup
    style*: RoomStyle
    rules*: MapRules
    allCells*: seq[ConvexCell]
    allInset*: seq[ConvexCell]
    mine*: seq[int]
    role*: seq[CellRole]
    placements*: seq[Placement]
    trenches*: seq[ArenaShape]
    kits*: seq[MapPoint]
    doorRects*: seq[MapRect]
    budgetPx*, spentPx*: int
    notes*: seq[string]
    posts*: seq[Post]
    stats*: RoomStats

const
  MinRingWallSlack = 30.0
    ## A cell can hold a ring when its inradius clears the wall plus a body's
    ## width of interior. Derived from the style's own wall thickness, not a
    ## flat constant: a flat 58 refused every cell of a `warrens` map, whose
    ## whole point is small rooms with thin walls.
  ScanStep = 4
    ## The validator's own horizontal-ray sampling period. Matching it exactly
    ## is deliberate: the interval cover must cover the rows that are CHECKED.
  SkeletonCellPx = 26
    ## ⚠️ `map_metrics.RouteCellPx`. The METRIC's grid, not `burrow`'s 8px one:
    ## two corridors disjoint in an 8px grid can share a 26px metric cell, and
    ## a disjointness proof on the wrong grid is a proof about a different
    ## graph. Spelled as a literal because `map_metrics` imports `arena`, which
    ## imports this — pinned equal by `tests/test_mapgen_rooms.nim`.
  RimInsetPx = 2.0
    ## How far a cell is pulled in from the BOARD edge. Not zero, and not the
    ## street inset either.
    ##
    ## Zero puts a rim room's wall at y in [0, wallPx], which misses the
    ## validator's very first scan row at y = border + 2 = 12 whenever the
    ## wall is thinner than 13px — measured as three of sixteen seeds failing
    ## with "open horizontal sightline at y=12". Two pixels puts the band at
    ## [2, 2 + wallPx], which contains row 12 for every wall this generator
    ## draws. The street inset would be worse still: it would leave a clear
    ## lane hugging the map border, which is the same failure with more rows.
  MinWallPx = 12
    ## The floor `sizeTheLastPiece` may thin a wall to. Below this a rim wall
    ## stops covering scan row 12 (see `RimInsetPx`).
  UsefulWindowPx = 200
    ## `tools/mapgen_defect_probe.nim`'s bar: a pane is worth building only if
    ## a shot through it reaches 200px of open ground on BOTH sides. Measured
    ## here BEFORE glazing rather than hoped for afterwards.
  MultiBiomeFrom = mszLarge
    ## Zones need room. Measured during the biome port: a 3x3 zone lattice on
    ## a standard board gives ~5x5 automaton cells, too small for a CA to make
    ## anything (caves-as-zones scored interiorFrac 0.046 against 0.148 as a
    ## full fill). So multi-biome composition is a BIG-BOARD feature and
    ## anything below `large` picks one biome for the whole map.

proc note(b: RoomBoard, text: string) = b.notes.add text

# ---------------------------------------------------------------------------
# Style draw
# ---------------------------------------------------------------------------

proc drawStyle*(rng: var MapRng, rules: MapRules, host: TerrainHost): RoomStyle =
  ## One map's whole character, drawn once. Every number is anchored to
  ## `map_rules` and then jittered, so a size-class change moves the rooms and
  ## a taste change moves one multiplier.
  result.pattern = SeedPattern(rng.pick(ord(SeedPattern.high) + 1))
  ## rot90 boards get the two patterns whose orbit does NOT read as a
  ## pinwheel. A ring seeded in one quadrant becomes four arcs of the same
  ## ring (fine), but a spine becomes four spokes meeting at the centre, which
  ## is exactly the "four corners through a hub" graph we are replacing.
  if host.symmetry == symRot90 and result.pattern == spSpine:
    result.pattern = if rng.coin(): spGrid else: spClusters
  let arch = RoomArchetype(rng.pick(ord(RoomArchetype.high) + 1))
  result.archetype = arch
  let pitchPct =
    case arch
    of raCompound: rng.pickRange(115, 145)
    of raWarrens: rng.pickRange(62, 80)
    of raQuarry: rng.pickRange(88, 115)
    of raTerraces: rng.pickRange(95, 125)
    of raBazaar: rng.pickRange(78, 100)
  result.insetPx =
    case arch
    of raWarrens: rng.pickRange(22, 30)
    of raCompound: rng.pickRange(30, 44)
    else: rng.pickRange(26, 38)
  result.doorPx = rng.pickRange(46, 76)
  result.wallPx =
    case arch
    of raCompound: rng.pickRange(16, 24)
    of raWarrens: rng.pickRange(10, 14)
    else: rng.pickRange(12, 18)
  ## Maximal Poisson-disk sampling guarantees every cell contains a disc of
  ## radius pitch/2. Inset by the street and walled, the interior left is
  ## `pitch/2 - inset - wall`, so a pitch below `2 * (inset + wall + slack)`
  ## produces cells that CANNOT hold a room — and the first build drew exactly
  ## that on `warrens` maps, where 30 of 32 cells fell through to `plaza` and
  ## the map came out as scattered pebbles. Deriving the floor from the two
  ## knobs it depends on makes small-room styles small ROOMS instead.
  result.pitchPx = max(rules.lanePitchPx * pitchPct div 100,
                       2 * (result.insetPx + result.wallPx +
                            int(MinRingWallSlack) + 6))
  ## ⚠️ A doorway is a PINCH, and its depth is the wall's thickness.
  ## `map_lanes.maxPinchRunPx` is the length-aware predicate the chokepoint
  ## work derived: 66px of pinch at a 30px gap, grading to 132px at 62px+.
  ## A 40px doorway through a 40x400px wall scores identically to a 40px
  ## doorway on every metric we have, and plays like a shooting gallery. This
  ## is the clamp that stops the generator building one.
  result.wallPx = min(result.wallPx, maxPinchRunPx(result.doorPx))
  let
    lo = max(host.coverPermilleMin + 10, rules.coverPermilleMin)
    hi = min(host.coverPermilleMax - 10, rules.coverPermilleMax)
  result.coverPermille = rng.pickRange(min(lo, hi), max(lo, hi))

  ## BIOMES. A biome is an additive wall-writer, not an exclusive terrain, so
  ## a palette of two or three composes: whichever zone draws which style, the
  ## union is the map. Big boards hold several; small boards take one, because
  ## a zone smaller than a few automaton cells produces nothing (see
  ## `MultiBiomeFrom`).
  var palette: seq[BiomeStyle]
  let preferred =
    case arch
    of raQuarry: @[biomeStyleCaves, biomeStyleForest]
    of raCompound: @[biomeStyleCity, biomeStylePlains]
    of raWarrens: @[biomeStyleCity, biomeStyleDesert]
    of raTerraces: @[biomeStyleDesert, biomeStylePlains]
    of raBazaar: @[biomeStylePlains, biomeStyleForest, biomeStyleCaves]
  palette.add preferred[rng.pick(preferred.len)]
  result.multiBiome = host.sizeClass >= MultiBiomeFrom
  if result.multiBiome:
    for _ in 0 ..< 1 + rng.pick(2):
      let extra = BiomeStyle(rng.pick(ord(BiomeStyle.high) + 1))
      if extra notin palette: palette.add extra
  result.biomePalette = palette
  result.biome = palette[0]

  result.vocab =
    case arch
    of raCompound: @[viTemple, viBunker, viCan]
    of raWarrens: @[viCan, viDorito, viBeam]
    of raQuarry: @[viMassif, viCave, viCan]
    of raTerraces: @[viBeam, viSnake, viTemple]
    of raBazaar: @[viBunker, viDorito, viCan, viMassif]
  result.ringBias =
    case arch
    of raCompound: 72
    of raWarrens: 58
    of raQuarry: 14
    of raTerraces: 28
    of raBazaar: 34
  result.hallBias =
    case arch
    of raTerraces: 68
    of raCompound: 18
    else: 28
  result.rubbleBias =
    case arch
    of raQuarry: 70
    of raBazaar: 34
    else: 18
  result.glassPanes = rng.pickRange(2, 5)
  result.trenchRuns = if host.teams == 2: rng.pickRange(0, 3) else: 0

# ---------------------------------------------------------------------------
# Seeding: five genuinely different site sets
# ---------------------------------------------------------------------------

proc seedSites*(pattern: SeedPattern, rng: var MapRng, region: MapRect,
                pitch: int, pre: seq[MapPoint], center: MapPoint):
                seq[MapPoint] =
  ## The site set. Poisson-disk underlies four of the five so the spacing
  ## bounds still hold (no cell holds a disc larger than the pitch, every cell
  ## holds one of half it); the patterns differ in what is PRE-PLACED before
  ## the fill, which is what bends the resulting graph.
  var prng = initPoissonRng(rng.next())
  var pinned = pre
  let
    r = float(pitch)
    cx = float(region.x + region.w)
    cy = float(center.y)
  proc addIfInside(p: MapPoint) =
    if p.x >= region.x and p.y >= region.y and
        p.x < region.x + region.w and p.y < region.y + region.h:
      pinned.add p
  case pattern
  of spScatter:
    discard
  of spGrid:
    ## A jittered lattice. Streets line up across the board, which reads as a
    ## planned district rather than an organic one, and gives long straight
    ## routes broken by rooms rather than winding ones.
    let
      step = pitch
      jitter = max(2, pitch div 6)
    var y = region.y + step div 2
    while y < region.y + region.h:
      var x = region.x + step div 2
      while x < region.x + region.w:
        addIfInside MapPoint(x: x + rng.pickRange(-jitter, jitter),
                             y: y + rng.pickRange(-jitter, jitter))
        x += step
      y += step
  of spRing:
    ## Concentric rings about the board centre: the cells become arcs, the
    ## streets become a ring road, and the middle of the map is a keep instead
    ## of an empty circle.
    let rings = 1 + rng.pick(2)
    for k in 0 ..< rings:
      let rad = float(pitch) * (1.0 + float(k) * 1.15) + float(rng.pick(pitch div 3))
      let n = max(4, int(TAU * rad / r))
      for i in 0 ..< n:
        let a = TAU * float(i) / float(n) + float(rng.pick(60)) / 100.0
        addIfInside MapPoint(x: int(cx + cos(a) * rad), y: int(cy + sin(a) * rad))
  of spSpine:
    ## One main street with lateral branches. The route graph gets a spine and
    ## ribs instead of a mesh, so a map has a THROUGH-route and pockets.
    let
      y0 = region.y + rng.pickRange(region.h div 4, region.h * 3 div 4)
      amp = rng.pickRange(pitch div 3, pitch)
    var x = region.x + pitch div 2
    var i = 0
    while x < region.x + region.w:
      let sy = y0 + int(sin(float(i) * 0.9) * float(amp))
      addIfInside MapPoint(x: x, y: sy)
      addIfInside MapPoint(x: x, y: sy - pitch - rng.pick(pitch div 3))
      addIfInside MapPoint(x: x, y: sy + pitch + rng.pick(pitch div 3))
      x += pitch
      inc i
  of spClusters:
    ## Tight clusters with open ground between them: dense warrens you fight
    ## inside, wilderness you cross between. The most uneven of the five, and
    ## `visDegreeCv` (how uneven exposure is) is a band we score on.
    let clusters = 2 + rng.pick(3)
    for _ in 0 ..< clusters:
      let
        ox = region.x + rng.pick(max(1, region.w))
        oy = region.y + rng.pick(max(1, region.h))
        n = 3 + rng.pick(4)
      for _ in 0 ..< n:
        let
          a = TAU * float(rng.pick(1000)) / 1000.0
          d = float(rng.pick(pitch * 3 div 2))
        addIfInside MapPoint(x: ox + int(cos(a) * d), y: oy + int(sin(a) * d))
  ## The pattern's own points are PINNED (exempt from the spacing rule, like
  ## the axis seeds), then Poisson fills whatever gaps are left. That keeps
  ## maximality — and so the cell-size bounds — on every pattern.
  let fillPitch =
    if pattern == spScatter: pitch else: pitch * 5 div 4
  for p in poissonDisk(prng, region, float(fillPitch), pinned):
    if p notin result: result.add p

# ---------------------------------------------------------------------------
# Placement primitives — every write goes through here
# ---------------------------------------------------------------------------

proc shapeAreaPx*(s: ArenaShape): int =
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
  ## precondition of every placement, not a property somebody hopes for.
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
  let (x0, y0, x1, y1) = b.host.shapeBox(s)
  let box = MapRect(x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1)
  for d in b.doorRects:
    if rectsOverlap(box, d): return true
  false

proc place(b: RoomBoard, s: ArenaShape, cell: int, serves: string,
           screen = false): bool {.discardable.} =
  ## THE write. Refuses rather than corrupting an invariant.
  doAssert serves.len > 0, "every placement must name what it serves"
  let px = shapeAreaPx(s)
  if b.budgetPx > 0 and b.spentPx + px > b.budgetPx: return false
  if b.blocksADoor(s): return false
  b.placements.add Placement(shape: s, cell: cell, serves: serves,
                             screen: screen)
  b.spentPx += px
  if screen: b.stats.screenPx += px
  true

proc nearestProtected(b: RoomBoard, cell: ConvexCell,
                      step = 10): tuple[found: bool, at: PtF] =
  ## The protected-floor sample inside this cell closest to its own site, or
  ## `found = false` when the cell is clean.
  result = (false, pt(0.0, 0.0))
  if cell.poly.len < 3: return
  let
    bb = cell.bbox()
    sx = float(cell.site.x)
    sy = float(cell.site.y)
  var best = 1.0e18
  var y = bb.y
  while y <= bb.y + bb.h:
    var x = bb.x
    while x <= bb.x + bb.w:
      if cell.contains(float(x), float(y)) and b.host.protectedAt(x, y):
        let d = (float(x) - sx) * (float(x) - sx) +
                (float(y) - sy) * (float(y) - sy)
        if d < best:
          best = d
          result = (true, pt(float(x), float(y)))
      x += step
    y += step

proc carveProtected(b: RoomBoard, cell: ConvexCell, margin: float,
                    passes = 6): ConvexCell =
  ## Cut the protected floor OUT of a cell instead of throwing the cell away.
  ##
  ## This is the difference between a generator and a rubble field. Protected
  ## floor — the capture columns, the flag ring, the spawn pockets — covers a
  ## large fraction of a 2-team board, and the engine silently DELETES any
  ## wall drawn on it, so a room built there cannot keep the sightline
  ## promise the interval cover makes on its behalf. The first version simply
  ## refused every cell that touched any of it, which on a standard board
  ## refused nearly all of them: `interiorFrac` came out at 0.049 and 13 of
  ## 20 seeds could not produce one valid map in 100 attempts.
  ##
  ## The complement of a protected region is not convex, so it cannot be a
  ## single half-plane. But the TANGENT half-plane at the protected sample
  ## nearest the site is convex, excludes that sample, and keeps the site — so
  ## iterating it converges on a convex sub-cell clear of the obstruction.
  ## Conservative: it removes more than strictly necessary, which is the right
  ## direction to be wrong in, because what is left is buildable for certain.
  result = cell
  for _ in 0 ..< passes:
    let (found, bad) = b.nearestProtected(result)
    if not found: return
    let
      dx = bad.x - float(result.site.x)
      dy = bad.y - float(result.site.y)
      len = sqrt(dx * dx + dy * dy)
    if len < 1.0:
      ## The site itself is protected: there is no sub-cell to keep.
      result.poly.setLen(0)
      result.owner.setLen(0)
      return
    let
      nx = dx / len
      ny = dy / len
    var
      poly = result.poly
      owner = result.owner
    ## Tagged as a boundary edge (-1): it faces protected floor, not a
    ## neighbouring room, so it must never be given a doorway.
    clipHalfPlane(poly, owner, nx, ny, nx * bad.x + ny * bad.y - margin, -1)
    result.poly = poly
    result.owner = owner
    if poly.len < 3: return

proc cellTouchesProtected(b: RoomBoard, cell: ConvexCell): bool =
  b.nearestProtected(cell).found

proc cellInBoard(b: RoomBoard, cell: ConvexCell): bool =
  ## Slack of two pixels on each side ON PURPOSE. `bbox` is INCLUSIVE, so a
  ## cell that legitimately touches the board edge reports `x + w == width + 1`
  ## — and the first version's exact test therefore rejected every cell on the
  ## rim, which on a standard board is most of them. Measured cost of that one
  ## off-by-one: 0 of 16 seeds produced a valid first attempt.
  let bb = cell.bbox()
  bb.x >= -2 and bb.y >= -2 and
    bb.x + bb.w <= b.host.width + 2 and bb.y + bb.h <= b.host.height + 2

# ---------------------------------------------------------------------------
# Rooms: ring + doorways
# ---------------------------------------------------------------------------

type DoorPlan = object
  edge: int
  t0, t1: float      ## span along the edge, in px from its start vertex

proc planDoorways(cell: ConvexCell, style: RoomStyle, rng: var MapRng,
                  maxDoors: int, verticalOnly = false): seq[DoorPlan] =
  ## Choose the openings. THE constraint that replaces the sightline
  ## prosthetic: a horizontal line meets a convex ring exactly twice, once on
  ## the WEST-facing chain and once on the EAST-facing chain, so a row can
  ## only escape if a west door and an east door overlap in y. This refuses
  ## that overlap, which makes "the ring blocks every row of its y-extent" a
  ## property of the geometry rather than of a scan run afterwards.
  ##
  ## `verticalOnly` is the SEAM case. A cell that is its own mirror image has
  ## its ring completed by the lift, so a door on its west chain reappears as
  ## a door on its east chain at exactly the same rows — the one arrangement
  ## the rule forbids, arriving through the back door. Restricting a seam
  ## room's doors to horizontal edges sidesteps it, and gives the map's
  ## centrepiece a north-south passage, which is the traffic a centre wants.
  var
    westSpans, eastSpans: seq[(float, float)]
    candidates: seq[int]
  for i in 0 ..< cell.edgeCount():
    let e = cell.edge(i)
    if e.owner < 0: continue                      ## board boundary: no door
    if cell.edgeLen(i) < float(style.doorPx + 2 * style.wallPx + 24): continue
    if verticalOnly:
      let (_, ny, _) = edgeNormal(e.a, e.b)
      if abs(ny) < 0.72: continue
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
  ## The pixels a doorway must keep clear: the opening plus a stub of room on
  ## the inside, so the fill pass cannot park a block against a door it never
  ## knew about. Axis-aligned, so a conservative superset of the oriented
  ## opening — the right direction to be wrong in.
  let
    reach = float(wallPx) + 52.0
    half = float(doorPx) / 2.0 + 10.0
    ext = half + reach * 0.6
    cx = mid.x - nx * (reach * 0.35)
    cy = mid.y - ny * (reach * 0.35)
  MapRect(x: int(cx - ext), y: int(cy - ext),
          w: int(2.0 * ext), h: int(2.0 * ext))

proc ringCostPx*(cell: ConvexCell, wallPx: int): int =
  ## What a ring on this cell will cost, before it is drawn. The interval
  ## cover's rooms are mandatory — their y-extents ARE the sightline
  ## guarantee — so their cost has to be known up front: a ring that runs out
  ## of budget half-drawn is a wall with a side missing, and the guarantee
  ## goes with it.
  var perimeter = 0.0
  for i in 0 ..< cell.edgeCount():
    perimeter += cell.edgeLen(i)
  int(perimeter * float(wallPx) * 0.86)

proc buildRing(b: RoomBoard, ci: int, hall: bool, rng: var MapRng,
               seamHalf = false) =
  ## A room: thin wall quads along the inset cell's own edges, split around
  ## the doorways. Never fill — a filled cell can seal a pocket, and "thin
  ## borders only" is what makes reachability a property of the drawing rather
  ## than of a flood fill run afterwards.
  let
    cell = b.allInset[ci]
    style = b.style
    thick = float(style.wallPx)
    axis = float(b.sym.axisX()) + 0.5
  if cell.poly.len < 3: return
  let
    maxDoors =
      if hall: max(1, cell.edgeCount() - 1)
      else: max(2, min(4, cell.edgeCount() - 1))
    doors = planDoorways(cell, style, rng, maxDoors, verticalOnly = seamHalf)
  ## A hall drops one whole side, chosen from the edges that face a NEIGHBOUR
  ## — never the board border, which would open the ring onto the map edge and
  ## hand the validator a clear border lane.
  var skipEdge = -1
  if hall:
    var facing: seq[int]
    for i in 0 ..< cell.edgeCount():
      if cell.owner[i] >= 0 and cell.edgeLen(i) >= 40.0: facing.add i
    if facing.len > 0: skipEdge = facing[rng.pick(facing.len)]

  ## A ring with no doorway is a sealed pocket — floor nobody can reach, and
  ## the sim validator will not catch it because it only demands that the
  ## flags and the centre connect. If the chain rule and the length rule
  ## between them left no opening, force one on the longest neighbour-facing
  ## edge: a room you cannot enter is strictly worse than a row the interval
  ## cover has to find elsewhere.
  var doorsOnEdge = newSeq[seq[DoorPlan]](cell.edgeCount())
  for d in doors: doorsOnEdge[d.edge].add d
  if doors.len == 0 and not hall:
    var (bestEdge, bestLen) = (-1, 0.0)
    for i in 0 ..< cell.edgeCount():
      if cell.owner[i] < 0: continue
      if cell.edgeLen(i) > bestLen: (bestEdge, bestLen) = (i, cell.edgeLen(i))
    if bestEdge >= 0 and bestLen > 40.0:
      let w = min(float(style.doorPx), bestLen - 24.0)
      doorsOnEdge[bestEdge].add DoorPlan(
        edge: bestEdge, t0: (bestLen - w) * 0.5, t1: (bestLen + w) * 0.5)

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
    ## On a seam cell only the half at x <= axis is drawn; the mirror supplies
    ## the rest. x is monotone along a straight edge, so the span clips to a
    ## single sub-interval.
    var
      spanLo = -thick
      spanHi = len + thick
    if seamHalf:
      if abs(dx) < 1e-9:
        if e.a.x > axis: continue
      elif dx > 0.0: spanHi = min(spanHi, (axis - e.a.x) / dx)
      else: spanLo = max(spanLo, (axis - e.a.x) / dx)
      if spanHi - spanLo < 8.0: continue

    var cuts = doorsOnEdge[i]
    cuts.sort(proc(p, q: DoorPlan): int = cmp(p.t0, q.t0))
    ## Segments run from -thick to len+thick so consecutive walls overlap at
    ## the corners; a ring of exactly-length segments leaves a mitre-shaped
    ## hole at every vertex.
    var cursor = spanLo
    for d in cuts:
      let
        dt0 = clamp(d.t0, spanLo, spanHi)
        dt1 = clamp(d.t1, spanLo, spanHi)
      if dt1 - dt0 < 8.0: continue
      if dt0 - cursor > 6.0:
        discard b.place(wallQuad(pt(e.a.x + dx * cursor, e.a.y + dy * cursor),
                                 pt(e.a.x + dx * dt0, e.a.y + dy * dt0),
                                 nx, ny, thick), ci, "room wall")
      let mid = pt(e.a.x + dx * (dt0 + dt1) * 0.5,
                   e.a.y + dy * (dt0 + dt1) * 0.5)
      b.doorRects.add doorCorridor(mid, nx, ny, style.doorPx, style.wallPx)
      inc b.stats.doorways
      cursor = dt1
    if spanHi - cursor > 6.0:
      discard b.place(wallQuad(pt(e.a.x + dx * cursor, e.a.y + dy * cursor),
                               pt(e.a.x + dx * spanHi, e.a.y + dy * spanHi),
                               nx, ny, thick), ci, "room wall")

# ---------------------------------------------------------------------------
# Fill: cover inside the cells, never outside them
# ---------------------------------------------------------------------------

proc clipToCell(b: RoomBoard, ci: int, shapes: seq[ArenaShape],
                serves: string, margin = 2.0): int {.discardable.} =
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
  let
    c = cell.centroid()
    r = max(0.0, cell.inradius() - shrink)
    half = r * 0.82
  MapRect(x: int(c.x - half), y: int(c.y - half),
          w: max(8, int(2.0 * half)), h: max(8, int(2.0 * half)))

proc fillCell(b: RoomBoard, ci: int, role: CellRole, rng: var MapRng,
              vocabRng: var Rand) =
  let
    cell = b.allInset[ci]
    style = b.style
    rules = b.rules
  if cell.poly.len < 3: return
  var vp = vocabParams(rules)
  case role
  of crRing, crHall:
    ## Inside a room: one mass, well clear of the walls and of every doorway
    ## (`place` checks the door rects). This is what makes the interior READ
    ## as a room rather than as an empty box.
    let region = vocabRegion(cell, float(style.wallPx) + 30.0)
    if region.w < 56 or region.h < 56: return
    vp.density = 0.45
    b.clipToCell(ci, emitVocab(style.vocab[rng.pick(style.vocab.len)],
                               vocabRng, region, vp), "room interior mass")
  of crBlocks:
    let region = vocabRegion(cell, 8.0)
    vp.density = 0.85
    b.clipToCell(ci, emitVocab(style.vocab[rng.pick(style.vocab.len)],
                               vocabRng, region, vp), "block mass")
  of crPlaza:
    ## A plaza earns a LITTLE cover: enough that crossing it is not naked,
    ## little enough that it still reads as open ground.
    for _ in 0 .. rng.pick(3):
      let
        rad = max(16, rules.coverSizePx div 2 - rng.pick(12))
        c = cell.centroid()
        ir = max(1.0, cell.inradius() - float(rad) - 6.0)
        ang = float(rng.pick(628)) / 100.0
        d = float(rng.pick(max(1, int(ir))))
        s = ArenaShape(kind: shapeDisc, cx: int(c.x + cos(ang) * d),
                       cy: int(c.y + sin(ang) * d), radius: rad)
      if fitsInCell(cell, s, 4.0): discard b.place(s, ci, "plaza cover")
  of crRubble:
    ## Biome terrain, clipped to the cell. Noise is a TEXTURE layer here and
    ## deliberately downstream of structure: a Gaussian excursion set has
    ## strictly positive Euler density at every threshold our cover cap
    ## permits, so it makes blobs, never rooms. Blobs are what a quarry wants.
    ##
    ## MULTI-BIOME: on a big board each rubble zone draws its own style from
    ## the map's palette and ~40% of them stay bare, which is exactly how the
    ## source composes biomes — additively, with stochastic partial coverage
    ## as the blend.
    let bb = cell.bbox()
    if bb.w < 60 or bb.h < 60: return
    if style.multiBiome and rng.pick(100) < 40: return
    let pick =
      if style.multiBiome: style.biomePalette[rng.pick(style.biomePalette.len)]
      else: style.biome
    var bp = defaultBiomeParams(pick)
    bp.cell = max(BiomeCellPx, rules.coverSizePx div 3)
    ## The zone is SHRUNK to a centred sub-rect and the gap is the soft seam
    ## between this biome and whatever surrounds it.
    let
      inset = min(bb.w, bb.h) div 8
      zone = MapRect(x: bb.x + inset, y: bb.y + inset,
                     w: bb.w - 2 * inset, h: bb.h - 2 * inset)
      dom = FundamentalDomain(
        rect: zone,
        board: MapRect(x: 0, y: 0, w: b.host.width, h: b.host.height),
        order: max(2, b.sym.orbitOrder()))
    b.clipToCell(ci, genBiome(vocabRng, pick, zone, bp, dom), "rubble", 4.0)
  of crApron:
    ## Cover on the APPROACH to a pedestal. The engine protects the floor
    ## right around a stand, so the only place cover CAN go is the annulus
    ## just outside it — which is exactly where an attacker has to stand.
    ## Measured defect: pool standCover median 1.1% against the arena's 7.2%.
    var placed = 0
    for _ in 0 ..< 12:
      if placed >= 3: break
      let
        c = cell.centroid()
        rad = 20 + rng.pick(20)
        ir = max(1.0, cell.inradius() - float(rad) - 8.0)
        ang = float(rng.pick(628)) / 100.0
        d = float(rng.pick(max(1, int(ir))))
        cx = int(c.x + cos(ang) * d)
        cy = int(c.y + sin(ang) * d)
        s = ArenaShape(kind: shapeDisc, cx: cx, cy: cy, radius: rad)
      if not fitsInCell(cell, s, 8.0): continue
      if b.host.protectedAt(cx, cy): continue
      ## Keep a corridor between apron pieces, or an apron cell can pinch the
      ## street it sits on. This is a CHECK, not a guarantee — stated plainly;
      ## the validator's eroded flood is the backstop.
      var tooClose = false
      for p in b.placements:
        if p.cell != ci or p.shape.kind != shapeDisc: continue
        let
          dx = p.shape.cx - cx
          dy = p.shape.cy - cy
          need = p.shape.radius + rad + rules.minCorridorWidthPx
        if dx * dx + dy * dy < need * need: tooClose = true
      if tooClose: continue
      if b.place(s, ci, "cover on the stand approach"): inc placed
  of crStreet: discard

proc fillSeamCell(b: RoomBoard, ci: int, rng: var MapRng) =
  ## A cell that is its own mirror image is the ONLY place a 2-team map can
  ## put a genuine central feature, and 52% of the old generator's 2-team maps
  ## had none.
  ##
  ## Every piece is either centred ON the axis — so it is its own mirror and
  ## the lift is idempotent — or clear of it by half a corridor, so the piece
  ## and its image leave a full corridor between them. Nothing in between,
  ## because in between is where a pair of images fuses into a plug.
  let
    cell = b.allInset[ci]
    axis = float(b.sym.axisX())
    keep = float(b.rules.minCorridorWidthPx) / 2.0 + 6.0
  if cell.poly.len < 3: return
  let c = cell.centroid()
  for k in 0 ..< 6:
    let
      onAxis = k mod 2 == 0
      rad = b.rules.coverSizePx div 2 + rng.pick(max(1, b.rules.coverSizePx div 3))
      ir = max(1.0, cell.inradius() - float(rad) - 6.0)
      dy = float(rng.pick(max(1, int(2.0 * ir)))) - ir
      cx = if onAxis: axis else: axis - keep - float(rad) - float(rng.pick(60))
      s =
        if onAxis and rng.coin():
          ArenaShape(kind: shapeDiamond, cx: int(cx), cy: int(c.y + dy),
                     radius: rad)
        else:
          ArenaShape(kind: shapeDisc, cx: int(cx), cy: int(c.y + dy),
                     radius: rad)
    if not fitsInCell(cell, s, 4.0): continue
    if b.host.protectedAt(s.cx, s.cy): continue
    discard b.place(s, ci, "central feature on the seam")

# ---------------------------------------------------------------------------
# The 1-D interval cover: no cross-field horizontal sightline
# ---------------------------------------------------------------------------

proc scanRows(b: RoomBoard): seq[int] =
  var y = b.host.border + 2
  while y < b.host.height - b.host.border:
    result.add y
    y += ScanStep

proc rowsCovered(b: RoomBoard): seq[bool] =
  ## Which of the validator's scan rows the CURRENT wall set actually blocks,
  ## measured the way the validator measures: at least one wall pixel inside
  ## the sightline x-band that survives the protected-floor carve.
  ##
  ## Per SHAPE (bounding box, then a few samples per row) rather than by
  ## rasterising the board: a giant board is 5.5M pixels and this runs on
  ## every candidate.
  let rows = b.scanRows()
  result = newSeq[bool](rows.len)
  if rows.len == 0: return
  let
    y0 = rows[0]
    ax = b.host.scanLoX
    bx = b.host.scanHiX
  for pl in b.placements:
    let (sx0, sy0, sx1, sy1) = b.host.shapeBox(pl.shape)
    if sx1 < ax or sx0 > bx: continue
    var ri = max(0, (sy0 - y0 + ScanStep - 1) div ScanStep)
    while ri < rows.len and rows[ri] <= sy1:
      let y = rows[ri]
      if not result[ri]:
        var x = max(ax, sx0)
        let xe = min(bx, sx1)
        while x <= xe:
          if b.host.inShapeAt(x, y, pl.shape) and not b.host.protectedAt(x, y):
            result[ri] = true
            break
          x += 3
      inc ri
  ## The images the lift adds block rows too, and on a rot180/rot90 board they
  ## block DIFFERENT ones (row y maps to row h-1-y). Fold them in rather than
  ## making the domain carry the whole band alone.
  if b.sym.kind != symMirror:
    var folded = newSeq[bool](rows.len)
    for i, y in rows:
      let mi = (b.sym.reflectY(y) - y0) div ScanStep
      if mi >= 0 and mi < rows.len and result[mi]: folded[i] = true
    for i in 0 ..< rows.len:
      if folded[i]: result[i] = true

proc coverGaps(b: RoomBoard): seq[int] =
  for i, ok in b.rowsCovered():
    if not ok: result.add i

# ---------------------------------------------------------------------------
# Skeleton route count — proved on the METRIC's grid
# ---------------------------------------------------------------------------

type FlowEdge = object
  to, rev, cap: int

proc addFlowEdge(g: var seq[seq[FlowEdge]], a, bIdx, cap: int) =
  g[a].add FlowEdge(to: bIdx, rev: g[bIdx].len, cap: cap)
  g[bIdx].add FlowEdge(to: a, rev: g[a].len - 1, cap: 0)

proc maxFlow(g: var seq[seq[FlowEdge]], s, t, cap: int): int =
  ## Edmonds-Karp, capped. We only ever ask "are there three?", so this
  ## returns after at most `cap` augmenting passes.
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
      for ei in 0 ..< g[v].len:
        if g[v][ei].cap > 0 and prevNode[g[v][ei].to] < 0:
          prevNode[g[v][ei].to] = v
          prevEdge[g[v][ei].to] = ei
          queue.add g[v][ei].to
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

proc skeletonRouteCount*(b: RoomBoard): int =
  ## How many VERTEX-DISJOINT routes the street network carries between the
  ## two furthest-apart base approaches, on the 26px grid `map_metrics`
  ## measures on.
  ##
  ## This is the number the fill pass provably cannot reduce: every wall this
  ## generator writes lies inside an inset cell, and no inset-cell pixel is a
  ## street pixel. Checking it HERE, before a single cover piece exists,
  ## bounds the finished map from below.
  let
    cs = SkeletonCellPx
    cols = b.host.width div cs
    rows = b.host.height div cs
  if cols < 4 or rows < 4 or b.host.anchors.len < 2: return 0
  var open = newSeq[bool](cols * rows)
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let
        x = c * cs + cs div 2
        y = r * cs + cs div 2
      if x < b.host.border or y < b.host.border or
          x >= b.host.width - b.host.border or
          y >= b.host.height - b.host.border: continue
      if b.host.protectedAt(x, y):
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
  var g = newSeq[seq[FlowEdge]](2 * cols * rows + 2)
  let
    src = 2 * cols * rows
    snk = src + 1
  for i in 0 ..< cols * rows:
    if open[i]: addFlowEdge(g, 2 * i, 2 * i + 1, 1)
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let i = r * cols + c
      if not open[i]: continue
      for (dc, dr) in [(1, 0), (-1, 0), (0, 1), (0, -1)]:
        let (nc, nr) = (c + dc, r + dr)
        if nc < 0 or nr < 0 or nc >= cols or nr >= rows: continue
        if open[nr * cols + nc]:
          addFlowEdge(g, 2 * i + 1, 2 * (nr * cols + nc), 1)
  ## Source and sink are the two anchors furthest apart — on a 4-team board
  ## that is the OPPOSED pair, not two adjacent corners, so the count measures
  ## a real base-to-base crossing.
  var (bi, bj, bd) = (0, 1, -1)
  for i in 0 ..< b.host.anchors.len:
    for j in i + 1 ..< b.host.anchors.len:
      let
        dx = b.host.anchors[i].x - b.host.anchors[j].x
        dy = b.host.anchors[i].y - b.host.anchors[j].y
        d = dx * dx + dy * dy
      if d > bd: (bi, bj, bd) = (i, j, d)
  var attached = 0
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      let i = r * cols + c
      if not open[i]: continue
      let
        x = c * cs + cs div 2
        y = r * cs + cs div 2
      if abs(x - b.host.anchors[bi].x) + abs(y - b.host.anchors[bi].y) <= 3 * cs:
        addFlowEdge(g, src, 2 * i, 1)
        inc attached
      elif abs(x - b.host.anchors[bj].x) + abs(y - b.host.anchors[bj].y) <= 3 * cs:
        addFlowEdge(g, 2 * i + 1, snk, 1)
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
    let (x, y) = (x0 + dx * i, y0 + dy * i)
    if x < 0 or y < 0 or x >= b.host.width or y >= b.host.height: return i
    if b.host.wallAt(x, y, obstacles): return i
    i += 2
  limit

proc currentShapes(b: RoomBoard): seq[ArenaShape] =
  for p in b.placements: result.add p.shape

proc glazeWindows(b: RoomBoard, rng: var MapRng) =
  ## Glass ONLY where a sightline genuinely exists to see through.
  ##
  ## Measured defect: 27.8% of the old generator's panes cleared 200px of open
  ## ground on both sides, against the hand-authored arena's 71.4%, and 41.7%
  ## of maps had no useful pane at all. The cause was not a bad selector —
  ## adjacent lattice columns sat 51-76px apart, so the SPACING was the
  ## occluder. Here a pane's two sides are a street and a room interior, and
  ## the pane is only cut once a ray has been fired and measured on both.
  ##
  ## The promise outlives the pass: the post re-fires the same ray after
  ## everything else has rendered, so a later scene that blocks it fails the
  ## map by name instead of shipping a pointless window.
  var candidates: seq[int]
  for i, p in b.placements:
    if p.shape.kind != shapePolygon or p.shape.window: continue
    if p.serves != "room wall": continue
    if shapeAreaPx(p.shape) < 44 * max(6, b.style.wallPx): continue
    candidates.add i
  rng.shuffle(candidates)
  let obstacles = b.host.lift(b.currentShapes())
  var glazed = 0
  for idx in candidates:
    if glazed >= b.style.glassPanes: break
    let
      (x0, y0, x1, y1) = b.host.shapeBox(b.placements[idx].shape)
      cx = (x0 + x1) div 2
      cy = (y0 + y1) div 2
      wide = (x1 - x0) >= (y1 - y0)
      (dx, dy) = if wide: (0, 1) else: (1, 0)
      span = if wide: (y1 - y0) else: (x1 - x0)
      aOut = b.rayOpenPx(obstacles, cx - dx * (span div 2 + 3),
                         cy - dy * (span div 2 + 3), -dx, -dy, 420)
      bOut = b.rayOpenPx(obstacles, cx + dx * (span div 2 + 3),
                         cy + dy * (span div 2 + 3), dx, dy, 420)
    if aOut < UsefulWindowPx or bOut < UsefulWindowPx:
      inc b.stats.glassRejected
      continue
    ## Cut a pane out of the MIDDLE of the host wall rather than glazing the
    ## whole segment: a wall that is entirely glass is a window with no frame,
    ## and the frame is what makes it read as a building.
    let
      paneLen = min(104, max(48, (if wide: x1 - x0 else: y1 - y0) div 2))
      pane =
        if wide: MapRect(x: cx - paneLen div 2, y: y0, w: paneLen, h: y1 - y0 + 1)
        else: MapRect(x: x0, y: cy - paneLen div 2, w: x1 - x0 + 1, h: paneLen)
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
        let obs = b.host.lift(b.currentShapes())
        b.rayOpenPx(obs, px - pdx * (pspan div 2 + 3),
                    py - pdy * (pspan div 2 + 3), -pdx, -pdy, 300) >= 150 and
        b.rayOpenPx(obs, px + pdx * (pspan div 2 + 3),
                    py + pdy * (pspan div 2 + 3), pdx, pdy, 300) >= 150)

proc digTrenches(b: RoomBoard, rng: var MapRng) =
  ## Trenches go on EXPOSED crossings — street with no cover inside a lethal
  ## envelope — and nowhere else. A trench with cover beside it is decoration;
  ## a trench where you would otherwise be shot crossing is the mechanic
  ## doing its job.
  if b.style.trenchRuns <= 0 or b.mine.len == 0: return
  let
    obstacles = b.host.lift(b.currentShapes())
    size = b.rules.trenchSizePx
  var dug = 0
  for _ in 0 ..< 48:
    if dug >= b.style.trenchRuns: break
    let ci = b.mine[rng.pick(b.mine.len)]
    if b.role[ci] notin {crStreet, crPlaza}: continue
    let cell = b.allCells[ci]
    if cell.poly.len < 3: continue
    let
      c = cell.centroid()
      horiz = rng.coin()
      w = if horiz: 3 * size else: size
      h = if horiz: size else: 3 * size
      r = MapRect(x: int(c.x) - w div 2, y: int(c.y) - h div 2, w: w, h: h)
    if r.x < b.host.border or r.y < b.host.border or
        r.x + r.w >= b.host.width - b.host.border or
        r.y + r.h >= b.host.height - b.host.border: continue
    if b.host.protectedAt(r.x, r.y) or
        b.host.protectedAt(r.x + r.w, r.y + r.h): continue
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
        if b.host.wallAt(x, y, obstacles): clear = false
    if not clear: continue
    ## Fairness before density: the dig ships with its whole orbit or not at
    ## all, so neither team ever has a private pit.
    for img in b.host.liftRect(r):
      b.trenches.add ArenaShape(kind: shapeRect, rect: img)
    inc dug

proc placePickups(b: RoomBoard, rng: var MapRng) =
  ## Half safe, half contested — and back on floor the terrain actually left
  ## open. A kit that spawns in stone is a kit nobody collects: measured at
  ## 5.0% in stone and 15.5% unreachable on the old 4-team boards.
  let obstacles = b.host.lift(b.currentShapes())
  for i, base in b.host.kitCandidates:
    var best = base
    block find:
      for radius in countup(0, 280, 10):
        for a in 0 ..< 16:
          let
            ang = TAU * float(a) / 16.0
            x = base.x + int(cos(ang) * float(radius))
            y = base.y + int(sin(ang) * float(radius))
          if x < b.host.border or y < b.host.border or
              x >= b.host.width - b.host.border or
              y >= b.host.height - b.host.border: continue
          if b.host.wallAt(x, y, obstacles): continue
          ## Even-index kits want SHELTER (inside a room, where taking one
          ## costs a detour off the street), odd-index kits want the street,
          ## where taking one costs exposure. Either is a real decision; a kit
          ## dropped wherever there happened to be floor is not.
          var inRoom = false
          for ci, cell in b.allInset:
            if b.role[ci] in {crRing, crHall} and cell.poly.len >= 3 and
                cell.contains(float(x), float(y)):
              inRoom = true
              break
          if (i mod 2 == 0) != inRoom and radius < 230: continue
          best = MapPoint(x: x, y: y)
          break find
    b.kits.add best

# ---------------------------------------------------------------------------
# The pass
# ---------------------------------------------------------------------------

type TerrainResult* = object
  shapes*: seq[ArenaShape]     ## DOMAIN shapes; the caller lifts them
  trenches*: seq[ArenaShape]   ## already lifted (full board)
  kits*: seq[MapPoint]
  biome*: BiomeStyle
  stats*: RoomStats
  notes*: seq[string]

proc buildRoomBoard*(host: TerrainHost, seed, attempt: int): RoomBoard =
  ## The whole pass, in the order the brief lays it out: seed, lift,
  ## partition, rooms and doorways, protected skeleton, fill, features.
  let
    root = mapSeed(seed, attempt)
    rules = mapRules(host.sizeClass, host.teams)
  var
    layoutRng = root.stream(SceneLayout)
    terrainRng = root.stream(SceneTerrain)
    coverRng = root.stream(SceneCover)
    pickupRng = root.stream(ScenePickups)
    biomeRng = root.stream(SceneBiome)
  var vocabRng = initRand(int(biomeRng.next() and 0x7FFF_FFFF'u64))

  result = RoomBoard(host: host, rules: rules,
                     sym: symGroup(host.symmetry, host.width, host.height))
  result.style = drawStyle(layoutRng, rules, host)
  let
    sym = result.sym
    dom = sym.domain()
    style = result.style

  # --- 1. SEED the fundamental domain -------------------------------------
  var pre: seq[MapPoint]
  ## ⚠️ The axis FIRST, at spacing below r. A mirror axis is a Voronoi edge
  ## unless a seed sits on it, and an unseeded axis is a perfectly straight
  ## full-board corridor down the middle of every 2-team map.
  for p in sym.axisSeeds(style.pitchPx * 3 div 4,
                         host.border + 40, host.height - host.border - 40):
    pre.add p
  ## The seeding region is the fundamental domain INTERSECTED with the
  ## buildable band, so no site is wasted inside protected floor.
  let region = block:
    let
      x0 = max(dom.x + host.border, host.buildRegion.x)
      y0 = max(dom.y + host.border, host.buildRegion.y)
      x1 = min(dom.x + dom.w, host.buildRegion.x + host.buildRegion.w)
      y1 = min(dom.y + dom.h - host.border,
               host.buildRegion.y + host.buildRegion.h)
    MapRect(x: x0, y: y0, w: max(48, x1 - x0), h: max(48, y1 - y0))
  ## …and each pedestal gets a site on its APPROACH. Seeding the pedestal
  ## itself is useless on a column-endzone board — the anchor sits inside the
  ## protected strip, so its whole cell would be carved away — but a site at
  ## the same row, just inside the buildable band, owns the annulus an
  ## attacker actually has to stand in. That annulus is where the old pool had
  ## standCover 1.1% against the hand-authored arena's 7.2%.
  for a in host.anchors:
    let ap = MapPoint(x: clamp(a.x, region.x + 24, region.x + region.w - 24),
                      y: clamp(a.y, region.y + 24, region.y + region.h - 24))
    if inRectPt(ap, dom) and ap notin pre: pre.add ap
  var domainSites: seq[MapPoint]
  for p in seedSites(style.pattern, terrainRng, region, style.pitchPx, pre,
                     host.center):
    ## `liftSites` promises that site index i names domain seed i, and it can
    ## only keep that promise on a duplicate-free input.
    if p notin domainSites: domainSites.add p
  result.stats.sites = domainSites.len

  # --- 2. LIFT by the orbit, 3. PARTITION ---------------------------------
  let sites = sym.liftSites(domainSites)
  result.allCells = voronoiCells(
    sites, MapRect(x: 0, y: 0, w: host.width, h: host.height))
  ## Inset by the street half-width — EXCEPT against the board border, where
  ## there is no neighbour to make room for. Insetting there would leave a
  ## clear lane hugging the map edge, which is precisely the row the sightline
  ## validator rejects (it scans from y = border + 2).
  result.allInset = newSeq[ConvexCell](result.allCells.len)
  for i, c in result.allCells:
    result.allInset[i] = insetCellEdges(c, float(style.insetPx), RimInsetPx)
  result.role = newSeq[CellRole](result.allCells.len)
  ## The domain owns the cell of every seed it drew, and `liftSites` puts
  ## those first and in order. The group permutes the cells, so drawing here
  ## and lifting covers every cell exactly once — no clipping to a half-board
  ## rectangle anywhere, which is what lets a rot180 cell bulge across the
  ## seam without breaking anything.
  for si in 0 ..< domainSites.len: result.mine.add si

  result.budgetPx = style.coverPermille * host.interiorPx div 1000 div
    max(2, sym.orbitOrder())

  # --- 4. ROOMS: which cells, and why -------------------------------------
  let minRingInradius = float(style.wallPx) + MinRingWallSlack
  var capable: seq[int]
  for ci in result.mine:
    var inset = result.allInset[ci]
    if inset.poly.len < 3 or not result.cellInBoard(inset):
      result.role[ci] = crStreet
      continue
    if result.cellTouchesProtected(inset):
      ## Carve the protected floor out and keep what is left. The APRON is
      ## what remains when the carve leaves too little to build a room in —
      ## the annulus just outside a pedestal, which is exactly where an
      ## attacker has to stand and where the old pool had no cover at all.
      inset = result.carveProtected(inset, 8.0)
      result.allInset[ci] = inset
      if inset.poly.len < 3 or inset.inradius() < minRingInradius:
        result.role[ci] = crApron
        continue
    elif inset.inradius() < minRingInradius:
      result.role[ci] = crPlaza
      continue
    capable.add ci

  ## THE INTERVAL COVER. Under the lift the domain's own structures must break
  ## every horizontal ray, so pick a set of cells whose y-extents COVER the
  ## validator's scan band, taking at each step the candidate that reaches
  ## FURTHEST rather than merely the next one that starts in time. Each chosen
  ## cell becomes a room because it covers rows nothing else covers — that is
  ## the reason, and it is why no repair pass is needed.
  var
    yLo = newSeq[int](result.allCells.len)
    yHi = newSeq[int](result.allCells.len)
    inBand = newSeq[bool](result.allCells.len)
  for ci in capable:
    let bb = result.allInset[ci].bbox()
    yLo[ci] = bb.y
    yHi[ci] = bb.y + bb.h
    inBand[ci] = bb.x + bb.w >= host.scanLoX and bb.x <= host.scanHiX
  var
    chosen: HashSet[int]
    cursor = host.border + 2
  while cursor < host.height - host.border:
    var best = -1
    for ci in capable:
      if ci in chosen or not inBand[ci]: continue
      if yLo[ci] <= cursor and yHi[ci] > cursor:
        if best < 0 or yHi[ci] > yHi[best]: best = ci
    if best < 0:
      ## An honest failure, not a patch: this seed's partition cannot cover
      ## the band, so the candidate is left to fail validation and best-of-K
      ## draws another. No random diamonds are dropped to make it pass — that
      ## pass does not exist here any more.
      result.note "y-cover incomplete from y=" & $cursor
      break
    chosen.incl best
    cursor = yHi[best]
  for ci in chosen: result.role[ci] = crRing

  ## SIZE THE LAST PIECE. The interval cover's rooms are mandatory, so if they
  ## alone would blow the cover budget the answer is thinner walls, not fewer
  ## rooms: wall thickness is continuous and monotone in cover, room count is
  ## not, and dropping a room drops a sightline guarantee with it.
  var mandatory = 0
  for ci in chosen: mandatory += ringCostPx(result.allInset[ci], style.wallPx)
  while mandatory > result.budgetPx * 3 div 4 and result.style.wallPx > MinWallPx:
    result.style.wallPx -= 2
    mandatory = 0
    for ci in chosen:
      mandatory += ringCostPx(result.allInset[ci], result.style.wallPx)

  ## Spend the rest on character, biggest cells first so the map gains
  ## architecture rather than confetti. Rings are added only while the running
  ## estimate fits — an over-budget ring is a wall with a side missing.
  var
    spare = result.budgetPx - mandatory
    rest = capable.filterIt(it notin chosen)
  let board = result   ## `result` inside the comparator is the comparator's
  rest.sort(proc(p, q: int): int =
    cmp(area(board.allInset[q]), area(board.allInset[p])))
  for ci in rest:
    let
      roll = terrainRng.pick(100)
      cost = ringCostPx(result.allInset[ci], result.style.wallPx)
      canRing = cost <= spare * 2 div 3
    result.role[ci] =
      if canRing and roll < style.ringBias: crRing
      elif canRing and roll < style.ringBias + style.hallBias: crHall
      elif roll < style.ringBias + style.hallBias + style.rubbleBias: crRubble
      elif terrainRng.coin(): crBlocks
      else: crPlaza
    if result.role[ci] in {crRing, crHall}: spare -= cost

  # --- 5. PROTECTED SKELETON ---------------------------------------------
  #
  # The route count is measured HERE, on the street network alone, before a
  # single wall exists. Everything drawn after this lives inside an inset cell
  # and no inset-cell pixel is a street pixel, so the finished map cannot
  # carry fewer routes than this number.
  result.stats.skeletonRoutes = result.skeletonRouteCount()

  for ci in result.mine:
    let seam = sym.isFixed(result.allCells[ci].site)
    case result.role[ci]
    of crRing: result.buildRing(ci, hall = false, terrainRng, seamHalf = seam)
    of crHall: result.buildRing(ci, hall = not seam, terrainRng,
                                seamHalf = seam)
    else: discard

  # --- 6. FILL: cover, on the other pixel family --------------------------
  for ci in result.mine:
    if sym.isFixed(result.allCells[ci].site):
      result.fillSeamCell(ci, coverRng)
    else:
      result.fillCell(ci, result.role[ci], coverRng, vocabRng)

  ## SPEND THE BUDGET. Measured on the first working build: the fill came out
  ## at 0-83 permille against a 50-160 target, and seven of sixteen seeds were
  ## rejected as "too open". Rooms are bounded by the interval cover and
  ## plazas are deliberately sparse, so nothing was reaching for the rest of
  ## the allowance. This tops it up from the same vocabulary, biggest cells
  ## first, and stops at three quarters of the budget so the ceiling is never
  ## the thing that rejects a map.
  block spendTheRest:
    var fillable: seq[int]
    for ci in result.mine:
      if result.role[ci] in {crPlaza, crBlocks, crRubble} and
          result.allInset[ci].poly.len >= 3:
        fillable.add ci
    if fillable.len == 0: break spendTheRest
    fillable.sort(proc(p, q: int): int =
      cmp(area(board.allInset[q]), area(board.allInset[p])))
    var guard = 0
    while result.spentPx < result.budgetPx * 3 div 4 and guard < 60:
      inc guard
      let ci = fillable[guard mod fillable.len]
      let before = result.spentPx
      result.fillCell(ci, crBlocks, coverRng, vocabRng)
      if result.spentPx == before and guard > fillable.len * 3: break

  # --- 7. FEATURES WITH REASONS ------------------------------------------
  result.glazeWindows(coverRng)
  result.digTrenches(coverRng)
  result.placePickups(pickupRng)

  # --- accounting ---------------------------------------------------------
  var styles: HashSet[BiomeStyle]
  for ci in result.mine:
    inc result.stats.cells
    case result.role[ci]
    of crRing: inc result.stats.rings
    of crHall: inc result.stats.halls
    of crBlocks: inc result.stats.blocks
    of crPlaza: inc result.stats.plazas
    of crRubble:
      inc result.stats.rubble
      styles.incl style.biome
    of crApron: inc result.stats.aprons
    of crStreet: discard
  result.stats.biomesUsed =
    if style.multiBiome: style.biomePalette.len else: 1
  result.stats.wallPx = result.spentPx
  result.stats.uncoveredRows = result.coverGaps().len
  for p in result.posts:
    if not p.check(): result.stats.brokenPosts.add p.claim

proc buildRoomTerrain*(host: TerrainHost, seed, attempt: int): TerrainResult =
  ## THE call `arena.generateMapAttempt` makes.
  let b = buildRoomBoard(host, seed, attempt)
  for p in b.placements: result.shapes.add p.shape
  result.trenches = b.trenches
  result.kits = b.kits
  result.biome = b.style.biome
  result.stats = b.stats
  result.notes = b.notes

## map_archetypes — WHICH MAP THIS IS.
##
## The brief's primary acceptance criterion is a statement about the GRAPH:
##
##   "an archetype picks the route topology and the spatial character; the
##    biome and the shape vocabulary then only skin it. Different archetype =
##    different GRAPH, not different pebbles."
##
## Before this module the generator had exactly two topologies — the three-lane
## half-field (2 teams) and the street grid (4 teams) — skinned by five biomes
## and a twelve-entry shape vocabulary. That is enough to make a 50-map sheet
## look VARIED and not enough to make one tile NAMEABLE: rendered, all twenty
## 2-team tiles carried the same three lane bands, the same centre plaza and
## the same two spawn pockets (docs/plans/2026-08-06-sheet-2team-verdict.md).
## Sameness at the level of the route graph is invisible to every per-map
## metric we own, because every one of them is computed on ONE map.
##
## ---------------------------------------------------------------------------
## THE ONE CONSTRUCTION EVERY ARCHETYPE USES
## ---------------------------------------------------------------------------
##
## Route count rises only when floor is OPENED; cover rises only when wall is
## ADDED. The two layers have opposite monotonicity, so they are given disjoint
## pixel sets rather than allowed to fight: an archetype RESERVES its corridors
## before any fill is drawn, and anything overlapping one is dropped. That is
## the same argument `map_lanes` makes for the three-lane grammar, generalized
## to topologies a lane network cannot express. Connectivity then holds by
## construction instead of by luck — measured on 4-team boards before the
## street grid existed, sparse fills failed "no 26px route to the blue flag" at
## 125-167 permille and dense ones failed "too clogged" at 175-242, with no
## window in between, because nothing reserved a corridor.
##
## Reserved corridors are given in BOARD coordinates and built symmetric about
## the board centre. The generator emits terrain into a fundamental domain and
## lifts it, so a corridor set that is already invariant under the map's
## symmetry group survives the lift as itself: the quarter of a ring road that
## falls in a rot90 quadrant lifts back into exactly that ring road, with no
## seam and no corner gap. Building the same shape in domain-relative
## coordinates is what makes a four-fold lift read as a pinwheel.
##
## ---------------------------------------------------------------------------
## WHY A RESERVED RUN CARRIES ITS OWN BLOCKERS
## ---------------------------------------------------------------------------
##
## A corridor that crosses the whole board leaves an open horizontal ray, and
## the validator rejects those. The generator's row-cover pass would plug it —
## but a picket is 24 px wide and 26 px tall, and three of them stacked across
## a 68 px corridor is a 24 x 78 plug that SEALS the corridor it was placed in.
## That is a route the archetype promised and the repair pass quietly took
## back, and it is the shape of defect the play harness measured: a generated
## map scoring staticScore 1.000 whose enemy heart was never taken in three
## episodes, with 62% of its floor never entered.
##
## So every full-width run is CHICANED at construction time: alternating
## half-width blockers, top edge then bottom edge, so no straight ray threads
## the run while a serpentine at least `MinRouteWidthPx` wide always does. The
## row is closed by the same geometry that keeps the route open, which is what
## lets the picket pass leave reserved ground alone.

import std/math
import sim_types
import map_rules
import map_seed
import mapgen_vocab

const
  MinRouteWidthPx* = 30
    ## The narrowest a chicaned corridor is ever left. Above the validator's
    ## 26 px passability floor, below `RecommendedCorridorWidthPx` (68) — a
    ## chicane is a squeeze you fight through, not a boulevard.

type
  MapArchetype* = enum
    ## Six route topologies. The names are the brief's, and each one is a
    ## different answer to "how do you get from your base to theirs".
    archThreeLane = "three-lane"
      ## Three parallel routes of DIFFERENT lengths, base to seam, with
      ## staggered gates. The MW2 grammar; owned by `map_lanes`.
    archBlocks = "blocks"
      ## A grid of streets dividing city blocks. Many equivalent routes, so
      ## flanking is cheap and holding ground is expensive.
    archRing = "ring"
      ## A perimeter loop. Two long ways round, and a centre that is
      ## contested but OPTIONAL — reachable by spur, never on the fast path.
    archHub = "hub"
      ## One dominant central space every route funnels through. High
      ## contact, short fights, nowhere to hide in the middle.
    archWarren = "warren"
      ## Many small rooms joined by doorways. High route count, short
      ## sightlines, the highest enclosure of the six.
    archField = "field"
      ## A few LARGE masses in a lot of open ground. Long sightlines; cover
      ## is rare and therefore worth fighting for.

  CentrePolicy* = enum
    ## What sits at the middle of the board. THE CENTRE IS NOT A FIXTURE: it
    ## was the same bright colonnade on 36 of 36 rendered tiles across both
    ## team counts and every size class, and the sheets name it the single
    ## strongest source of sameness.
    ##
    ## It cannot simply be deleted, because the spinning-diamond mechanic
    ## selects `shapeDiamond` obstacles within 80 px of the symmetry axis and
    ## the shape vocabulary almost never emits one — an empty selection is a
    ## live test failure, not a cosmetic one. So each policy still puts
    ## diamonds ON the axis; they differ in WHERE.
    centreColonnade
      ## The classic column of spinners down the axis.
    centreCluster
      ## A pair just off centre, INSIDE an open central space: the hub's
      ## furniture rather than a wall across it.
    centrePoles
      ## One near each end of the axis, and NOTHING in the middle.

  ArchetypePlan* = object
    ## One archetype instantiated on one board.
    kind*: MapArchetype
    reserved*: seq[MapRect]
      ## Corridors, in BOARD coordinates. Fill overlapping one is dropped and
      ## the row-cover pass will not plug one.
    structure*: seq[ArenaShape]
      ## The walls that MAKE the topology, clipped to the emission domain.
      ## Spends before the fill budget, exactly like a lane separator.
    cells*: seq[MapRect]
      ## The COMPARTMENTS the vocabulary is emitted into — a city block, a
      ## warren room, the ground inside a ring road. Empty means "the whole
      ## domain", which is what `three-lane` and `field` want.
      ##
      ## Handing the vocabulary the whole domain and then DROPPING whatever
      ## landed on a corridor is the obvious way and it does not work: a
      ## `viCave` is 10 cover-widths long, so on a street grid its footprint
      ## almost always crosses a street and the whole shape is discarded.
      ## Measured, `blocks` and `ring` sat at 141-144 permille cover and
      ## 0.22-0.26 enclosure and would not move when their fill budget was
      ## raised 30% — because the budget was never what bound them. Emitting
      ## INTO the compartments makes the topology choose where cover can be,
      ## which is the whole idea: the archetype picks the graph, the
      ## vocabulary only skins it.
    fillPermille*: int
      ## This archetype's share of the nominal fill budget, in permille of
      ## 1000. `field` is sparse because it spends 340, not because its
      ## pebbles are smaller.
    massLo*, massHi*: int      ## how many vocabulary layers to draw.
    items*: seq[VocabItem]     ## the vocabulary this archetype draws from.
    centre*: CentrePolicy

func legalArchetypes*(teams: int): seq[MapArchetype] =
  ## Which topologies a team count can actually carry.
  ##
  ## `archThreeLane` is 2-team only, and that is a measurement rather than a
  ## taste: three lanes in a rot90 QUARTER of the board, lifted four times,
  ## measured 187-235 permille cover against a 170 ceiling. The structure
  ## alone was over budget, so no amount of fill budgeting could rescue it.
  ## The brief is explicit that 4-team topology must stop being radial-only,
  ## and the other five are all rot90-legal by construction.
  if teams == 4:
    @[archBlocks, archRing, archHub, archWarren, archField]
  else:
    @[archThreeLane, archBlocks, archRing, archHub, archWarren, archField]

func drawArchetype*(rng: var MapRng, teams: int): MapArchetype =
  ## The archetype draw. One uniform pick off its own seed-level stream, so
  ## adding this stage disturbed no existing scene and every candidate for a
  ## seed is another try at the SAME design.
  let legal = legalArchetypes(teams)
  legal[rng.pick(legal.len)]

# ---------------------------------------------------------------------------
# Geometry helpers. Everything here is integer and axis-aligned, so a shape
# and its symmetry image rasterize to exactly mirror-symmetric masks.
# ---------------------------------------------------------------------------

func clipTo(r, bounds: MapRect): MapRect =
  ## Intersection. A `w` or `h` of zero or less means "nothing left".
  let
    x0 = max(r.x, bounds.x)
    y0 = max(r.y, bounds.y)
    x1 = min(r.x + r.w, bounds.x + bounds.w)
    y1 = min(r.y + r.h, bounds.y + bounds.h)
  MapRect(x: x0, y: y0, w: x1 - x0, h: y1 - y0)

func isEmpty(r: MapRect): bool {.inline.} = r.w <= 0 or r.h <= 0

func hRun(x0, x1, yMid, thick: int): MapRect =
  ## A horizontal corridor centred on `yMid`.
  MapRect(x: min(x0, x1), y: yMid - thick div 2,
          w: abs(x1 - x0), h: thick)

func vRun(y0, y1, xMid, thick: int): MapRect =
  MapRect(x: xMid - thick div 2, y: min(y0, y1),
          w: thick, h: abs(y1 - y0))

func rectShapeOf(r: MapRect): ArenaShape {.inline.} =
  ArenaShape(kind: shapeRect, rect: r)

func overlaps(a, b: MapRect): bool {.inline.} =
  a.x < b.x + b.w and a.x + a.w > b.x and
    a.y < b.y + b.h and a.y + a.h > b.y

func reservesBounds*(plan: ArchetypePlan, x0, y0, x1, y1: int): bool =
  ## Does this axis-aligned box touch a reserved corridor? Used both to drop
  ## fill and to keep the row-cover pass off the routes.
  let box = MapRect(x: x0, y: y0, w: max(1, x1 - x0 + 1), h: max(1, y1 - y0 + 1))
  for r in plan.reserved:
    if overlaps(box, r): return true
  false

proc chicane(
  dst: var seq[ArenaShape], rng: var MapRng, run, bounds: MapRect,
  horizontal: bool
) =
  ## Alternating half-width blockers inside one reserved run.
  ##
  ## A run of thickness T gets blockers of depth `T - MinRouteWidthPx`,
  ## alternately against its two edges. Every offset across the run is behind
  ## at least one blocker — the two families overlap in the middle — so no
  ## straight ray threads the corridor, while at every point along it at least
  ## `MinRouteWidthPx` of floor is open. Emitted into `bounds` only; the
  ## symmetry lift reproduces the rest of the run.
  let
    thick = if horizontal: run.h else: run.w
    span = if horizontal: run.w else: run.h
    depth = thick - MinRouteWidthPx
  if depth < 12 or span < 160: return
  ## At least four blockers per run, so each half of a run that the domain
  ## splits still gets one of each parity and the alternation survives the
  ## clip.
  let
    count = max(4, span div (5 * thick))
    step = span div count
    width = max(24, min(step * 2 div 5, thick))
  for i in 0 ..< count:
    let
      at = (if horizontal: run.x else: run.y) +
        i * step + (step - width) div 2 + rng.pick(max(1, step div 8))
      far = (i and 1) == 1
    var piece =
      if horizontal:
        MapRect(x: at, y: (if far: run.y + MinRouteWidthPx else: run.y),
                w: width, h: depth)
      else:
        MapRect(x: (if far: run.x + MinRouteWidthPx else: run.x), y: at,
                w: depth, h: width)
    piece = piece.clipTo(bounds)
    if not piece.isEmpty:
      dst.add rectShapeOf(piece)

proc wallWithDoors(
  dst: var seq[ArenaShape], reserved: var seq[MapRect], rng: var MapRng,
  vertical: bool, at, lo, hi, thick, pitch, door: int, bounds: MapRect
) =
  ## One warren wall: a straight run broken by a doorway roughly every
  ## `pitch`. The doorway is RESERVED as well as cut, or the biome fill lands
  ## in it and the room becomes a sealed box — the whole point of a warren is
  ## that its route count is high, and a plugged door costs two routes.
  var cursor = lo
  while cursor < hi:
    let seg = min(pitch, hi - cursor)
    if seg <= door + 16:
      cursor += seg
      continue
    let gapAt = cursor + 8 + rng.pick(max(1, seg - door - 16))
    for (a, b) in [(cursor, gapAt), (gapAt + door, cursor + seg)]:
      if b - a < 8: continue
      let piece =
        if vertical: MapRect(x: at - thick div 2, y: a, w: thick, h: b - a)
        else: MapRect(x: a, y: at - thick div 2, w: b - a, h: thick)
      let clipped = piece.clipTo(bounds)
      if not clipped.isEmpty:
        dst.add rectShapeOf(clipped)
    let gap =
      if vertical:
        MapRect(x: at - thick, y: gapAt, w: 2 * thick, h: door)
      else:
        MapRect(x: gapAt, y: at - thick, w: door, h: 2 * thick)
    reserved.add gap
    cursor += seg

proc blobPolygon(
  rng: var MapRng, cx, cy, rx, ry, lobes: int
): ArenaShape =
  ## A big organic mass: a jittered ellipse flattened to integer vertices.
  ## `field` wants masses you read as LANDFORM rather than as furniture, and
  ## the vocabulary tops out an order of magnitude smaller than that.
  var pts: seq[MapPoint]
  for i in 0 ..< lobes:
    let
      a = 2.0 * PI * float(i) / float(lobes)
      j = 72 + rng.pick(46)
    pts.add MapPoint(
      x: cx + int(round(cos(a) * float(rx * j) / 100.0)),
      y: cy + int(round(sin(a) * float(ry * j) / 100.0)))
  ArenaShape(kind: shapePolygon, points: pts)

# ---------------------------------------------------------------------------
# The planners.
# ---------------------------------------------------------------------------

proc planArchetype*(
  kind: MapArchetype, rng: var MapRng, board, region: MapRect,
  anchor: MapPoint, rules: MapRules, quadrant: bool
): ArchetypePlan =
  ## Instantiate one archetype on one board.
  ##
  ## `region` is the terrain emission domain — the left half on a 2-team map,
  ## the top-left quadrant on a rot90 one. `quadrant` says which, because a
  ## four-fold board has to keep its corridor set invariant under 90 degrees
  ## and a two-fold one does not.
  result.kind = kind
  result.fillPermille = 1000
  result.massLo = 2
  result.massHi = 3
  result.centre = centreColonnade
  let
    cx = board.w div 2
    cy = board.h div 2
    street = max(MinRouteWidthPx * 2, rules.minCorridorWidthPx)
    short = min(board.w, board.h)
    ## Structure is authored in the domain and completed by the lift, so it is
    ## clipped to the domain widened to the SEAM: a wall that stops 52 px
    ## short of the axis meets its own image across a 104 px gap, and every
    ## warren on the sheet would carry the same slot down its middle.
    bounds = MapRect(x: region.x, y: region.y, w: cx - region.x,
                     h: (if quadrant: cy - region.y else: region.h))

  case kind
  of archThreeLane:
    ## Owned by `map_lanes.carveLanes`; nothing to reserve here. The default
    ## budget, the full vocabulary and the classic colonnade.
    result.items = @[viBunker, viBunker, viBunker, viSnake, viSnake,
                     viCave, viCave, viBeam, viDorito, viCan,
                     viMassif, viTemple]

  of archBlocks:
    ## STREETS. Reserved on a board-centred lattice rather than a
    ## domain-relative one: the same grid then lifts to itself under mirror,
    ## rot180 and rot90 alike, so a 4-team board reads as a city and not as
    ## four rotated copies of a quarter of one.
    ## A 68 px street on a 659 px board cannot have SMALL blocks without being
    ## mostly street: five horizontal streets is 31% of the board's height in
    ## tarmac before a single vertical one is drawn, which measured as a
    ## barcode — 136 permille cover at 0.204 enclosure, the emptiest of the
    ## six. So the short axis takes three streets and only the LONG axis may
    ## take five.
    let
      lanesY = 1
      lanesX = if quadrant: lanesY else: 1 + rng.pick(2)
      pitchX = board.w div (2 * lanesX + 2)
      pitchY = if quadrant: pitchX else: board.h div (2 * lanesY + 2)
    for j in -lanesX .. lanesX:
      result.reserved.add vRun(0, board.h, cx + j * pitchX, street)
    for j in -lanesY .. lanesY:
      let run = hRun(0, board.w, cy + j * pitchY, street)
      result.reserved.add run
      ## Only the horizontal runs cross the sightline band end to end.
      chicane(result.structure, rng, run, bounds, horizontal = true)
    ## The BLOCKS themselves are the fill compartments.
    for jx in -lanesX - 1 .. lanesX:
      for jy in -lanesY - 1 .. lanesY:
        ## Inset by HALF a street on each side, because the street is CENTRED
        ## on the grid line. Insetting by a whole one left 29 px blocks on a
        ## 659 px board, every one of them below the minimum cell size, so
        ## `blocks` silently emitted no masses at all and fell to 0.187
        ## enclosure — lower than before it had compartments.
        let cell = MapRect(
          x: cx + jx * pitchX + street div 2, y: cy + jy * pitchY + street div 2,
          w: pitchX - street, h: pitchY - street).clipTo(bounds)
        if not cell.isEmpty: result.cells.add cell
    ## Plus a cross through the team's own anchor: every route in or out of a
    ## base uses it, and the lift hands each team the identical approach.
    ## Without it the fill simply lands on the base — measured, all 60
    ## attempts failed "no 26px route to the blue flag" at a perfectly
    ## healthy 122-134 permille.
    let anchorRun = hRun(0, board.w, anchor.y, street)
    result.reserved.add anchorRun
    result.reserved.add vRun(0, board.h, anchor.x, street)
    chicane(result.structure, rng, anchorRun, bounds, horizontal = true)
    ## A rot90 lift doubles what the same lattice costs, so the four-fold
    ## board spends less: measured at the 2-team budget one seed in eight
    ## failed "too clogged" at 217 permille.
    result.fillPermille = if quadrant: 800 else: 1200
    result.massLo = 3
    result.massHi = 4
    ## Blocky, and weighted to the items `vocab_bench` measures as ENCLOSING:
    ## bunker 0.456 and cave 0.355 against temple 0.128. A city block you can
    ## be inside is the difference between this and a car park.
    result.items = @[viBunker, viBunker, viBunker, viCave, viTemple, viCan,
                     viDorito]

  of archRing:
    ## A PERIMETER LOOP. Two long ways round from base to base, and a centre
    ## reached only by a spur — contested, but never on the fast path.
    let
      inset = rng.pickRange(short div 9, short div 5)
      sx = cx - inset
      sy = cy - inset
      runs = [hRun(cx - sx, cx + sx, cy - sy, street),
              hRun(cx - sx, cx + sx, cy + sy, street),
              vRun(cy - sy, cy + sy, cx - sx, street),
              vRun(cy - sy, cy + sy, cx + sx, street)]
    for i, run in runs:
      result.reserved.add run
      chicane(result.structure, rng, run, bounds, horizontal = i < 2)
    ## The base spur: the anchor onto the loop.
    result.reserved.add hRun(0, cx - sx + street, anchor.y, street)
    ## The centre spur, an L rather than a straight shot. A straight one would
    ## be a fourth full-width corridor and the ring would read as a lane map
    ## with a border; the dog-leg leaves the centre reachable and the row
    ## through it blocked by ordinary fill on either side.
    let spurX = cx - (sx * rng.pickRange(35, 60)) div 100
    result.reserved.add vRun(cy - sy, cy, spurX, street)
    result.reserved.add hRun(spurX, cx, cy, street)
    ## Two compartments: the ground INSIDE the loop, and the margin outside
    ## it. Both get cover; neither gets a route the loop does not grant.
    for cell in [MapRect(x: cx - sx + street, y: cy - sy + street,
                         w: 2 * sx - 2 * street, h: 2 * sy - 2 * street),
                 MapRect(x: 0, y: 0, w: cx - sx - street div 2, h: board.h),
                 MapRect(x: 0, y: 0, w: board.w, h: cy - sy - street div 2),
                 MapRect(x: 0, y: cy + sy + street, w: board.w, h: board.h)]:
      let clipped = cell.clipTo(bounds)
      if clipped.w > 48 and clipped.h > 48: result.cells.add clipped
    result.fillPermille = if quadrant: 1000 else: 1250
    result.massLo = if quadrant: 3 else: 4
    result.massHi = if quadrant: 4 else: 6
    result.items = @[viCave, viCave, viSnake, viSnake, viBunker, viMassif,
                     viBeam]
    result.centre = centrePoles

  of archHub:
    ## ONE DOMINANT CENTRAL SPACE. Every approach funnels into it, the
    ## periphery is dense, and the fight is short because there is nowhere in
    ## the middle to break contact.
    let
      hubR = rng.pickRange(short * 20 div 100, short * 28 div 100)
      hub = MapRect(x: cx - hubR, y: cy - hubR, w: 2 * hubR, h: 2 * hubR)
    result.reserved.add hub
    ## Three approaches per team: one straight in from the base, and two
    ## diagonals built as dog-legs off the hub's near corners. Their images
    ## give six on a 2-team board and twelve on a rot90 one.
    result.reserved.add hRun(anchor.x, cx - hubR + street, anchor.y, street)
    for sign in [-1, 1]:
      let
        cornerY = cy + sign * hubR
        outX = region.x + rng.pick(max(1, region.w div 3))
      result.reserved.add hRun(outX, cx - hubR + street, cornerY, street)
      result.reserved.add vRun(cornerY, anchor.y, outX, street)
    ## The PERIPHERY is the compartment: everything the hub is not.
    for cell in [MapRect(x: 0, y: 0, w: cx - hubR - street, h: board.h),
                 MapRect(x: cx - hubR, y: 0, w: 2 * hubR,
                         h: cy - hubR - street),
                 MapRect(x: cx - hubR, y: cy + hubR + street, w: 2 * hubR,
                         h: board.h)]:
      let clipped = cell.clipTo(bounds)
      if clipped.w > 48 and clipped.h > 48: result.cells.add clipped
    ## The periphery has to be DENSE, or a hub is just an open board with a
    ## label: the contrast between a bare middle and a warren of approaches is
    ## the whole archetype. Measured at the first draft's 950/3-4 it came back
    ## the emptiest of the six, 107 permille at 0.153 enclosure.
    result.fillPermille = if quadrant: 1150 else: 1400
    result.massLo = if quadrant: 4 else: 5
    result.massHi = if quadrant: 5 else: 7
    result.items = @[viBunker, viBunker, viBunker, viCave, viCave, viCan]
    result.centre = centreCluster

  of archWarren:
    ## MANY SMALL ROOMS. The highest route count and the shortest sightlines
    ## of the six, and the only archetype whose enclosure comes from WALLS
    ## rather than from masses.
    ##
    ## The grid is centred on the board with no wall ON either axis, so the
    ## axes themselves are through-streets and the lattice is invariant under
    ## all three symmetries at once (a vertical wall at x maps to a horizontal
    ## wall at y = x under rot90, which is why the pitch is shared).
    let
      ## A rot90 lift turns the same lattice into twice the wall — the
      ## vertical lines become horizontal ones too — so a four-fold board
      ## takes a coarser grid. Measured at the 2-team pitch, 4-team `warren`
      ## failed "too clogged" on 2 of 6 seeds at 228-243 permille.
      pitchLo = if quadrant: 28 else: 22
      pitch = rng.pickRange(short * pitchLo div 100,
                            short * (pitchLo + 8) div 100)
      thick = max(12, rules.coverSizePx div 3)
      door = max(MinRouteWidthPx + 8, rules.minCorridorWidthPx * 3 div 4)
    var k = 1
    while cx - (2 * k - 1) * pitch div 2 > region.x - pitch:
      let wx = cx - (2 * k - 1) * pitch div 2
      wallWithDoors(result.structure, result.reserved, rng,
        vertical = true, at = wx, lo = region.y, hi = bounds.y + bounds.h,
        thick = thick, pitch = pitch, door = door, bounds = bounds)
      inc k
      if k > 12: break
    k = 1
    while cy - (2 * k - 1) * pitch div 2 > region.y - pitch:
      let wy = cy - (2 * k - 1) * pitch div 2
      for side in (if quadrant: @[-1] else: @[-1, 1]):
        wallWithDoors(result.structure, result.reserved, rng,
          vertical = false, at = cy + side * (2 * k - 1) * pitch div 2,
          lo = region.x, hi = bounds.x + bounds.w,
          thick = thick, pitch = pitch, door = door, bounds = bounds)
      discard wy
      inc k
      if k > 12: break
    ## Each ROOM is a compartment, so the furniture lands inside rooms and
    ## never in a doorway.
    var ry = cy - (pitch div 2) - pitch * 12
    while ry < cy + pitch * 12:
      var rx = cx - (pitch div 2) - pitch * 12
      while rx < cx + pitch * 12:
        let cell = MapRect(x: rx + thick, y: ry + thick,
                           w: pitch - 2 * thick, h: pitch - 2 * thick)
          .clipTo(bounds)
        if cell.w > 60 and cell.h > 60: result.cells.add cell
        rx += pitch
      ry += pitch
    ## The base's own room always has a door onto the axis street.
    result.reserved.add hRun(anchor.x, cx, anchor.y, door)
    result.fillPermille = if quadrant: 260 else: 420
    result.massLo = 1
    result.massHi = 2
    result.items = @[viCan, viDorito, viTemple, viBunker]
    result.centre = centrePoles

  of archField:
    ## FEW LARGE MASSES. Cover is rare and therefore worth fighting for, and
    ## the masses are landform-scale — an order of magnitude past anything
    ## `mapgen_vocab` emits.
    ##
    ## They are staggered down the domain rather than clustered, because a
    ## row with no wall anywhere in the sightline band is a validator
    ## rejection: the masses have to BETWEEN them span the height, even
    ## though the floor between them is wide open.
    ##
    ## Sized from a BUDGET, not from the region. Taking the radii as a
    ## fraction of the domain — the obvious way — put four ellipses of
    ## 200 x 190 into a 521 x 639 half-field, 43% of it in stone: `field`
    ## measured 225 permille cover against a 170 ceiling and validated 2 of 7
    ## seeds, the emptiest-LOOKING archetype failing for being the fullest.
    ## An area budget divided by the mass count and split across a chosen
    ## aspect ratio holds at every size class and every endzone shape.
    ## Budgeted in permille OF THE DOMAIN, and the constant is ~1.4x the
    ## permille it buys on the board: `coverPermille`'s denominator is the
    ## INTERIOR (border and capture columns excluded), which on a
    ## column-endzone small board is 70% of the emission domain. A budget in
    ## board pixels reads 40% low against the ruler that actually gates.
    ##
    ## No radius FLOOR. Flooring rx/ry at "landform scale" is what blew the
    ## first budgeted draft: on a 244 x 540 domain the floors overrode the
    ## budget by 2.8x and `field` still failed "too clogged" at 258 permille.
    ## A small board gets small masses; the archetype is the COUNT and the
    ## spacing, not an absolute size.
    const MassPermille = 100
    let
      count = rng.pickRange(3, 4)
      bandH = max(1, bounds.h div count)
      area = max(1200, bounds.w * bounds.h * MassPermille div 1000 div count)
      ## Elongated: a mass you flank around the long way, not a boulder.
      aspect = rng.pickRange(180, 300)     ## rx:ry, in percent.
      ry = max(22, int(sqrt(float(area) * 100.0 / (PI * float(aspect)))))
      rx = max(30, ry * aspect div 100)
    ## Half the masses come as a BAY: two ridges with a fightable gap between
    ## them, the vocabulary's `viCave` at landform scale. A sparse board still
    ## needs somewhere you can be INSIDE something, or "cover is rare" becomes
    ## "there is no cover" — and enclosure is what tells the two apart.
    for i in 0 ..< count:
      let
        my = bounds.y + i * bandH + bandH div 2
        mx = region.x + rx + rng.pick(max(1, region.w - 2 * rx))
      if rng.coin():
        let half = max(18, ry * 45 div 100)
        for side in [-1, 1]:
          result.structure.add blobPolygon(
            rng, mx, my + side * (half + street * 3 div 4), rx, half, 9)
      else:
        result.structure.add blobPolygon(rng, mx, my, rx, ry, 9)
    result.reserved.add hRun(anchor.x, cx, anchor.y, street)
    result.fillPermille = 340
    result.massLo = 1
    result.massHi = 1
    result.items = @[viMassif, viBeam, viTemple]
    result.centre = centrePoles

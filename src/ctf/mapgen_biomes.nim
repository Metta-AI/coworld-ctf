## Biome terrain emitters, ported from the Cogs-vs-Clips (mettagrid) biome
## scenes into CTF's continuous pixel space.
##
## Source of truth for the algorithms:
## `mettagrid/mapgen/scenes/{biome_desert,biome_city,biome_plains,biome_forest,
## biome_caves,dither,asteroid_mask}.py`. Each one is reproduced here with its
## published parameters intact; where a number had to move, the reason is in
## the comment next to it.
##
## HOUSE STYLE. Every emitter is a PURE function of
## `(rng, region, params, domain) -> seq[ArenaShape]`, exactly like
## `mapgen_styles.generateShapes`: it never touches symmetry, protected-floor
## carve, endzones, or validation. The extra `domain` argument is not
## decoration — see THE DITHER RULE below.
##
## ---------------------------------------------------------------------------
## CELL SIZE: WHY 34 px (and 56 for plains)
## ---------------------------------------------------------------------------
##
## The source algorithms live on numpy boolean grids where one cell is one
## agent-sized tile. CTF has no tile grid, so the cell size is a decision, and
## it is the decision that makes or breaks the port. Two numbers bound it:
##
##   `arena.MinPassableWidth`      = 26 px  — the solid-footprint floor the
##                                            connectivity flood is eroded to
##   `map_rules.RecommendedCorridorWidthPx` = 68 px  — two DRAWN cog bodies
##                                                     abreast (2 * 34)
##
## and one more sets the floor on a useful wall: `map_rules.BaseCoverSizePx`
## = 56 px, the derived width at which a body behind cover is actually hidden.
##
## `BiomeCellPx` = 34 px = `SoldierBodyPx`, the drawn cog body, because:
##
## - It is the COARSEST cell whose lattice can express 68 px exactly, as two
##   cells. Anything larger and the recommended corridor is not a lattice
##   quantity at all.
## - It is the FINEST cell whose single wall cell (34 px) is still a real piece
##   of terrain — it stops a bullet and hides a body edge-on. A 24 px cell
##   would emit sub-body noise.
## - The seed region of a standard 2-team board is about 570 x 645 px, i.e.
##   16 x 19 cells — the same order as the 10-60 cell zones the source biomes
##   were tuned on, so the published densities transfer instead of degenerating.
##
## A one-cell corridor would still be only 34 px, above the enforced 26 but
## below the recommended 68. So the grid biomes run `widenCorridors` with
## `minOpenCells` = 2 as a MANDATORY post-pass, which makes 68 px the narrowest
## passage a player can be COMMITTED to. The guarantee is tested, not asserted.
##
## What counts as a corridor is the subtle part, and getting it wrong was
## visible in the renders: widening every one-cell pinch shatters a
## cellular-automata field into isolated dots, because most pinches in one are
## just two pebbles a cell apart. A 34 px gap between two boulders is not a
## corridor — you walk around it. So a corridor is a pinch that CONTINUES: two
## adjacent cells pinched the same way, 68 px of enclosed run. See
## `widenCorridors`.
##
## `plains` is the exception and uses `BiomePebbleCellPx` = 56 px
## (`BaseCoverSizePx`): it is a SPARSE scatter of isolated pebbles, so its cells
## almost never form corridors, and a pebble should be one cover piece rather
## than one body. `desert` and `city` use no grid at all — they are analytic in
## pixel space, which is strictly better than quantising them.
##
## ---------------------------------------------------------------------------
## THE DITHER RULE: it is symmetry-destroying, so the API will not let you
## break fairness with it
## ---------------------------------------------------------------------------
##
## `dither_edges` flips cells at random along the wall/open boundary. Run it on
## a finished CTF map and the two halves stop matching — team A gets a notch
## team B does not. It MUST run inside the fundamental domain, BEFORE the
## symmetry lift.
##
## That is enforced three ways, none of them a comment:
##
## 1. `ditherEdges` takes a `FundamentalDomain` as a REQUIRED argument. There is
##    no overload without it.
## 2. `FundamentalDomain` has exactly one constructor, `fundamentalDomain`,
##    which REFUSES a domain that is not a proper fundamental domain: it must
##    lie inside the board, it must not straddle a symmetry axis, and
##    `area * order` must fit inside the board. Handing it the whole board — the
##    exact mistake we are guarding against — raises.
## 3. `ditherEdges` additionally re-checks that the grid's own pixel footprint
##    lies inside `domain.rect`, so a grid built somewhere else cannot be
##    dithered against a domain it does not belong to.
##
## Every generator here takes the domain and threads it through, so a caller
## cannot get a dithered biome without having proved a domain first.

import std/[random, math]
import sim_types
import map_rules

const
  BiomeCellPx* = SoldierBodyPx
    ## 34 px. See the header: the coarsest cell that expresses
    ## `RecommendedCorridorWidthPx` = 68 as two cells, and the finest whose
    ## single cell is still terrain rather than noise.
  BiomePebbleCellPx* = BaseCoverSizePx
    ## 56 px. `plains` scatters isolated pebbles, so its quantum is one COVER
    ## PIECE, not one body.
  BiomeMinOpenCells* = 2
    ## Narrowest passage a grid biome may emit, in cells. 2 * 34 = 68 px =
    ## `RecommendedCorridorWidthPx`.
  BiomeWidenPasses* = 32
    ## Bound on `widenCorridors` sweeps. Every sweep that changes anything
    ## strictly REMOVES wall cells, so the loop always terminates; the cap only
    ## bounds a pathological grid, and a converged grid exits on sweep two.

type
  BiomeStyle* = enum
    ## The five terrain families the Cogs-vs-Clips arena composes. The string
    ## values match `MapBiome`'s, so a scene graph can map a chosen biome skin
    ## onto its terrain emitter by name.
    biomeStyleCaves = "caves"
    biomeStyleForest = "forest"
    biomeStyleDesert = "desert"
    biomeStyleCity = "city"
    biomeStylePlains = "plains"

  BiomeEdge* = enum
    ## Which side of a region the asteroid/edge mask rags.
    edgeTop, edgeBottom, edgeLeft, edgeRight

  BiomeParams* = object
    ## Per-biome knobs. Every field has a usable default
    ## (`defaultBiomeParams`); the source's own published value is quoted in
    ## the comment where we kept it, and the reason is quoted where we did not.

    # --- shared ------------------------------------------------------------
    cell*: int              ## automaton cell size in px (grid biomes only)
    minOpenCells*: int      ## corridor-width guarantee, in cells
    ditherProb*: float      ## dither.py prob (source 0.15)
    ditherDepth*: int       ## dither.py depth (source 5)
    pebbleDiscs*: bool      ## emit isolated 1x1 wall cells as discs, not rects

    # --- caves (biome_caves.py) -------------------------------------------
    fillProb*: float        ## source 0.4
    steps*: int             ## source 3
    birthLimit*: int        ## source 5 (birth when neighbours > birthLimit)
    deathLimit*: int        ## source 3 (survive when neighbours >= deathLimit)
    borderIsRock*: bool     ## source pads with constant_values=1

    # --- forest (biome_forest.py) -----------------------------------------
    clumpiness*: int        ## source 2 growth passes
    seedProb*: float        ## source 0.03
    growthProb*: float      ## source 0.5
    neighborThreshold*: int ## source 3

    # --- desert (biome_desert.py) -----------------------------------------
    dunePeriodPx*: int      ## ridge-to-ridge spacing, px
    ridgeWidthPx*: int      ## ridge thickness, px
    duneAngle*: float       ## source pi/4
    noiseProb*: float       ## source 0.1 — chance a ridge run is broken
    duneSegmentPx*: int     ## length of one emitted ridge capsule
    duneGapPx*: int         ## length of a noise gap when one occurs

    # --- city (biome_city.py) ---------------------------------------------
    pitchPx*: int           ## block lattice spacing, px (source 10 cells)
    roadWidthPx*: int       ## road margin on each side, px (source 3 cells)
    placeProb*: float       ## source 0.9
    minBlockFrac*: float    ## source 0.5
    blockJitterPx*: int     ## source jitter 1 cell

    # --- plains (biome_plains.py) -----------------------------------------
    clusterPeriod*: int     ## source 7 cells
    clusterMinRadius*: int  ## source 0 cells
    clusterMaxRadius*: int  ## source 2 cells
    clusterFill*: float     ## source 0.7
    clusterProb*: float     ## source 0.8
    clusterJitter*: int     ## source 2 cells

    # --- asteroid / edge mask (asteroid_mask.py) --------------------------
    maskStepPx*: int        ## source step 3 cells
    maskDepthMin*, maskDepthMax*: int  ## source 2..8 cells, in px here
    maskWidthMin*, maskWidthMax*: int  ## source 2..6 cells, in px here
    maskChunkProb*: float   ## source 0.6

  FundamentalDomain* = object
    ## A PROOF that a rectangle is a legal place to do symmetry-destroying
    ## work. Build it only with `fundamentalDomain`, which refuses anything
    ## that is not one. Fields are read-only by convention; nothing in this
    ## module mutates a domain.
    rect*: MapRect          ## the sub-board the generator writes into
    board*: MapRect         ## the whole board
    order*: int             ## symmetry order: 2 (mirror/rot180), 4 (rot90)

  BiomeGrid* = object
    ## A boolean wall lattice over a pixel region — the numpy array the source
    ## algorithms are written on. `originX/originY` centre the lattice in the
    ## region so the leftover `region.w mod cell` px is split evenly.
    cell*: int
    cols*, rows*: int
    originX*, originY*: int
    wall*: seq[bool]

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

proc defaultBiomeParams*(style: BiomeStyle): BiomeParams =
  ## Source-faithful wherever the source's number is a RATIO the algorithm's
  ## character depends on; re-derived wherever it is a LENGTH (the source's are
  ## agent tiles, ours are pixels) or a DENSITY.
  ##
  ## THE DENSITIES ALL MOVED, and the reason is one number: `arena.nim` rejects
  ## a map outside 40..170 permille cover. Every biome at its published density
  ## lands outside that window on a CTF board — caves at 334, desert at 251,
  ## forest at 26, plains at 37 (measured, 8 seeds, standard board). So each
  ## density knob below is set to put its biome near 140 permille, the middle
  ## of the legal band, and the value it moved FROM is recorded next to it.
  ## Nothing else was retuned: the automata, thresholds, growth rules, walk
  ## rules and the dither are the source's.
  result = BiomeParams(
    cell: BiomeCellPx,
    minOpenCells: BiomeMinOpenCells,
    ditherProb: 0.15,        # dither.py default, kept
    ditherDepth: 5,          # dither.py default, kept
    pebbleDiscs: true,
    # caves — fill 0.4 -> 0.25. At 0.4 the CA lands at 334 permille, twice the
    # legal ceiling; this is the biome the source itself weights 0 as an
    # overlay and uses only as a base.
    fillProb: 0.25, steps: 3, birthLimit: 5, deathLimit: 3, borderIsRock: true,
    # forest — seed 0.03 -> 0.085. With `neighbor_threshold` 3, an isolated seed
    # can never grow (three of its eight neighbours must already be forest), so
    # the forest is very nearly its own seed density: 3% of cells, which is
    # 26 permille, well under the 40 permille floor. 0.10 puts it at 141 and
    # switches the growth rule on, which is what makes it CLUMP.
    clumpiness: 2, seedProb: 0.085, growthProb: 0.5, neighborThreshold: 3,
    # desert — the source's period is 8 CELLS with a 1-cell ridge. A 1-cell
    # ridge here would be 34 px, under the 47 px at which cover actually hides
    # a body, so the ridge is `BaseCoverSizePx`; holding the 8:1 ratio would
    # then put the period at 448 and the duty cycle at 250 permille. 416 gives
    # 136 permille and a 360 px sand lane between ridges.
    dunePeriodPx: 416, ridgeWidthPx: BaseCoverSizePx, duneAngle: PI / 4.0,
    noiseProb: 0.1, duneSegmentPx: 192,
    duneGapPx: BaseCoverSizePx + RecommendedCorridorWidthPx,
    # city — see genCityBiome. pitch 200 px with a 68 px road is the finest
    # lattice that still leaves a block worth calling one, given that the road
    # may not go below `RecommendedCorridorWidthPx`; minBlockFrac 0.5 -> 0.32
    # because at 0.5 the size jitter is entirely clipped away (in the source
    # too — its city is a perfectly regular grid).
    pitchPx: 200, roadWidthPx: RecommendedCorridorWidthPx,
    placeProb: 0.9, minBlockFrac: 0.32, blockJitterPx: 16,
    # plains — cluster_period 7 -> 3 cells. The source's grids are 60+ cells
    # across, so a period of 7 gives it dozens of anchors; our 10x10 pebble
    # lattice would get four, for 37 permille. At 3 it gets ~16; cluster_prob
    # 0.8 -> 0.55 then trims the variance, landing at 141 permille.
    clusterPeriod: 3, clusterMinRadius: 0, clusterMaxRadius: 2,
    clusterFill: 0.7, clusterProb: 0.55, clusterJitter: 2,
    # asteroid mask — source counts are CELLS; scaled to px by BiomeCellPx
    maskStepPx: 3 * BiomeCellPx,
    maskDepthMin: 2 * BiomeCellPx, maskDepthMax: 8 * BiomeCellPx,
    maskWidthMin: 2 * BiomeCellPx, maskWidthMax: 6 * BiomeCellPx,
    maskChunkProb: 0.6)
  case style
  of biomeStylePlains:
    # A pebble is one COVER PIECE, not one body: the scatter is sparse enough
    # that its cells never form corridors, so the corridor argument that pins
    # 34 px for the dense biomes does not apply.
    result.cell = BiomePebbleCellPx
  of biomeStyleDesert, biomeStyleCity:
    # Analytic in pixel space; `cell` is unused by these two and is left at the
    # shared default so a caller that reads it is never surprised.
    discard
  of biomeStyleCaves, biomeStyleForest:
    discard

proc parseBiomeStyle*(text: string): BiomeStyle =
  for s in BiomeStyle:
    if $s == text: return s
  raise newException(ValueError, "unknown biome style: " & text)

# ---------------------------------------------------------------------------
# Fundamental domain — the fairness gate
# ---------------------------------------------------------------------------

proc contains(outer, inner: MapRect): bool =
  inner.x >= outer.x and inner.y >= outer.y and
    inner.x + inner.w <= outer.x + outer.w and
    inner.y + inner.h <= outer.y + outer.h

proc symmetryOrder*(symmetry: MapSymmetry): int =
  ## How many copies of the fundamental domain tile the board.
  case symmetry
  of symMirror, symRot180: 2
  of symRot90: 4

proc fundamentalDomain*(
    board, region: MapRect, symmetry: MapSymmetry
): FundamentalDomain =
  ## THE ONLY constructor. Raises `ValueError` unless `region` really is a
  ## fundamental domain of `board` under `symmetry`:
  ##
  ## - it lies inside the board;
  ## - it does not straddle a symmetry axis (the vertical centre line for
  ##   mirror/rot180; both centre lines for rot90) — a region that straddles is
  ##   its own mirror image in part, so a dither flip there lands on top of
  ##   itself and cannot be lifted fairly;
  ## - `area * order` fits inside the board, which is what makes handing this
  ##   the WHOLE BOARD — the mistake this type exists to prevent — a hard error
  ##   rather than a silently unfair map.
  if region.w <= 0 or region.h <= 0:
    raise newException(ValueError, "fundamental domain has empty area")
  if not board.contains(region):
    raise newException(ValueError,
      "fundamental domain is not inside the board")
  let order = symmetryOrder(symmetry)
  if region.w * region.h * order > board.w * board.h:
    raise newException(ValueError,
      "region is too big to be a fundamental domain of order " & $order &
        ": " & $region.w & "x" & $region.h & " * " & $order &
        " exceeds the board " & $board.w & "x" & $board.h &
        " (did you pass the whole board?)")
  let
    midX = board.x + board.w div 2
    midY = board.y + board.h div 2
  if region.x < midX and region.x + region.w > midX:
    raise newException(ValueError,
      "fundamental domain straddles the vertical symmetry axis at x=" & $midX)
  if symmetry == symRot90 and region.y < midY and region.y + region.h > midY:
    raise newException(ValueError,
      "fundamental domain straddles the horizontal symmetry axis at y=" & $midY)
  FundamentalDomain(rect: region, board: board, order: order)

# ---------------------------------------------------------------------------
# Grid
# ---------------------------------------------------------------------------

proc newBiomeGrid*(region: MapRect, cell: int): BiomeGrid =
  let c = max(8, cell)
  result.cell = c
  result.cols = max(1, region.w div c)
  result.rows = max(1, region.h div c)
  result.originX = region.x + (region.w - result.cols * c) div 2
  result.originY = region.y + (region.h - result.rows * c) div 2
  result.wall = newSeq[bool](result.cols * result.rows)

proc idx*(g: BiomeGrid, c, r: int): int {.inline.} = r * g.cols + c

proc inGrid*(g: BiomeGrid, c, r: int): bool {.inline.} =
  c >= 0 and c < g.cols and r >= 0 and r < g.rows

proc at*(g: BiomeGrid, c, r: int): bool {.inline.} =
  g.inGrid(c, r) and g.wall[g.idx(c, r)]

proc footprint*(g: BiomeGrid): MapRect {.inline.} =
  MapRect(x: g.originX, y: g.originY,
          w: g.cols * g.cell, h: g.rows * g.cell)

proc neighbours8(g: BiomeGrid, c, r: int, outside: bool): int =
  ## 8-neighbour wall count. `outside` is what an off-grid neighbour counts as
  ## — the source's `np.pad(..., constant_values=...)`.
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      if dx == 0 and dy == 0: continue
      let
        nc = c + dx
        nr = r + dy
      if not g.inGrid(nc, nr):
        if outside: inc result
      elif g.wall[g.idx(nc, nr)]:
        inc result

# ---------------------------------------------------------------------------
# dither_edges (dither.py) — SYMMETRY-DESTROYING, domain-gated
# ---------------------------------------------------------------------------

proc expand8(mask: seq[bool], cols, rows: int): seq[bool] =
  ## `dither._expand`: the 8-neighbour dilation. Off-grid shifts fill with
  ## False, exactly as numpy's zero-filled slice assignment does.
  result = newSeq[bool](cols * rows)
  for r in 0 ..< rows:
    for c in 0 ..< cols:
      var any = false
      for dy in -1 .. 1:
        for dx in -1 .. 1:
          if dx == 0 and dy == 0: continue
          let
            nc = c + dx
            nr = r + dy
          if nc >= 0 and nc < cols and nr >= 0 and nr < rows and
              mask[nr * cols + nc]:
            any = true
      result[r * cols + c] = any

proc ditherEdges*(
    r: var Rand, g: var BiomeGrid, domain: FundamentalDomain,
    prob: float, depth: int
) =
  ## `dither.dither_edges`, cell for cell: multi-source BFS out from the
  ## 8-connected wall/open boundary, then a distance-weighted flip with LINEAR
  ## FALLOFF from `prob` at the boundary to `prob/depth` at `depth`, with a
  ## `depth`-wide border band excluded so the frame never dissolves.
  ##
  ## THE DOMAIN IS REQUIRED AND CHECKED. `domain` must contain the grid's whole
  ## pixel footprint; the type itself can only have been built by
  ## `fundamentalDomain`, which refuses the whole board. Between the two, there
  ## is no way to call this on a finished, already-lifted map.
  if not domain.rect.contains(g.footprint()):
    raise newException(ValueError,
      "dither would run outside the fundamental domain: grid footprint is " &
        "not contained in the domain rect")
  if depth <= 0 or prob <= 0.0:
    return
  let
    cols = g.cols
    rows = g.rows
    n = cols * rows
  var
    wallMask = g.wall
    emptyMask = newSeq[bool](n)
  for i in 0 ..< n: emptyMask[i] = not wallMask[i]
  let
    expWall = expand8(wallMask, cols, rows)
    expEmpty = expand8(emptyMask, cols, rows)
  var
    frontier = newSeq[bool](n)
    seen = newSeq[bool](n)
    dist = newSeq[int](n)
  for i in 0 ..< n:
    dist[i] = depth + 1
    frontier[i] = (expWall[i] and emptyMask[i]) or (expEmpty[i] and wallMask[i])
    if frontier[i]:
      dist[i] = 0
      seen[i] = true
  var currentDepth = 0
  while currentDepth < depth:
    inc currentDepth
    var nextFrontier = expand8(frontier, cols, rows)
    var any = false
    for i in 0 ..< n:
      if nextFrontier[i] and seen[i]: nextFrontier[i] = false
      if nextFrontier[i]:
        dist[i] = currentDepth
        seen[i] = true
        any = true
    frontier = nextFrontier
    if not any: break
  # One draw per cell in row-major order, whether or not the cell is eligible:
  # the RNG consumption is then independent of the mask, which is what makes a
  # dithered biome reproducible from its seed alone.
  for rr in 0 ..< rows:
    for cc in 0 ..< cols:
      let
        i = rr * cols + cc
        roll = rand(r, 1.0)
        reachable = dist[i] <= depth and
          rr >= depth and rr < rows - depth and
          cc >= depth and cc < cols - depth
      if not reachable: continue
      let
        effective = max(1, dist[i])
        edgeProb = prob * float(depth - effective + 1) / float(depth)
      if roll < edgeProb:
        g.wall[i] = not wallMask[i]

# ---------------------------------------------------------------------------
# Corridor-width guarantee
# ---------------------------------------------------------------------------

proc pinchedH(g: BiomeGrid, c, row: int): bool {.inline.} =
  ## The cell is open with wall on its left AND right.
  not g.at(c, row) and g.at(c - 1, row) and g.at(c + 1, row)

proc pinchedV(g: BiomeGrid, c, row: int): bool {.inline.} =
  not g.at(c, row) and g.at(c, row - 1) and g.at(c, row + 1)

proc corridorH(g: BiomeGrid, c, row: int): bool {.inline.} =
  ## A one-cell-wide VERTICAL corridor: the cell is pinched left/right AND the
  ## passage CONTINUES, i.e. the cell above or below is pinched the same way.
  ## Two stacked pinched cells is 68 px of enclosed run — a corridor a player
  ## has to commit to. One pinched cell on its own is just a gap between two
  ## pebbles, which a player walks around, and which is why this distinction
  ## exists at all.
  g.pinchedH(c, row) and (g.pinchedH(c, row - 1) or g.pinchedH(c, row + 1))

proc corridorV(g: BiomeGrid, c, row: int): bool {.inline.} =
  g.pinchedV(c, row) and (g.pinchedV(c - 1, row) or g.pinchedV(c + 1, row))

proc widenCorridors*(r: var Rand, g: var BiomeGrid, minOpenCells: int) =
  ## Open every one-cell-wide CORRIDOR to `minOpenCells` cells, so the
  ## narrowest passage a player can be committed to is `minOpenCells * cell`
  ## px — with the defaults, 2 * 34 = 68 = `RecommendedCorridorWidthPx`.
  ##
  ## WHAT COUNTS AS A CORRIDOR IS THE WHOLE DESIGN. The first version widened
  ## every pinch: any open cell with wall on both sides. That is far too
  ## greedy. In a cellular-automata field most pinches are just two pebbles a
  ## cell apart, and deleting one of them every time SHATTERS the rock into
  ## isolated dots — the caves render came out as scatter, not caves, and
  ## `interiorFrac` sat at the pool median. A 34 px gap between two boulders is
  ## not a corridor; you walk around it.
  ##
  ## So a corridor is a pinch that CONTINUES: two adjacent cells pinched the
  ## same way, i.e. 68 px of enclosed run. Those are the passages a player
  ## commits to and cannot dodge inside, and they are the only ones widened.
  ##
  ## Of the two flanking walls we clear the more isolated one (fewest wall
  ## neighbours), so the pass eats a stray pebble before it eats a ridge; ties
  ## break on the rng. Off-grid counts as OPEN — the pass must not chew the
  ## region border, where the map simply continues.
  if minOpenCells <= 1: return
  for _ in 0 ..< BiomeWidenPasses:
    var changed = false
    for row in 0 ..< g.rows:
      for c in 0 ..< g.cols:
        if g.wall[g.idx(c, row)]: continue
        if g.corridorH(c, row):
          let
            a = g.neighbours8(c - 1, row, false)
            b = g.neighbours8(c + 1, row, false)
            takeLeft = (if a == b: rand(r, 1.0) < 0.5 else: a < b)
          g.wall[g.idx(if takeLeft: c - 1 else: c + 1, row)] = false
          changed = true
        if g.corridorV(c, row):
          let
            a = g.neighbours8(c, row - 1, false)
            b = g.neighbours8(c, row + 1, false)
            takeUp = (if a == b: rand(r, 1.0) < 0.5 else: a < b)
          g.wall[g.idx(c, if takeUp: row - 1 else: row + 1)] = false
          changed = true
    if not changed: break

proc hasPinch*(g: BiomeGrid): bool =
  ## True when a one-cell-wide corridor of at least two cells survives — the
  ## test hook for the corridor guarantee. Isolated pinches are deliberately
  ## NOT reported; see `widenCorridors`.
  for row in 0 ..< g.rows:
    for c in 0 ..< g.cols:
      if g.corridorH(c, row) or g.corridorV(c, row): return true
  false

# ---------------------------------------------------------------------------
# Emission: coalesce wall cells into as few shapes as possible
# ---------------------------------------------------------------------------

proc rectShape(x, y, w, h: int): ArenaShape {.inline.} =
  ArenaShape(kind: shapeRect, rect: MapRect(x: x, y: y, w: w, h: h))

proc discShape(cx, cy, radius: int): ArenaShape {.inline.} =
  ArenaShape(kind: shapeDisc, cx: cx, cy: cy, radius: radius)

proc emitCells*(g: BiomeGrid, pebbleDiscs: bool): seq[ArenaShape] =
  ## Greedy maximal-rectangle decomposition of the wall set. One shape per
  ## automaton CELL would put 300+ shapes on a standard board and hundreds more
  ## on a giant one; coalescing runs into rectangles cuts that by roughly an
  ## order of magnitude and — because neighbouring rectangles share their whole
  ## edge — the union rasterizes to EXACTLY the cell set, with no seams and no
  ## sub-cell holes that could strand floor.
  ##
  ## `pebbleDiscs` emits a 1x1 wall cell with no 4-neighbour as a DISC instead:
  ## an isolated cell is a boulder or a tree, and a disc inscribed in its own
  ## cell can never overlap a neighbour, so the exactness argument survives.
  var used = newSeq[bool](g.cols * g.rows)
  for row in 0 ..< g.rows:
    for c in 0 ..< g.cols:
      let i = g.idx(c, row)
      if not g.wall[i] or used[i]: continue
      if pebbleDiscs and not g.at(c - 1, row) and not g.at(c + 1, row) and
          not g.at(c, row - 1) and not g.at(c, row + 1):
        used[i] = true
        result.add discShape(g.originX + c * g.cell + g.cell div 2,
                             g.originY + row * g.cell + g.cell div 2,
                             g.cell div 2)
        continue
      var w = 1
      while c + w < g.cols and g.wall[g.idx(c + w, row)] and
          not used[g.idx(c + w, row)]:
        inc w
      var h = 1
      block grow:
        while row + h < g.rows:
          for cc in c ..< c + w:
            if not g.wall[g.idx(cc, row + h)] or used[g.idx(cc, row + h)]:
              break grow
          inc h
      for rr in row ..< row + h:
        for cc in c ..< c + w:
          used[g.idx(cc, rr)] = true
      result.add rectShape(g.originX + c * g.cell, g.originY + row * g.cell,
                           w * g.cell, h * g.cell)

# ---------------------------------------------------------------------------
# desert (biome_desert.py) — a pure analytic field, no grid
# ---------------------------------------------------------------------------

proc clipSegmentToRect(
    px, py, dx, dy: float, rect: MapRect, inset: float
): tuple[t0, t1: float, ok: bool] =
  ## Parameter range of the line `p + t*d` that stays inside `rect` shrunk by
  ## `inset` on every side. Liang-Barsky.
  var
    t0 = -1.0e9
    t1 = 1.0e9
  let
    xlo = float(rect.x) + inset
    xhi = float(rect.x + rect.w) - inset
    ylo = float(rect.y) + inset
    yhi = float(rect.y + rect.h) - inset
  if xhi <= xlo or yhi <= ylo: return (0.0, 0.0, false)
  for axis in 0 .. 1:
    let
      d = (if axis == 0: dx else: dy)
      p = (if axis == 0: px else: py)
      lo = (if axis == 0: xlo else: ylo)
      hi = (if axis == 0: xhi else: yhi)
    if abs(d) < 1.0e-9:
      if p < lo or p > hi: return (0.0, 0.0, false)
    else:
      let
        a = (lo - p) / d
        b = (hi - p) / d
      t0 = max(t0, min(a, b))
      t1 = min(t1, max(a, b))
  if t1 <= t0: return (0.0, 0.0, false)
  (t0, t1, true)

proc genDesertBiome*(
    r: var Rand, region: MapRect, p: BiomeParams, domain: FundamentalDomain
): seq[ArenaShape] =
  ## `BiomeDesert`: striated dunes. The source builds the boolean field
  ## `(x*cos(theta) + y*sin(theta)) mod period < ridge_width` and peppers it
  ## with `noise_prob` gaps.
  ##
  ## We keep the field EXACTLY and skip the quantisation: a ridge is the level
  ## set `u = x*cos + y*sin == const`, which is a straight line, and a straight
  ## thick line is precisely what `shapeDiagonal` is (an integer capsule
  ## between two endpoints). So the desert ports at full analytic precision —
  ## no cell size, no stair-stepping, any angle.
  ##
  ## The lengths do move. The source's period is 8 CELLS and its ridge is 1;
  ## at our scale a 1-cell ridge would be 34 px, under the 47 px at which cover
  ## actually hides a body, so the ridge is `BaseCoverSizePx` = 56 and the
  ## period is set to leave a 136 px sand lane (two recommended corridors)
  ## between ridges. The 8:1 source ratio would have left a 392 px lane, which
  ## on an occlusion-regime board is most of a gun range of open ground.
  ##
  ## `noise_prob` becomes a per-RUN break rather than a per-cell hole: a
  ## one-cell hole in a 56 px ridge is a 34 px doorway that no two cogs can use
  ## abreast, so a break opens `duneGapPx` = ridge + corridor, which clears
  ## `RecommendedCorridorWidthPx` of actual floor.
  discard domain  # desert never dithers; the argument keeps the API uniform
  let
    period = max(16, p.dunePeriodPx)
    width = max(4, p.ridgeWidthPx)
    theta = p.duneAngle
    ct = cos(theta)
    st = sin(theta)
    # Ridge direction: perpendicular to the field gradient.
    dx = -st
    dy = ct
    segLen = float(max(16, p.duneSegmentPx))
    gapLen = float(max(width + 8, p.duneGapPx))
    half = float(width) / 2.0
    # PHASE. The source's field is anchored at the array origin because a
    # source zone is itself placed at a random position — the randomness lives
    # one level up. Ours fills a fixed band, so without a phase the field is
    # the same for every seed: at a 384 px period only two or three ridges
    # cross the band, the 10% break roll rarely fires, and two different seeds
    # produce byte-identical deserts (they did; the determinism test caught
    # it). One uniform draw over a whole period restores the variation the
    # source got from placement.
    phase = rand(r, 1.0) * float(period)
  # u-range of the region's four corners bounds which ridges can intersect it.
  var
    uLo = 1.0e9
    uHi = -1.0e9
  for (cx, cy) in [(region.x, region.y), (region.x + region.w, region.y),
                   (region.x, region.y + region.h),
                   (region.x + region.w, region.y + region.h)]:
    let u = float(cx) * ct + float(cy) * st
    uLo = min(uLo, u)
    uHi = max(uHi, u)
  var k = int(floor((uLo - phase) / float(period))) - 1
  while float(k) * float(period) + phase <= uHi + float(period):
    let
      u = float(k) * float(period) + phase + float(width) / 2.0
      # A point on this ridge's centre line, plus the in-region span.
      px = u * ct
      py = u * st
      # `inShape` accepts a point within `thickness div 2 + 1` of the segment,
      # so the centre line is inset by that plus a pixel: a dune never pokes
      # out of the placement band, which is what keeps the seed set fair.
      clip = clipSegmentToRect(px, py, dx, dy, region,
                               float(width div 2 + 2))
    inc k
    if not clip.ok: continue
    var t = clip.t0
    while t < clip.t1:
      if rand(r, 1.0) < p.noiseProb:
        t += gapLen
        continue
      let e = min(t + segLen, clip.t1)
      if e - t > float(width) / 2.0:
        result.add ArenaShape(
          kind: shapeDiagonal,
          x0: int(round(px + dx * t)), y0: int(round(py + dy * t)),
          x1: int(round(px + dx * e)), y1: int(round(py + dy * e)),
          thickness: width)
      t = e

# ---------------------------------------------------------------------------
# city (biome_city.py) — jittered block lattice + forced roads, no grid
# ---------------------------------------------------------------------------

proc cityRoadBands*(region: MapRect, p: BiomeParams): seq[MapRect] =
  ## The FORCED road stripes: `road_width` wide, every `pitch`, on both axes.
  ##
  ## In the source these are applied with `np.where(grid == "wall", "wall",
  ## "empty")`, which PRESERVES existing walls in the road band — the roads
  ## only clear non-wall content. Our emitters are additive (they return
  ## shapes, they do not own a canvas), so a pure city emitter has nothing to
  ## clear: it never places a block in a road band in the first place, which is
  ## the same result on an empty region.
  ##
  ## This proc exists so a scene graph that OVERLAYS city on another biome can
  ## reproduce the source's second effect — carving the road network through
  ## whatever was already there — as an explicit subtractive mask. That is the
  ## one guarantee of baseline connectivity in the whole biome family, and it
  ## is worth not losing.
  let
    pitch = max(32, p.pitchPx)
    road = max(8, p.roadWidthPx)
  var y = region.y
  while y < region.y + region.h:
    result.add MapRect(x: region.x, y: y, w: region.w,
                       h: min(road, region.y + region.h - y))
    y += pitch
  var x = region.x
  while x < region.x + region.w:
    result.add MapRect(x: x, y: region.y,
                       w: min(road, region.x + region.w - x), h: region.h)
    x += pitch

proc genCityBiome*(
    r: var Rand, region: MapRect, p: BiomeParams, domain: FundamentalDomain
): seq[ArenaShape] =
  ## `BiomeCity`: rectangular blocks on a `pitch` lattice with a road margin on
  ## every side, each block jittered in size and placed with `place_prob`.
  ##
  ## The structure is the source's, exactly: one `place_prob` roll per lattice
  ## cell, block origin a road width past the lattice line, nominal side
  ## `pitch * min_block_frac`, jittered, then clipped to `pitch - 2*road` so a
  ## block can never spill into the next road. Only the units and two numbers
  ## move, and both for a stated reason:
  ##
  ## - LENGTHS. The source's lattice is 10 cells with a 3-cell road. Ours is
  ##   `WallSpanPx` = 264 px with a 72 px road, which makes the road itself
  ##   wider than `RecommendedCorridorWidthPx` and makes one block a
  ##   STRUCTURAL wall rather than a pebble. Streets come out 144-180 px and
  ##   blocks 84-120 px, for a cover fraction near 145 permille — inside
  ##   `map_rules`' 42..168 occlusion band, which is what the ratio was picked
  ##   for.
  ## - `min_block_frac` 0.5 -> 0.38. At 0.5 the nominal block (`pitch/2`) is
  ##   LARGER than the clip (`pitch - 2*road`) for any road wider than a
  ##   quarter of the pitch, so `min(bw, maxBlock)` swallows the jitter whole
  ##   and every block comes out identical. That is true of the source's own
  ##   numbers as well (5 jittered to 4..6, clipped to 4, always 4) — its city
  ##   is a perfectly regular grid. 0.38 keeps the jitter live.
  ##
  ## One addition the source does not have: the block is also OFFSET inside its
  ## own cell, within the slack the clip leaves. It cannot reach a road band
  ## (tested), so the road guarantee is untouched, and it is what stops a
  ## coarse lattice — a standard board only fits 3x3 cells — from producing the
  ## same nine squares for every seed.
  discard domain  # city is rectilinear and never dithers in our port; see note
  let
    pitch = max(32, p.pitchPx)
    road = max(8, p.roadWidthPx)
    minBlock = max(1, int(float(pitch) * p.minBlockFrac))
    jitter = max(0, p.blockJitterPx)
    maxBlock = pitch - 2 * road
  if maxBlock <= 0: return
  var gy = region.y
  while gy < region.y + region.h:
    var gx = region.x
    while gx < region.x + region.w:
      # Every roll happens for every lattice cell whether or not the block
      # lands, so the rng stream is a function of the lattice alone.
      let place = rand(r, 1.0) <= p.placeProb
      var
        bw = minBlock + (if jitter > 0: rand(r, 2 * jitter) - jitter else: 0)
        bh = minBlock + (if jitter > 0: rand(r, 2 * jitter) - jitter else: 0)
      bw = min(bw, maxBlock)
      bh = min(bh, maxBlock)
      let
        offX = (if maxBlock > bw: rand(r, maxBlock - bw) else: 0)
        offY = (if maxBlock > bh: rand(r, maxBlock - bh) else: 0)
      if place and bw > 0 and bh > 0:
        let
          x0 = gx + road + offX
          y0 = gy + road + offY
          w = min(bw, region.x + region.w - x0)
          h = min(bh, region.y + region.h - y0)
        if w > 0 and h > 0:
          result.add rectShape(x0, y0, w, h)
      gx += pitch
    gy += pitch

# ---------------------------------------------------------------------------
# plains (biome_plains.py) — random-walk pebble clusters, NO dither
# ---------------------------------------------------------------------------

proc genPlainsBiome*(
    r: var Rand, region: MapRect, p: BiomeParams, domain: FundamentalDomain
): seq[ArenaShape] =
  ## `BiomePlains`: a lattice of anchors at `cluster_period`, each accepted
  ## with `cluster_prob` and jittered, each spawning 2..4 simultaneous random
  ## walkers that drop rocks with probability `fill`, turn 35% of the time,
  ## are FORCED to turn when they leave `(radius+1)^2`, and throw 12% two-cell
  ## spurs after the second step.
  ##
  ## Ported step for step, with the walkers advanced in LOCKSTEP so the branch
  ## interaction is the source's and not a sequence of independent walks.
  ##
  ## This is the one biome the source does NOT dither, and we do not either.
  ## Its cell is `BiomePebbleCellPx` = 56 px so a single dropped rock is one
  ## cover piece; at the 34 px cell the pebbles would be sub-cover noise.
  discard domain  # plains never dithers (source parity)
  var g = newBiomeGrid(region, p.cell)
  let
    period = max(3, p.clusterPeriod)
    minRadius = max(0, p.clusterMinRadius)
    maxRadius = max(minRadius, p.clusterMaxRadius)
    jitter = max(0, p.clusterJitter)
    dirsX = [1, -1, 0, 0]
    dirsY = [0, 0, 1, -1]
  var ay = 0
  while ay < g.rows:
    var ax = 0
    while ax < g.cols:
      let take = rand(r, 1.0) <= p.clusterProb
      var
        cx = ax
        cy = ay
      if jitter > 0:
        cx += rand(r, 2 * jitter) - jitter
        cy += rand(r, 2 * jitter) - jitter
      if not take or not g.inGrid(cx, cy):
        ax += period
        continue
      let radius = (if maxRadius > 0: minRadius + rand(r, maxRadius - minRadius)
                    else: 0)
      if radius == 0:
        g.wall[g.idx(cx, cy)] = true
        ax += period
        continue
      let
        fill = p.clusterFill * (0.6 + rand(r, 1.0) * 0.4)
        branches = 2 + rand(r, 2)
        maxSteps = max(3, radius * 3)
        maxDist2 = (radius + 1) * (radius + 1)
      var
        wx = newSeq[int](branches)
        wy = newSeq[int](branches)
        wd = newSeq[int](branches)
      for b in 0 ..< branches:
        wx[b] = cx
        wy[b] = cy
        wd[b] = rand(r, 3)
      for step in 0 ..< maxSteps:
        for b in 0 ..< branches:
          if g.inGrid(wx[b], wy[b]) and rand(r, 1.0) <= fill:
            g.wall[g.idx(wx[b], wy[b])] = true
        for b in 0 ..< branches:
          if rand(r, 1.0) < 0.35: wd[b] = rand(r, 3)
        for b in 0 ..< branches:
          let
            nx = wx[b] + dirsX[wd[b]]
            ny = wy[b] + dirsY[wd[b]]
          if (nx - cx) * (nx - cx) + (ny - cy) * (ny - cy) > maxDist2:
            wd[b] = rand(r, 3)
          wx[b] += dirsX[wd[b]]
          wy[b] += dirsY[wd[b]]
        if step > 1:
          for b in 0 ..< branches:
            if rand(r, 1.0) >= 0.12: continue
            let sd = rand(r, 3)
            var
              sx = wx[b] + dirsX[sd]
              sy = wy[b] + dirsY[sd]
            if (sx - cx) * (sx - cx) + (sy - cy) * (sy - cy) > maxDist2:
              continue
            if g.inGrid(sx, sy) and rand(r, 1.0) <= fill:
              g.wall[g.idx(sx, sy)] = true
            sx += dirsX[sd]
            sy += dirsY[sd]
            if (sx - cx) * (sx - cx) + (sy - cy) * (sy - cy) > maxDist2:
              continue
            if g.inGrid(sx, sy) and rand(r, 1.0) <= fill:
              g.wall[g.idx(sx, sy)] = true
      ax += period
    ay += period
  widenCorridors(r, g, p.minOpenCells)
  emitCells(g, p.pebbleDiscs)

# ---------------------------------------------------------------------------
# forest (biome_forest.py) — seeded monotone growth
# ---------------------------------------------------------------------------

proc genForestBiome*(
    r: var Rand, region: MapRect, p: BiomeParams, domain: FundamentalDomain
): seq[ArenaShape] =
  ## `BiomeForest`: sparse seeds at `seed_prob`, then `clumpiness` MONOTONE
  ## growth passes — a cell becomes forest when it already has
  ## `neighbor_threshold` forest neighbours and wins a `growth_prob` roll, and
  ## forest never dies. Off-grid counts as OPEN (`np.pad` default 0), so the
  ## forest does not accrete at the region border the way caves does.
  ##
  ## The sparsest of the five: it produces isolated thickets with wide ground
  ## between them, which is why it is the one biome that reads as cover you can
  ## fight AROUND rather than terrain you fight THROUGH.
  var g = newBiomeGrid(region, p.cell)
  for i in 0 ..< g.wall.len:
    g.wall[i] = rand(r, 1.0) < p.seedProb
  for _ in 0 ..< max(0, p.clumpiness):
    var nxt = g.wall
    for row in 0 ..< g.rows:
      for c in 0 ..< g.cols:
        let
          nb = g.neighbours8(c, row, false)
          roll = rand(r, 1.0)
        if nb >= p.neighborThreshold and roll < p.growthProb:
          nxt[g.idx(c, row)] = true
    g.wall = nxt
  ditherEdges(r, g, domain, p.ditherProb, p.ditherDepth)
  widenCorridors(r, g, p.minOpenCells)
  emitCells(g, p.pebbleDiscs)

# ---------------------------------------------------------------------------
# caves (biome_caves.py) — cellular automata
# ---------------------------------------------------------------------------

proc genCavesBiome*(
    r: var Rand, region: MapRect, p: BiomeParams, domain: FundamentalDomain
): seq[ArenaShape] =
  ## `BiomeCaves`: classic CA. Rock at `fill_prob`, then `steps` passes of
  ## "born when neighbours > birth_limit, survives when neighbours >=
  ## death_limit", with the array padded `constant_values=1` — off-grid counts
  ## as ROCK, which is what makes a cave zone SELF-SEAL at its border instead
  ## of spilling into whatever is next to it.
  ##
  ## That padding is the source's and we keep it (`borderIsRock`, default
  ## true), because it is the property that makes caves usable as a ZONE in a
  ## scene graph. It is also why caves is the DENSEST of the five and why the
  ## source weights it 0 as an overlay and uses it as a base: as a full-region
  ## fill on a CTF board it lands far above the cover band. Set
  ## `borderIsRock = false` for a full-region fill; see the module test.
  var g = newBiomeGrid(region, p.cell)
  for i in 0 ..< g.wall.len:
    g.wall[i] = rand(r, 1.0) < p.fillProb
  for _ in 0 ..< max(0, p.steps):
    var nxt = newSeq[bool](g.wall.len)
    for row in 0 ..< g.rows:
      for c in 0 ..< g.cols:
        let nb = g.neighbours8(c, row, p.borderIsRock)
        nxt[g.idx(c, row)] =
          nb > p.birthLimit or (nb >= p.deathLimit and g.wall[g.idx(c, row)])
    g.wall = nxt
  ditherEdges(r, g, domain, p.ditherProb, p.ditherDepth)
  widenCorridors(r, g, p.minOpenCells)
  emitCells(g, p.pebbleDiscs)

# ---------------------------------------------------------------------------
# AsteroidMask (asteroid_mask.py) — edge ragging
# ---------------------------------------------------------------------------

proc edgeMaskShapes*(
    r: var Rand, region: MapRect, p: BiomeParams,
    edges: set[BiomeEdge] = {edgeTop, edgeBottom, edgeLeft, edgeRight}
): seq[ArenaShape] =
  ## `AsteroidMask`: for every anchor along every edge at `step`, with
  ## `chunk_prob`, cut an inward-TAPERING triangle of depth `depth_min ..
  ## depth_max` and half-width `width_min .. width_max`.
  ##
  ## The source draws it as a stack of shrinking spans, which IS a triangle; we
  ## emit the triangle itself as a three-vertex `shapePolygon`, so one tooth is
  ## one shape instead of `depth` rows of them and the taper is exact rather
  ## than stair-stepped. Integer vertices keep the strict-straddle even-odd
  ## test — and therefore mirror-exactness — intact.
  ##
  ## The source enables this size-conditionally (min(w, h) >= 80 cells). That
  ## decision belongs to the scene graph, not here; this proc just does the
  ## cutting when asked.
  let
    step = max(8, p.maskStepPx)
    depthLo = max(0, p.maskDepthMin)
    depthHi = max(depthLo, p.maskDepthMax)
    widthLo = max(0, p.maskWidthMin)
    widthHi = max(widthLo, p.maskWidthMax)
  if depthHi == 0 or widthHi == 0 or p.maskChunkProb <= 0.0: return

  proc tooth(anchor, depth, halfW: int, edge: BiomeEdge): ArenaShape =
    case edge
    of edgeTop:
      ArenaShape(kind: shapePolygon, points: @[
        MapPoint(x: max(region.x, anchor - halfW), y: region.y),
        MapPoint(x: min(region.x + region.w, anchor + halfW), y: region.y),
        MapPoint(x: anchor, y: min(region.y + region.h, region.y + depth))])
    of edgeBottom:
      let yb = region.y + region.h
      ArenaShape(kind: shapePolygon, points: @[
        MapPoint(x: max(region.x, anchor - halfW), y: yb),
        MapPoint(x: min(region.x + region.w, anchor + halfW), y: yb),
        MapPoint(x: anchor, y: max(region.y, yb - depth))])
    of edgeLeft:
      ArenaShape(kind: shapePolygon, points: @[
        MapPoint(x: region.x, y: max(region.y, anchor - halfW)),
        MapPoint(x: region.x, y: min(region.y + region.h, anchor + halfW)),
        MapPoint(x: min(region.x + region.w, region.x + depth), y: anchor)])
    of edgeRight:
      let xr = region.x + region.w
      ArenaShape(kind: shapePolygon, points: @[
        MapPoint(x: xr, y: max(region.y, anchor - halfW)),
        MapPoint(x: xr, y: min(region.y + region.h, anchor + halfW)),
        MapPoint(x: max(region.x, xr - depth), y: anchor)])

  for edge in [edgeTop, edgeBottom, edgeLeft, edgeRight]:
    let
      horizontal = edge in {edgeTop, edgeBottom}
      lo = (if horizontal: region.x else: region.y)
      extent = (if horizontal: region.w else: region.h)
    var anchor = lo
    while anchor < lo + extent:
      # Roll for every anchor on every edge, whether or not that edge is
      # selected, so the stream depends on the region alone.
      let
        cut = rand(r, 1.0) < p.maskChunkProb
        depth = depthLo + (if depthHi > depthLo: rand(r, depthHi - depthLo)
                           else: 0)
        halfW = widthLo + (if widthHi > widthLo: rand(r, widthHi - widthLo)
                           else: 0)
      if cut and edge in edges and depth > 0 and halfW > 0:
        result.add tooth(anchor, depth, halfW, edge)
      anchor += step

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

proc genBiome*(
    r: var Rand, style: BiomeStyle, region: MapRect, p: BiomeParams,
    domain: FundamentalDomain
): seq[ArenaShape] =
  ## The single entry point a scene graph composes with. Same shape as
  ## `mapgen_styles.generateShapes`, plus the domain the dither pass needs.
  case style
  of biomeStyleCaves: genCavesBiome(r, region, p, domain)
  of biomeStyleForest: genForestBiome(r, region, p, domain)
  of biomeStyleDesert: genDesertBiome(r, region, p, domain)
  of biomeStyleCity: genCityBiome(r, region, p, domain)
  of biomeStylePlains: genPlainsBiome(r, region, p, domain)

proc generateBiomeShapes*(
    style: BiomeStyle, seed: int, region: MapRect, p: BiomeParams,
    domain: FundamentalDomain
): seq[ArenaShape] =
  ## Deterministic for a given (style, seed, region, params, domain). The
  ## stream is independent of the map generator's own rng, exactly as
  ## `mapgen_styles.generateShapes` is, so styling a base map never perturbs
  ## its drawn size, endzone or clearances.
  var r = initRand(seed)
  genBiome(r, style, region, p, domain)

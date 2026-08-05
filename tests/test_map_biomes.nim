## The Cogs-vs-Clips biome terrain emitters (`src/ctf/mapgen_biomes.nim`).
##
## Three jobs, in order of how badly a regression would hurt:
##
## 1. FAIRNESS. The dither pass flips wall cells at random, so running it
##    anywhere but inside a fundamental domain, before the symmetry lift, hands
##    one team a notch the other does not have. The module's defence is a type
##    with one validating constructor plus a required argument; these tests are
##    what prove the defence actually refuses the mistakes it claims to.
## 2. DETERMINISM. A map seed must reproduce a map. Same seed in, byte-identical
##    shape set out — for every biome, including the ones that draw thousands of
##    rng values.
## 3. THE PIXEL-SPACE CONTRACT. The source algorithms are written on tile grids
##    where a one-cell corridor is fine; here 26 px is the enforced minimum and
##    68 px the recommended one. `widenCorridors` claims to make 68 px a
##    guarantee by construction, and every shape must stay inside the band.

import
  std/[math, random, unittest],
  ctf/[map_rules, mapgen_biomes, sim_types]

# --- helpers -----------------------------------------------------------------

proc boardRect(w, h: int): MapRect = MapRect(x: 0, y: 0, w: w, h: h)

proc leftHalfRegion(board: MapRect, inset = 20): MapRect =
  ## A placement band in the left half of a board, the way
  ## `mapkit.placementRegion` builds one: inset from every side and stopping
  ## short of the vertical seam.
  MapRect(x: board.x + inset, y: board.y + inset,
          w: board.w div 2 - 2 * inset, h: board.h - 2 * inset)

proc bounds(s: ArenaShape): tuple[x0, y0, x1, y1: int] =
  case s.kind
  of shapeRect:
    (s.rect.x, s.rect.y, s.rect.x + s.rect.w, s.rect.y + s.rect.h)
  of shapeDisc, shapeDiamond:
    (s.cx - s.radius, s.cy - s.radius, s.cx + s.radius, s.cy + s.radius)
  of shapeDiagonal:
    let half = s.thickness div 2 + 1
    (min(s.x0, s.x1) - half, min(s.y0, s.y1) - half,
     max(s.x0, s.x1) + half, max(s.y0, s.y1) + half)
  of shapePolygon:
    var b = (s.points[0].x, s.points[0].y, s.points[0].x, s.points[0].y)
    for p in s.points:
      b[0] = min(b[0], p.x); b[1] = min(b[1], p.y)
      b[2] = max(b[2], p.x); b[3] = max(b[3], p.y)
    b

proc insideRegion(shapes: seq[ArenaShape], region: MapRect): bool =
  for s in shapes:
    let b = s.bounds()
    if b.x0 < region.x or b.y0 < region.y or
        b.x1 > region.x + region.w or b.y1 > region.y + region.h:
      return false
  true

proc digest(shapes: seq[ArenaShape]): string =
  ## A stable serialization: two runs agree iff the shape sets are identical.
  for s in shapes:
    result.add $s.kind & ":"
    case s.kind
    of shapeRect:
      result.add $s.rect.x & "," & $s.rect.y & "," & $s.rect.w & "," & $s.rect.h
    of shapeDisc, shapeDiamond:
      result.add $s.cx & "," & $s.cy & "," & $s.radius
    of shapeDiagonal:
      result.add $s.x0 & "," & $s.y0 & "," & $s.x1 & "," & $s.y1 & "," &
        $s.thickness
    of shapePolygon:
      for p in s.points: result.add $p.x & "/" & $p.y & " "
    result.add ";"

const
  TestBoard = boardRect(1235, 659)
  TestRegion = leftHalfRegion(TestBoard, 24)

proc testDomain(): FundamentalDomain =
  fundamentalDomain(TestBoard, TestRegion, symMirror)

# --- 1. fairness: the fundamental-domain gate --------------------------------

suite "the dither pass cannot escape a fundamental domain":
  test "the whole board is REFUSED as a domain":
    # The exact mistake the type exists to prevent: dithering a finished map.
    expect ValueError:
      discard fundamentalDomain(TestBoard, TestBoard, symMirror)
    expect ValueError:
      discard fundamentalDomain(TestBoard, TestBoard, symRot90)

  test "a region straddling the symmetry axis is REFUSED":
    # Half the board's area, but centred: area fits, yet every flip in it lands
    # on top of its own mirror image.
    let straddling = MapRect(x: 1235 div 4, y: 20,
                             w: 1235 div 2, h: 659 - 40)
    expect ValueError:
      discard fundamentalDomain(TestBoard, straddling, symMirror)

  test "a rot90 domain must clear BOTH axes":
    let topHalf = MapRect(x: 20, y: 20, w: 1235 div 2 - 40, h: 659 - 40)
    # Fine under mirror (one axis), refused under rot90 (crosses y as well).
    check fundamentalDomain(TestBoard, topHalf, symMirror).order == 2
    expect ValueError:
      discard fundamentalDomain(TestBoard, topHalf, symRot90)
    let quadrant = MapRect(x: 20, y: 20, w: 1235 div 2 - 40, h: 659 div 2 - 40)
    check fundamentalDomain(TestBoard, quadrant, symRot90).order == 4

  test "a region outside the board, or empty, is REFUSED":
    expect ValueError:
      discard fundamentalDomain(TestBoard, MapRect(x: -5, y: 20, w: 100, h: 100),
                                symMirror)
    expect ValueError:
      discard fundamentalDomain(TestBoard, MapRect(x: 20, y: 20, w: 0, h: 100),
                                symMirror)

  test "ditherEdges REFUSES a grid that is not inside its domain":
    # A domain in the left half, a grid built in the right half: the type is
    # valid, the pairing is not, and the pass must not run.
    let
      domain = testDomain()
      elsewhere = MapRect(x: 700, y: 24, w: 400, h: 400)
    var
      g = newBiomeGrid(elsewhere, BiomeCellPx)
      r = initRand(7)
    for i in 0 ..< g.wall.len: g.wall[i] = (i mod 3) == 0
    expect ValueError:
      ditherEdges(r, g, domain, 0.15, 5)

  test "dither never touches a cell outside the domain's border band":
    # The source excludes a `depth`-wide band on every side so the frame never
    # dissolves; here that band is also what keeps the seam edge intact.
    let domain = testDomain()
    var
      g = newBiomeGrid(TestRegion, BiomeCellPx)
      r = initRand(11)
    for i in 0 ..< g.wall.len: g.wall[i] = (i mod 4) < 2
    let before = g.wall
    ditherEdges(r, g, domain, 1.0, 3)  # prob 1.0: every eligible cell flips
    var flippedInBand = 0
    for row in 0 ..< g.rows:
      for c in 0 ..< g.cols:
        if before[g.idx(c, row)] != g.wall[g.idx(c, row)]:
          if row < 3 or row >= g.rows - 3 or c < 3 or c >= g.cols - 3:
            inc flippedInBand
    check flippedInBand == 0

  test "dither with prob 0 or depth 0 is a no-op":
    let domain = testDomain()
    var
      g = newBiomeGrid(TestRegion, BiomeCellPx)
      r = initRand(3)
    for i in 0 ..< g.wall.len: g.wall[i] = (i mod 5) == 0
    let before = g.wall
    ditherEdges(r, g, domain, 0.0, 5)
    check g.wall == before
    ditherEdges(r, g, domain, 0.15, 0)
    check g.wall == before

  test "dither actually changes something at the published defaults":
    # A guard against the pass silently becoming a no-op: 0.15 / depth 5 on a
    # real cave field must move cells.
    let domain = testDomain()
    var
      g = newBiomeGrid(TestRegion, BiomeCellPx)
      r = initRand(5)
    for i in 0 ..< g.wall.len: g.wall[i] = rand(r, 1.0) < 0.4
    let before = g.wall
    ditherEdges(r, g, domain, 0.15, 5)
    var flips = 0
    for i in 0 ..< g.wall.len:
      if g.wall[i] != before[i]: inc flips
    check flips > 0

# --- 2. determinism ----------------------------------------------------------

suite "biome emitters are deterministic":
  test "same seed reproduces byte-identical shapes, every biome":
    let domain = testDomain()
    for style in BiomeStyle:
      let p = defaultBiomeParams(style)
      var seen: string
      for attempt in 0 .. 1:
        let d = digest(generateBiomeShapes(style, 4242, TestRegion, p, domain))
        if attempt == 0: seen = d
        else: check d == seen
      check seen.len > 0

  test "different seeds produce different terrain":
    let domain = testDomain()
    for style in BiomeStyle:
      let p = defaultBiomeParams(style)
      check digest(generateBiomeShapes(style, 1, TestRegion, p, domain)) !=
        digest(generateBiomeShapes(style, 2, TestRegion, p, domain))

  test "the edge mask is deterministic too":
    let p = defaultBiomeParams(biomeStyleCaves)
    var a = initRand(9)
    var b = initRand(9)
    check digest(edgeMaskShapes(a, TestRegion, p)) ==
      digest(edgeMaskShapes(b, TestRegion, p))

# --- 3. the pixel-space contract ---------------------------------------------

suite "biome emitters honour the pixel-space contract":
  test "every shape stays inside the placement band":
    let domain = testDomain()
    for style in BiomeStyle:
      let
        p = defaultBiomeParams(style)
        shapes = generateBiomeShapes(style, 77, TestRegion, p, domain)
      check shapes.len > 0
      check shapes.insideRegion(TestRegion)

  test "the edge mask stays inside the band as well":
    let p = defaultBiomeParams(biomeStyleCaves)
    var r = initRand(31)
    let teeth = edgeMaskShapes(r, TestRegion, p)
    check teeth.len > 0
    check teeth.insideRegion(TestRegion)
    for t in teeth:
      check t.kind == shapePolygon
      check t.points.len == 3

  test "widenCorridors leaves no passage narrower than two cells":
    # THE corridor guarantee: 2 * 34 px = RecommendedCorridorWidthPx. Run it on
    # the densest thing we generate (a raw CA field) for several seeds.
    for seed in 1 .. 8:
      var
        r = initRand(seed)
        g = newBiomeGrid(TestRegion, BiomeCellPx)
      for i in 0 ..< g.wall.len: g.wall[i] = rand(r, 1.0) < 0.45
      check g.hasPinch()  # the raw field has pinches, or the test proves nothing
      widenCorridors(r, g, BiomeMinOpenCells)
      check not g.hasPinch()
    check BiomeMinOpenCells * BiomeCellPx == RecommendedCorridorWidthPx

  test "widenCorridors with minOpenCells <= 1 is a no-op":
    var
      r = initRand(2)
      g = newBiomeGrid(TestRegion, BiomeCellPx)
    for i in 0 ..< g.wall.len: g.wall[i] = rand(r, 1.0) < 0.45
    let before = g.wall
    widenCorridors(r, g, 1)
    check g.wall == before

  test "emitCells reproduces the wall set EXACTLY":
    # Coalescing into maximal rectangles must be lossless in both directions:
    # no cell dropped, no open cell covered. A sub-cell seam here would strand
    # floor and fail the validator downstream.
    var
      r = initRand(19)
      g = newBiomeGrid(MapRect(x: 100, y: 60, w: 40 * BiomeCellPx,
                               h: 24 * BiomeCellPx), BiomeCellPx)
    for i in 0 ..< g.wall.len: g.wall[i] = rand(r, 1.0) < 0.4
    let shapes = emitCells(g, false)  # rects only: exact by construction
    var covered = newSeq[bool](g.cols * g.rows)
    for s in shapes:
      check s.kind == shapeRect
      let
        c0 = (s.rect.x - g.originX) div g.cell
        r0 = (s.rect.y - g.originY) div g.cell
        cw = s.rect.w div g.cell
        rh = s.rect.h div g.cell
      check s.rect.w mod g.cell == 0
      check s.rect.h mod g.cell == 0
      for rr in r0 ..< r0 + rh:
        for cc in c0 ..< c0 + cw:
          check not covered[g.idx(cc, rr)]  # no overlap
          covered[g.idx(cc, rr)] = true
    check covered == g.wall

  test "coalescing beats one shape per cell by a wide margin":
    var
      r = initRand(23)
      g = newBiomeGrid(TestRegion, BiomeCellPx)
    for i in 0 ..< g.wall.len: g.wall[i] = rand(r, 1.0) < 0.45
    widenCorridors(r, g, BiomeMinOpenCells)
    var cells = 0
    for w in g.wall:
      if w: inc cells
    let shapes = emitCells(g, true)
    check shapes.len < cells

  test "isolated cells become discs, not squares":
    var g = newBiomeGrid(MapRect(x: 0, y: 0, w: 10 * BiomeCellPx,
                                 h: 10 * BiomeCellPx), BiomeCellPx)
    g.wall[g.idx(4, 4)] = true          # lone pebble
    g.wall[g.idx(7, 7)] = true          # a 2x1 bar: not isolated
    g.wall[g.idx(8, 7)] = true
    let shapes = emitCells(g, true)
    var discs, rects = 0
    for s in shapes:
      if s.kind == shapeDisc: inc discs else: inc rects
    check discs == 1
    check rects == 1

# --- 4. per-biome character --------------------------------------------------

suite "each biome emits the terrain it claims to":
  test "desert is analytic: nothing but thick diagonal ridges":
    let
      domain = testDomain()
      p = defaultBiomeParams(biomeStyleDesert)
      shapes = generateBiomeShapes(biomeStyleDesert, 5, TestRegion, p, domain)
    check shapes.len > 0
    for s in shapes:
      check s.kind == shapeDiagonal
      check s.thickness == p.ridgeWidthPx
      # Every ridge runs along the SAME direction: that is what "striated"
      # means, and it is the property a quantised port loses.
      let
        dx = float(s.x1 - s.x0)
        dy = float(s.y1 - s.y0)
        len = sqrt(dx * dx + dy * dy)
      check len > 0.0
      # Ridge direction is perpendicular to the field gradient (cos, sin).
      # The tolerance is the integer rounding of the endpoints, nothing more.
      check abs(dx / len * cos(p.duneAngle) + dy / len * sin(p.duneAngle)) < 0.02

  test "desert angle 0 gives vertical stripes":
    var p = defaultBiomeParams(biomeStyleDesert)
    p.duneAngle = 0.0
    p.noiseProb = 0.0
    let shapes = generateBiomeShapes(biomeStyleDesert, 5, TestRegion, p,
                                     testDomain())
    check shapes.len > 0
    for s in shapes:
      check s.x0 == s.x1  # a vertical wall

  test "city is a road lattice: blocks never sit in a road band":
    let
      p = defaultBiomeParams(biomeStyleCity)
      shapes = generateBiomeShapes(biomeStyleCity, 8, TestRegion, p,
                                   testDomain())
      roads = cityRoadBands(TestRegion, p)
    check shapes.len > 0
    check roads.len > 0
    for s in shapes:
      check s.kind == shapeRect
      # Every block starts one road width past a lattice line and is clipped so
      # it cannot reach the next one: that is what guarantees the roads survive.
      let offX = (s.rect.x - TestRegion.x) mod p.pitchPx
      check offX >= p.roadWidthPx
      check offX + s.rect.w <= p.pitchPx - p.roadWidthPx

  test "city roads clear RecommendedCorridorWidthPx":
    let p = defaultBiomeParams(biomeStyleCity)
    check p.roadWidthPx >= RecommendedCorridorWidthPx

  test "forest is sparser than caves at the published defaults":
    let domain = testDomain()
    var area: array[BiomeStyle, int]
    for style in BiomeStyle:
      let shapes = generateBiomeShapes(style, 101, TestRegion,
                                       defaultBiomeParams(style), domain)
      for s in shapes:
        let b = s.bounds()
        area[style] += (b.x1 - b.x0) * (b.y1 - b.y0)
    check area[biomeStyleForest] < area[biomeStyleCaves]
    check area[biomeStylePlains] < area[biomeStyleCaves]

  test "caves self-seals at the region border when borderIsRock is set":
    # np.pad(constant_values=1): off-grid counts as rock, so a cave ZONE closes
    # itself off instead of spilling. Turning it off must visibly thin the rim.
    let domain = testDomain()
    var sealed = defaultBiomeParams(biomeStyleCaves)
    var open = sealed
    open.borderIsRock = false
    proc rimWall(p: BiomeParams): int =
      var
        r = initRand(64)
        g = newBiomeGrid(TestRegion, p.cell)
      for i in 0 ..< g.wall.len: g.wall[i] = rand(r, 1.0) < p.fillProb
      for _ in 0 ..< p.steps:
        var nxt = newSeq[bool](g.wall.len)
        for row in 0 ..< g.rows:
          for c in 0 ..< g.cols:
            var nb = 0
            for dy in -1 .. 1:
              for dx in -1 .. 1:
                if dx == 0 and dy == 0: continue
                if not g.inGrid(c + dx, row + dy):
                  if p.borderIsRock: inc nb
                elif g.wall[g.idx(c + dx, row + dy)]: inc nb
            nxt[g.idx(c, row)] =
              nb > p.birthLimit or (nb >= p.deathLimit and g.wall[g.idx(c, row)])
        g.wall = nxt
      for c in 0 ..< g.cols:
        if g.wall[g.idx(c, 0)]: inc result
        if g.wall[g.idx(c, g.rows - 1)]: inc result
    check rimWall(sealed) > rimWall(open)
    check generateBiomeShapes(biomeStyleCaves, 3, TestRegion, sealed,
                              domain).len > 0

  test "parseBiomeStyle round-trips every biome name":
    for style in BiomeStyle:
      check parseBiomeStyle($style) == style
    expect ValueError:
      discard parseBiomeStyle("tundra")

  test "the biome style names match the shipped MapBiome skins":
    # A scene graph maps a chosen skin onto its terrain emitter BY NAME; if the
    # two enums drift, it silently picks the wrong terrain.
    for style in BiomeStyle:
      var found = false
      for skin in MapBiome:
        if $skin == $style: found = true
      check found

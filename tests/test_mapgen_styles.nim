## Unit + integration tests for the mapkit terrain-style generators.
##
## Fairness itself is the sim's job (symmetry + carve + validators); these
## tests prove the generators are deterministic, stay inside their placement
## band, round-trip through mapSpec, and CAN produce maps the real validator
## accepts.

import
  std/unittest,
  ctf/[sim, mapgen_styles]

const styles = [styleBsp, styleCaves, styleMaze, styleScatter]

proc sampleRegion(): MapRect =
  MapRect(x: 64, y: 64, w: 420, h: 520)

proc withinBounds(shapes: seq[ArenaShape], region: MapRect): bool =
  for s in shapes:
    case s.kind
    of shapeRect:
      if s.rect.x < region.x or s.rect.y < region.y: return false
      if s.rect.x + s.rect.w > region.x + region.w: return false
      if s.rect.y + s.rect.h > region.y + region.h: return false
    of shapeDisc, shapeDiamond:
      if s.cx - s.radius < region.x or s.cy - s.radius < region.y: return false
      if s.cx + s.radius > region.x + region.w: return false
      if s.cy + s.radius > region.y + region.h: return false
    of shapeDiagonal:
      discard
    of shapePolygon:
      for p in s.points:
        if p.x < region.x or p.y < region.y or
            p.x > region.x + region.w or p.y > region.y + region.h:
          return false
  true

proc testRegion(base: CtfMap): MapRect =
  ## Mirrors mapkit.placementRegion (kept local to avoid a pixie dependency
  ## in the test binary via tools/map_render).
  const
    vMargin = 2
    hMargin = 40
    seam = 20
  let halfW = base.width div 2
  case base.symmetry
  of symMirror, symRot180:
    MapRect(x: hMargin, y: vMargin,
            w: halfW - hMargin - seam, h: base.height - 2 * vMargin)
  of symRot90:
    MapRect(x: hMargin, y: vMargin,
            w: halfW - hMargin - seam, h: base.height div 2 - vMargin - seam)

suite "mapgen styles":
  test "parseStyle round-trips the names":
    check parseStyle("bsp") == styleBsp
    check parseStyle("caves") == styleCaves
    check parseStyle("maze") == styleMaze
    check parseStyle("scatter") == styleScatter
    expect ValueError:
      discard parseStyle("nope")

  test "deterministic for a fixed seed":
    let region = sampleRegion()
    for style in styles:
      let
        a = generateShapes(style, 12345, region, defaultParams(style))
        b = generateShapes(style, 12345, region, defaultParams(style))
      check a == b
      check a.len > 0

  test "different seeds give different layouts":
    let region = sampleRegion()
    for style in styles:
      let
        a = generateShapes(style, 1, region, defaultParams(style))
        b = generateShapes(style, 2, region, defaultParams(style))
      check a != b

  test "every shape stays inside the placement region":
    let region = sampleRegion()
    for style in styles:
      for seed in 1 .. 20:
        let shapes = generateShapes(style, seed, region, defaultParams(style))
        check shapes.len > 0
        check withinBounds(shapes, region)

  test "spec round-trips the generated obstacle set":
    var base = generateMapAttempt(
      7, MapGenOverrides(size: "standard", windows: -1, pits: 0, pitDensity: -1))
    base.leftObstacles =
      generateShapes(styleCaves, 7, testRegion(base), defaultParams(styleCaves))
    let rt = mapFromSpecJson(mapSpecJson(base))
    check rt.leftObstacles.len == base.leftObstacles.len
    check buildArenaObstacles(rt).len > 0

  test "each style can produce a map the validator accepts":
    for style in styles:
      var passed = 0
      for seed in 1 .. 16:
        var base = generateMapAttempt(
          seed,
          MapGenOverrides(size: "standard", windows: -1, pits: 0, pitDensity: -1))
        base.leftObstacles =
          generateShapes(style, seed xor 0x9E3779B1, testRegion(base),
                         defaultParams(style))
        if validateGeneratedMap(base).len == 0:
          inc passed
      check passed >= 1

suite "polygon obstacles":
  test "pointInPolygon matches a known square":
    let sq = @[MapPoint(x: 100, y: 100), MapPoint(x: 200, y: 100),
               MapPoint(x: 200, y: 200), MapPoint(x: 100, y: 200)]
    check pointInPolygon(150, 150, sq)
    check pointInPolygon(101, 101, sq)
    check not pointInPolygon(50, 150, sq)
    check not pointInPolygon(250, 150, sq)
    check not pointInPolygon(150, 250, sq)

  test "a polygon obstacle builds an exactly mirror-symmetric wall set":
    ## The fairness invariant: integer vertex transforms make a polygon and its
    ## image rasterize to bit-identical mirror masks (no boundary drift).
    var base = generateMapAttempt(5, MapGenOverrides(
      size: "standard", symmetry: "mirror", windows: -1, pits: 0, pitDensity: -1))
    base.leftObstacles = @[ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: 210, y: 150), MapPoint(x: 268, y: 172),
      MapPoint(x: 252, y: 262), MapPoint(x: 188, y: 250),
      MapPoint(x: 172, y: 198)])]
    ##
    ## EVERY pixel, not every 9th. The stride this used to walk is why a real
    ## fairness bug shipped GREEN: `pointInPolygon` counted edges on a strict
    ## straddle, which dropped BOTH edges at any vertex whose neighbours
    ## straddled its row and inverted the even-odd parity across the rest of
    ## that row — 274 asymmetric px in this very fixture, 8,770 in the CAVES
    ## style — and a 9 px stride stepped over all of them. A fairness test that
    ## samples sparsely is worse than no test, because it gets believed.
    ##
    ## Compares the POLYGON RASTERIZATION against its own mirror image, not
    ## `mapWallAt` — `mapProtectedFloorAt` carries a separate, older asymmetry
    ## of its own (522 px on a standard column-endzone board, present on maps
    ## with no polygon in them at all), and folding that in here would blame
    ## this primitive for someone else's bug. Map-wide wall symmetry on real
    ## generated boards is asserted below, where it is exactly 0.
    let
      obstacles = buildArenaObstacles(base)
      left = obstacles[0]
      right = obstacles[1]
    var
      sawWall = false
      asymmetric = 0
    for y in 0 ..< base.height:
      for x in 0 ..< base.width:
        let inside = pointInPolygon(x, y, left.points)
        if inside != pointInPolygon(base.width - 1 - x, y, right.points):
          inc asymmetric
        if inside: sawWall = true
    check asymmetric == 0
    check sawWall

  test "a polygon with vertices alone on their scan row is exactly symmetric":
    ## The shape that used to break. Sort ANY convex quad's corners by y and
    ## the middle two sit alone on their rows, so this is not an exotic input,
    ## it is the general one. Measured 538 asymmetric px before the fix, 0
    ## after.
    var base = generateMapAttempt(5, MapGenOverrides(
      size: "standard", symmetry: "mirror", windows: -1, pits: 0,
      pitDensity: -1))
    base.leftObstacles = @[ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: 180, y: 120), MapPoint(x: 300, y: 190),
      MapPoint(x: 260, y: 330), MapPoint(x: 150, y: 240)])]
    let
      obstacles = buildArenaObstacles(base)
      left = obstacles[0]
      right = obstacles[1]
    var
      asymmetric = 0
      wall = 0
      emptyInteriorRows = 0
    for y in 0 ..< base.height:
      var rowWall = 0
      for x in 0 ..< base.width:
        let inside = pointInPolygon(x, y, left.points)
        if inside:
          inc wall
          inc rowWall
        if inside != pointInPolygon(base.width - 1 - x, y, right.points):
          inc asymmetric
      ## Second symptom, same root cause: a row INSIDE the shape that comes
      ## back empty is a 1 px horizontal hole straight through a barrier — it
      ## leaks line of sight and trips the open-sightline validator.
      if y > 121 and y < 329 and rowWall == 0:
        inc emptyInteriorRows
    check wall > 0
    check asymmetric == 0
    check emptyInteriorRows == 0

  test "a point exactly on a polygon edge is inside, from either side":
    ## The on-edge residue, which the half-open y rule alone does NOT fix: the
    ## parity test flips on crossings strictly to one side of the sample, and
    ## reflection swaps which side, so a sample sitting exactly on an edge
    ## differed between a shape and its mirror (118 px on a quad, 60 on a
    ## 24-gon, even after half-open). Deciding on-boundary explicitly is the
    ## only reflection-invariant answer.
    let tri = @[MapPoint(x: 0, y: 0), MapPoint(x: 100, y: 0),
                MapPoint(x: 0, y: 100)]
    check pointInPolygon(0, 0, tri)        ## a vertex
    check pointInPolygon(50, 0, tri)       ## the horizontal edge
    check pointInPolygon(0, 50, tri)       ## the vertical edge
    check pointInPolygon(50, 50, tri)      ## the diagonal itself
    check not pointInPolygon(51, 50, tri)  ## just outside it

  test "a polygon obstacle round-trips through mapSpec":
    var base = generateMapAttempt(
      5, MapGenOverrides(size: "standard", windows: -1, pits: 0, pitDensity: -1))
    let poly = ArenaShape(kind: shapePolygon, points: @[
      MapPoint(x: 210, y: 150), MapPoint(x: 268, y: 172),
      MapPoint(x: 252, y: 262), MapPoint(x: 188, y: 250)])
    base.leftObstacles = @[poly]
    base.trenches = @[poly]  # trenches are shapes too now
    let rt = mapFromSpecJson(mapSpecJson(base))
    check rt.leftObstacles == @[poly]
    check rt.trenches == @[poly]

suite "generated boards are exactly wall-symmetric":
  test "every real generated map mirrors its walls bit for bit":
    ## The end-to-end form of the `pointInPolygon` fairness fix, at EVERY pixel
    ## on real generator output. Measured 0 asymmetric wall px across these
    ## seeds and both symmetries after the fix.
    ##
    ## KNOWN SEPARATE DEFECT, deliberately not asserted here: the same sweep
    ## finds `mapProtectedFloorAt` asymmetric by 522 px on a standard
    ## column-endzone board and 1012 px on a square-endzone one, on maps
    ## containing no polygons at all. Different function, different root cause,
    ## not fixed by this change — see the commit message.
    for seed in [5, 1000, 1003]:
      for sym in ["mirror", "rot180"]:
        let base = generateMapAttempt(seed, MapGenOverrides(
          size: "standard", symmetry: sym, windows: -1, pits: 0,
          pitDensity: -1))
        let obstacles = buildArenaObstacles(base)
        var asymmetric = 0
        for y in 0 ..< base.height:
          for x in 0 ..< base.width:
            let (mx, my) =
              if sym == "mirror": (base.width - 1 - x, y)
              else: (base.width - 1 - x, base.height - 1 - y)
            if mapWallAt(base, obstacles, x, y) !=
                mapWallAt(base, obstacles, mx, my):
              inc asymmetric
        check asymmetric == 0

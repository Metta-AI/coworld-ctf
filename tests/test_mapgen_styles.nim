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

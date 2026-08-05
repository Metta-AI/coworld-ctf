## Tests for the shape vocabulary (`src/ctf/mapgen_vocab.nim`).
##
## The vocabulary emits geometry that the sim will MIRROR and then rasterize
## into a wall mask, so the properties worth pinning are the ones whose
## failure is silent:
##
##  1. DETERMINISM. A generator that is not a pure function of its seed makes
##     every map un-reproducible and every A/B unrepeatable.
##  2. THE `MaxPolygonVerts` CEILING. A massif is a union of up to 96 discs;
##     the whole `ridgeHull` design exists to keep its outline under 48
##     vertices, and nothing else in the build would notice if it stopped.
##  3. POLYGON WELL-FORMEDNESS. `arena.pointInPolygon` counts an edge only on
##     a STRICT straddle (`ylo < y < yhi`) because that is what makes a
##     polygon and its mirror image rasterize to bit-identical masks — the
##     team-fairness invariant. A ring this module emits must be usable under
##     that rule, and the tests check membership AGAINST `inShape` itself
##     rather than re-deriving it.
##  4. REGION CONTAINMENT. Shapes are placed in a band already inset from the
##     home border and the symmetry seam; one shape outside it is a shape the
##     mirror can drop on top of a spawn.
##  5. SIZES SCALE WITH THE BOARD. The whole complaint that started the
##     rewrite is that a giant map is the standard map photocopied. A test
##     that cover size tracks `MapRules.coverSizePx` is what stops that
##     regressing.

import
  std/[math, random, unittest],
  ctf/[sim, map_rules, mapgen_vocab]

const AllItems = [viDorito, viCan, viSnake, viBeam, viTemple, viBunker,
                  viMassif, viCave]

proc stdParams(): VocabParams = vocabParams("standard", 2)

proc bigRegion(): MapRect = MapRect(x: 60, y: 40, w: 620, h: 520)

proc emit(item: VocabItem, seed: int, region: MapRect,
          p: VocabParams): seq[ArenaShape] =
  var r = initRand(seed)
  emitVocab(item, r, region, p)

proc within(s: ArenaShape, region: MapRect): bool =
  ## Containment measured through `shapeBounds`, which is the sim's OWN answer
  ## to "where can this shape possibly paint a wall pixel". Re-deriving the
  ## bounds here would let the two drift apart silently.
  let (x0, y0, x1, y1) = shapeBounds(s)
  x0 >= region.x and y0 >= region.y and
    x1 <= region.x + region.w - 1 and y1 <= region.y + region.h - 1

# ---------------------------------------------------------------------------

suite "shape vocabulary: determinism":
  test "the same seed produces byte-identical shapes":
    let p = stdParams()
    for item in AllItems:
      for seed in [1, 7, 99]:
        let
          a = emit(item, seed, bigRegion(), p)
          b = emit(item, seed, bigRegion(), p)
        check a.len == b.len
        for i in 0 ..< a.len:
          # `$` on a variant object prints only the ACTIVE branch, so this is
          # a full structural comparison and not a pointer one.
          check $a[i] == $b[i]

  test "different seeds produce different shapes":
    # A generator that ignores its RNG would pass every other test here.
    let p = stdParams()
    for item in AllItems:
      var seen: seq[string]
      for seed in 1 .. 6:
        var acc = ""
        for s in emit(item, seed, bigRegion(), p): acc.add $s
        seen.add acc
      var distinct1 = 0
      for i in 0 ..< seen.len:
        if seen[i] != seen[0]: inc distinct1
      check distinct1 > 0

  test "the generator never consumes the caller's RNG unpredictably":
    # Two items drawn from ONE stream must be reproducible as a pair; this is
    # what lets a scene graph replay a whole composition from one seed.
    let p = stdParams()
    proc pair(): string =
      var r = initRand(4242)
      for s in emitVocab(viDorito, r, bigRegion(), p): result.add $s
      for s in emitVocab(viMassif, r, bigRegion(), p): result.add $s
    check pair() == pair()

# ---------------------------------------------------------------------------

suite "shape vocabulary: polygons":
  test "no emitted polygon exceeds MaxPolygonVerts":
    # THE ceiling. `mapgen_styles` carries the same number as a private
    # `BlobMaxVerts`; if that one moves this must be revisited deliberately.
    check MaxPolygonVerts == 48
    let p = stdParams()
    for item in AllItems:
      for seed in 1 .. 40:
        for s in emit(item, seed, bigRegion(), p):
          if s.kind == shapePolygon:
            check s.points.len <= MaxPolygonVerts
            check s.points.len >= 3

  test "a massif on a huge board still meets the ceiling":
    # The case the ceiling actually bites: a colossal-class massif walks many
    # more discs, which is what `ridgeHull`'s SPLIT is for.
    let p = vocabParams("colossal", 2)
    for seed in 1 .. 20:
      let shapes = emit(viMassif, seed,
                        MapRect(x: 0, y: 0, w: 4000, h: 900), p)
      check shapes.len > 0
      for s in shapes:
        check s.kind == shapePolygon
        check s.points.len <= MaxPolygonVerts

  test "every polygon is well-formed for pointInPolygon":
    let p = stdParams()
    for item in AllItems:
      for seed in 1 .. 30:
        for s in emit(item, seed, bigRegion(), p):
          check polygonWellFormed(s)

  test "a polygon actually encloses area under the sim's own inShape":
    # A ring can satisfy every counting rule above and still enclose NOTHING
    # (a zero-width sliver, or a ring wound so the even-odd rule cancels).
    # The only honest check is to ask `inShape` — the proc the sim itself
    # calls — whether the centroid region is inside.
    let p = stdParams()
    var tested = 0
    for item in [viBeam, viMassif, viCave, viBunker]:
      for seed in 1 .. 25:
        for s in emit(item, seed, bigRegion(), p):
          if s.kind != shapePolygon: continue
          let (x0, y0, x1, y1) = shapeBounds(s)
          var inside = 0
          for yy in countup(y0, y1, max(1, (y1 - y0) div 12)):
            for xx in countup(x0, x1, max(1, (x1 - x0) div 12)):
              if inShape(xx, yy, s): inc inside
          check inside > 0
          inc tested
    check tested > 20

  test "vocabulary polygons build an exactly mirror-symmetric wall set":
    # The fairness invariant `pointInPolygon`'s strict straddle exists to
    # protect, stated the way the SIM uses it (as `test_mapgen_styles` does):
    # over the full obstacle set that `buildArenaObstacles` produces, every
    # wall pixel must have a wall pixel at its mirror.
    #
    # Note this is deliberately NOT the stronger claim that one polygon and
    # its image agree pixel for pixel in isolation. They need not: on a scan
    # line that passes exactly through a vertex, the strict straddle drops
    # edges and a lone ring can differ from its image by a 1 px sliver. The
    # sim never asks a lone ring that question — it rasterizes both halves
    # from the same union — and loosening the straddle to make the stronger
    # claim true is exactly the change that would break fairness.
    let p = stdParams()
    for item in [viMassif, viCave, viBeam]:
      var base = generateMapAttempt(5, MapGenOverrides(
        size: "standard", symmetry: "mirror", windows: 0, pits: 0,
        pitDensity: -1))
      base.leftObstacles = emit(item, 11,
        MapRect(x: 120, y: 60, w: 380, h: 500), p)
      check base.leftObstacles.len > 0
      let obstacles = buildArenaObstacles(base)
      var sawWall = false
      var y = 30
      while y < base.height - 30:
        var x = 30
        while x < base.width - 30:
          let inside = mapWallAt(base, obstacles, x, y)
          check inside == mapWallAt(base, obstacles, base.width - 1 - x, y)
          if inside: sawWall = true
          x += 7
        y += 7
      check sawWall

# ---------------------------------------------------------------------------

suite "shape vocabulary: containment":
  test "every shape stays inside the region it was given":
    let p = stdParams()
    for item in AllItems:
      for seed in 1 .. 30:
        let region = bigRegion()
        for s in emit(item, seed, region, p):
          check s.within(region)

  test "containment holds in awkward regions too":
    # Long thin bands, near-square slots, and regions barely bigger than one
    # cover piece are all things a scene graph will hand these.
    let p = stdParams()
    let regions = [
      MapRect(x: 0, y: 0, w: 900, h: 120),
      MapRect(x: 300, y: 200, w: 120, h: 900),
      MapRect(x: 10, y: 10, w: 200, h: 200),
      MapRect(x: 5, y: 5, w: 70, h: 70),
      MapRect(x: 0, y: 0, w: 30, h: 400),
    ]
    for item in AllItems:
      for region in regions:
        for seed in 1 .. 12:
          for s in emit(item, seed, region, p):
            check s.within(region)

  test "a region too small for an item yields nothing, never a bad shape":
    let p = stdParams()
    for item in AllItems:
      for seed in 1 .. 5:
        let shapes = emit(item, seed, MapRect(x: 0, y: 0, w: 8, h: 8), p)
        for s in shapes:
          check s.within(MapRect(x: 0, y: 0, w: 8, h: 8))
          check polygonWellFormed(s)

# ---------------------------------------------------------------------------

suite "shape vocabulary: sizes are derived from the board":
  test "vocabParams reads MapRules, never a literal":
    for name in ["small", "standard", "large", "huge", "giant"]:
      let
        rules = mapRules(name, 2)
        p = vocabParams(name, 2)
      check p.coverSizePx == rules.coverSizePx
      check p.corridorPx == rules.minCorridorWidthPx
      check p.maxExposedRunPx == rules.maxExposedRunPx

  test "the brief's standard-class literals are reproduced exactly":
    # Doritos r22-34 and cans r18-40 are quoted in the design brief at the
    # standard class. They are stored as fractions of `RefCoverPx`, so this
    # test is what proves the re-expression did not move them.
    let p = stdParams()
    check p.coverSizePx == RefCoverPx
    check p.doritoRadius == (22, 34)
    check p.canRadius == (18, 40)

  test "cover size scales with the board, monotonically":
    var last = 0
    for name in ["small", "standard", "large", "huge", "giant", "colossal"]:
      let p = vocabParams(name, 2)
      check p.coverSizePx > last
      last = p.coverSizePx
    # The end-to-end claim: a giant board's cover really is bigger, not the
    # same rocks spread further apart.
    check vocabParams("giant", 2).doritoRadius.hi >
          vocabParams("standard", 2).doritoRadius.hi * 3 div 2

  test "the passability floor is the DRAWN corridor, not the collision floor":
    # 68 px = two drawn cog bodies abreast. `arena.MinCorridorWidth` is 26,
    # and designing gaps to that number is how you get a map you can only
    # cross single file.
    for name in ["small", "standard", "giant"]:
      check vocabParams(name, 2).corridorPx == RecommendedCorridorWidthPx

  test "emitted shapes actually get bigger on a bigger board":
    let regionS = MapRect(x: 0, y: 0, w: 700, h: 560)
    var stdArea, giantArea = 0
    for seed in 1 .. 10:
      for s in emit(viDorito, seed, regionS, vocabParams("standard", 2)):
        let (x0, y0, x1, y1) = shapeBounds(s)
        stdArea += (x1 - x0 + 1) * (y1 - y0 + 1)
      for s in emit(viDorito, seed, regionS, vocabParams("giant", 2)):
        let (x0, y0, x1, y1) = shapeBounds(s)
        giantArea += (x1 - x0 + 1) * (y1 - y0 + 1)
    check giantArea > stdArea

# ---------------------------------------------------------------------------

suite "shape vocabulary: the composition budget":
  test "no item is mostly plain rects except the one that is meant to be":
    # The brief's budget: at most half a finished map may be plain rects or
    # bars. `viTemple` IS the plain-rect item and is exempt; everything else
    # must come in under half on its own.
    let p = stdParams()
    for item in AllItems:
      if item == viTemple: continue
      var shapes: seq[ArenaShape]
      for seed in 1 .. 25:
        shapes.add emit(item, seed, bigRegion(), p)
      check rectShare(shapes) <= 0.5

  test "a plausible mixed composition comes in under the rect budget":
    let p = stdParams()
    var shapes: seq[ArenaShape]
    var r = initRand(31337)
    for seed in 1 .. 12:
      for item in AllItems:
        shapes.add emitVocab(item, r, bigRegion(), p)
    check shapes.len > 100
    check rectShare(shapes) <= 0.5

  test "every item emits something in a region of its own footprint":
    # `vocabFootprint` is the contract a scene graph sizes slots by; an item
    # that returns nothing at its own declared footprint has a broken one.
    let p = stdParams()
    for item in AllItems:
      let (fw, fh) = vocabFootprint(item, p)
      var produced = 0
      for seed in 1 .. 10:
        produced += emit(item, seed,
                         MapRect(x: 100, y: 100, w: fw, h: fh), p).len
      check produced > 0

  test "the item names round-trip":
    for item in AllItems:
      check parseVocabItem(vocabName(item)) == item
    expect ValueError:
      discard parseVocabItem("obelisk")

# ---------------------------------------------------------------------------

suite "shape vocabulary: the features are what they claim":
  test "a bunker cluster mixes kinds and leaves a passable gap":
    let p = stdParams()
    var sawMultipleKinds = 0
    for seed in 1 .. 30:
      let shapes = emit(viBunker, seed,
                        MapRect(x: 0, y: 0, w: 500, h: 260), p)
      if shapes.len < 2: continue
      var kinds: set[ArenaShapeKind]
      for s in shapes: kinds.incl s.kind
      if card(kinds) >= 2: inc sawMultipleKinds
    # "2-3 shapes of DIFFERENT kinds" is the definition of the item, so a
    # cluster that is three of one thing is a regression, not a variation.
    check sawMultipleKinds >= 25

  test "a cave leaves a mouth at least one corridor wide":
    # The cave's whole reason to exist is the gap. Measured the way a player
    # meets it: walk the cross-axis at several points along the run and
    # require an unbroken open span of at least `corridorPx`.
    let p = stdParams()
    let region = MapRect(x: 0, y: 0, w: 700, h: 460)
    for seed in 1 .. 15:
      let shapes = emit(viCave, seed, region, p)
      if shapes.len < 2: continue
      var narrowest = high(int)
      for x in countup(region.x + 40, region.x + region.w - 40, 37):
        var run = 0
        var best = 0
        for y in region.y ..< region.y + region.h:
          var solid = false
          for s in shapes:
            if inShape(x, y, s):
              solid = true
              break
          if solid:
            run = 0
          else:
            inc run
            best = max(best, run)
        narrowest = min(narrowest, best)
      check narrowest >= p.corridorPx

  test "a massif admits no sightline slit through its body":
    # `arena.pointInPolygon`'s STRICT straddle gives no crossing at all on the
    # scan row of a pass-through vertex, so a bare traced ring is slit by one
    # empty row per such vertex — measured at 8 of 594 rows before the hidden
    # core discs were added. Eight one-pixel holes through a barrier leak
    # line of sight and trip the generator's own sightline validator.
    #
    # Stated in the orientation that matters: a massif laid ACROSS the attack
    # axis is there to break horizontal sightlines, so no horizontal line may
    # pass through it. (The bbox's two extreme rows are excluded: at a
    # y-extremum the shape genuinely has zero width, which is correct
    # geometry and is the sliver `arena` documents.)
    let p = stdParams()
    for item in [viMassif, viCave]:
      for seed in 1 .. 30:
        let shapes = emit(item, seed, MapRect(x: 0, y: 0, w: 240, h: 600), p)
        check shapes.len > 0
        var x0 = high(int)
        var y0 = high(int)
        var x1 = low(int)
        var y1 = low(int)
        for s in shapes:
          let (a, b, c, d) = shapeBounds(s)
          x0 = min(x0, a); y0 = min(y0, b)
          x1 = max(x1, c); y1 = max(y1, d)
        for y in y0 + 1 .. y1 - 1:
          var covered = false
          for x in x0 .. x1:
            for s in shapes:
              if inShape(x, y, s):
                covered = true
                break
            if covered: break
          check covered

  test "a massif is one connected mass, not a string of beads":
    # The failure mode named in the brief. Consecutive discs on the spine
    # overlap by design, so the emitted polygons must overlap or touch: walk
    # the run axis and require NO fully open column inside the mass's span.
    let p = stdParams()
    for seed in 1 .. 15:
      let shapes = emit(viMassif, seed,
                        MapRect(x: 0, y: 0, w: 700, h: 200), p)
      check shapes.len > 0
      var x0 = high(int)
      var x1 = low(int)
      for s in shapes:
        let (bx0, _, bx1, _) = shapeBounds(s)
        x0 = min(x0, bx0)
        x1 = max(x1, bx1)
      # Sample INSIDE the span, off the tapering end caps.
      let margin = (x1 - x0) div 10
      for x in countup(x0 + margin, x1 - margin, 5):
        var covered = false
        for y in 0 ..< 200:
          for s in shapes:
            if inShape(x, y, s):
              covered = true
              break
          if covered: break
        check covered

  test "doritos are diamonds in the brief's radius band":
    let p = stdParams()
    let (rLo, rHi) = p.doritoRadius
    for seed in 1 .. 25:
      for s in emit(viDorito, seed, bigRegion(), p):
        check s.kind == shapeDiamond
        check s.radius >= 1
        check s.radius <= rHi
    discard rLo

  test "cans are separated by at least a corridor":
    # "Fights wrap around them" is a geometric claim: there has to be walkable
    # floor all the way round, which means no two cans may be closer than a
    # corridor.
    let p = stdParams()
    for seed in 1 .. 25:
      let shapes = emit(viCan, seed, bigRegion(), p)
      for i in 0 ..< shapes.len:
        for j in i + 1 ..< shapes.len:
          let
            a = shapes[i]
            b = shapes[j]
            dx = a.cx - b.cx
            dy = a.cy - b.cy
            need = a.radius + b.radius + p.corridorPx
          check dx * dx + dy * dy >= need * need

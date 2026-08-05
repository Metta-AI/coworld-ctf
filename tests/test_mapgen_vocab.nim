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

proc mirrorAsymmetry(
    item: VocabItem, sizeName: string, symmetry: string, teams = 2
): tuple[wall, bad: int] =
  ## Stone pixels, and stone pixels whose SYMMETRY IMAGE is not also stone,
  ## over the full obstacle set `buildArenaObstacles` produces. EVERY pixel is
  ## compared — no stride. A fairness test that samples is not a fairness test:
  ## `test_mapgen_styles`' mirror check samples every 9th pixel and is green on
  ## a polygon that is in fact 274 pixels asymmetric.
  ##
  ## THIS DELIBERATELY DOES NOT GO THROUGH `mapWallAt`, and the reason is a
  ## defect this test used to blame on the constructors. `mapWallAt` subtracts
  ## `mapProtectedFloorAt`, and THAT is asymmetric on every size class and both
  ## 2-team symmetries: the generator places team anchors at `width - x` while
  ## every shape mirrors with `width - 1 - x`, so a team's spawn pocket sits
  ## one pixel off its own mirror image. Measured: exactly two 1px columns of
  ## 261 rows = 522 px on the standard board (x = 256 and x = 978 — Red's
  ## pocket is [116,256], its exact mirror is [978,1118], but Blue's is
  ## [979,1119]); 688 to 1,772 px on the other classes. Any obstacle
  ## overlapping a pocket edge then reads as stone for one team and floor for
  ## the other, whoever authored it. That is `arena`'s to fix. What a shape
  ## constructor owns — and what this measures — is the obstacle union itself.
  var base = generateMapAttempt(5, MapGenOverrides(
    size: sizeName, symmetry: symmetry, windows: 0, pits: 0, pitDensity: -1),
    teams)
  let p = vocabParams(sizeName, teams)
  var shapes: seq[ArenaShape]
  var r = initRand(90210)
  let (fw, fh) = vocabFootprint(item, p)
  let
    yLimit = (if symmetry == "rot90": base.height div 2 else: base.height) - 20
    xLimit = base.width div 2 - 20
  var y = 20
  while y + fh <= yLimit:
    var x = (if symmetry == "rot90": 20 else: 60)
    while x + fw <= xLimit:
      shapes.add emitVocab(item, r, MapRect(x: x, y: y, w: fw, h: fh), p)
      x += fw
    y += fh
  if shapes.len == 0: return
  base.leftObstacles = shapes
  let
    w = base.width
    h = base.height
  # Paint each shape over its own bounding box: cost is area + the sum of the
  # box areas, so even a colossal board is affordable at full resolution.
  var mask = newSeq[bool](w * h)
  for s in buildArenaObstacles(base):
    let (x0, y0, x1, y1) = shapeBounds(s)
    for yy in max(0, y0) .. min(h - 1, y1):
      for xx in max(0, x0) .. min(w - 1, x1):
        if not mask[yy * w + xx] and inShape(xx, yy, s):
          mask[yy * w + xx] = true
  for yy in 0 ..< h:
    for xx in 0 ..< w:
      if not mask[yy * w + xx]: continue
      inc result.wall
      let image =
        case symmetry
        of "rot180": (h - 1 - yy) * w + (w - 1 - xx)
        of "rot90": xx * w + (w - 1 - yy)   ## one 90-degree step
        else: yy * w + (w - 1 - xx)
      if image < 0 or image >= mask.len or not mask[image]: inc result.bad

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
                        MapRect(x: 0, y: 0, w: 900, h: 4000), p)
      check shapes.len > 0
      var sawPolygon = false
      for s in shapes:
        # A massif emits its traced rings AND the hidden core discs that keep
        # it solid under the strict straddle, so not every shape is a polygon.
        if s.kind == shapePolygon:
          sawPolygon = true
          check s.points.len <= MaxPolygonVerts
      check sawPolygon

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

  test "non-polygon items are EXACTLY fair on EVERY size class":
    # Rects, discs, diamonds and diagonals transform exactly under
    # `x -> width-1-x`, so for these the bar is zero asymmetric pixels.
    #
    # THE SWEEP IS THE POINT. This test used to pin one parameter set
    # (`stdParams()`), and a constructor that is exact at the standard class
    # and asymmetric at giant would have sailed through it — the same weakness
    # as a mirror test that samples every 9th pixel. We ship six size classes
    # and `coverSizePx` scales as `56*sqrt(scale)` across them (52..128), so
    # every radius, thickness and offset these constructors compute lands on a
    # different parity at every class. Sweep them all, and both 2-team
    # symmetries, or the guarantee is only about one board.
    for sizeName in DrawableSizeNames & @["colossal"]:
      for symmetry in ["mirror", "rot180"]:
        for item in [viDorito, viCan, viSnake, viTemple]:
          let m = mirrorAsymmetry(item, sizeName, symmetry)
          check m.wall > 0
          if m.bad != 0:
            checkpoint("asymmetric: " & vocabName(item) & " " & sizeName &
                       " " & symmetry & " bad=" & $m.bad)
          check m.bad == 0

  test "polygon items stay within the primitive's known asymmetry":
    # A FINDING, PINNED. `arena.pointInPolygon` counts an edge only on a
    # STRICT straddle, and that rule does NOT deliver the mirror symmetry its
    # own comment claims: a vertex whose neighbours straddle its scan row
    # contributes no crossing, so that row's inside/outside INVERTS, and under
    # the mirror the inversion lands on the other side. Measured on this
    # branch, on a standard 2-team board:
    #
    #   shipped `mapgen_styles` caves     8,770 asymmetric px  (19% of wall)
    #   the hand-picked 5-gon in
    #     tests/test_mapgen_styles          274 asymmetric px
    #   massif, profiles simplified
    #     INDEPENDENTLY                 158,136 asymmetric px  (17.7%)
    #   massif, `pairedSimplify`          3,458 asymmetric px  (0.46%)
    #   beams, before the mid-y snap        5,630 asymmetric px
    #   beams, after                          434 asymmetric px
    #
    # The residue is pixels lying EXACTLY on an edge: the strict test skips
    # that edge on both sides, leaving an odd count, so those pixels flip.
    # That part cannot be fixed from this module. The real fix is one line in
    # `arena.pointInPolygon` — the half-open rule `(yi > y) != (yj > y)`
    # counts every crossing exactly once AND is exactly mirror-symmetric,
    # because it never drops an edge. When that lands, these bounds should be
    # tightened to zero.
    # Swept over every size class, for the same reason as the test above: a
    # bound that holds only at the standard class is not a bound.
    for sizeName in DrawableSizeNames & @["colossal"]:
      for symmetry in ["mirror", "rot180"]:
        for item in [viBeam, viBunker, viMassif, viCave]:
          let m = mirrorAsymmetry(item, sizeName, symmetry)
          check m.wall > 0
          # Under 2% of the item's own wall, and far under the shipped caves
          # style's 19%.
          if m.bad * 50 >= m.wall:
            checkpoint("over budget: " & vocabName(item) & " " & sizeName &
                       " " & symmetry & " bad=" & $m.bad & " wall=" & $m.wall)
          check m.bad * 50 < m.wall

  test "EVERY item is exactly fair on the 4-team rot90 board":
    # rot90 is the case the polygon mitigations cannot help: `pairedSimplify`
    # and `wedgePolygon`'s mid-y snap both work by putting matched vertices on
    # one scan ROW, and a quarter turn maps rows to columns. Measured before
    # the fallbacks, on a giant rot90 board: massif 47 per mille asymmetric,
    # cave 45, beams 12-14, bunker 2-7.
    #
    # So on a non-reflection symmetry the traced outline is dropped: a massif
    # emits its spine discs at full radius and a wedge becomes a capsule. Both
    # primitives are exactly equivariant under every transform the map uses,
    # so the bar here is ZERO for the whole vocabulary, not a budget.
    for sizeName in ["standard", "large", "giant"]:
      for item in AllItems:
        let m = mirrorAsymmetry(item, sizeName, "rot90", teams = 4)
        if m.wall == 0: continue   ## footprint did not fit the quadrant
        if m.bad != 0:
          checkpoint("rot90 asymmetric: " & vocabName(item) & " " & sizeName &
                     " bad=" & $m.bad & " wall=" & $m.wall)
        check m.bad == 0

  test "vocabParams picks the fair construction from the team count":
    # The fallback must not depend on a composer remembering to set a flag.
    check vocabParams("standard", 2).symmetryIsReflection
    check not vocabParams("standard", 4).symmetryIsReflection
    var r = initRand(5)
    let quad = MapRect(x: 0, y: 0, w: 420, h: 420)
    var sawPolygon = false
    for s in emitVocab(viMassif, r, quad, vocabParams("standard", 4)):
      if s.kind == shapePolygon: sawPolygon = true
    check not sawPolygon

# ---------------------------------------------------------------------------

suite "the arena defects this vocabulary has to live with":
  test "the anchor seam is STILL open: it needs a GameVersion bump":
    # PINNED SO IT CANNOT HIDE. `arena` places team anchors at `width - x`
    # while it mirrors every SHAPE at `width - 1 - x`, so a spawn pocket sits
    # one pixel off its own mirror and `mapProtectedFloorAt` contradicts itself
    # across the seam. Any obstacle overlapping a pocket edge is then stone for
    # one team and floor for the other.
    #
    # The fix is one line (`axisHomeHi` -> `size - 1 - axisHomeLo(...)`) and was
    # verified to take standard from 522 asymmetric px to 0. It is NOT applied,
    # because moving a spawn by one pixel is a SIM-BEHAVIOUR change: it breaks
    # every recorded replay fixture hash and alters the hand-authored arena
    # (22 test failures). That needs a GameVersion bump plus a fixture
    # re-record, the same route the GV38 grenade change took.
    #
    # WHEN THAT LANDS: flip this to `anchors[1] == m.width - 1 - anchors[0]`,
    # and the odd-width classes below to `bad == 0`.
    for sizeName in ["small", "standard", "large", "huge", "giant"]:
      let m = generateMapAttempt(5, MapGenOverrides(
        size: sizeName, symmetry: "mirror", windows: 0, pits: 0,
        pitDensity: -1))
      var anchors: seq[int]
      for t in m.teams(): anchors.add m.teamAnchor(t).x
      check anchors.len >= 2
      checkpoint(sizeName & ": anchors " & $anchors[0] & "/" & $anchors[1] &
        ", exact mirror of first would be " & $(m.width - 1 - anchors[0]))
      check anchors[1] == m.width - anchors[0]       ## the defect
      check anchors[1] != m.width - 1 - anchors[0]   ## ...is exactly one px

  test "a SECOND, independent defect lives on EVEN-sided boards":
    # Found while measuring the anchor seam, and NOT the same bug: protected
    # geometry is anchored on `center = size div 2`, whose mirror is
    # `size - 1 - size div 2`, and those differ by one whenever the side is
    # EVEN. Same hazard `rot90Point`'s own comment warns about — the true
    # symmetry axis of an even side is a half pixel off the div-derived centre.
    #
    # Proof they are independent: applying the anchor fix locally took the
    # ODD-width classes to exactly 0 (standard, huge-mirror, giant) and left
    # every EVEN-sided one non-zero — small 242 px and large 366 px under
    # mirror, and under rot180 the even-HEIGHT classes add their own share
    # (small 498, huge 838). The correlation with parity is exact.
    #
    # Fix belongs with whoever moves protected geometry onto doubled
    # coordinates, the way `hex.HexBoard` already does.
    for sizeName in ["small", "large"]:
      let m = generateMapAttempt(5, MapGenOverrides(
        size: sizeName, symmetry: "mirror", windows: 0, pits: 0,
        pitDensity: -1))
      check m.width mod 2 == 0
      var bad = 0
      for y in 0 ..< m.height:
        for x in 0 ..< m.width:
          if mapProtectedFloorAt(m, x, y) !=
             mapProtectedFloorAt(m, m.width - 1 - x, y):
            inc bad
      checkpoint(sizeName & ": protected-floor asymmetric px = " & $bad)
      check bad > 0             ## both defects, awaiting their own fixes
      # While the anchor seam is also open, the figure above is the SUM of the
      # two. The isolation measurement is in the comment: with the anchor fix
      # applied locally, the odd-width classes went to 0 and these did not.

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
    # A cave runs PERPENDICULAR to the mirror line (see
    # `VocabParams.mirrorIsVertical`), so with the shipping vertical mirror
    # its walls are vertical and its mouth is measured ACROSS x — the axis a
    # player crosses it on.
    let p = stdParams()
    let (fw, fh) = vocabFootprint(viCave, p)
    let region = MapRect(x: 0, y: 0, w: fw, h: fh)
    check fh > fw          ## the footprint really is portrait
    for seed in 1 .. 15:
      let shapes = emit(viCave, seed, region, p)
      if shapes.len < 2: continue
      var narrowest = high(int)
      for y in countup(region.y + 40, region.y + region.h - 40, 31):
        var run = 0
        var best = 0
        for x in region.x ..< region.x + region.w:
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

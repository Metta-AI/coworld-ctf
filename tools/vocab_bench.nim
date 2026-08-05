## vocab_bench — measure and LOOK AT one shape-vocabulary item at a time.
##
## The question this answers is not "does it compile" but "how much ENCLOSURE
## does this feature buy per unit of wall coverage". `map_metrics.interiorFrac`
## (open floor with >= 6 of 8 directions blocked within 120 px) is the
## scatter-vs-architecture discriminator: the hand-authored arena measures
## 0.342, the current 20-seed generated pool medians 0.118. Coverage alone can
## be bought by dumping rocks; enclosure cannot.
##
## Each item is tiled across the map's own seed region on a grid of its own
## `vocabFootprint` (long items get full-width BANDS instead of slots), the
## sim mirrors it, and `evaluateMap` scores the finished map. So every number
## printed is measured on a real, symmetric, carved CtfMap — not on a shape
## list in isolation.
##
##   vocab_bench table                    # every item, ranked
##   vocab_bench render --item massif -o /tmp/massif.png
##   vocab_bench table --size giant       # sizes must scale with the board
##
## PURITY: like `tools/map_render.nim`, this never installs a map and never
## reads the process-wide arena globals.
##
## ---------------------------------------------------------------------------
## THE RANKING, AND WHY IT MUST BE READ NEXT TO THE RENDER
## ---------------------------------------------------------------------------
##
## Measured 2026-08-05, 2-team standard board, seeds 1/2/3. `ENCL/COV` is
## marginal enclosure per unit wall coverage; `diag` is the P95 diagonal open
## run, which `map_metrics` does not measure at all (its scan is horizontal and
## vertical only). Controls: arena 2.05 encl/cov, 0.342 interior, 376 diag;
## empty board 903 diag.
##
##   at its OWN footprint             at MATCHED coverage (~167 permille)
##   snake    2.51   diag 426         cave     2.61   diag 297
##   massif   1.26   diag 341         bunker   2.58   diag 371
##   dorito   1.08   diag 671         snake    2.52   diag 357
##   beam     0.93   diag 635         beam     1.38   diag 486
##   temple   0.91   diag 535         dorito   1.12   diag 585
##   cave     0.83   diag 546         can      1.05   diag 524
##   bunker   0.78   diag 763         temple   0.52   diag 665
##   can      0.50   diag 881         massif   0.31   diag 562
##
## TWO OF THE TOP THREE MATCHED-COVERAGE SCORES ARE METRIC ARTIFACTS, and that
## is the most useful thing this tool found. Look at the renders:
##
##  * `cave` at 55% pitch scores best in the whole table and renders as a
##    BARCODE — eight thin parallel vertical stripes. Parallel walls create
##    "enclosed" floor by definition, so `interiorFrac` loves them; a player
##    would just be threading identical lanes.
##  * `bunker` at 34% pitch scores second and renders as CONFETTI — a regular
##    lattice of ~130 rice grains. Dense fine obstacles block everything,
##    including diagonals (371, tighter than the arena), and look like nothing.
##  * `snake` is the only top-three entry whose render is a map.
##
## So `interiorFrac` per unit cover rewards FINE-GRAINED and PARALLEL layouts,
## and both look terrible. Use the ranking to choose which feature buys
## architecture cheaply — not to choose a density, and never without looking.

import
  std/[algorithm, math, os, random, strformat, strutils],
  pixie,
  ../src/ctf/[sim, map_metrics, mapgen_vocab],
  map_render

type CliError = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(CliError, msg)

const BenchSalt = 0x51ED2A17

# ---------------------------------------------------------------------------
# Placement
# ---------------------------------------------------------------------------

proc placementRegion(base: CtfMap): MapRect =
  ## Byte-identical to `mapkit.placementRegion`: the seed band, inset off the
  ## home border and short of the symmetry seam.
  let
    sr = mapSeedRegion(base)
    vMargin = 2
    hMargin = 40
    seam = 20
  case base.symmetry
  of symMirror, symRot180:
    MapRect(x: sr.x + hMargin, y: sr.y + vMargin,
            w: max(1, sr.w - hMargin - seam), h: max(1, sr.h - 2 * vMargin))
  of symRot90:
    MapRect(x: sr.x + hMargin, y: sr.y + vMargin,
            w: max(1, sr.w - hMargin - seam), h: max(1, sr.h - vMargin - seam))

proc slotsFor(item: VocabItem, p: VocabParams, region: MapRect,
              pitchPct = 100): seq[MapRect] =
  ## The regions one item is handed to fill the placement band. A composer
  ## does exactly this, only with intent about WHERE; the bench is the
  ## uniform-fill control so items are compared at equal opportunity.
  ##
  ## `pitchPct` stretches the footprint, which is how the bench MATCHES WALL
  ## COVERAGE across items — see `matchedPitch`. Without it a massif tiles at
  ## 470 permille cover and a can at 68, and their `interiorFrac` values are
  ## then answers to two different questions.
  var (fw, fh) = vocabFootprint(item, p)
  fw = max(8, fw * pitchPct div 100)
  fh = max(8, fh * pitchPct div 100)
  if isLongItem(item):
    # A snake / massif / cave is a RUN, so it gets a BAND, never a slot —
    # slicing one into slots measures a different feature than the one named.
    #
    # ORIENTATION IS DELIBERATE. Every long item takes its run axis from the
    # region's longer side, so the band's shape decides what the feature is:
    #   * a massif or a cave is a BARRIER, so it gets vertical columns and
    #     runs ACROSS the attack axis, where it breaks the horizontal
    #     sightlines a 2-team board is made of;
    #   * a snake is a FLANK route, so it gets horizontal rows and runs ALONG
    #     the attack axis, hugging the top or bottom edge.
    # Getting this backwards is not a small error: a massif laid in a
    # landscape band is a lane divider, and it measures like one.
    if item == viSnake:
      let rows = max(1, region.h div fh)
      let rh = region.h div rows
      for i in 0 ..< rows:
        result.add MapRect(x: region.x, y: region.y + i * rh, w: region.w, h: rh)
    else:
      # `vocabFootprint` already returns a massif/cave footprint oriented for
      # the mirror axis (portrait, on every board that ships), so the band is
      # a COLUMN and `fw` is its width.
      let cols = max(1, region.w div fw)
      let cw = region.w div cols
      for i in 0 ..< cols:
        result.add MapRect(x: region.x + i * cw, y: region.y, w: cw, h: region.h)
  else:
    let
      cols = max(1, region.w div fw)
      rows = max(1, region.h div fh)
      cw = region.w div cols
      ch = region.h div rows
    for j in 0 ..< rows:
      for i in 0 ..< cols:
        result.add MapRect(x: region.x + i * cw, y: region.y + j * ch,
                           w: cw, h: ch)

proc fillWith(
    item: VocabItem, seed: int, base: CtfMap, p: VocabParams, pitchPct = 100
): seq[ArenaShape] =
  var r = initRand(seed xor BenchSalt)
  for slot in slotsFor(item, p, placementRegion(base), pitchPct):
    result.add emitVocab(item, r, slot, p)

const
  TargetCoverPermille = 167
    ## The hand-authored arena's own wall coverage. Every item is tiled at
    ## whatever pitch brings it nearest to this, so the `interiorFrac` column
    ## answers ONE question: at the control's wall budget, how much enclosure
    ## does this feature buy?
  PitchLadder = [34, 40, 47, 55, 65, 78, 92, 110, 130, 155, 185, 220, 265,
                 315, 380, 460]

proc coverAt(item: VocabItem, seed: int, base: CtfMap, p: VocabParams,
             pitchPct: int): int =
  var probe = base
  probe.leftObstacles = fillWith(item, seed, base, p, pitchPct)
  mapDiagnostics(probe, {}).coverPermille

proc matchedPitch(item: VocabItem, seed: int, base: CtfMap,
                  p: VocabParams): int =
  ## The ladder rung whose wall coverage lands closest to the control's. A
  ## ladder scan, not a bisection: coverage is only ROUGHLY monotone in pitch
  ## (shapes clamp against slot edges), and a bisection on a non-monotone
  ## function silently returns a local answer.
  result = 100
  var bestErr = high(int)
  for pitch in PitchLadder:
    let err = abs(coverAt(item, seed, base, p, pitch) - TargetCoverPermille)
    if err < bestErr:
      bestErr = err
      result = pitch

proc fillMixed(seed: int, base: CtfMap, p: VocabParams): seq[ArenaShape] =
  ## A crude composition: every slot draws a random item. NOT a scene graph —
  ## it has no intent whatsoever — but it is the honest "what does the
  ## vocabulary look like with no composer at all" reference, and it is the
  ## floor any real composer must beat.
  var r = initRand(seed xor BenchSalt xor 0x2C1B3F)
  let region = placementRegion(base)
  let items = [viDorito, viCan, viBeam, viTemple, viBunker, viMassif]
  for slot in slotsFor(viBunker, p, region):
    result.add emitVocab(items[rand(r, items.high)], r, slot, p)
  # One snake down each long flank, and a cave through the middle third.
  let flank = MapRect(x: region.x, y: region.y, w: region.w,
                      h: max(1, region.h div 5))
  result.add snake(r, flank, p)
  result.add snake(r, MapRect(x: region.x, y: region.y + region.h - flank.h,
                              w: region.w, h: flank.h), p)
  result.add cave(r, MapRect(x: region.x, y: region.y + region.h * 2 div 5,
                             w: region.w, h: max(1, region.h div 4)), p)

# ---------------------------------------------------------------------------
# Measurement
# ---------------------------------------------------------------------------

type Row = object
  name: string
  shapes: int
  polys: int
  maxVerts: int
  rectShare: float
  coverFrac: float
  interiorFrac: float
  coveredFrac: float
  exposedFrac: float
  openP95: int
  diagP95: int
  score: float
  pitch: int
  valid: bool
  reason: string

proc diagonalOpenP95(gameMap: CtfMap): int =
  ## P95 of the longest unbroken DIAGONAL open run, in pixels.
  ##
  ## `map_metrics.openRunP95Px` scans horizontals and verticals ONLY, so a
  ## 900 px diagonal sightline is invisible to it — and a vocabulary built to
  ## please that metric could sail straight through the hole. Anything here
  ## that scores well on enclosure has to be checked against this too, with
  ## the hand-authored arena as the control.
  let
    obstacles = buildArenaObstacles(gameMap)
    (maxWall, _) = rasterizeWallMasks(gameMap, obstacles)
    w = gameMap.width
    h = gameMap.height
  var runs: seq[int]
  for dirIdx in 0 .. 1:
    let dy = 1
    let dx = if dirIdx == 0: 1 else: -1
    # Seed every border pixel so every diagonal line is walked exactly once.
    var starts: seq[(int, int)]
    for x in 0 ..< w: starts.add (x, 0)
    for y in 0 ..< h:
      starts.add (if dx == 1: (0, y) else: (w - 1, y))
    for (sx, sy) in starts:
      var
        x = sx
        y = sy
        run = 0
      while x >= 0 and x < w and y >= 0 and y < h:
        if maxWall[y * w + x]:
          if run > 0: runs.add run
          run = 0
        else:
          inc run
        x += dx
        y += dy
      if run > 0: runs.add run
  if runs.len == 0: return 0
  runs.sort()
  # Diagonal steps are sqrt(2) px apart.
  int(float(runs[int(float(runs.len - 1) * 0.95)]) * 1.41421356)

proc shapeStats(shapes: seq[ArenaShape]): tuple[polys, maxVerts: int] =
  for s in shapes:
    if s.kind == shapePolygon:
      inc result.polys
      result.maxVerts = max(result.maxVerts, s.points.len)

proc measure(name: string, gameMap: CtfMap): Row =
  let m = evaluateMap(gameMap, name)
  let (polys, maxVerts) = shapeStats(gameMap.leftObstacles)
  Row(name: name,
      shapes: gameMap.leftObstacles.len,
      polys: polys, maxVerts: maxVerts,
      rectShare: rectShare(gameMap.leftObstacles),
      coverFrac: float(m.coverPermille) / 1000.0,
      interiorFrac: m.interiorFrac,
      coveredFrac: m.coveredFrac,
      exposedFrac: m.exposedFrac,
      openP95: m.openRunP95Px,
      diagP95: diagonalOpenP95(gameMap),
      score: m.staticScore(),
      valid: m.valid, reason: m.reason)

proc baseMap(sizeName: string, seed: int): CtfMap =
  var overrides = MapGenOverrides(
    size: sizeName, symmetry: "mirror", endzone: "",
    windows: 0, pits: 0, pitDensity: -1)
  generateMapAttempt(seed, overrides, 2)

proc benchOne(item: VocabItem, sizeName: string, seed: int,
              matchCover = true): (Row, CtfMap) =
  var gameMap = baseMap(sizeName, seed)
  let p = vocabParams(sizeName, 2)
  let pitch =
    if matchCover: matchedPitch(item, seed, gameMap, p) else: 100
  gameMap.leftObstacles = fillWith(item, seed, gameMap, p, pitch)
  var row = measure(vocabName(item), gameMap)
  row.pitch = pitch
  (row, gameMap)

proc benchMixed(sizeName: string, seed: int): (Row, CtfMap) =
  var gameMap = baseMap(sizeName, seed)
  let p = vocabParams(sizeName, 2)
  gameMap.leftObstacles = fillMixed(seed, gameMap, p)
  (measure("MIXED", gameMap), gameMap)

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

var emptyCover = 0.0
var emptyInterior = 0.0
  ## The bare board with NO obstacles at all. The 10 px perimeter wall is
  ## itself ~46 permille of cover and buys real enclosure along the edges, so
  ## an item measured at low coverage gets that for free and its raw
  ## interior/cover ratio is flattered. Every ratio printed is MARGINAL over
  ## this baseline.

proc marginal(r: Row): float =
  let
    dc = r.coverFrac - emptyCover
    di = r.interiorFrac - emptyInterior
  if dc > 0.001: di / dc else: 0.0

proc header(): string =
  &"""{"item":<10} {"pitch":>6} {"shp":>4} {"ply":>4} {"vmax":>4} """ &
  &"""{"rect%":>6} {"cover":>6} {"interior":>9} {"covrd":>6} {"expsd":>6} """ &
  &"""{"openP95":>8} {"diagP95":>8} {"score":>6} {"ENCL/COV":>9}"""

proc line(r: Row): string =
  &"{r.name:<10} {r.pitch:>5}% {r.shapes:>4} {r.polys:>4} {r.maxVerts:>4} " &
  &"{r.rectShare * 100.0:>5.0f}% {r.coverFrac:>6.3f} {r.interiorFrac:>9.3f} " &
  &"{r.coveredFrac:>6.3f} {r.exposedFrac:>6.3f} {r.openP95:>8} {r.diagP95:>8} " &
  &"{r.score:>6.3f} {marginal(r):>9.2f}" &
  (if r.valid: "" else: "  INVALID: " & r.reason)

proc meanRows(sizeName: string, seeds: seq[int], matchCover: bool): seq[Row] =
  for item in VocabItem:
    var acc: Row
    acc.name = vocabName(item)
    for s in seeds:
      let (r, _) = benchOne(item, sizeName, s, matchCover)
      acc.shapes += r.shapes
      acc.polys += r.polys
      acc.maxVerts = max(acc.maxVerts, r.maxVerts)
      acc.rectShare += r.rectShare
      acc.coverFrac += r.coverFrac
      acc.interiorFrac += r.interiorFrac
      acc.coveredFrac += r.coveredFrac
      acc.exposedFrac += r.exposedFrac
      acc.openP95 += r.openP95
      acc.diagP95 += r.diagP95
      acc.score += r.score
      acc.pitch += r.pitch
      if not r.valid and acc.reason.len == 0: acc.reason = r.reason
    let n = float(seeds.len)
    acc.shapes = int(float(acc.shapes) / n)
    acc.polys = int(float(acc.polys) / n)
    acc.pitch = int(float(acc.pitch) / n)
    acc.rectShare /= n
    acc.coverFrac /= n
    acc.interiorFrac /= n
    acc.coveredFrac /= n
    acc.exposedFrac /= n
    acc.openP95 = int(float(acc.openP95) / n)
    acc.diagP95 = int(float(acc.diagP95) / n)
    acc.score /= n
    acc.valid = acc.reason.len == 0
    result.add acc
  result.sort(proc (a, b: Row): int = cmp(marginal(b), marginal(a)))

proc cmdTable(sizeName: string, seeds: seq[int]) =
  echo &"# board: 2-team {sizeName};  seeds: {seeds.join(\",\")}"
  let p = vocabParams(sizeName, 2)
  echo &"# coverSizePx={p.coverSizePx} corridorPx={p.corridorPx} " &
       &"maxExposedRunPx={p.maxExposedRunPx}"
  echo ""
  # Controls first: the hand-authored arena, then whatever the current
  # generator produces at this seed with no vocabulary at all.
  block:
    var g = baseMap(sizeName, seeds[0])
    g.leftObstacles = @[]
    let e = measure("empty", g)
    emptyCover = e.coverFrac
    emptyInterior = e.interiorFrac
  echo header()
  block:
    var g = baseMap(sizeName, seeds[0])
    g.leftObstacles = @[]
    echo line(measure("empty", g))
  echo line(measure("arena", loadCtfMapMetadata("arena")))
  block:
    var g = baseMap(sizeName, seeds[0])
    echo line(measure("gen-bare", g))
  echo ""
  echo "## A. NATURAL DENSITY — each item tiled at its own vocabFootprint."
  echo "##    This is the density the item is DESIGNED for; `cover` is the"
  echo "##    wall budget it naturally carries."
  for r in meanRows(sizeName, seeds, matchCover = false): echo line(r)
  echo ""
  echo "## B. MATCHED COVERAGE — pitch stretched until wall coverage lands"
  echo "##    near the arena control's 167 permille. Read `interiorFrac` here"
  echo "##    directly against the control's 0.342. CAVEAT: stretching the"
  echo "##    pitch of a long item reduces it to one or two instances per"
  echo "##    half-map, which is a degenerate layout, not a fair density."
  echo ""
  var rows = meanRows(sizeName, seeds, matchCover = true)
  var mixedAcc: Row
  mixedAcc.name = "MIXED"
  for s in seeds:
    let (r, _) = benchMixed(sizeName, s)
    mixedAcc.shapes += r.shapes
    mixedAcc.polys += r.polys
    mixedAcc.maxVerts = max(mixedAcc.maxVerts, r.maxVerts)
    mixedAcc.rectShare += r.rectShare
    mixedAcc.coverFrac += r.coverFrac
    mixedAcc.interiorFrac += r.interiorFrac
    mixedAcc.coveredFrac += r.coveredFrac
    mixedAcc.exposedFrac += r.exposedFrac
    mixedAcc.openP95 += r.openP95
    mixedAcc.diagP95 += r.diagP95
    mixedAcc.score += r.score
    if not r.valid and mixedAcc.reason.len == 0: mixedAcc.reason = r.reason
  block:
    let n = float(seeds.len)
    mixedAcc.shapes = int(float(mixedAcc.shapes) / n)
    mixedAcc.polys = int(float(mixedAcc.polys) / n)
    mixedAcc.rectShare /= n
    mixedAcc.coverFrac /= n
    mixedAcc.interiorFrac /= n
    mixedAcc.coveredFrac /= n
    mixedAcc.exposedFrac /= n
    mixedAcc.openP95 = int(float(mixedAcc.openP95) / n)
    mixedAcc.diagP95 = int(float(mixedAcc.diagP95) / n)
    mixedAcc.score /= n
    mixedAcc.valid = mixedAcc.reason.len == 0

  for r in rows: echo line(r)
  echo ""
  echo line(mixedAcc)

proc cmdRender(item: string, sizeName: string, seed: int, outPath: string,
               maxDim: int, matchCover: bool, overlay = false) =
  var gameMap: CtfMap
  var row: Row
  if item == "mixed":
    (row, gameMap) = benchMixed(sizeName, seed)
  else:
    (row, gameMap) = benchOne(parseVocabItem(item), sizeName, seed, matchCover)
  let options = MapRenderOptions(
    maxDimension: maxDim,
    overlays: (if overlay: {overlayProtected, overlaySeedRegion} else: {}),
    pickupKinds: {})
  renderMap(gameMap, options).image.writeFile(outPath)
  stderr.writeLine(line(row))
  stderr.writeLine(&"rendered {item} -> {outPath}")

proc cmdSpec(item: string, sizeName: string, seed: int, outPath: string) =
  var gameMap: CtfMap
  var row: Row
  if item == "mixed":
    (row, gameMap) = benchMixed(sizeName, seed)
  else:
    (row, gameMap) = benchOne(parseVocabItem(item), sizeName, seed, false)
  writeFile(outPath, mapSpecJson(gameMap))
  stderr.writeLine(line(row))

const usage = """
vocab_bench — measure and look at the shape vocabulary

  vocab_bench table  [--size standard] [--seeds 1,2,3]
  vocab_bench render --item <name>|mixed [--size ...] [--seed N] [-o out.png]
                     [--max N] [--match]
  vocab_bench spec   --item <name>|mixed [--size ...] [--seed N] -o spec.json

items: dorito can snake beam temple bunker massif cave mixed
"""

when isMainModule:
  let argv = commandLineParams()
  if argv.len == 0 or argv[0] in ["-h", "--help", "help"]:
    echo usage
    quit(0)
  var
    size = "standard"
    seed = 1
    seedList = @[1, 2, 3]
    item = ""
    outPath = ""
    maxDim = 0
    matchCover = false
    overlay = false
  var i = 1
  while i < argv.len:
    case argv[i]
    of "--size": inc i; size = argv[i]
    of "--seed": inc i; seed = argv[i].parseInt
    of "--seeds":
      inc i
      seedList = @[]
      for s in argv[i].split(','): seedList.add s.strip.parseInt
    of "--item": inc i; item = argv[i]
    of "--max": inc i; maxDim = argv[i].parseInt
    of "--match": matchCover = true
    of "--overlay": overlay = true
    of "-o", "--out": inc i; outPath = argv[i]
    else: fail("unknown argument: " & argv[i])
    inc i
  try:
    case argv[0]
    of "table": cmdTable(size, seedList)
    of "render":
      if item.len == 0: fail("render needs --item")
      cmdRender(item, size, seed,
                (if outPath.len > 0: outPath else: "/tmp/vocab_" & item & ".png"),
                maxDim, matchCover, overlay)
    of "spec":
      if item.len == 0: fail("spec needs --item")
      if outPath.len == 0: fail("spec needs -o")
      cmdSpec(item, size, seed, outPath)
    else:
      stderr.writeLine("unknown command: " & argv[0])
      echo usage
      quit(2)
  except CliError as e:
    stderr.writeLine("vocab_bench: " & e.msg)
    quit(2)
  except ValueError as e:
    stderr.writeLine("vocab_bench: " & e.msg)
    quit(2)

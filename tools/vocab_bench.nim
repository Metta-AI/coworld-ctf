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
    # Full-width bands: a snake / massif / cave is a RUN, and slicing it into
    # slots would measure a different feature than the one being tested.
    let rows = max(1, region.h div fh)
    let rh = region.h div rows
    for i in 0 ..< rows:
      result.add MapRect(x: region.x, y: region.y + i * rh, w: region.w, h: rh)
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
  score: float
  pitch: int
  valid: bool
  reason: string

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

proc header(): string =
  &"""{"item":<10} {"pitch":>6} {"shp":>4} {"ply":>4} {"vmax":>4} """ &
  &"""{"rect%":>6} {"cover":>6} {"interior":>9} {"covrd":>6} {"expsd":>6} """ &
  &"""{"openP95":>8} {"score":>6} {"int/cov":>8}"""

proc line(r: Row): string =
  let ratio = if r.coverFrac > 0.0: r.interiorFrac / r.coverFrac else: 0.0
  &"{r.name:<10} {r.pitch:>5}% {r.shapes:>4} {r.polys:>4} {r.maxVerts:>4} " &
  &"{r.rectShare * 100.0:>5.0f}% {r.coverFrac:>6.3f} {r.interiorFrac:>9.3f} " &
  &"{r.coveredFrac:>6.3f} {r.exposedFrac:>6.3f} {r.openP95:>8} " &
  &"{r.score:>6.3f} {ratio:>8.2f}" &
  (if r.valid: "" else: "  INVALID: " & r.reason)

proc cmdTable(sizeName: string, seeds: seq[int]) =
  echo &"# board: 2-team {sizeName};  seeds: {seeds.join(\",\")}"
  let p = vocabParams(sizeName, 2)
  echo &"# coverSizePx={p.coverSizePx} corridorPx={p.corridorPx} " &
       &"maxExposedRunPx={p.maxExposedRunPx}"
  echo ""
  # Controls first: the hand-authored arena, then whatever the current
  # generator produces at this seed with no vocabulary at all.
  echo header()
  var ctrl = measure("arena", loadCtfMapMetadata("arena"))
  echo line(ctrl)
  block:
    var g = baseMap(sizeName, seeds[0])
    var row = measure("gen-bare", g)
    echo line(row)
  echo ""
  var rows: seq[Row]
  for item in VocabItem:
    var acc: Row
    acc.name = vocabName(item)
    for s in seeds:
      let (r, _) = benchOne(item, sizeName, s)
      acc.shapes += r.shapes
      acc.polys += r.polys
      acc.maxVerts = max(acc.maxVerts, r.maxVerts)
      acc.rectShare += r.rectShare
      acc.coverFrac += r.coverFrac
      acc.interiorFrac += r.interiorFrac
      acc.coveredFrac += r.coveredFrac
      acc.exposedFrac += r.exposedFrac
      acc.openP95 += r.openP95
      acc.score += r.score
      acc.pitch += r.pitch
      if not r.valid and acc.reason.len == 0:
        acc.reason = r.reason
    let n = float(seeds.len)
    acc.pitch = int(float(acc.pitch) / n)
    acc.shapes = int(float(acc.shapes) / n)
    acc.polys = int(float(acc.polys) / n)
    acc.rectShare /= n
    acc.coverFrac /= n
    acc.interiorFrac /= n
    acc.coveredFrac /= n
    acc.exposedFrac /= n
    acc.openP95 = int(float(acc.openP95) / n)
    acc.score /= n
    acc.valid = acc.reason.len == 0
    rows.add acc
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
    mixedAcc.score /= n
    mixedAcc.valid = mixedAcc.reason.len == 0

  # Ranked by ENCLOSURE PER UNIT WALL COVERAGE. Coverage is matched to the
  # control first, so this is very nearly a ranking on `interiorFrac` alone;
  # the ratio is still the ranking key because a couple of items cannot reach
  # the target coverage at any pitch and would otherwise be flattered.
  rows.sort(proc (a, b: Row): int =
    let
      ra = if a.coverFrac > 0: a.interiorFrac / a.coverFrac else: 0.0
      rb = if b.coverFrac > 0: b.interiorFrac / b.coverFrac else: 0.0
    cmp(rb, ra))
  for r in rows: echo line(r)
  echo ""
  echo line(mixedAcc)

proc cmdRender(item: string, sizeName: string, seed: int, outPath: string,
               maxDim: int) =
  var gameMap: CtfMap
  var row: Row
  if item == "mixed":
    (row, gameMap) = benchMixed(sizeName, seed)
  else:
    (row, gameMap) = benchOne(parseVocabItem(item), sizeName, seed)
  let options = MapRenderOptions(
    maxDimension: maxDim, overlays: {}, pickupKinds: {})
  renderMap(gameMap, options).image.writeFile(outPath)
  stderr.writeLine(line(row))
  stderr.writeLine(&"rendered {item} -> {outPath}")

proc cmdSpec(item: string, sizeName: string, seed: int, outPath: string) =
  var gameMap: CtfMap
  var row: Row
  if item == "mixed":
    (row, gameMap) = benchMixed(sizeName, seed)
  else:
    (row, gameMap) = benchOne(parseVocabItem(item), sizeName, seed)
  writeFile(outPath, mapSpecJson(gameMap))
  stderr.writeLine(line(row))

const usage = """
vocab_bench — measure and look at the shape vocabulary

  vocab_bench table  [--size standard] [--seeds 1,2,3]
  vocab_bench render --item <name>|mixed [--size ...] [--seed N] [-o out.png]
                     [--max N]
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
                maxDim)
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

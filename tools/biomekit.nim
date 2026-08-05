## biomekit — drive the Cogs-vs-Clips biome terrain emitters and SCORE them.
##
## A peer to `tools/mapkit.nim` for the biome family in
## `src/ctf/mapgen_biomes.nim`. It never reimplements geometry: it builds a
## base map with the sim's own `generateMapAttempt`, replaces the seed obstacle
## set with a biome's, and then hands the result to the shared `map_render`
## rasterizer and `map_metrics.evaluateMap` — the same scorer the curated pool
## is graded with, so a biome's number is directly comparable to the arena
## control (staticScore 1.000, interiorFrac 0.342).
##
##   biomekit render  --biome desert --seed 7 -o /tmp/desert.png
##   biomekit score   --biome desert --seeds 8
##   biomekit table   --seeds 8          # every biome, one row each
##
## `--mask` adds the AsteroidMask edge ragging on top of the biome.

import
  std/[os, random, strformat, strutils],
  pixie,
  ../src/ctf/[map_metrics, mapgen_biomes, sim],
  map_render

const BiomeSalt = 0x5BF03635  ## decorrelate the biome stream from the map seed.

proc placementRegion(base: CtfMap): MapRect =
  ## The same band `mapkit` uses: inset enough to clear the perimeter wall,
  ## keep off the home border, and stop short of the symmetry seam. Being
  ## short of the seam is also what makes it a legal fundamental domain.
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

var overrideParams: seq[(string, string)]

proc applyOverrides(p: var BiomeParams) =
  for (key, raw) in overrideParams:
    template asInt: int = raw.parseInt
    template asFloat: float = raw.parseFloat
    case key
    of "cell": p.cell = asInt
    of "fillProb": p.fillProb = asFloat
    of "steps": p.steps = asInt
    of "seedProb": p.seedProb = asFloat
    of "growthProb": p.growthProb = asFloat
    of "clumpiness": p.clumpiness = asInt
    of "neighborThreshold": p.neighborThreshold = asInt
    of "dunePeriodPx": p.dunePeriodPx = asInt
    of "ridgeWidthPx": p.ridgeWidthPx = asInt
    of "duneAngle": p.duneAngle = asFloat
    of "noiseProb": p.noiseProb = asFloat
    of "pitchPx": p.pitchPx = asInt
    of "roadWidthPx": p.roadWidthPx = asInt
    of "minBlockFrac": p.minBlockFrac = asFloat
    of "placeProb": p.placeProb = asFloat
    of "clusterPeriod": p.clusterPeriod = asInt
    of "clusterMaxRadius": p.clusterMaxRadius = asInt
    of "clusterProb": p.clusterProb = asFloat
    of "ditherProb": p.ditherProb = asFloat
    of "borderIsRock": p.borderIsRock = raw == "true"
    of "minOpenCells": p.minOpenCells = asInt
    else: quit("unknown --set key: " & key, 2)

proc sightlineAnchors(r: var Rand, region: MapRect, period: int): seq[ArenaShape] =
  ## MEASUREMENT INSTRUMENT, NOT TERRAIN. `validateGeneratedMap` rejects any
  ## map with an unbroken horizontal sightline, and three of the five biomes
  ## produce one as a FULL-REGION fill (city's road lattice by construction;
  ## forest and plains because they are sparse scatters). Breaking that is the
  ## structure pass's job, and the structure pass is not this module's.
  ##
  ## But `staticScore` returns 0 for an invalid map, so without something here
  ## every biome would score 0.000 and the terrain itself would be
  ## unmeasurable. This is the minimum that opens the gate: one staggered
  ## mid-field bar per row band, the same device `mapgen_styles.verticalAnchors`
  ## uses. It lives in the TOOL so nothing ships it by accident.
  let
    loX = region.x + region.w * 50 div 100
    hiX = region.x + region.w * 82 div 100
    thick = 18
  var gy = region.y
  while gy <= region.y + region.h:
    let
      x = clamp(loX + rand(r, max(1, hiX - loX)), region.x,
                region.x + region.w - thick)
      y = max(region.y, gy - 12)
      hh = min(period + 24, region.y + region.h - y)
    result.add ArenaShape(kind: shapeRect,
                          rect: MapRect(x: x, y: y, w: thick, h: hh))
    gy += period

var
  zoneCount = 0     ## --zones N: tile the band with an NxN zone lattice
  zoneFill = 0.4    ## --zonefill F: fraction of those zones that get terrain

proc zoneRects(r: var Rand, region: MapRect, n: int, fill: float): seq[MapRect] =
  ## The band cut into an n x n lattice of zone rects, a `fill` fraction of
  ## them kept. This is what the SOURCE actually does — its BiomeArena places
  ## biomes as ZONES capped at `max_biome_zone_fraction` = 0.27 of the map, not
  ## as full-map fills — and it is the composition a scene graph will perform.
  ## Reproducing it here is how we test whether a biome that cannot survive
  ## dilution to a legal full-board cover budget survives as a zone at its own
  ## native density.
  let
    zw = region.w div n
    zh = region.h div n
  for gy in 0 ..< n:
    for gx in 0 ..< n:
      if rand(r, 1.0) >= fill: continue
      result.add MapRect(x: region.x + gx * zw, y: region.y + gy * zh,
                         w: zw, h: zh)

proc biomeMap(
    style: BiomeStyle, seed: int, size: string, mask, anchor: bool
): CtfMap =
  var overrides = MapGenOverrides(
    size: size, symmetry: "mirror", endzone: "",
    windows: -1, pits: 0, pitDensity: -1)
  result = generateMapAttempt(seed, overrides, 2)
  let
    region = placementRegion(result)
    board = MapRect(x: 0, y: 0, w: result.width, h: result.height)
    domain = fundamentalDomain(board, region, result.symmetry)
  var p = defaultBiomeParams(style)
  applyOverrides(p)
  var r = initRand(seed xor BiomeSalt xor 0x1234)
  if zoneCount > 0:
    # The base map arrives WITH the current generator's own obstacle set.
    # Forgetting to clear it made every zone measurement a reading of the
    # existing generator plus a handful of biome shapes.
    result.leftObstacles = @[]
    for i, zone in zoneRects(r, region, zoneCount, zoneFill):
      result.leftObstacles.add generateBiomeShapes(
        style, seed xor BiomeSalt xor (i * 0x9E3779B1), zone, p, domain)
  else:
    result.leftObstacles =
      generateBiomeShapes(style, seed xor BiomeSalt, region, p, domain)
  if mask:
    result.leftObstacles.add edgeMaskShapes(r, region, p)
  if anchor:
    result.leftObstacles.add sightlineAnchors(r, region, 120)

proc bandScore(m: MapMetrics): float =
  ## `staticScore` with the VALIDATOR GATE BYPASSED: the same weighted mean of
  ## the same bands, but not short-circuited to 0 when `validateGeneratedMap`
  ## refuses the map.
  ##
  ## This is the number that measures TERRAIN. The hard gates a biome trips as
  ## a full-region fill — an unbroken cross-field row — are the structure
  ## pass's to fix, and scoring them as 0 would only measure how good the
  ## stand-in anchor above is. `valid=` in the same row keeps the gate visible.
  var total, weight = 0.0
  for r in m.scoreBands(DefaultBands):
    total += r.sub * r.band.weight
    weight += r.band.weight
  if weight <= 0.0: 0.0 else: total / weight

proc row(style: BiomeStyle, seeds: int, size: string,
         mask, anchor: bool): string =
  var
    score = 0.0
    band = 0.0
    interior = 0.0
    cover = 0.0
    openRun = 0.0
    shapes = 0
    full = 0
    valid = 0
    firstReason = ""
  for i in 0 ..< seeds:
    let
      gameMap = biomeMap(style, 1000 + i, size, mask, anchor)
      m = evaluateMap(gameMap, $style)
    score += staticScore(m)
    band += bandScore(m)
    interior += m.interiorFrac
    cover += float(m.coverPermille)
    openRun += float(m.openRunP95Px)
    shapes += gameMap.leftObstacles.len
    full += buildArenaObstacles(gameMap).len
    if m.valid: inc valid
    elif firstReason.len == 0: firstReason = m.reason
  let n = float(seeds)
  &"{$style:<8} band={band / n:5.3f} score={score / n:5.3f} " &
    &"interior={interior / n:5.3f} " &
    &"cover={int(cover / n):4d}pm openP95={int(openRun / n):5d}px " &
    &"seed_shapes={shapes div seeds:4d} full={full div seeds:4d} " &
    &"valid={valid}/{seeds} {firstReason}"

when isMainModule:
  let argv = commandLineParams()
  if argv.len == 0:
    echo "biomekit render|score|table [--biome X] [--seed N] [--seeds N] " &
      "[--size X] [--mask] [--anchor] [--set k=v] [-o out.png]"
    quit(0)
  var
    cmd = argv[0]
    biome = "desert"
    seed = 7
    seeds = 8
    size = "standard"
    mask = false
    anchor = false
    outPath = "/tmp/biome.png"
    i = 1
  while i < argv.len:
    case argv[i]
    of "--biome": inc i; biome = argv[i]
    of "--seed": inc i; seed = argv[i].parseInt
    of "--seeds": inc i; seeds = argv[i].parseInt
    of "--size": inc i; size = argv[i]
    of "--zones": inc i; zoneCount = argv[i].parseInt
    of "--zonefill": inc i; zoneFill = argv[i].parseFloat
    of "--mask": mask = true
    of "--anchor": anchor = true
    of "--set":
      inc i
      let kv = argv[i].split('=', 1)
      if kv.len != 2: quit("--set expects k=v", 2)
      overrideParams.add (kv[0], kv[1])
    of "-o", "--out": inc i; outPath = argv[i]
    else: quit("unknown flag: " & argv[i], 2)
    inc i
  case cmd
  of "render":
    let gameMap = biomeMap(parseBiomeStyle(biome), seed, size, mask, anchor)
    let options = MapRenderOptions(
      maxDimension: 0, overlays: {overlayProtected},
      pickupKinds: {pickupMedKitActive})
    renderMap(gameMap, options).image.writeFile(outPath)
    let m = evaluateMap(gameMap, biome)
    echo &"{biome} seed={seed} shapes={gameMap.leftObstacles.len} " &
      &"band={bandScore(m):5.3f} score={staticScore(m):5.3f} " &
      &"interior={m.interiorFrac:5.3f} " &
      &"cover={m.coverPermille}pm valid={m.valid} {m.reason}"
    echo "wrote " & outPath
  of "score":
    echo row(parseBiomeStyle(biome), seeds, size, mask, anchor)
  of "table":
    for style in BiomeStyle:
      echo row(style, seeds, size, mask, anchor)
  else:
    quit("unknown command: " & cmd, 2)

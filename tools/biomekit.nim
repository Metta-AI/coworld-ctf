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

proc biomeMap(
    style: BiomeStyle, seed: int, size: string, mask: bool
): CtfMap =
  var overrides = MapGenOverrides(
    size: size, symmetry: "mirror", endzone: "",
    windows: -1, pits: 0, pitDensity: -1)
  result = generateMapAttempt(seed, overrides, 2)
  let
    region = placementRegion(result)
    board = MapRect(x: 0, y: 0, w: result.width, h: result.height)
    domain = fundamentalDomain(board, region, result.symmetry)
    p = defaultBiomeParams(style)
  result.leftObstacles =
    generateBiomeShapes(style, seed xor BiomeSalt, region, p, domain)
  if mask:
    var r = initRand(seed xor BiomeSalt xor 0x1234)
    result.leftObstacles.add edgeMaskShapes(r, region, p)

proc row(style: BiomeStyle, seeds: int, size: string, mask: bool): string =
  var
    score = 0.0
    interior = 0.0
    cover = 0.0
    openRun = 0.0
    shapes = 0
    full = 0
    valid = 0
    firstReason = ""
  for i in 0 ..< seeds:
    let
      gameMap = biomeMap(style, 1000 + i, size, mask)
      m = evaluateMap(gameMap, $style)
    score += staticScore(m)
    interior += m.interiorFrac
    cover += float(m.coverPermille)
    openRun += float(m.openRunP95Px)
    shapes += gameMap.leftObstacles.len
    full += buildArenaObstacles(gameMap).len
    if m.valid: inc valid
    elif firstReason.len == 0: firstReason = m.reason
  let n = float(seeds)
  &"{$style:<8} score={score / n:5.3f} interior={interior / n:5.3f} " &
    &"cover={int(cover / n):4d}pm openP95={int(openRun / n):5d}px " &
    &"seed_shapes={shapes div seeds:4d} full={full div seeds:4d} " &
    &"valid={valid}/{seeds} {firstReason}"

when isMainModule:
  let argv = commandLineParams()
  if argv.len == 0:
    echo "biomekit render|score|table [--biome X] [--seed N] [--seeds N] " &
      "[--size X] [--mask] [-o out.png]"
    quit(0)
  var
    cmd = argv[0]
    biome = "desert"
    seed = 7
    seeds = 8
    size = "standard"
    mask = false
    outPath = "/tmp/biome.png"
    i = 1
  while i < argv.len:
    case argv[i]
    of "--biome": inc i; biome = argv[i]
    of "--seed": inc i; seed = argv[i].parseInt
    of "--seeds": inc i; seeds = argv[i].parseInt
    of "--size": inc i; size = argv[i]
    of "--mask": mask = true
    of "-o", "--out": inc i; outPath = argv[i]
    else: quit("unknown flag: " & argv[i], 2)
    inc i
  case cmd
  of "render":
    let gameMap = biomeMap(parseBiomeStyle(biome), seed, size, mask)
    let options = MapRenderOptions(
      maxDimension: 0, overlays: {overlayProtected},
      pickupKinds: {pickupMedKitActive})
    renderMap(gameMap, options).image.writeFile(outPath)
    let m = evaluateMap(gameMap, biome)
    echo &"{biome} seed={seed} shapes={gameMap.leftObstacles.len} " &
      &"score={staticScore(m):5.3f} interior={m.interiorFrac:5.3f} " &
      &"cover={m.coverPermille}pm valid={m.valid} {m.reason}"
    echo "wrote " & outPath
  of "score":
    echo row(parseBiomeStyle(biome), seeds, size, mask)
  of "table":
    for style in BiomeStyle:
      echo row(style, seeds, size, mask)
  else:
    quit("unknown command: " & cmd, 2)

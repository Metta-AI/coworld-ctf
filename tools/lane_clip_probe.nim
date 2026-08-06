## lane_clip_probe — what does clearLanes DO to a biome's fill, shape by shape?
##
## `lane_openrow_probe` reports the map-level cover permille, which cannot tell
## "the biome emitted nothing" apart from "the biome emitted plenty and the
## lane clip ate it". This prints both sides of that: the fill as emitted, and
## the fill as it survives the lane network.
##
##   nim c -d:release -r tools/lane_clip_probe.nim --cover=city 1 2 3

import std/[os, random, strformat, strutils], pixie
import ../src/ctf/[sim, map_lanes, map_rules, mapgen_biomes, mapgen_styles]

var coverStyle = "city"
var pngDir = ""

func areaOf(s: ArenaShape): int =
  case s.kind
  of shapeRect: s.rect.w * s.rect.h
  of shapeDisc: (s.radius * s.radius * 314) div 100
  of shapeDiamond: 2 * s.radius * s.radius
  of shapeDiagonal:
    let
      dx = abs(s.x1 - s.x0)
      dy = abs(s.y1 - s.y0)
    (max(dx, dy) + 1) * s.thickness
  of shapePolygon:
    var a = 0
    for i in 0 ..< s.points.len:
      let
        p = s.points[i]
        q = s.points[(i + 1) mod s.points.len]
      a += p.x * q.y - q.x * p.y
    abs(a) div 2

proc describe(s: ArenaShape): string =
  case s.kind
  of shapeRect: &"rect {s.rect.x},{s.rect.y} {s.rect.w}x{s.rect.h}"
  of shapeDisc: &"disc {s.cx},{s.cy} r={s.radius}"
  of shapeDiamond: &"diamond {s.cx},{s.cy} r={s.radius}"
  of shapeDiagonal: &"diag {s.x0},{s.y0}->{s.x1},{s.y1} t={s.thickness}"
  of shapePolygon: &"poly {s.points.len}v"

proc probe(seed: int, verbose: bool) =
  var gameMap = loadCtfMapMetadata("arena")
  let
    rules = mapRules("standard", 2)
    base = gameMap.flagHome(Red)
    seamX = gameMap.width div 2
    region = MapRect(x: BorderPx, y: BorderPx,
      w: seamX - BorderPx, h: gameMap.height - 2 * BorderPx)
    coverRegion = MapRect(x: base.x + gameMap.spawnClearW + 30, y: BorderPx + 20,
      w: seamX - (base.x + gameMap.spawnClearW + 30) - 10,
      h: gameMap.height - 2 * BorderPx - 40)
    style = parseBiomeStyle(coverStyle)
    board = MapRect(x: 0, y: 0, w: gameMap.width, h: gameMap.height)
    domain = fundamentalDomain(board, coverRegion, gameMap.symmetry)
    cover = generateBiomeShapes(style, seed, coverRegion,
      defaultBiomeParams(style), domain)
  var rng = initRand(seed)
  let plan = planLanes(rng, region, base, seamX, rules)
  let kept = clearLanes(cover, plan)

  var inArea, outArea = 0
  for s in cover: inArea += areaOf(s)
  for s in kept: outArea += areaOf(s)
  echo &"--- seed {seed} {coverStyle}: coverRegion {coverRegion.x},{coverRegion.y} " &
    &"{coverRegion.w}x{coverRegion.h}  emitted={cover.len} shapes " &
    &"area={inArea}  kept={kept.len} area={outArea} " &
    &"({(if inArea == 0: 0 else: outArea * 100 div inArea)}% of emitted)"
  if verbose:
    for lane in plan.lanes:
      var pts = ""
      for p in lane.path: pts &= &"({p.x},{p.y})"
      echo &"    LANE {lane.role} w={lane.widthPx} {pts}"
    for s in cover:
      echo &"    IN  {describe(s):<34} area={areaOf(s):<7} " &
        &"intrudes={plan.intrudesOnLane(s)}"
    for s in kept:
      echo &"    OUT {describe(s):<34} area={areaOf(s)}"

proc render(seed: int) =
  ## The picture a human has to judge: the carved half-field with this biome
  ## as its fill, mirrored into a whole board exactly as the sim rasterizes it.
  ## Plain stone-on-floor, no lane overlay — a map that only reads as blocks
  ## and streets once you draw the lanes on top of it does not read as blocks
  ## and streets.
  var gameMap = loadCtfMapMetadata("arena")
  let
    rules = mapRules("standard", 2)
    base = gameMap.flagHome(Red)
    seamX = gameMap.width div 2
    region = MapRect(x: BorderPx, y: BorderPx,
      w: seamX - BorderPx, h: gameMap.height - 2 * BorderPx)
    coverRegion = MapRect(x: base.x + gameMap.spawnClearW + 30, y: BorderPx + 20,
      w: seamX - (base.x + gameMap.spawnClearW + 30) - 10,
      h: gameMap.height - 2 * BorderPx - 40)
    style = parseBiomeStyle(coverStyle)
    board = MapRect(x: 0, y: 0, w: gameMap.width, h: gameMap.height)
    domain = fundamentalDomain(board, coverRegion, gameMap.symmetry)
    cover = generateBiomeShapes(style, seed, coverRegion,
      defaultBiomeParams(style), domain)
  var rng = initRand(seed)
  gameMap.leftObstacles = carveLanes(rng, region, base, seamX, rules, cover).shapes
  gameMap.name = "carved"

  let obstacles = buildArenaObstacles(gameMap)
  var img = newImage(gameMap.width, gameMap.height)
  let
    floorC = rgba(232, 220, 200, 255)
    stoneC = rgba(58, 49, 40, 255)
  for y in 0 ..< gameMap.height:
    for x in 0 ..< gameMap.width:
      var solid = false
      for s in obstacles:
        if inShape(x, y, s):
          solid = true
          break
      img.unsafe[x, y] = (if solid: stoneC else: floorC)
  let path = &"{pngDir}/{coverStyle}-seed{seed}.png"
  img.writeFile(path)
  echo &"    wrote {path}"

when isMainModule:
  var seeds: seq[int]
  var verbose = false
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--cover="): coverStyle = a["--cover=".len .. ^1]
    elif a.startsWith("--png="): pngDir = a["--png=".len .. ^1]
    elif a == "-v": verbose = true
    else: seeds.add parseInt(a)
  if seeds.len == 0: seeds = @[1, 2, 3]
  for s in seeds:
    probe(s, verbose)
    if pngDir.len > 0: render(s)

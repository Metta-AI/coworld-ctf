## lane_openrow_probe — why does a carved lane map still have an open row?
##
## `plugOpenRows` is an interval cover: it marks a row blocked as soon as some
## shape's row span crosses it, then plugs whatever is left. The standing
## diagnosis (task 76332cf1) was that `shapeRowSpan` over-claims for "some
## shape kind". This probe tests that against the alternative the validator's
## own code suggests — that the shape IS there and the mask drops it anyway,
## because `rasterizeWallMasks` carves protected floor out of both masks
## unconditionally (arena.nim, the `mapProtectedFloorAt` branch).
##
## For every row the validator reports open, it classifies each x in the
## sightline window:
##   covered  — some obstacle's `inShape` is true AND minWall agrees
##   carved   — some obstacle's `inShape` is true but minWall is FALSE
##   empty    — no obstacle there at all
##
## A row that is all `empty` means the cover genuinely missed it (the standing
## diagnosis). A row containing `carved` pixels means the cover placed
## something and protected floor deleted it, which no shape-span fix can
## reach.
##
##   nim c -d:release -r tools/lane_openrow_probe.nim [seeds...]

import std/[os, random, strformat, strutils]
import ../src/ctf/[sim, map_lanes, map_rules, mapgen_biomes, mapgen_styles]

var coverStyle = "scatter"
  ## "scatter" reproduces the original blocker report; a biome name feeds the
  ## organic fill layer in as the lane network's cover instead, which is the
  ## composition the rewrite brief actually specifies (skeleton then fill).

proc carvedMap(seed: int, withCover = true): CtfMap =
  ## Same construction as `tools/lane_dbg.nim`, which is what the blocker was
  ## reported from: the hand-authored arena with its left obstacles replaced
  ## by a carved lane network.
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
  var rng = initRand(seed)
  ## `withCover = false` isolates the STRUCTURE's own cover. The scatter fed
  ## in here is synthetic and carries no budget of its own, so a cover-permille
  ## verdict on the full map cannot tell "the lanes are too thick" apart from
  ## "the probe asked for too much scatter".
  let cover =
    if not withCover: @[]
    elif coverStyle == "scatter":
      generateShapes(styleScatter, seed, coverRegion, defaultParams(styleScatter))
    else:
      ## The fill layer, emitted INSIDE the fundamental domain so its dither —
      ## which is symmetry-destroying by construction — lifts to an exactly
      ## fair board. Organic look, exact fairness: the lift is what enforces
      ## fairness, so any irregularity inside the domain is free.
      let
        style = parseBiomeStyle(coverStyle)
        board = MapRect(x: 0, y: 0, w: gameMap.width, h: gameMap.height)
        domain = fundamentalDomain(board, coverRegion, gameMap.symmetry)
      generateBiomeShapes(style, seed, coverRegion,
        defaultBiomeParams(style), domain)
  gameMap.leftObstacles = carveLanes(rng, region, base, seamX, rules, cover).shapes
  gameMap.name = "carved"
  gameMap

proc planOf(seed: int): LanePlan =
  ## The same plan `carvedMap` built, so an open row can be attributed to the
  ## lane that owns it.
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
  var rng = initRand(seed)
  let cover = generateShapes(styleScatter, seed, coverRegion,
    defaultParams(styleScatter))
  carveLanes(rng, region, base, seamX, rules, cover).plan

proc probe(seed: int) =
  let
    gameMap = carvedMap(seed)
    diag = mapDiagnostics(gameMap, {diagnosticWallMasks})
    obstacles = buildArenaObstacles(gameMap)
    plan = planOf(seed)
    w = gameMap.width
    ax = gameMap.sightlineLoX
    bx = gameMap.sightlineHiX

  echo &"    plan: corridorMin={plan.corridorMinPx} sep={plan.sepThickPx} " &
    &"laneStartX={plan.laneStartX} seamX={plan.seamX} lanes={plan.lanes.len}"
  for lane in plan.lanes:
    ## The vertical EXCURSION of the centreline is the quantity that decides
    ## whether a lane can contain an unbroken row: a lane whose centreline
    ## wanders less than its own width has rows that clear it end to end.
    var loY, hiY = lane.laneY(plan.laneStartX)
    var x = plan.laneStartX
    while x <= plan.seamX:
      let cy = lane.laneY(x)
      loY = min(loY, cy); hiY = max(hiY, cy)
      x += 4
    echo &"      {lane.role} width={lane.widthPx:<4} " &
      &"centreline y {loY}..{hiY} excursion={hiY - loY:<4} " &
      &"spare={lane.widthPx - 22 - plan.corridorMinPx}"

  let bare = mapDiagnostics(carvedMap(seed, withCover = false),
    {diagnosticWallMasks})
  echo &"--- seed {seed}: {gameMap.width}x{gameMap.height} " &
    &"valid={diag.reason.len == 0} openRows={diag.openSightlineRows.len} " &
    &"cover={diag.coverPermille} structureOnly={bare.coverPermille} " &
    &"(max {CoverPermilleMax}) window x={ax}..{bx}"
  if diag.reason.len > 0:
    echo &"    reason: {diag.reason}"

  for y in diag.openSightlineRows:
    var carved, empty = 0
    var firstCarvedX = -1
    for x in ax .. bx:
      var inAny = false
      for shape in obstacles:
        if inShape(x, y, shape):
          inAny = true
          break
      if inAny:
        ## inShape says stone, the mask says floor: something deleted it.
        inc carved
        if firstCarvedX < 0: firstCarvedX = x
      else:
        inc empty
    let verdict =
      if carved > 0: "CARVED (protected floor ate the cover)"
      else: "EMPTY (the cover genuinely missed this row)"
    echo &"    y={y:<5} carved={carved:<5} empty={empty:<5} {verdict}"
    if firstCarvedX >= 0:
      echo &"           first carved x={firstCarvedX}, " &
        &"protectedFloor={mapProtectedFloorAt(gameMap, firstCarvedX, y)}"

when isMainModule:
  var seeds: seq[int]
  for i in 1 .. paramCount():
    let a = paramStr(i)
    if a.startsWith("--cover="): coverStyle = a["--cover=".len .. ^1]
    else: seeds.add parseInt(a)
  if seeds.len == 0: seeds = @[1, 2, 3]
  echo &"### cover layer: {coverStyle}"
  for s in seeds:
    probe(s)

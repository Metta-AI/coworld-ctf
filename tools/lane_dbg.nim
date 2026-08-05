## Scratch probe: render a map's wall mask with the pinch audit's findings
## drawn on top, so a verdict can be LOOKED at instead of argued about.
##
## Floor is shaded by the local WIDTH the rule actually reads: green at or
## above the corridor floor, amber in the chokepoint band, red below it.
import std/[os, strformat, strutils]
import pixie
import std/random
import ../src/ctf/[sim, map_lanes, map_rules, mapgen_styles]

proc carvedMap(seed: int): CtfMap =
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
  gameMap.leftObstacles = carveLanes(rng, region, base, seamX, rules, cover).shapes
  gameMap.name = "carved"
  gameMap

proc render(name: string, outPath: string, cropX, cropY, cropW, cropH: int,
            report: bool) =
  let gameMap =
    if name.startsWith("carved:"): carvedMap(parseInt(name[7 .. ^1]))
    else: loadCtfMapMetadata(name)
  let diag = mapDiagnostics(gameMap, {diagnosticWallMasks})
  let
    w = gameMap.width
    h = gameMap.height
  var homes: seq[MapPoint]
  for t in gameMap.teams(): homes.add gameMap.flagHome(t)
  let
    clear = clearancePx(diag.maxWall, w, h)
    audit = auditCorridorPinches(diag.maxWall, w, h, homes)
  if report:
    echo &"{name}: routeWidth={audit.routeWidthPx} runs={audit.runs.len} " &
         &"gates={audit.gates.len} chokes={audit.chokepoints.len} ok={audit.ok}"
    for r in audit.runs:
      echo &"   pass{r.pass} ({r.x},{r.y}) w={r.minWidthPx} arc={r.arcLenPx} " &
           &"exposed={r.exposedPx} allowed={r.allowedPx} mand={r.mandatory}"

  let img = newImage(cropW, cropH)
  for y in 0 ..< cropH:
    for x in 0 ..< cropW:
      let
        mx = cropX + x
        my = cropY + y
      if mx < 0 or my < 0 or mx >= w or my >= h:
        img.unsafe[x, y] = rgba(0, 0, 0, 255)
        continue
      let i = my * w + mx
      if diag.maxWall[i]:
        img.unsafe[x, y] = rgba(60, 45, 32, 255)
      else:
        let wide = 2 * int(clear[i])
        if wide >= RecommendedCorridorWidthPx:
          img.unsafe[x, y] = rgba(150, 205, 150, 255)
        elif wide >= ChokeWidthMinPx:
          img.unsafe[x, y] = rgba(235, 200, 120, 255)
        else:
          img.unsafe[x, y] = rgba(230, 130, 120, 255)
  for r in audit.runs:
    let
      px = r.x - cropX
      py = r.y - cropY
    for dy in -9 .. 9:
      for dx in -9 .. 9:
        let x = px + dx
        let y = py + dy
        if x < 0 or y < 0 or x >= cropW or y >= cropH: continue
        if abs(dx) <= 1 or abs(dy) <= 1:
          img.unsafe[x, y] = rgba(30, 60, 220, 255)
  img.writeFile(outPath)
  echo "wrote ", outPath

when isMainModule:
  let name = if paramCount() >= 1: paramStr(1) else: "arena"
  createDir("/tmp/lanes")
  let gameMap =
    if name.startsWith("carved:"): carvedMap(parseInt(name[7 .. ^1]))
    else: loadCtfMapMetadata(name)
  let tag = name.replace(":", "_")
  render(name, "/tmp/lanes/" & tag & "_full.png", 0, 0,
    gameMap.width, gameMap.height, true)

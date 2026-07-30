## Renders every curated-pool map to an annotated PNG plus a JSON manifest
## for the pool-review page: floor/stone/glass like dump_map_mask, with the
## protected zones tinted, pedestal positions dotted, and the med-kit
## candidate/active points marked.
## Usage: nim c -r tools/render_map_pool.nim outDir
## Demo/curation tooling; not part of the server.
import std/[json, os, strformat], pixie, ../src/ctf/sim, ../src/ctf/map_pool

const
  FloorColor = rgba(214, 189, 150, 255)
  ZoneColor = rgba(226, 205, 172, 255)   ## protected floor (never carved).
  StoneColor = rgba(64, 48, 34, 255)
  GlassColor = rgba(80, 220, 255, 255)
  RedColor = rgba(210, 60, 50, 255)
  BlueColor = rgba(60, 110, 220, 255)
  KitColor = rgba(200, 30, 30, 255)
  KitIdleColor = rgba(120, 100, 80, 255)
  TrenchColor = rgba(120, 96, 62, 255)   ## dug pits (config-gated): walkable, dark.
  TrenchRimColor = rgba(88, 66, 38, 255)

proc fillDisc(img: Image, cx, cy, r: int, color: ColorRGBA) =
  for y in max(0, cy - r) .. min(img.height - 1, cy + r):
    for x in max(0, cx - r) .. min(img.width - 1, cx + r):
      if (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r:
        img.unsafe[x, y] = color

proc drawCross(img: Image, cx, cy, r: int, color: ColorRGBA) =
  for d in -r .. r:
    for t in -1 .. 1:
      if cx + d >= 0 and cx + d < img.width and
          cy + t >= 0 and cy + t < img.height:
        img.unsafe[cx + d, cy + t] = color
      if cx + t >= 0 and cx + t < img.width and
          cy + d >= 0 and cy + d < img.height:
        img.unsafe[cx + t, cy + d] = color

proc renderPoolMap(gameMap: CtfMap): Image =
  let
    cx = gameMap.center.x
    cy = gameMap.center.y
  result = newImage(MapWidth, MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      var c = FloorColor
      let wall =
        x < ArenaBorder or y < ArenaBorder or
        x >= MapWidth - ArenaBorder or y >= MapHeight - ArenaBorder or
        obstacleWallAtF(float(x), float(y), cx, cy)
      if isArenaWindowPixel(x, y, cx, cy):
        c = GlassColor
      elif wall:
        c = StoneColor
      elif mapProtectedFloorAt(gameMap, x, y):
        c = ZoneColor
      result.unsafe[x, y] = c
  for trench in gameMap.trenches:
    for y in trench.y ..< trench.y + trench.h:
      for x in trench.x ..< trench.x + trench.w:
        let rim = x - trench.x < 3 or trench.x + trench.w - 1 - x < 3 or
          y - trench.y < 3 or trench.y + trench.h - 1 - y < 3
        result.unsafe[x, y] = if rim: TrenchRimColor else: TrenchColor
  result.fillDisc(gameMap.flagHome(Red).x, gameMap.flagHome(Red).y, 7, RedColor)
  result.fillDisc(gameMap.flagHome(Blue).x, gameMap.flagHome(Blue).y, 7, BlueColor)
  for p in gameMap.medKitCandidates:
    result.drawCross(p.x, p.y, 6, KitIdleColor)
  for p in gameMap.medKitSpawns:
    result.drawCross(p.x, p.y, 8, KitColor)

when isMainModule:
  let outDir = if paramCount() >= 1: paramStr(1) else: "pool-preview"
  createDir(outDir)
  var manifest = newJArray()
  for i, seed in MapPoolSeeds:
    let gameMap = loadCtfMap("gen:" & $seed)
    doAssert gameMap.genSeed == seed, "pool seed rolled forward: " & $seed
    let img = renderPoolMap(gameMap)
    let name = &"pool-{i:02}-seed-{seed}.png"
    img.writeFile(outDir / name)
    var kits = newJArray()
    for p in gameMap.medKitSpawns:
      kits.add %*[p.x, p.y]
    var candidates = newJArray()
    for p in gameMap.medKitCandidates:
      candidates.add %*[p.x, p.y]
    manifest.add %*{
      "index": i,
      "seed": seed,
      "file": name,
      "width": gameMap.width,
      "height": gameMap.height,
      "symmetry": (
        if gameMap.symmetry == symMirror: "mirror" else: "rot180"),
      "obstacles": gameMap.leftObstacles.len,
      "trenches": gameMap.trenches.len,
      "medKitSpawns": kits,
      "medKitCandidates": candidates,
    }
    echo "rendered ", name
  writeFile(outDir / "manifest.json", pretty(manifest))
  echo "wrote ", outDir / "manifest.json"

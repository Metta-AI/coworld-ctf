## Dumps the BAKED board art (floor, stone, glass, endzone glow + threshold
## line, pedestals) for one map to a PNG — the picture players actually see,
## as opposed to the schematic tools/render_map_pool.nim draws.
## Usage: nim c -r -d:release tools/dump_endzone_bake.nim <mapPath> <out.png>
##          [biome]
##        (mapPath: arena | gen:<seed> | pool:<index>)
##        (biome: arena | caves | forest | desert | city | plains — overrides
##         the map's own skin, which is how a floor texture gets eyeballed on a
##         real board with the endzone ember on it before any map ships with it)
import std/[os], pixie, ../src/ctf/sim

when isMainModule:
  let
    mapPath = if paramCount() >= 1: paramStr(1) else: "arena"
    outPath = if paramCount() >= 2: paramStr(2) else: "endzone-bake.png"
    biomeArg = if paramCount() >= 3: paramStr(3) else: ""
  var gameMap = loadCtfMap(mapPath)
  if biomeArg.len > 0:
    gameMap.biome = biomeFromName(biomeArg)
  let layers = loadMapLayers(gameMap)
  layers.mapImage.writeFile(outPath)
  echo "wrote ", outPath, " (", gameMap.name, " biome=", gameMap.biome,
    " endzone=", gameMap.endzone, " r=", gameMap.endzoneRadius, ")"

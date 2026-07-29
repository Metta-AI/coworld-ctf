## Renders one map's PAINTED board art (the real spectator floor + carved-stone
## cover the viewer draws, not the flat collision mask dump_map_mask emits) to a
## PNG. Use it to review a new arena's art read at a glance.
## Usage: nim c -r tools/render_map_art.nim out.png <mapName>
## Demo/audit tooling; not part of the server.
import std/os, pixie, ../src/ctf/sim

when isMainModule:
  let
    mapName = if paramCount() >= 2: paramStr(2) else: ""
    gameMap = loadCtfMap(mapName)
    (mapImage, _, _) = loadMapLayers(gameMap)
  mapImage.writeFile(paramStr(1))
  echo "wrote ", paramStr(1), " (", gameMap.name, " ",
    mapImage.width, "x", mapImage.height, ")"

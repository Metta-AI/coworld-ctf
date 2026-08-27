## Dumps the REAL baked arena art plus the walk mask to PNGs so design mocks and
## placement-funnel probes work off the engine's own pixels and its own
## collision geometry instead of a hand-approximated copy.
## Usage: nim c -r tools/dump_map_art.nim outArt.png [outWalk.png] [mapName]
## Demo/design tooling; not part of the server.
import std/os, pixie, ../src/ctf/sim

when isMainModule:
  let gameMap = loadCtfMap(if paramCount() >= 3: paramStr(3) else: "")
  let (mapImage, walkImage, _) = loadMapLayers(gameMap)
  mapImage.writeFile(if paramCount() >= 1: paramStr(1) else: "/tmp/map_art.png")
  if paramCount() >= 2:
    walkImage.writeFile(paramStr(2))
  echo "wrote ", MapWidth, "x", MapHeight,
    " captureClear=", gameMap.captureClear,
    " flagRing=", gameMap.flagRing,
    " center=", gameMap.center.x, ",", gameMap.center.y

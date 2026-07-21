## Dumps the generated arena wall mask to a PNG for visual inspection when
## iterating on the obstacle layout. Stone = dark brown, glass windows =
## cyan, floor = warm tan. Usage: nim c -r tools/dump_map_mask.nim out.png
## Demo/audit tooling; not part of the server.
import std/os, pixie, ../src/ctf/sim

when isMainModule:
  let
    gameMap = loadCtfMap()
    cx = gameMap.center.x
    cy = gameMap.center.y
  var img = newImage(MapWidth, MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      var c = rgba(214, 189, 150, 255)
      let wall =
        x < ArenaBorder or y < ArenaBorder or
        x >= MapWidth - ArenaBorder or y >= MapHeight - ArenaBorder or
        obstacleWallAtF(float(x), float(y), cx, cy)
      if isArenaWindowPixel(x, y, cx, cy):
        c = rgba(80, 220, 255, 255)
      elif wall:
        c = rgba(64, 48, 34, 255)
      img.unsafe[x, y] = c.rgbx()
  img.writeFile(paramStr(1))
  echo "wrote ", paramStr(1)

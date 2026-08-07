## Dump one CTF map's resolved arena geometry as JSON.
##
## Written for the Observatory Log page's heatmap backdrop: that page runs in a
## wasm reporter under `default-src 'none'` and cannot fetch the map, load an
## image, or link the game, so the geometry has to be BAKED into the generator.
## Baking it from a hand transcription would drift silently the first time an
## obstacle moves, so it is dumped from the game's own tables instead.
##
## Emits the MIRRORED obstacle set (`buildArenaObstacles` runs on selection, so
## `ArenaObstacles` is already left + right), the map dimensions, and the
## clearances `isProtectedFloor` carves back OUT of that set. A consumer that
## draws the shapes without subtracting the clearances will paint walls across
## the capture lanes, the center ring and the spawn pockets.
##
##   nim c -r --hints:off tools/dump_arena_geometry.nim > arena.json
##
## The map is selected at `ctf/sim` module init (`selectCtfMap(arenaCtfMap())`),
## so the default arena needs no argument; pass a name for any other map.

import std/[json, os]

import ctf/sim

proc shapeJson(shape: ArenaShape): JsonNode =
  result = %*{"kind": $shape.kind, "window": shape.window}
  case shape.kind
  of shapeRect:
    result["x"] = %shape.rect.x
    result["y"] = %shape.rect.y
    result["w"] = %shape.rect.w
    result["h"] = %shape.rect.h
  of shapeDisc, shapeDiamond:
    result["cx"] = %shape.cx
    result["cy"] = %shape.cy
    result["radius"] = %shape.radius
  of shapeDiagonal:
    result["x0"] = %shape.x0
    result["y0"] = %shape.y0
    result["x1"] = %shape.x1
    result["y1"] = %shape.y1
    result["thickness"] = %shape.thickness

when isMainModule:
  let name = if paramCount() >= 1: paramStr(1) else: ""
  # Installs the map as this process's arena, which is what rebuilds
  # `ArenaObstacles` into the mirrored set read below.
  let gameMap = loadCtfMap(name)

  var shapes = newJArray()
  for shape in ArenaObstacles:
    shapes.add shapeJson(shape)

  echo (%*{
    "map": gameMap.name,
    "width": gameMap.width,
    "height": gameMap.height,
    "center": {"x": gameMap.center.x, "y": gameMap.center.y},
    "border": ArenaBorder,
    # `isProtectedFloor` clears these back out of the obstacle set.
    "flag_ring": gameMap.flagRing,
    "capture_clear": gameMap.captureClear,
    "spawn_clear_w": gameMap.spawnClearW,
    "spawn_clear_h": gameMap.spawnClearH,
    "red_home_x": gameMap.teamHomeX(Red),
    "blue_home_x": gameMap.teamHomeX(Blue),
    "obstacles": shapes,
  }).pretty

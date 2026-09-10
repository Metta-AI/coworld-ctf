## Compare every coarse-index move bit with the eight-direction reference.
import std/json
import crunchy/[common, sha256]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_route_index]

proc inspectMap(label: string; gameMap: CtfMap): JsonNode =
  let map = newBodyMap(gameMap)
  let index = newBodyRouteIndex(map)
  var masks = newString(map.gridWidth * map.gridHeight)
  var checked: int64
  for y in 0 ..< map.gridHeight:
    for x in 0 ..< map.gridWidth:
      let cell: BodyPoint = (x, y)
      var expected = 0'u8
      for direction, delta in NavNeighbors:
        if map.legalNavMove(cell, (x + delta.x, y + delta.y)):
          expected = expected or uint8(1 shl direction)
        inc checked
      let node = y * map.gridWidth + x
      doAssert index.legalMovesAt(node) == expected,
        label & " move mask differs at " & $cell
      masks[node] = char(expected)
  %*{"map": label, "checked_bits": checked,
    "mask_sha256": sha256(masks).toHex(), "equal": true}

var rows = newJArray()
let pool = loadBrS2PoolRaw()
for i in 0 ..< pool.len:
  let label = "pool:" & $i
  stderr.writeLine label
  rows.add inspectMap(label, mapFromSpecJson($pool[i]["spec"]))
let configured = parseJson(readFile(BrS2SoloMapPoolPath))
for i in 0 ..< configured.len:
  let label = "configured:" & $i
  stderr.writeLine label
  rows.add inspectMap(label, mapFromSpecJson($configured[i]))
stderr.writeLine "colossal"
rows.add inspectMap("colossal", generateCtfMap(4242,
  MapGenOverrides(size: "colossal", windows: -1, pits: -1, pitDensity: -1), 4))
echo %*{"maps": rows}

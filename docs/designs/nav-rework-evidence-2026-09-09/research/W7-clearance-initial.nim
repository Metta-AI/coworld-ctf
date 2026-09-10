## Verify the clearance bound used to skip exact discrete ray samples.
## Zero at walls plus the eight-neighbor 1-Lipschitz property implies that
## clearance never exceeds the Chebyshev distance to any wall or boundary.
import std/[json, strformat]
import ../src/ctf/[arena, sim_types]
import ../src/shell/body_map

proc checkMap(gameMap: CtfMap, label: string): JsonNode =
  let map = newBodyMap(gameMap)
  let width = map.width
  let height = map.height
  var values = newSeq[uint8](width * height)
  var zeroFailures, boundaryFailures, neighborFailures: int
  for y in 0 ..< height:
    for x in 0 ..< width:
      let point = (x, y)
      let value = map.clearanceAt(point)
      values[y * width + x] = uint8(value)
      if (value == 0) != map.isWall(point): inc zeroFailures
      if (x == 0 or y == 0 or x == width - 1 or y == height - 1) and
          value > 1:
        inc boundaryFailures
  # These four undirected edges cover all eight neighbors exactly once.
  for y in 0 ..< height:
    for x in 0 ..< width:
      for delta in [(1, 0), (0, 1), (1, 1), (-1, 1)]:
        let nextX = x + delta[0]
        let nextY = y + delta[1]
        if nextX >= 0 and nextX < width and nextY < height:
          if abs(values[y * width + x].int -
              values[nextY * width + nextX].int) > 1:
            inc neighborFailures
  %*{"map": label, "pixels": width * height,
    "zero_failures": zeroFailures, "boundary_failures": boundaryFailures,
    "neighbor_failures": neighborFailures,
    "pass": zeroFailures == 0 and boundaryFailures == 0 and neighborFailures == 0}

when isMainModule:
  var rows = newJArray()
  var passed = true
  for path in ["data/br_s2_map_pool.json", "data/br_map_pool.json"]:
    let pool = parseJson(readFile(path))
    for index in 0 ..< pool.len:
      let entry = pool[index]
      let name = entry["name"].getStr()
      let label = &"{path}:{index}:{name}"
      stderr.writeLine label
      let row = checkMap(mapFromSpecJson($entry["spec"]), label)
      passed = passed and row["pass"].getBool()
      rows.add row
  let overrides = MapGenOverrides(
    size: "colossal", windows: -1, pits: -1, pitDensity: -1)
  let row = checkMap(generateCtfMap(4242, overrides, 4), "colossal:4242")
  passed = passed and row["pass"].getBool()
  rows.add row
  echo pretty(%*{"schema": "body_ray_clearance_bound", "maps": rows, "pass": passed})
  if not passed: quit(1)

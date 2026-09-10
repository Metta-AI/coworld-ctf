import std/[json, strformat]
import ctf/[arena, br_map_pool, sim_types]
import shell/[body_map, body_route_query]
# Independent eight-direction reference built only from public canStand/segmentClear.
proc bit(standable: seq[uint8], node: int): bool = ((standable[node shr 3] shr (node and 7)) and 1) != 0
var totalNodes, totalDiff = 0
proc checkMap(label: string, gm: CtfMap) =
  let map = newBodyMap(gm)
  let graph = newBodyMixedGraph(map)
  let lg = graph.legality
  let w = lg.width; let h = lg.height
  var diff = 0
  for node in 0 ..< lg.legal.len:
    let x = node mod w; let y = node div w
    let point: BodyPoint = (x: x * BodyFineStepPx, y: y * BodyFineStepPx)
    var expected = 0'u8
    let standable = map.canStand(point)
    if bit(lg.standable, node) != standable: inc diff
    if standable:
      for direction, delta in NavNeighbors:
        let nx = x + delta.x; let ny = y + delta.y
        if nx < 0 or nx >= w or ny < 0 or ny >= h: continue
        let np: BodyPoint = (x: nx * BodyFineStepPx, y: ny * BodyFineStepPx)
        if map.canStand(np) and map.segmentClear(point, np):
          expected = expected or uint8(1 shl direction)
    if lg.legal[node] != expected: inc diff
  totalNodes += lg.legal.len; totalDiff += diff
  echo &"{label}: nodes {lg.legal.len} diffs {diff}"
let pool = loadBrS2PoolRaw()
for i in 0 ..< pool.len: checkMap(&"pool:{i}", mapFromSpecJson($pool[i]["spec"]))
let configured = parseJson(readFile(BrS2SoloMapPoolPath))
for i in 0 ..< configured.len: checkMap(&"configured:{i}", mapFromSpecJson($configured[i]))
checkMap("colossal", generateCtfMap(4242, MapGenOverrides(size: "colossal", windows: -1, pits: -1, pitDensity: -1), 4))
echo &"TOTAL nodes {totalNodes} diffs {totalDiff}"

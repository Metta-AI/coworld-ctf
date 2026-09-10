## Whole-array identities for exact graph-construction experiments.
import std/[json, monotimes, times]
import crunchy/[common, sha256]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_route_query]

proc digest[T](values: seq[T]): string =
  # Arrays below contain fixed-width integers with no padding. All supported
  # native and wasm targets are little-endian; no native-width fields are hashed.
  if values.len == 0: return sha256("").toHex()
  sha256(unsafeAddr values[0], values.len * sizeof(T)).toHex()

proc inspectMap(label: string; gameMap: CtfMap): JsonNode =
  let map = newBodyMap(gameMap)
  let started = getMonoTime()
  let graph = newBodyMixedGraph(map)
  let elapsed = (getMonoTime() - started).inNanoseconds
  %*{"map": label, "graph_activation_ns": elapsed,
    "width": graph.legality.width, "height": graph.legality.height,
    "standable": digest(graph.legality.standable),
    "legal": digest(graph.legality.legal),
    "cell_for_node": digest(graph.cellForNode),
    "fine_for_cell": digest(graph.fineForCell),
    "anchor_for_cell": digest(graph.anchorForCell),
    "anchor_node": digest(graph.anchorNode), "wall_band": digest(graph.wallBand),
    "bridge_offset": digest(graph.bridgeOffset), "bridge_len": digest(graph.bridgeLen),
    "bridge_nodes": digest(graph.bridgeNodes), "bridge_node_count": graph.bridgeNodes.len}

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
echo %*{"maps": rows, "array_encoding": "fixed-width little-endian"}

import std/[json, strformat, os]
import ctf/[arena, br_map_pool]
import shell/[body_map, body_route_query, body_route_index]
let pool = parseJson(readFile(BrS2SoloMapPoolPath))
for poolIndex, spec in pool.elems:
  let gameMap = mapFromSpecJson($spec)
  let map = newBodyMap(gameMap)
  let graph = newBodyMixedGraph(map)
  let ws = newBodyRouteWorkspace(graph)
  let b = graph.bodyMixedGraphBytes(ws)
  var standable = 0
  var legalAny = 0
  for b in graph.legality.standable:
    var v = b
    while v != 0:
      inc standable
      v = v and (v - 1)
  for node in 0 ..< graph.legality.legal.len:
    if graph.legality.legal[node] != 0: inc legalAny
  var wallBand = 0
  for v in graph.wallBand: (if v != 0: inc wallBand)
  var anchorCells = 0
  for v in graph.anchorForCell: (if v >= 0: inc anchorCells)
  var anchorNodes = 0
  for v in graph.anchorNode: (if v != 0: inc anchorNodes)
  echo &"map={poolIndex} name={spec[\"name\"].getStr()} cells={graph.wallBand.len} latticeNodes={graph.legality.legal.len} standable={standable} legalAny={legalAny} wallBandCells={wallBand} anchorCells={anchorCells} anchorNodes={anchorNodes} bridgeNodesLen={graph.bridgeNodes.len} bridgeNodesCap={graph.bridgeNodes.capacity} bytes: legality={b.legality} cellForNode={b.cellForNode} fineForCell={b.fineForCell} anchors={b.anchors} wallBand={b.wallBand} bridges={b.bridges} workspace={b.workspace} buckets={b.buckets} reconstruction={b.reconstruction} total={b.total}"

import std/[json, strformat, sequtils, algorithm]
import ctf/[arena, br_map_pool]
import shell/[body_map, body_route_query]
# fineBitAt is private to body_route_query; replicate the bitset read.
proc bit(standable: seq[uint8], node: int): bool = ((standable[node shr 3] shr (node and 7)) and 1) != 0
proc opposite(direction: int): int =
  let d = NavNeighbors[direction]
  for i, e in NavNeighbors:
    if e.x == -d.x and e.y == -d.y: return i
  -1
# Verbatim replica of findBodyBridge (body_route_query.nim), returning the path and nodes inserted.
proc bfsBridge(legal: seq[uint8], width, height, startNode, targetNode: int): tuple[path: seq[int32], inserted: int] =
  let startX = startNode mod width
  let startY = startNode div width
  let targetX = targetNode mod width
  let targetY = targetNode div width
  let minX = max(0, min(startX, targetX) - 2)
  let maxX = min(width - 1, max(startX, targetX) + 2)
  let minY = max(0, min(startY, targetY) - 2)
  let maxY = min(height - 1, max(startY, targetY) + 2)
  var nodes: array[128, int32]
  var parents: array[128, int16]
  var head = 0
  var tail = 1
  var found = -1
  nodes[0] = int32(startNode); parents[0] = -1
  while head < tail and found < 0:
    let node = nodes[head].int
    let x = node mod width
    let y = node div width
    let lg = legal[node]
    for direction, delta in NavNeighbors:
      if (lg and uint8(1 shl direction)) == 0: continue
      let nx = x + delta.x
      let ny = y + delta.y
      if nx < minX or nx > maxX or ny < minY or ny > maxY: continue
      let nextNode = ny * width + nx
      var seen = false
      for offset in 0 ..< tail:
        if nodes[offset].int == nextNode: seen = true; break
      if seen: continue
      if tail >= nodes.len: return (@[], tail)
      nodes[tail] = int32(nextNode); parents[tail] = int16(head)
      if nextNode == targetNode: found = tail; break
      inc tail
    inc head
  if found < 0: return (@[], tail)
  var cursor = found
  var path: seq[int32]
  while cursor > 0:
    path.add nodes[cursor]; cursor = parents[cursor].int
  path.reverse()
  (path, tail)
proc dirIndex(dx, dy: int): int =
  for i, e in NavNeighbors:
    if e.x == dx and e.y == dy: return i
  -1
var totalAsym, totalEdges, bridges, shortcutHits, mismatches, bfsInserted, shortcutInserted, regular = 0
proc checkMap(label: string, gm: CtfMap) =
  let map = newBodyMap(gm)
  let graph = newBodyMixedGraph(map)
  let lg = graph.legality
  let w = lg.width; let h = lg.height
  # 1. legality symmetry
  var asym, edges = 0
  for node in 0 ..< lg.legal.len:
    let x = node mod w; let y = node div w
    for direction, delta in NavNeighbors:
      if (lg.legal[node] and uint8(1 shl direction)) == 0: continue
      inc edges
      let nx = x + delta.x; let ny = y + delta.y
      let nextNode = ny * w + nx
      let back = opposite(direction)
      if (lg.legal[nextNode] and uint8(1 shl back)) == 0: inc asym
  totalAsym += asym; totalEdges += edges
  # 2. bridge shortcut vs BFS on every stored bridge (cell, direction)
  var mb, hits, mm, ins, sins, reg = 0
  for cellIndex in 0 ..< graph.bridgeOffset.len:
    let node = graph.anchorForCell[cellIndex].int
    if node < 0: continue
    let cx = cellIndex mod map.gridWidth; let cy = cellIndex div map.gridWidth
    for direction, delta in NavNeighbors:
      let nxc = cx + delta.x; let nyc = cy + delta.y
      if nxc < 0 or nxc >= map.gridWidth or nyc < 0 or nyc >= map.gridHeight: continue
      let target = graph.anchorForCell[nyc * map.gridWidth + nxc].int
      if target < 0: continue
      inc mb
      let (bfs, tail) = bfsBridge(lg.legal, w, h, node, target)
      ins += tail
      # stored path for comparison (verifies replica)
      let off = graph.bridgeOffset[cellIndex][direction].int
      let ln = graph.bridgeLen[cellIndex][direction].int
      var stored: seq[int32]
      if off >= 0:
        for i in 0 ..< ln: stored.add graph.bridgeNodes[off + i]
      if bfs.len > 0 and bfs.len <= 255:
        if stored != bfs: inc mm
      elif stored.len != 0: inc mm
      # shortcut: regular delta (+-2,0),(0,+-2),(+-2,+-2) in fine units
      let ddx = (target mod w) - (node mod w)
      let ddy = (target div w) - (node div w)
      if (abs(ddx) == 2 or ddx == 0) and (abs(ddy) == 2 or ddy == 0) and (ddx != 0 or ddy != 0):
        inc reg
        let sx = (if ddx > 0: 1 elif ddx < 0: -1 else: 0)
        let sy = (if ddy > 0: 1 elif ddy < 0: -1 else: 0)
        let d = dirIndex(sx, sy)
        let mid = node + sy * w + sx
        if (lg.legal[node] and uint8(1 shl d)) != 0 and (lg.legal[mid] and uint8(1 shl d)) != 0:
          inc hits
          sins += 2
          let sc = @[int32(mid), int32(target)]
          if sc != bfs: inc mm; echo "SHORTCUT MISMATCH ", label, " cell ", cellIndex, " dir ", direction, " bfs ", bfs, " shortcut ", sc
        else:
          sins += tail
      else:
        sins += tail
  bridges += mb; shortcutHits += hits; mismatches += mm; bfsInserted += ins; shortcutInserted += sins; regular += reg
  echo &"{label}: edges {edges} asym {asym} bridges {mb} regular {reg} shortcut_hits {hits} mismatches {mm} bfs_inserted {ins} with_shortcut {sins}"
let s2 = loadBrS2PoolRaw()
for i in 0 ..< s2.len: checkMap(&"s2-{i}", mapFromSpecJson($s2[i]["spec"]))
let giant = parseJson(readFile(BrS2SoloMapPoolPath))
for i in 0 ..< giant.len: checkMap(&"giant-{i}", mapFromSpecJson($giant[i]))
echo &"TOTAL edges {totalEdges} asymmetric {totalAsym} bridges {bridges} regular {regular} shortcut_hits {shortcutHits} mismatches {mismatches} bfs_inserted_nodes {bfsInserted} nodes_with_shortcut {shortcutInserted}"

## P9B Round 3.2: legacy-grounded 4 px search hot loop.

import std/[heapqueue, json, math, monotimes, options, os, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_cache, body_map, body_planner, body_route_index]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r31

const
  Samples = 15
  TieBits = 21
  TieMask = (1'i64 shl TieBits) - 1
  ClosedBit = 0x8000_0000'u32

type
  FloatNode = object
    priority, cost: float64
    node: int

  FloatWorkspace = object
    generation: uint32
    cost: seq[float64]
    seen, closed: seq[uint32]

  KeyHeap = object
    keys: seq[int64]
    positions: seq[int32]
    len: int

  DenseWorkspace = object
    generation: uint32
    g, parent: seq[int32]
    state: seq[uint32]
    heap: KeyHeap

  SearchResult = object
    reached: bool
    pops: int

proc `<`(a, b: FloatNode): bool =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  else: a.node < b.node

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc colossalMap(): BodyMap =
  let overrides = MapGenOverrides(
    size: "colossal", windows: -1, pits: -1, pitDensity: -1)
  var gameMap = generateCtfMap(4242, overrides, 4)
  gameMap.name = "size:colossal"
  newBodyMap(gameMap)

proc findCase(corpus: NavCorpus, id: string): NavCorpusCase =
  for item in corpus.cases:
    if item.id == id: return item
  raise newException(ValueError, "corpus case not found: " & id)

proc begin(workspace: var FloatWorkspace) =
  inc workspace.generation
  if workspace.generation == 0:
    for stamp in workspace.seen.mitems: stamp = 0
    for stamp in workspace.closed.mitems: stamp = 0
    workspace.generation = 1

proc begin(workspace: var DenseWorkspace) =
  inc workspace.generation
  if workspace.generation == 0 or
      (workspace.generation and ClosedBit) != 0:
    for stamp in workspace.state.mitems: stamp = 0
    workspace.generation = 1
  workspace.heap.len = 0

proc keyNode(key: int64): int {.inline.} = int(key and TieMask)
proc makeKey(f: int64, node: int): int64 {.inline.} =
  (f shl TieBits) or node.int64

proc swapNodes(heap: var KeyHeap, a, b: int) {.inline.} =
  swap(heap.keys[a], heap.keys[b])
  heap.positions[keyNode(heap.keys[a])] = int32(a)
  heap.positions[keyNode(heap.keys[b])] = int32(b)

proc siftUp(heap: var KeyHeap, start: int) {.inline.} =
  var current = start
  while current > 0:
    let parent = (current - 1) shr 1
    if heap.keys[parent] <= heap.keys[current]: break
    heap.swapNodes(parent, current)
    current = parent

proc siftDown(heap: var KeyHeap, start: int) {.inline.} =
  var current = start
  while true:
    let left = current * 2 + 1
    if left >= heap.len: break
    let right = left + 1
    var child = left
    if right < heap.len and heap.keys[right] < heap.keys[left]: child = right
    if heap.keys[current] <= heap.keys[child]: break
    heap.swapNodes(current, child)
    current = child

proc pushOrDecrease(heap: var KeyHeap, state: openArray[uint32],
    generation: uint32, key: int64) {.inline.} =
  let node = keyNode(key)
  if state[node] == generation:
    let position = heap.positions[node].int
    if key < heap.keys[position]:
      heap.keys[position] = key
      heap.siftUp(position)
    return
  doAssert heap.len < heap.keys.len
  heap.keys[heap.len] = key
  heap.positions[node] = int32(heap.len)
  inc heap.len
  heap.siftUp(heap.len - 1)

proc pop(heap: var KeyHeap): int64 {.inline.} =
  result = heap.keys[0]
  dec heap.len
  if heap.len > 0:
    heap.keys[0] = heap.keys[heap.len]
    heap.positions[keyNode(heap.keys[0])] = 0
    heap.siftDown(0)

proc newFloatWorkspace(count: int): FloatWorkspace =
  result.cost = newSeq[float64](count)
  result.seen = newSeq[uint32](count)
  result.closed = newSeq[uint32](count)

proc newDenseWorkspace(count: int): DenseWorkspace =
  doAssert count <= (1 shl TieBits)
  result.g = newSeq[int32](count)
  result.parent = newSeq[int32](count)
  result.state = newSeq[uint32](count)
  result.heap.keys = newSeq[int64](count)
  result.heap.positions = newSeq[int32](count)

proc profileWeightQ8(profile: NavCorpusProfile): int64 {.inline.} =
  case profile
  of ncpDefault: 256
  of ncpCarrier: 640
  of ncpHunter: 64

proc quantizeDangerQ8(value: float32): int64 {.inline.} =
  if value <= 0: return 0
  let scaled = value.float * 256.0
  let lower = floor(scaled).int64
  let fraction = scaled - lower.float
  if fraction > 0.5 or (fraction == 0.5 and (lower and 1) != 0):
    lower + 1
  else:
    lower

proc buildWeights(danger: BodyDangerField,
    profile: NavCorpusProfile): seq[int32] =
  result = newSeq[int32](danger.values.len)
  let weight = profile.profileWeightQ8
  for cell, value in danger.values:
    result[cell] = int32(65_536'i64 + weight * quantizeDangerQ8(value))

proc fineHeuristic(a, b, width: int): int32 {.inline.} =
  let
    ax = a mod width
    ay = a div width
    bx = b mod width
    by = b div width
    dx = abs(ax - bx)
    dy = abs(ay - by)
    diagonal = min(dx, dy)
  int32(91 * diagonal + 64 * (max(dx, dy) - diagonal))

proc midpointCell(map: BodyMap, node, nextNode, width: int): int {.inline.} =
  let
    a = pointAt(node, width)
    b = pointAt(nextNode, width)
    point = ((a.x + b.x) div 2, (a.y + b.y) div 2)
    cell = map.cellOf(point)
  cell.y * map.gridWidth + cell.x

proc searchDense(table: FineLegality, map: BodyMap,
    weights, hazardCost: openArray[int32], blockedCell, startNode,
    goalNode: int, workspace: var DenseWorkspace): SearchResult =
  workspace.begin()
  let generation = workspace.generation
  workspace.g[startNode] = 0
  workspace.parent[startNode] = -1
  workspace.heap.pushOrDecrease(workspace.state, generation,
    makeKey(fineHeuristic(startNode, goalNode, table.width), startNode))
  workspace.state[startNode] = generation
  while workspace.heap.len > 0:
    let
      key = workspace.heap.pop()
      node = keyNode(key)
    if workspace.state[node] != generation: continue
    workspace.state[node] = generation or ClosedBit
    inc result.pops
    if node == goalNode:
      result.reached = true
      return
    let
      fineX = node mod table.width
      fineY = node div table.width
      legal = table.legal[node]
      currentG = workspace.g[node]
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0: continue
      let nextNode = (fineY + delta.y) * table.width + fineX + delta.x
      if workspace.state[nextNode] == (generation or ClosedBit): continue
      let
        cell = map.midpointCell(node, nextNode, table.width)
        base = if direction < 4: 64'i64 else: 91'i64
        weighted = (base * weights[cell].int64 + 32_768) shr 16
        blocked = if cell == blockedCell: weighted * 8 else: weighted
        candidate64 = currentG.int64 + blocked + hazardCost[cell].int64
        candidate = int32(candidate64)
      if workspace.state[nextNode] != generation or
          candidate < workspace.g[nextNode]:
        workspace.g[nextNode] = candidate
        workspace.parent[nextNode] = int32(node)
        let f = candidate64 + fineHeuristic(nextNode, goalNode,
          table.width).int64
        workspace.heap.pushOrDecrease(workspace.state, generation,
          makeKey(f, nextNode))
        workspace.state[nextNode] = generation

proc floatEdgeCost(map: BodyMap, danger: BodyDangerField,
    item: NavCorpusCase, a, b: BodyPoint): float64 {.inline.} =
  let
    midpoint = ((a.x + b.x) div 2, (a.y + b.y) div 2)
    weight = planCostProfile(item.profile.corpusProfile).dangerWeight
  result = hypot((b.x - a.x).float, (b.y - a.y).float) *
    (1.0 + weight * danger.sample(map, midpoint))
  if item.blockedCell.isSome and map.cellOf(midpoint) == item.blockedCell.get:
    result *= 8.0

proc searchFloat(table: FineLegality, map: BodyMap,
    danger: BodyDangerField, item: NavCorpusCase, startNode,
    goalNode: int, workspace: var FloatWorkspace): SearchResult =
  workspace.begin()
  var heap: HeapQueue[FloatNode]
  workspace.seen[startNode] = workspace.generation
  workspace.cost[startNode] = 0
  heap.push FloatNode(priority: hypot(
    (item.validatedGoal.x - item.start.x).float,
    (item.validatedGoal.y - item.start.y).float), node: startNode)
  while heap.len > 0:
    let current = heap.pop()
    if workspace.closed[current.node] == workspace.generation or
        workspace.seen[current.node] != workspace.generation or
        workspace.cost[current.node] != current.cost: continue
    workspace.closed[current.node] = workspace.generation
    inc result.pops
    if current.node == goalNode:
      result.reached = true
      return
    let
      fineX = current.node mod table.width
      fineY = current.node div table.width
      legal = table.legal[current.node]
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0: continue
      let nextNode = (fineY + delta.y) * table.width + fineX + delta.x
      if workspace.closed[nextNode] == workspace.generation: continue
      let
        nextPoint = pointAt(nextNode, table.width)
        candidate = current.cost + map.floatEdgeCost(danger, item,
          pointAt(current.node, table.width), nextPoint)
      if workspace.seen[nextNode] != workspace.generation or
          candidate < workspace.cost[nextNode]:
        workspace.seen[nextNode] = workspace.generation
        workspace.cost[nextNode] = candidate
        heap.push FloatNode(priority: candidate + hypot(
          (nextPoint.x - item.validatedGoal.x).float,
          (nextPoint.y - item.validatedGoal.y).float),
          cost: candidate, node: nextNode)

proc finishPlan(planner: BodyPlanner, cache: BodySeatCache,
    danger: BodyDangerField, job: var BodyPlanJob) =
  var guard = 0
  while job.planPending:
    var budget = 1_000_000
    discard planner.stepPlan(cache, danger, job, budget)
    inc guard
    if guard >= 100_000:
      raise newException(ValueError, "legacy planner did not terminate")

proc profileCase(pool: JsonNode, item: NavCorpusCase): JsonNode =
  let
    map = pool.loadMap(item.poolIndex)
    table = map.buildFineLegality()
    startNode = item.start.y div 4 * table.width + item.start.x div 4
    goalNode = item.validatedGoal.y div 4 * table.width +
      item.validatedGoal.x div 4
    danger = map.buildOracleDanger(item)
    weights = buildWeights(danger, item.profile)
    hazardCost = newSeq[int32](map.gridWidth * map.gridHeight)
    blockedCell = if item.blockedCell.isSome:
      item.blockedCell.get.y * map.gridWidth + item.blockedCell.get.x else: -1
    planner = newBodyPlanner(map)
    cache = newBodySeatCache(map)
    validated = map.validateGoal(item.validatedGoal, item.start)
  doAssert validated.isSome and validated.get.goalPoint == item.validatedGoal
  var
    floatWorkspace = newFloatWorkspace(table.legal.len)
    denseWorkspace = newDenseWorkspace(table.legal.len)
    legacyRows, floatRows, denseRows = newJArray()
  for sample in 0 ..< Samples:
    var job: BodyPlanJob
    let started = getMonoTime()
    planner.startPlan(cache, job, uint64(sample + 1), item.start,
      validated.get, item.profile.corpusProfile,
      if item.blockedCell.isSome:
        some(cellCenter(item.blockedCell.get)) else: none(BodyPoint))
    planner.finishPlan(cache, danger, job)
    let elapsed = (getMonoTime() - started).inNanoseconds
    doAssert job.planSucceeded
    legacyRows.add %*{"ns": elapsed, "work_units": job.workUnits,
      "astar_expansions": job.astarExpansions,
      "ns_per_work_unit": elapsed.float / job.workUnits.float,
      "ns_per_expansion": elapsed.float / job.astarExpansions.float}

    var searchStarted = getMonoTime()
    let before = table.searchFloat(map, danger, item, startNode, goalNode,
      floatWorkspace)
    let beforeNs = (getMonoTime() - searchStarted).inNanoseconds
    doAssert before.reached
    floatRows.add %*{"ns": beforeNs, "pops": before.pops,
      "ns_per_pop": beforeNs.float / before.pops.float}

    searchStarted = getMonoTime()
    let after = table.searchDense(map, weights, hazardCost, blockedCell,
      startNode, goalNode, denseWorkspace)
    let afterNs = (getMonoTime() - searchStarted).inNanoseconds
    doAssert after.reached
    denseRows.add %*{"ns": afterNs, "pops": after.pops,
      "ns_per_pop": afterNs.float / after.pops.float}
  %*{"id": item.id, "map": item.mapName,
    "nodes": table.legal.len, "legacy": legacyRows,
    "float_precomputed_legality": floatRows,
    "dense_integer": denseRows}

proc storageRow(row: JsonNode, index: BodyRouteIndex): JsonNode =
  let
    nodes = row["nodes"].getInt()
    navCells = row["nav_cells"].getInt()
    legalityBytes = row["retained_bytes"].getInt()
    workspaceBytes = nodes * (sizeof(int32) * 3 + sizeof(int64) +
      sizeof(int32))
    stats = index.routeIndexStats()
  %*{"map": row["map"].getStr(), "nodes": nodes,
    "fine_legality_bytes": legalityBytes,
    "shared_search_workspace_bytes": workspaceBytes,
    "shared_total_bytes": legalityBytes + workspaceBytes,
    "danger_weight_bytes_per_seat": navCells * sizeof(int32),
    "hazard_price_bytes_per_seat": navCells * sizeof(int32),
    "current_route_index_bytes": index.retainedIndexBytes(),
    "route_index_portal_next_bytes": stats.portalFieldCells,
    "route_index_segment_cell_bytes": stats.segmentCells * sizeof(int32),
    "route_index_segments": stats.segments,
    "route_index_arcs": stats.arcs}

when isMainModule:
  if paramCount() != 2:
    quit("usage: investigate_body_nav_p9b_r32 CORPUS R31_JSON", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    r31 = parseFile(paramStr(2))
    pool = loadBrS2PoolRaw()
    median = corpus.findCase(
      "m09-br-gen-21450-r32-s9-default-blocked-far")
    far = corpus.findCase(
      "m15-br-gen-22010-r16-s15-default-danger-far")
  var maxPoolOffset = 0
  for offset in 1 ..< r31["maps"].len - 1:
    if r31["maps"][offset]["nodes"].getInt() >
        r31["maps"][maxPoolOffset]["nodes"].getInt():
      maxPoolOffset = offset
  stderr.writeLine "r3.2 profile median"
  let medianProfile = pool.profileCase(median)
  stderr.writeLine "r3.2 profile far"
  let farProfile = pool.profileCase(far)
  stderr.writeLine "r3.2 storage pool max"
  let poolIndex = newBodyRouteIndex(pool.loadMap(maxPoolOffset))
  stderr.writeLine "r3.2 storage colossal"
  let colossalIndex = newBodyRouteIndex(colossalMap())
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r32", "v": 1,
    "tie_bits": TieBits,
    "profiles": [medianProfile, farProfile],
    "storage": [storageRow(r31["maps"][maxPoolOffset], poolIndex),
      storageRow(r31["maps"][^1], colossalIndex)]})

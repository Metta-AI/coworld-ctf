## P9B Round 2 H2: isolate and remove weighted-A* per-pop overhead.

import std/[algorithm, heapqueue, json, math, monotimes, options, os,
  strformat, tables, times]
import ../src/ctf/[arena, br_map_pool]
import ../src/shell/[body_map, body_planner, body_route_index,
  body_route_query]
import ../tests/nav_route_corpus_support

const
  Samples = 15
  ComponentIterations = 4_000_000
  SearchPopCap = 65_536
  InfiniteCost = high(int64) div 4
  GoalAllowanceQ4 = PortalAnchorRingCells * NavCell * 181

type
  FloatNode = object
    priority, cost: float64
    cell: int

  IntNode = object
    priority, cost: int64
    cell: int32

  IntHeap = object
    nodes: seq[IntNode]
    len: int

  FloatWorkspace = object
    generation: uint32
    cost: seq[float64]
    seen, closed: seq[uint32]

  IntWorkspace = object
    generation: uint32
    cost: seq[int64]
    seen, closed: seq[uint32]
    goalCost: seq[int64]
    goalStamp: seq[uint32]
    heap: IntHeap

  SearchResult = object
    reached: bool
    pops: int

  ProfileAccum = object
    baselineNs, optimizedNs, baselinePops, optimizedPops: seq[float64]

proc `<`(a, b: FloatNode): bool =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  else: a.cell < b.cell

proc intLess(a, b: IntNode): bool {.inline.} =
  if a.priority != b.priority: a.priority < b.priority
  elif a.cost != b.cost: a.cost < b.cost
  else: a.cell < b.cell

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc findCase(corpus: NavCorpus, id: string): NavCorpusCase =
  for item in corpus.cases:
    if item.id == id: return item
  raise newException(ValueError, "corpus case not found: " & id)

proc percentile(values: openArray[float64], fraction: float64): float64 =
  if values.len == 0: return Inf
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high,
    max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc begin(workspace: var FloatWorkspace) =
  inc workspace.generation
  if workspace.generation == 0:
    for stamp in workspace.seen.mitems: stamp = 0
    for stamp in workspace.closed.mitems: stamp = 0
    workspace.generation = 1

proc begin(heap: var IntHeap) =
  heap.len = 0

proc begin(workspace: var IntWorkspace) =
  inc workspace.generation
  if workspace.generation == 0:
    for stamp in workspace.seen.mitems: stamp = 0
    for stamp in workspace.closed.mitems: stamp = 0
    for stamp in workspace.goalStamp.mitems: stamp = 0
    workspace.generation = 1
  workspace.heap.begin()

proc swapNodes(heap: var IntHeap, a, b: int) {.inline.} =
  swap(heap.nodes[a], heap.nodes[b])

proc siftUp(heap: var IntHeap, start: int) {.inline.} =
  var current = start
  while current > 0:
    let parent = (current - 1) shr 1
    if not intLess(heap.nodes[current], heap.nodes[parent]): break
    heap.swapNodes(current, parent)
    current = parent

proc siftDown(heap: var IntHeap, start: int) {.inline.} =
  var current = start
  while true:
    let left = current * 2 + 1
    if left >= heap.len: break
    let right = left + 1
    var child = left
    if right < heap.len and intLess(heap.nodes[right], heap.nodes[left]):
      child = right
    if not intLess(heap.nodes[child], heap.nodes[current]): break
    heap.swapNodes(child, current)
    current = child

proc push(heap: var IntHeap, node: IntNode) {.inline.} =
  doAssert heap.len < heap.nodes.len
  heap.nodes[heap.len] = node
  inc heap.len
  heap.siftUp(heap.len - 1)

proc pop(heap: var IntHeap): IntNode {.inline.} =
  result = heap.nodes[0]
  dec heap.len
  if heap.len > 0:
    heap.nodes[0] = heap.nodes[heap.len]
    heap.siftDown(0)

proc quantizeDangerQ8(value: float): int64 {.inline.} =
  if value <= 0.0: return 0
  let scaled = value * 256.0
  let lower = floor(scaled).int64
  let fraction = scaled - lower.float
  if fraction > 0.5 or (fraction == 0.5 and (lower and 1) != 0):
    lower + 1
  else:
    lower

proc profileWeightQ8(profile: NavCorpusProfile): int64 {.inline.} =
  case profile
  of ncpDefault: 256
  of ncpCarrier: 640
  of ncpHunter: 64

proc distanceQ4(a, b: BodyPoint): int64 {.inline.} =
  let
    dx = a.x - b.x
    dy = a.y - b.y
  int64(round(sqrt(float(dx * dx + dy * dy)) * 16.0))

proc floatEdgeCost(map: BodyMap, danger: BodyDangerField,
    item: NavCorpusCase, a, b: BodyPoint): float64 =
  let midpoint = ((a.x + b.x) div 2, (a.y + b.y) div 2)
  result = hypot((b.x - a.x).float, (b.y - a.y).float) *
    (1.0 + planCostProfile(item.profile.corpusProfile).dangerWeight *
      danger.sample(map, midpoint))
  if item.blockedCell.isSome and map.cellOf(midpoint) == item.blockedCell.get:
    result *= 8.0

proc buildWeights(danger: BodyDangerField,
    profile: NavCorpusProfile): seq[int32] =
  result = newSeq[int32](danger.values.len)
  let profileQ8 = profile.profileWeightQ8
  for cell, value in danger.values:
    result[cell] = int32(65_536'i64 + profileQ8 *
      quantizeDangerQ8(value.float))

proc intEdgeCost(map: BodyMap, weights: openArray[int32],
    item: NavCorpusCase, a, b: BodyPoint): int64 {.inline.} =
  let
    midpoint = ((a.x + b.x) div 2, (a.y + b.y) div 2)
    cell = map.cellOf(midpoint)
    cellIndex = cell.y * map.gridWidth + cell.x
    base = distanceQ4(a, b)
  result = (base * weights[cellIndex].int64 + 32_768) shr 16
  if item.blockedCell.isSome and cell == item.blockedCell.get:
    result *= 8

proc intGridEdgeCost(map: BodyMap, weights: openArray[int32],
    item: NavCorpusCase, cell: BodyPoint, direction: int,
    delta: BodyPoint): int64 {.inline.} =
  let
    midpointCell = (x: cell.x + max(0, delta.x),
      y: cell.y + max(0, delta.y))
    cellIndex = midpointCell.y * map.gridWidth + midpointCell.x
    base = if direction < 4: 128'i64 else: 181'i64
  result = (base * weights[cellIndex].int64 + 32_768) shr 16
  if item.blockedCell.isSome and midpointCell == item.blockedCell.get:
    result *= 8

proc floatAttachments(map: BodyMap, index: BodyRouteIndex,
    danger: BodyDangerField, item: NavCorpusCase, endpoint: BodyPoint):
    seq[tuple[cell: int, cost: float64]] =
  let center = map.cellOf(endpoint)
  for ring in 0 .. PortalAnchorRingCells:
    for y in max(0, center.y - ring) .. min(map.gridHeight - 1,
        center.y + ring):
      for x in max(0, center.x - ring) .. min(map.gridWidth - 1,
          center.x + ring):
        if max(abs(x - center.x), abs(y - center.y)) != ring: continue
        let
          cell = y * map.gridWidth + x
          point = cellCenter((x, y))
        if index.roomForCell(cell) >= 0 and map.segmentClear(endpoint, point):
          result.add (cell: cell,
            cost: map.floatEdgeCost(danger, item, endpoint, point))

proc intAttachments(map: BodyMap, index: BodyRouteIndex,
    weights: openArray[int32], item: NavCorpusCase, endpoint: BodyPoint):
    seq[tuple[cell: int, cost: int64]] =
  let center = map.cellOf(endpoint)
  for ring in 0 .. PortalAnchorRingCells:
    for y in max(0, center.y - ring) .. min(map.gridHeight - 1,
        center.y + ring):
      for x in max(0, center.x - ring) .. min(map.gridWidth - 1,
          center.x + ring):
        if max(abs(x - center.x), abs(y - center.y)) != ring: continue
        let
          cell = y * map.gridWidth + x
          point = cellCenter((x, y))
        if index.roomForCell(cell) >= 0 and map.segmentClear(endpoint, point):
          result.add (cell: cell,
            cost: map.intEdgeCost(weights, item, endpoint, point))

proc floatHeuristic(cell, goal: BodyPoint): float64 {.inline.} =
  max(0.0, routeOctileQ4(cell, goal).float / 16.0 -
    GoalAllowanceQ4.float / 16.0)

proc intHeuristic(cell, goal: BodyPoint): int64 {.inline.} =
  max(0'i64, routeOctileQ4(cell, goal) - GoalAllowanceQ4)

proc searchBaseline(map: BodyMap, index: BodyRouteIndex,
    danger: BodyDangerField, item: NavCorpusCase,
    workspace: var FloatWorkspace): SearchResult =
  workspace.begin()
  let
    starts = map.floatAttachments(index, danger, item, item.start)
    goals = map.floatAttachments(index, danger, item, item.validatedGoal)
    goalCell = map.cellOf(item.validatedGoal)
  var
    heap: HeapQueue[FloatNode]
    goalCosts = initTable[int, float64]()
    bestGoalCost = Inf
  for goal in goals:
    if goal.cell notin goalCosts or goal.cost < goalCosts[goal.cell]:
      goalCosts[goal.cell] = goal.cost
  for start in starts:
    workspace.seen[start.cell] = workspace.generation
    workspace.cost[start.cell] = start.cost
    heap.push FloatNode(priority: start.cost + floatHeuristic(
      (start.cell mod map.gridWidth, start.cell div map.gridWidth), goalCell),
      cost: start.cost, cell: start.cell)
  while heap.len > 0 and result.pops < SearchPopCap:
    let current = heap.pop()
    if workspace.closed[current.cell] == workspace.generation or
        workspace.seen[current.cell] != workspace.generation or
        current.cost != workspace.cost[current.cell]: continue
    if current.priority >= bestGoalCost: break
    workspace.closed[current.cell] = workspace.generation
    inc result.pops
    if current.cell in goalCosts:
      bestGoalCost = min(bestGoalCost, current.cost + goalCosts[current.cell])
      result.reached = true
      continue
    let
      cell: BodyPoint = (current.cell mod map.gridWidth,
        current.cell div map.gridWidth)
      legal = index.legalMovesAt(current.cell)
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0: continue
      let
        next: BodyPoint = (cell.x + delta.x, cell.y + delta.y)
        nextCell = next.y * map.gridWidth + next.x
      if workspace.closed[nextCell] == workspace.generation: continue
      let candidate = current.cost + map.floatEdgeCost(danger, item,
        cellCenter(cell), cellCenter(next))
      if workspace.seen[nextCell] != workspace.generation or
          candidate < workspace.cost[nextCell]:
        workspace.seen[nextCell] = workspace.generation
        workspace.cost[nextCell] = candidate
        heap.push FloatNode(priority: candidate + floatHeuristic(next,
          goalCell), cost: candidate, cell: nextCell)

proc searchOptimized(map: BodyMap, index: BodyRouteIndex,
    weights: openArray[int32], item: NavCorpusCase,
    workspace: var IntWorkspace): SearchResult =
  workspace.begin()
  let
    starts = map.intAttachments(index, weights, item, item.start)
    goals = map.intAttachments(index, weights, item, item.validatedGoal)
    goalCell = map.cellOf(item.validatedGoal)
  var bestGoalCost = InfiniteCost
  for goal in goals:
    if workspace.goalStamp[goal.cell] != workspace.generation or
        goal.cost < workspace.goalCost[goal.cell]:
      workspace.goalStamp[goal.cell] = workspace.generation
      workspace.goalCost[goal.cell] = goal.cost
  for start in starts:
    if workspace.seen[start.cell] != workspace.generation or
        start.cost < workspace.cost[start.cell]:
      workspace.seen[start.cell] = workspace.generation
      workspace.cost[start.cell] = start.cost
      workspace.heap.push IntNode(
        priority: start.cost + intHeuristic(
          (start.cell mod map.gridWidth, start.cell div map.gridWidth),
          goalCell), cost: start.cost, cell: int32(start.cell))
  while workspace.heap.len > 0 and result.pops < SearchPopCap:
    let current = workspace.heap.pop()
    let currentCell = current.cell.int
    if workspace.closed[currentCell] == workspace.generation or
        workspace.seen[currentCell] != workspace.generation or
        current.cost != workspace.cost[currentCell]: continue
    if current.priority >= bestGoalCost: break
    workspace.closed[currentCell] = workspace.generation
    inc result.pops
    if workspace.goalStamp[currentCell] == workspace.generation:
      bestGoalCost = min(bestGoalCost,
        current.cost + workspace.goalCost[currentCell])
      result.reached = true
      continue
    let
      cell: BodyPoint = (currentCell mod map.gridWidth,
        currentCell div map.gridWidth)
      legal = index.legalMovesAt(currentCell)
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0: continue
      let
        next: BodyPoint = (cell.x + delta.x, cell.y + delta.y)
        nextCell = next.y * map.gridWidth + next.x
      if workspace.closed[nextCell] == workspace.generation: continue
      let candidate = current.cost + map.intGridEdgeCost(weights, item,
        cell, direction, delta)
      if workspace.seen[nextCell] != workspace.generation or
          candidate < workspace.cost[nextCell]:
        workspace.seen[nextCell] = workspace.generation
        workspace.cost[nextCell] = candidate
        workspace.heap.push IntNode(
          priority: candidate + intHeuristic(next, goalCell),
          cost: candidate, cell: int32(nextCell))

proc newFloatWorkspace(count: int): FloatWorkspace =
  result.cost = newSeq[float64](count)
  result.seen = newSeq[uint32](count)
  result.closed = newSeq[uint32](count)

proc newIntWorkspace(count: int): IntWorkspace =
  result.cost = newSeq[int64](count)
  result.seen = newSeq[uint32](count)
  result.closed = newSeq[uint32](count)
  result.goalCost = newSeq[int64](count)
  result.goalStamp = newSeq[uint32](count)
  result.heap.nodes = newSeq[IntNode](count * 8)

proc nsPer(iterations: int, body: proc(): uint64): tuple[ns: float64,
    checksum: uint64] =
  let started = getMonoTime()
  result.checksum = body()
  result.ns = (getMonoTime() - started).inNanoseconds.float / iterations.float

proc componentProfile(map: BodyMap, index: BodyRouteIndex,
    danger: BodyDangerField, weights: seq[int32]): JsonNode =
  let count = map.gridWidth * map.gridHeight
  var points = newSeq[BodyPoint](count)
  for cell in 0 ..< count:
    points[cell] = cellCenter((cell mod map.gridWidth,
      cell div map.gridWidth))
  let sampleQuantize = nsPer(ComponentIterations, proc(): uint64 =
    var checksum = 0'u64
    for iteration in 0 ..< ComponentIterations:
      let cell = (iteration * 17) mod count
      checksum = checksum xor uint64(quantizeDangerQ8(
        danger.sample(map, points[cell])))
    checksum)
  let weightRead = nsPer(ComponentIterations, proc(): uint64 =
    var checksum = 0'u64
    for iteration in 0 ..< ComponentIterations:
      checksum = checksum xor uint64(weights[(iteration * 17) mod count])
    checksum)
  let legality = nsPer(ComponentIterations, proc(): uint64 =
    var checksum = 0'u64
    for iteration in 0 ..< ComponentIterations:
      checksum = checksum xor uint64(index.legalMovesAt(
        (iteration * 17) mod count))
    checksum)
  var stamps = newSeq[uint32](count)
  var hazardTable = newSeq[int32](count)
  for cell in count div 3 ..< count: stamps[cell] = 7
  let stampCheck = nsPer(ComponentIterations, proc(): uint64 =
    var checksum = 0'u64
    for iteration in 0 ..< ComponentIterations:
      checksum = checksum xor uint64(stamps[(iteration * 17) mod count] == 7)
    checksum)
  let hazardRead = nsPer(ComponentIterations, proc(): uint64 =
    var checksum = 0'u64
    for iteration in 0 ..< ComponentIterations:
      checksum = checksum xor uint64(hazardTable[(iteration * 17) mod count])
    checksum)
  let q4Arithmetic = nsPer(ComponentIterations, proc(): uint64 =
    var checksum = 0'u64
    for iteration in 0 ..< ComponentIterations:
      let base = if (iteration and 1) == 0: 128'i64 else: 181'i64
      checksum = checksum xor uint64(
        (base * weights[(iteration * 17) mod count].int64 + 32_768) shr 16)
    checksum)
  let etaDivision = nsPer(ComponentIterations, proc(): uint64 =
    var checksum = 0'u64
    for iteration in 0 ..< ComponentIterations:
      let physical = int64(iteration * 181 + 128)
      checksum = checksum xor uint64((physical + 32) div 33)
    checksum)
  var
    nextRemainder: array[2, array[33, uint8]]
    etaIncrement: array[2, array[33, uint8]]
  for kind, step in [128, 181]:
    for remainder in 0 .. 32:
      let total = remainder + step
      nextRemainder[kind][remainder] = uint8(total mod 33)
      etaIncrement[kind][remainder] = uint8(total div 33)
  let etaIncremental = nsPer(ComponentIterations, proc(): uint64 =
    var checksum = 0'u64
    var remainder = 0
    for iteration in 0 ..< ComponentIterations:
      let kind = iteration and 1
      checksum += etaIncrement[kind][remainder]
      remainder = nextRemainder[kind][remainder].int
    checksum xor uint64(remainder))
  var heap = newIntWorkspace(count).heap
  heap.begin()
  for cell in 0 ..< min(count, 4096):
    heap.push IntNode(priority: int64(cell * 37 mod 4096),
      cost: int64(cell), cell: int32(cell))
  let heapIterations = ComponentIterations div 64
  let heapOps = nsPer(heapIterations, proc(): uint64 =
    var checksum = 0'u64
    for iteration in 0 ..< heapIterations:
      let node = heap.pop()
      checksum = checksum xor uint64(node.priority)
      heap.push IntNode(priority: node.priority + 4097,
        cost: node.cost + 1, cell: node.cell)
    checksum)
  %*{"iterations": ComponentIterations,
    "danger_sample_quantize_ns": sampleQuantize.ns,
    "precomputed_weight_read_ns": weightRead.ns,
    "hazard_eta_division_ns": etaDivision.ns,
    "hazard_eta_incremental_table_ns": etaIncremental.ns,
    "hazard_cell_table_read_ns": hazardRead.ns,
    "q4_int64_arithmetic_ns": q4Arithmetic.ns,
    "heap_pop_push_ns": heapOps.ns,
    "legality_bitmap_read_ns": legality.ns,
    "stamp_check_ns": stampCheck.ns,
    "checksums": [sampleQuantize.checksum, weightRead.checksum,
      etaDivision.checksum, etaIncremental.checksum, hazardRead.checksum,
      q4Arithmetic.checksum, heapOps.checksum, legality.checksum,
      stampCheck.checksum]}

proc profileSearch(map: BodyMap, index: BodyRouteIndex,
    danger: BodyDangerField, weights: openArray[int32],
    item: NavCorpusCase): JsonNode =
  let count = map.gridWidth * map.gridHeight
  var
    floatWorkspace = newFloatWorkspace(count)
    intWorkspace = newIntWorkspace(count)
    baseline = newJArray()
    optimized = newJArray()
  discard map.searchBaseline(index, danger, item, floatWorkspace)
  discard map.searchOptimized(index, weights, item, intWorkspace)
  for _ in 0 ..< Samples:
    var started = getMonoTime()
    let before = map.searchBaseline(index, danger, item, floatWorkspace)
    let beforeNs = (getMonoTime() - started).inNanoseconds
    started = getMonoTime()
    let after = map.searchOptimized(index, weights, item, intWorkspace)
    let afterNs = (getMonoTime() - started).inNanoseconds
    baseline.add %*{"ns": beforeNs, "pops": before.pops,
      "ns_per_pop": beforeNs.float / before.pops.float,
      "reached": before.reached}
    optimized.add %*{"ns": afterNs, "pops": after.pops,
      "ns_per_pop": afterNs.float / after.pops.float,
      "reached": after.reached}
  %*{"id": item.id, "baseline_float_std_heap": baseline,
    "optimized_precomputed_lazy_int_heap": optimized}

proc allCorpusProfile(pool: JsonNode, corpus: NavCorpus): JsonNode =
  var accum: ProfileAccum
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"h2 map {poolIndex + 1}/{pool.len}"
    let
      map = pool.loadMap(poolIndex)
      index = newBodyRouteIndex(map)
      count = map.gridWidth * map.gridHeight
    var
      floatWorkspace = newFloatWorkspace(count)
      intWorkspace = newIntWorkspace(count)
      dangerCache = initTable[string, BodyDangerField]()
      weightCache = initTable[string, seq[int32]]()
    for item in corpus.cases:
      if item.poolIndex != poolIndex: continue
      if item.dangerHash notin dangerCache:
        dangerCache[item.dangerHash] = map.buildOracleDanger(item)
      let
        danger = dangerCache[item.dangerHash]
        weightKey = item.dangerHash & ":" & $item.profile
      if weightKey notin weightCache:
        weightCache[weightKey] = buildWeights(danger, item.profile)
      let weights = weightCache[weightKey]
      var started = getMonoTime()
      let before = map.searchBaseline(index, danger, item, floatWorkspace)
      let beforeNs = (getMonoTime() - started).inNanoseconds
      started = getMonoTime()
      let after = map.searchOptimized(index, weights, item, intWorkspace)
      let afterNs = (getMonoTime() - started).inNanoseconds
      if not before.reached or not after.reached:
        raise newException(ValueError, "H2 search failed: " & item.id)
      accum.baselineNs.add beforeNs.float / before.pops.float
      accum.optimizedNs.add afterNs.float / after.pops.float
      accum.baselinePops.add before.pops.float
      accum.optimizedPops.add after.pops.float
  %*{
    "baseline_ns_per_pop_p50": percentile(accum.baselineNs, 0.50),
    "baseline_ns_per_pop_p95": percentile(accum.baselineNs, 0.95),
    "optimized_ns_per_pop_p50": percentile(accum.optimizedNs, 0.50),
    "optimized_ns_per_pop_p95": percentile(accum.optimizedNs, 0.95),
    "baseline_pops_p50": percentile(accum.baselinePops, 0.50),
    "baseline_pops_p95": percentile(accum.baselinePops, 0.95),
    "optimized_pops_p50": percentile(accum.optimizedPops, 0.50),
    "optimized_pops_p95": percentile(accum.optimizedPops, 0.95)}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_h2 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
    median = corpus.findCase(
      "m09-br-gen-21450-r32-s9-default-blocked-far")
    far = corpus.findCase(
      "m15-br-gen-22010-r16-s15-default-danger-far")
    componentMap = pool.loadMap(far.poolIndex)
    componentIndex = newBodyRouteIndex(componentMap)
    componentDanger = componentMap.buildOracleDanger(far)
    componentWeights = buildWeights(componentDanger, far.profile)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_h2", "v": 1,
    "components": componentProfile(componentMap, componentIndex,
      componentDanger, componentWeights),
    "dedicated": [
      block:
        let map = pool.loadMap(median.poolIndex)
        let index = newBodyRouteIndex(map)
        let danger = map.buildOracleDanger(median)
        map.profileSearch(index, danger, buildWeights(danger, median.profile),
          median),
      componentMap.profileSearch(componentIndex, componentDanger,
        componentWeights, far)],
    "corpus": pool.allCorpusProfile(corpus)})

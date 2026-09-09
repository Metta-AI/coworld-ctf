## P9B Round 5.3: concrete compact mixed graph and sparse Dial workspace.

import std/[algorithm, json, math, monotimes, options, os, strformat, tables,
  times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_planner]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r31
import investigate_body_nav_p9b_r33
import investigate_body_nav_p9b_r42

const
  HashCapacity = 131_072
  QueueCapacity = 65_536
  BucketCapacity = 65_536
  EmptyKey = -1'i32
  Samples = 15

type
  CompactQueue = object
    heads, tails: seq[int32]
    entryF, entryG, entryNode, entryNext: seq[int32]
    currentF: int32
    len, highWater, freeHead, peakLen: int

  CompactWorkspace = object
    keys, g, parent, parentBridge: seq[int32]
    closed: seq[uint8]
    used, peakUsed: int
    queue: CompactQueue

  CompactGraph = object
    legality: FineLegality
    wallBand: seq[uint8]
    gridWidth, gridHeight: int

  CompactResult = object
    reached: bool
    settledPops, queuePops: int
    route: seq[BodyPoint]

  QualityAccum = object
    inflations: seq[float64]
    strata: Table[string, seq[float64]]
    missing, illegal: int

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

proc percentileInt(values: openArray[int64], fraction: float64): int64 =
  if values.len == 0: return 0
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc begin(queue: var CompactQueue) =
  for head in queue.heads.mitems: head = -1
  for tail in queue.tails.mitems: tail = -1
  queue.currentF = high(int32)
  queue.len = 0
  queue.highWater = 0
  queue.freeHead = -1
  queue.peakLen = 0

proc push(queue: var CompactQueue, f, g, node: int32) {.inline.} =
  let entry = if queue.freeHead >= 0:
      queue.freeHead
    else:
      doAssert queue.highWater < queue.entryF.len,
        "compact Dial live-entry capacity exhausted"
      let allocated = queue.highWater
      inc queue.highWater
      allocated
  if queue.freeHead >= 0:
    queue.freeHead = queue.entryNext[entry]
  queue.entryF[entry] = f
  queue.entryG[entry] = g
  queue.entryNode[entry] = node
  queue.entryNext[entry] = -1
  let slot = f.int mod queue.heads.len
  if queue.tails[slot] >= 0:
    queue.entryNext[queue.tails[slot]] = int32(entry)
  else:
    queue.heads[slot] = int32(entry)
  queue.tails[slot] = int32(entry)
  queue.currentF = min(queue.currentF, f)
  inc queue.len
  queue.peakLen = max(queue.peakLen, queue.len)

proc pop(queue: var CompactQueue): tuple[f, g, node: int32] =
  while queue.len > 0:
    let slot = queue.currentF.int mod queue.heads.len
    let entry = queue.heads[slot].int
    if entry >= 0 and queue.entryF[entry] == queue.currentF:
      result = (queue.entryF[entry], queue.entryG[entry],
        queue.entryNode[entry])
      queue.heads[slot] = queue.entryNext[entry]
      if queue.heads[slot] < 0: queue.tails[slot] = -1
      queue.entryNext[entry] = int32(queue.freeHead)
      queue.freeHead = entry
      dec queue.len
      return
    inc queue.currentF
  raise newException(IndexDefect, "pop from empty compact Dial queue")

proc newCompactWorkspace(): CompactWorkspace =
  result.keys = newSeq[int32](HashCapacity)
  result.g = newSeq[int32](HashCapacity)
  result.parent = newSeq[int32](HashCapacity)
  result.parentBridge = newSeq[int32](HashCapacity)
  result.closed = newSeq[uint8](HashCapacity)
  result.queue.heads = newSeq[int32](BucketCapacity)
  result.queue.tails = newSeq[int32](BucketCapacity)
  result.queue.entryF = newSeq[int32](QueueCapacity)
  result.queue.entryG = newSeq[int32](QueueCapacity)
  result.queue.entryNode = newSeq[int32](QueueCapacity)
  result.queue.entryNext = newSeq[int32](QueueCapacity)
  for key in result.keys.mitems: key = EmptyKey

proc begin(workspace: var CompactWorkspace) =
  for key in workspace.keys.mitems: key = EmptyKey
  workspace.used = 0
  workspace.peakUsed = 0
  workspace.queue.begin()

proc slotFor(workspace: CompactWorkspace, node: int): int {.inline.} =
  var slot = (uint32(node) * 2_654_435_761'u32 and
    uint32(workspace.keys.high)).int
  while workspace.keys[slot] != EmptyKey and
      workspace.keys[slot] != int32(node):
    slot = (slot + 1) and workspace.keys.high
  slot

proc ensure(workspace: var CompactWorkspace, node: int): int {.inline.} =
  result = workspace.slotFor(node)
  if workspace.keys[result] == EmptyKey:
    doAssert workspace.used * 2 < workspace.keys.len,
      "compact search hash load exceeded 50 percent"
    workspace.keys[result] = int32(node)
    workspace.g[result] = high(int32)
    workspace.parent[result] = -1
    workspace.parentBridge[result] = -1
    workspace.closed[result] = 0
    inc workspace.used
    workspace.peakUsed = max(workspace.peakUsed, workspace.used)

proc existing(workspace: CompactWorkspace, node: int): int {.inline.} =
  result = workspace.slotFor(node)
  if workspace.keys[result] == EmptyKey: result = -1

proc bitAt(values: openArray[uint8], index: int): bool {.inline.} =
  (values[index shr 3] and uint8(1 shl (index and 7))) != 0

proc setBit(values: var seq[uint8], index: int) {.inline.} =
  values[index shr 3] = values[index shr 3] or uint8(1 shl (index and 7))

proc buildCompactGraph(map: BodyMap): CompactGraph =
  result.legality = map.buildFineLegality()
  result.gridWidth = map.gridWidth
  result.gridHeight = map.gridHeight
  let cells = map.gridWidth * map.gridHeight
  result.wallBand = newSeq[uint8]((cells + 7) div 8)
  var seeds = newSeq[uint8]((cells + 7) div 8)
  for y in 0 ..< map.gridHeight:
    for x in 0 ..< map.gridWidth:
      let cell = y * map.gridWidth + x
      if map.canStand(cellCenter((x, y))): continue
      var anyFine = false
      for fy in 0 .. 1:
        for fx in 0 .. 1:
          let node = (y * 2 + fy) * result.legality.width + x * 2 + fx
          anyFine = anyFine or result.legality.standable.bitAt(node)
      if anyFine: seeds.setBit(cell)
  for source in 0 ..< cells:
    if not seeds.bitAt(source): continue
    let cell: BodyPoint =
      (source mod map.gridWidth, source div map.gridWidth)
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let next: BodyPoint = (cell.x + dx, cell.y + dy)
        if next.x >= 0 and next.x < map.gridWidth and
            next.y >= 0 and next.y < map.gridHeight:
          result.wallBand.setBit(next.y * map.gridWidth + next.x)

proc profileWeightQ8(profile: NavCorpusProfile): int32 {.inline.} =
  case profile
  of ncpDefault: 256
  of ncpCarrier: 640
  of ncpHunter: 64

proc packedWeights(danger: BodyDangerField,
    hot: openArray[uint8]): seq[int16] =
  result = newSeq[int16](danger.values.len)
  for cell, value in danger.values:
    let q8 = if value <= 0: 0 else: min(0x7fff,
      int(round(value.float * 256.0)))
    let packed = uint16(q8) or (if hot[cell] != 0: 0x8000'u16 else: 0'u16)
    result[cell] = cast[int16](packed)

proc hot(packed: int16): bool {.inline.} =
  (cast[uint16](packed) and 0x8000'u16) != 0

proc factorQ16(packed: int16, profileWeight: int32): int32 {.inline.} =
  65_536'i32 + profileWeight *
    int32(cast[uint16](packed) and 0x7fff'u16)

proc cellFor(graph: CompactGraph, node: int): int {.inline.} =
  let
    fineX = node mod graph.legality.width
    fineY = node div graph.legality.width
  (fineY div 2) * graph.gridWidth + fineX div 2

proc centerNode(graph: CompactGraph, cell: int): int {.inline.} =
  let
    x = cell mod graph.gridWidth
    y = cell div graph.gridWidth
  (y * 2 + 1) * graph.legality.width + x * 2 + 1

proc refined(graph: CompactGraph, weights: openArray[int16],
    cell: int): bool {.inline.} =
  graph.wallBand.bitAt(cell) or weights[cell].hot

proc active(graph: CompactGraph, weights: openArray[int16], node: int,
    startNode, goalNode: int): bool {.inline.} =
  if not graph.legality.standable.bitAt(node): return false
  if node == startNode or node == goalNode: return true
  let cell = graph.cellFor(node)
  graph.refined(weights, cell) or node == graph.centerNode(cell)

proc edgeCost(graph: CompactGraph, map: BodyMap,
    weights: openArray[int16], profileWeight: int32,
    blockedCell, node, nextNode, direction: int): int32 {.inline.} =
  let
    fineX = node mod graph.legality.width
    fineY = node div graph.legality.width
    delta = NavNeighbors[direction]
    cellX = (fineX * 4 + delta.x * 2) div NavCell
    cellY = (fineY * 4 + delta.y * 2) div NavCell
    cell = cellY * map.gridWidth + cellX
    base = stepCost(weights[cell].factorQ16(profileWeight), direction >= 4)
  if cell == blockedCell: base * 8 else: base

proc compactSearch(graph: CompactGraph, map: BodyMap, item: NavCorpusCase,
    weights: openArray[int16], workspace: var CompactWorkspace): CompactResult =
  workspace.begin()
  doAssert item.start.x mod 4 == 0 and item.start.y mod 4 == 0
  doAssert item.validatedGoal.x mod 4 == 0 and
    item.validatedGoal.y mod 4 == 0
  let
    startNode = item.start.y div 4 * graph.legality.width + item.start.x div 4
    goalNode = item.validatedGoal.y div 4 * graph.legality.width +
      item.validatedGoal.x div 4
    profileWeight = item.profile.profileWeightQ8
    blockedCell = if item.blockedCell.isSome:
      item.blockedCell.get.y * map.gridWidth + item.blockedCell.get.x else: -1
  doAssert graph.active(weights, startNode, startNode, goalNode)
  doAssert graph.active(weights, goalNode, startNode, goalNode)
  let startSlot = workspace.ensure(startNode)
  workspace.g[startSlot] = 0
  workspace.queue.push(octileQ4(item.start, item.validatedGoal, 90),
    0, int32(startNode))
  var
    bestNode = -1
    bestCost = high(int32)
  while workspace.queue.len > 0:
    let entry = workspace.queue.pop()
    inc result.queuePops
    let slot = workspace.existing(entry.node.int)
    if slot < 0 or workspace.g[slot] != entry.g or workspace.closed[slot] != 0:
      continue
    if entry.f >= bestCost: break
    workspace.closed[slot] = 1
    inc result.settledPops
    if entry.node.int == goalNode:
      bestNode = goalNode
      bestCost = entry.g
      continue
    let
      node = entry.node.int
      fineX = node mod graph.legality.width
      fineY = node div graph.legality.width
      legal = graph.legality.legal[node]
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) == 0: continue
      let nextNode = (fineY + delta.y) * graph.legality.width +
        fineX + delta.x
      if not graph.active(weights, nextNode, startNode, goalNode): continue
      let nextSlot = workspace.ensure(nextNode)
      if workspace.closed[nextSlot] != 0: continue
      let candidate = entry.g + graph.edgeCost(map, weights, profileWeight,
        blockedCell, node, nextNode, direction)
      if candidate < workspace.g[nextSlot]:
        workspace.g[nextSlot] = candidate
        workspace.parent[nextSlot] = int32(node)
        workspace.parentBridge[nextSlot] = -1
        let nextPoint = pointAt(nextNode, graph.legality.width)
        workspace.queue.push(candidate + octileQ4(nextPoint,
          item.validatedGoal, 90), candidate, int32(nextNode))
    let sourceCell = graph.cellFor(node)
    if node != graph.centerNode(sourceCell): continue
    let sourcePoint = pointAt(node, graph.legality.width)
    let sourceCellPoint: BodyPoint = (sourceCell mod graph.gridWidth,
      sourceCell div graph.gridWidth)
    for direction, delta in NavNeighbors:
      let targetCellPoint: BodyPoint = (sourceCellPoint.x + delta.x,
        sourceCellPoint.y + delta.y)
      if targetCellPoint.x < 0 or targetCellPoint.x >= graph.gridWidth or
          targetCellPoint.y < 0 or targetCellPoint.y >= graph.gridHeight:
        continue
      let targetCell = targetCellPoint.y * graph.gridWidth + targetCellPoint.x
      let targetNode = graph.centerNode(targetCell)
      if not graph.legality.standable.bitAt(targetNode): continue
      let
        middle: BodyPoint = (sourcePoint.x + delta.x * 4,
          sourcePoint.y + delta.y * 4)
        targetPoint = pointAt(targetNode, graph.legality.width)
      if not map.segmentClear(sourcePoint, middle) or
          not map.segmentClear(middle, targetPoint): continue
      let targetSlot = workspace.ensure(targetNode)
      if workspace.closed[targetSlot] != 0: continue
      let
        firstCell = map.midpointCell(sourcePoint, middle)
        secondCell = map.midpointCell(middle, targetPoint)
        firstBase = stepCost(weights[firstCell].factorQ16(profileWeight),
          direction >= 4)
        secondBase = stepCost(weights[secondCell].factorQ16(profileWeight),
          direction >= 4)
        candidate = entry.g +
          (if firstCell == blockedCell: firstBase * 8 else: firstBase) +
          (if secondCell == blockedCell: secondBase * 8 else: secondBase)
      if candidate < workspace.g[targetSlot]:
        workspace.g[targetSlot] = candidate
        workspace.parent[targetSlot] = int32(node)
        workspace.parentBridge[targetSlot] = int32(direction)
        workspace.queue.push(candidate + octileQ4(targetPoint,
          item.validatedGoal, 90), candidate, int32(targetNode))
  if bestNode < 0: return
  result.reached = true
  var cursor = bestNode
  while cursor >= 0:
    let slot = workspace.existing(cursor)
    doAssert slot >= 0
    result.route.add pointAt(cursor, graph.legality.width)
    let bridge = workspace.parentBridge[slot]
    if bridge >= 0:
      let
        parentNode = workspace.parent[slot].int
        parentPoint = pointAt(parentNode, graph.legality.width)
        delta = NavNeighbors[bridge.int]
      result.route.add (parentPoint.x + delta.x * 4,
        parentPoint.y + delta.y * 4)
    cursor = workspace.parent[slot].int
  result.route.reverse()

proc workspaceBytes(workspace: CompactWorkspace): int64 =
  result = sizeof(workspace).int64
  result += int64(workspace.keys.len + workspace.g.len +
    workspace.parent.len + workspace.parentBridge.len) * sizeof(int32)
  result += workspace.closed.len.int64 * sizeof(uint8)
  result += int64(workspace.queue.heads.len + workspace.queue.tails.len +
    workspace.queue.entryF.len + workspace.queue.entryG.len +
    workspace.queue.entryNode.len + workspace.queue.entryNext.len) * sizeof(int32)

proc profileCase(pool: JsonNode, corpus: NavCorpus, id: string): JsonNode =
  let
    item = corpus.findCase(id)
    map = pool.loadMap(item.poolIndex)
    graph = map.buildCompactGraph()
    danger = map.buildOracleDanger(item)
    hotMask = map.buildHot(danger)
    weights = danger.packedWeights(hotMask)
  var
    workspace = newCompactWorkspace()
    samplesNs, settled, queuePops, nsPerPop: seq[int64]
    routeHash = 0'u64
    peakSlots, peakEntries = 0
  for _ in 0 ..< Samples:
    let started = getMonoTime()
    let found = graph.compactSearch(map, item, weights, workspace)
    let elapsed = (getMonoTime() - started).inNanoseconds
    doAssert found.reached and map.routeLegal(item, found.route)
    samplesNs.add elapsed
    settled.add found.settledPops.int64
    queuePops.add found.queuePops.int64
    nsPerPop.add elapsed div max(1, found.settledPops).int64
    peakSlots = max(peakSlots, workspace.peakUsed)
    peakEntries = max(peakEntries, workspace.queue.peakLen)
    for point in found.route:
      routeHash = routeHash * 1_099_511_628_211'u64 xor
        uint64(point.x * 65_537 + point.y)
  %*{"id": id,
    "query_ns_p50": percentileInt(samplesNs, 0.50),
    "query_ns_p95": percentileInt(samplesNs, 0.95),
    "settled_pops_p50": percentileInt(settled, 0.50),
    "queue_pops_p50": percentileInt(queuePops, 0.50),
    "ns_per_settled_pop_p50": percentileInt(nsPerPop, 0.50),
    "ns_per_settled_pop_p95": percentileInt(nsPerPop, 0.95),
    "peak_sparse_slots": peakSlots,
    "peak_live_queue_entries": peakEntries,
    "route_hash": routeHash}

proc qualityRow(accum: QualityAccum): JsonNode =
  var worstP95, worstMax = 0.0
  for values in accum.strata.values:
    worstP95 = max(worstP95, percentile(values, 0.95))
    if values.len > 0: worstMax = max(worstMax, max(values))
  %*{"missing": accum.missing, "illegal": accum.illegal,
    "overall_p95_inflation_pct": percentile(accum.inflations, 0.95),
    "overall_max_inflation_pct": max(accum.inflations),
    "worst_stratum_p95_inflation_pct": worstP95,
    "worst_stratum_max_inflation_pct": worstMax}

proc measureQuality(pool: JsonNode, corpus: NavCorpus): JsonNode =
  var accum: QualityAccum
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"R5.3 quality map {poolIndex + 1}/{pool.len}"
    let
      map = pool.loadMap(poolIndex)
      graph = map.buildCompactGraph()
    var
      dangerByHash = initTable[string, BodyDangerField]()
      weightsByKey = initTable[string, seq[int16]]()
      workspace = newCompactWorkspace()
    for item in corpus.cases:
      if item.poolIndex != poolIndex: continue
      if item.dangerHash notin dangerByHash:
        dangerByHash[item.dangerHash] = map.buildOracleDanger(item)
      let key = item.dangerHash & "/" & $item.profile
      if key notin weightsByKey:
        let danger = dangerByHash[item.dangerHash]
        weightsByKey[key] = danger.packedWeights(map.buildHot(danger))
    for item in corpus.cases:
      if item.poolIndex != poolIndex: continue
      let
        danger = dangerByHash[item.dangerHash]
        key = item.dangerHash & "/" & $item.profile
        found = graph.compactSearch(map, item, weightsByKey[key], workspace)
      if not found.reached:
        inc accum.missing
        continue
      if not map.routeLegal(item, found.route):
        inc accum.illegal
        continue
      let inflation = routeInflationPct(oracleFloatCost(
        resampleRoute4px(found.route), map, danger,
        item.profile.corpusProfile, item.blockedCell), item.oracleCost)
      let stratum =
        &"r{item.rosterSize}/{item.profile}/{item.dynamic}/{item.distance}"
      accum.inflations.add inflation
      accum.strata.mgetOrPut(stratum, @[]).add inflation
  accum.qualityRow()

proc memoryRow(map: BodyMap, label: string, cap: int64): JsonNode =
  let
    graph = map.buildCompactGraph()
    navCells = map.gridWidth * map.gridHeight
    fineLegality = graph.legality.legal.len + graph.legality.standable.len
    packedWeights32 = navCells * sizeof(int16) * 32
    legalMoves = navCells * sizeof(uint8)
    roomIds = navCells * sizeof(uint16)
    componentIds = navCells * sizeof(uint16)
    wallBand = graph.wallBand.len
    backbone = legalMoves + roomIds + componentIds + wallBand
    workspace = newCompactWorkspace()
    workspaceRetained = workspace.workspaceBytes()
    total = fineLegality.int64 + packedWeights32.int64 + backbone.int64 +
      workspaceRetained
  %*{"map": label, "nav_cells": navCells,
    "fine_nodes": graph.legality.legal.len,
    "fine_legality_bytes": fineLegality,
    "packed_int16_weight_hot_bytes_32_seats": packedWeights32,
    "backbone": {"legal_moves_bytes": legalMoves,
      "room_ids_bytes": roomIds, "component_ids_bytes": componentIds,
      "wall_band_bytes": wallBand, "total_bytes": backbone},
    "compact_workspace": {"hash_capacity": HashCapacity,
      "queue_capacity": QueueCapacity, "bucket_capacity": BucketCapacity,
      "retained_bytes": workspaceRetained},
    "total_retained_bytes": total, "cap_bytes": cap,
    "headroom_bytes": cap - total, "fits": total <= cap}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r53 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
  var
    largestMap: BodyMap
    largestCells = -1
  for poolIndex in 0 ..< pool.len:
    let map = pool.loadMap(poolIndex)
    if map.gridWidth * map.gridHeight > largestCells:
      largestCells = map.gridWidth * map.gridHeight
      largestMap = map
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r53", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "packed_weight_contract":
      "15-bit exact danger Q8 plus one dilated-hot bit; profile factor reconstructed in int32",
    "quality": pool.measureQuality(corpus),
    "profiles": [
      pool.profileCase(corpus,
        "m09-br-gen-21450-r32-s9-default-blocked-far"),
      pool.profileCase(corpus,
        "m15-br-gen-22010-r16-s15-default-danger-far")],
    "memory": [
      largestMap.memoryRow("largest_pool", 16'i64 * 1024 * 1024),
      colossalMap().memoryRow("size:colossal", 32'i64 * 1024 * 1024)]})

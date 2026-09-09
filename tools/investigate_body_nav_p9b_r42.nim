## P9B Round 4.2: exact monotone bucket queue and one-read cell costs.

import std/[algorithm, json, math, monotimes, options, os, strformat, times]
import ../src/ctf/[arena, br_map_pool]
import ../src/shell/[body_map, body_route_index]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r31
import investigate_body_nav_p9b_r33

const
  Samples = 15
  ClosedBit = 0x8000_0000'u32

type
  BucketEntry* = object
    f*: int32
    g*: int32
    node*: int32
    insertion*: uint64

  DialQueue* = object
    width*, bucketCount*, len*: int
    currentQuotient*: int64
    nextInsertion*: uint64
    buckets*: seq[seq[BucketEntry]]
    touched*: seq[int32]

  DialWorkspace* = object
    generation*: uint32
    g*, parent*, parentBridge*, goalCost*: seq[int32]
    state*, goalStamp*: seq[uint32]
    queue*: DialQueue

  DialResult* = object
    reached*: bool
    pops*: int
    route*: seq[BodyPoint]

  DialJob* = object
    active*, complete*: bool
    generation*: uint32
    blockedCell*, startNode*, goalNode*: int
    allowance*: int32
    bestNode*: int
    bestCost*: int32
    pops*: int
    item*: NavCorpusCase

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc percentileInt(values: openArray[int64], fraction: float64): int64 =
  if values.len == 0: return high(int64)
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high, max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc begin(queue: var DialQueue) =
  for raw in queue.touched:
    queue.buckets[raw.int].setLen(0)
  queue.touched.setLen(0)
  queue.len = 0
  queue.currentQuotient = high(int64)
  queue.nextInsertion = 0

proc push(queue: var DialQueue, f, g, node: int32) {.inline.} =
  let
    quotient = f.int64 div queue.width
    slot = int(quotient mod queue.bucketCount)
  if queue.buckets[slot].len == 0:
    queue.touched.add int32(slot)
  queue.buckets[slot].add BucketEntry(
    f: f, g: g, node: node, insertion: queue.nextInsertion)
  inc queue.nextInsertion
  inc queue.len
  queue.currentQuotient = min(queue.currentQuotient, quotient)

proc pop(queue: var DialQueue): BucketEntry =
  while queue.len > 0:
    let slot = int(queue.currentQuotient mod queue.bucketCount)
    var best = -1
    for offset, entry in queue.buckets[slot]:
      if entry.f.int64 div queue.width != queue.currentQuotient: continue
      if best < 0 or entry.f < queue.buckets[slot][best].f or
          (entry.f == queue.buckets[slot][best].f and
            entry.insertion < queue.buckets[slot][best].insertion):
        best = offset
    if best >= 0:
      result = queue.buckets[slot][best]
      queue.buckets[slot][best] = queue.buckets[slot][^1]
      queue.buckets[slot].setLen(queue.buckets[slot].len - 1)
      dec queue.len
      return
    inc queue.currentQuotient
  raise newException(IndexDefect, "pop from empty Dial queue")

proc newDialWorkspace*(count, width, maxEdgeCost: int): DialWorkspace =
  result.g = newSeq[int32](count)
  result.parent = newSeq[int32](count)
  result.parentBridge = newSeq[int32](count)
  result.goalCost = newSeq[int32](count)
  result.state = newSeq[uint32](count)
  result.goalStamp = newSeq[uint32](count)
  result.queue.width = width
  result.queue.bucketCount = max(2, (maxEdgeCost * 8 + width - 1) div width)
  result.queue.buckets = newSeq[seq[BucketEntry]](result.queue.bucketCount)

proc begin(workspace: var DialWorkspace) =
  inc workspace.generation
  if workspace.generation == 0 or
      (workspace.generation and ClosedBit) != 0:
    for stamp in workspace.state.mitems: stamp = 0
    for stamp in workspace.goalStamp.mitems: stamp = 0
    workspace.generation = 1
  workspace.queue.begin()

proc buildCombinedCellCost*(weights,
    hazardCost: openArray[int32]): seq[int32] =
  ## R3.3's incremental hazard overlay is armed but zero in this corpus. The
  ## retained Q16 factor is therefore the exact combined table, and every
  ## neighbour performs one table read.
  result = newSeq[int32](weights.len)
  for cell in 0 ..< weights.len:
    doAssert hazardCost[cell] == 0
    result[cell] = weights[cell]

proc stepCost(factor: int32, diagonal: bool): int32 {.inline.} =
  let base = if diagonal: 91'i64 else: 64'i64
  int32((base * factor.int64 + 32_768) shr 16)

proc maximumEdgeCost*(graph: MixedGraph, combined,
    hazard: openArray[int32]): int =
  var maximumCell = 1
  for cell in 0 ..< combined.len:
    maximumCell = max(maximumCell,
      max(stepCost(combined[cell], false).int,
        stepCost(combined[cell], true).int))
  var maximumBridge = 1
  for lengths in graph.bridgeLen:
    for length in lengths:
      maximumBridge = max(maximumBridge, length.int)
  maximumCell * maximumBridge

proc searchDial*(graph: MixedGraph, map: BodyMap, item: NavCorpusCase,
    refined: openArray[uint8], combined, hazardCost: openArray[int32],
    workspace: var DialWorkspace): DialResult =
  workspace.begin()
  let blockedCell = if item.blockedCell.isSome:
      item.blockedCell.get.y * map.gridWidth + item.blockedCell.get.x else: -1
  let
    generation = workspace.generation
    starts = graph.attachments(map, refined, combined, hazardCost,
      blockedCell, item.start)
    goals = graph.attachments(map, refined, combined, hazardCost,
      blockedCell, item.validatedGoal)
    startNode = if starts.len == 1 and starts[0].cost == 0: starts[0].node
      else: -1
    goalNode = if goals.len == 1 and goals[0].cost == 0: goals[0].node
      else: -1
    allowance = int32(PortalAnchorRingCells * NavCell * 23)
  if starts.len == 0 or goals.len == 0: return
  for goal in goals:
    if workspace.goalStamp[goal.node] != generation or
        goal.cost < workspace.goalCost[goal.node]:
      workspace.goalStamp[goal.node] = generation
      workspace.goalCost[goal.node] = goal.cost
  for start in starts:
    if workspace.state[start.node] != generation or
        start.cost < workspace.g[start.node]:
      workspace.g[start.node] = start.cost
      workspace.parent[start.node] = -1
      workspace.parentBridge[start.node] = -1
      let heuristic = max(0'i32, octileQ4(
        pointAt(start.node, graph.legality.width), item.validatedGoal, 90) -
        allowance)
      workspace.queue.push(start.cost + heuristic,
        start.cost, int32(start.node))
      workspace.state[start.node] = generation
  var
    bestNode = -1
    bestCost = high(int32)
  while workspace.queue.len > 0:
    let entry = workspace.queue.pop()
    let node = entry.node.int
    if workspace.state[node] != generation or workspace.g[node] != entry.g:
      continue
    if entry.f >= bestCost: break
    workspace.state[node] = generation or ClosedBit
    inc result.pops
    let currentG = workspace.g[node]
    if workspace.goalStamp[node] == generation:
      let total = currentG.int64 + workspace.goalCost[node].int64
      if total < bestCost.int64:
        bestCost = int32(total)
        bestNode = node
    let
      fineX = node mod graph.legality.width
      fineY = node div graph.legality.width
      legal = graph.legality.legal[node]
      fromPoint = pointAt(node, graph.legality.width)
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) != 0:
        let nextNode = (fineY + delta.y) * graph.legality.width +
          fineX + delta.x
        if graph.active(refined, nextNode, startNode, goalNode) and
            workspace.state[nextNode] != (generation or ClosedBit):
          let
            toPoint = pointAt(nextNode, graph.legality.width)
            cell = map.midpointCell(fromPoint, toPoint)
            baseCost = stepCost(combined[cell], direction >= 4)
            edgeCost = if cell == blockedCell: baseCost * 8 else: baseCost
            candidate = currentG + edgeCost
          if workspace.state[nextNode] != generation or
              candidate < workspace.g[nextNode]:
            workspace.g[nextNode] = candidate
            workspace.parent[nextNode] = int32(node)
            workspace.parentBridge[nextNode] = -1
            let heuristic = max(0'i32, octileQ4(toPoint,
              item.validatedGoal, 90) - allowance)
            workspace.queue.push(candidate + heuristic,
              candidate, int32(nextNode))
            workspace.state[nextNode] = generation
      if graph.anchorNode[node] == 0: continue
      let sourceCell = graph.cellForNode[node].int
      let
        offset = graph.bridgeOffset[sourceCell][direction].int
        pathLen = graph.bridgeLen[sourceCell][direction].int
      if offset < 0 or pathLen == 0: continue
      let target = graph.bridgeNodes[offset + pathLen - 1].int
      if workspace.state[target] == (generation or ClosedBit): continue
      var
        edgeCost = 0'i32
        previous = fromPoint
      for pathIndex in 0 ..< pathLen:
        let nextPoint = pointAt(graph.bridgeNodes[offset + pathIndex].int,
          graph.legality.width)
        let
          dx = abs(nextPoint.x - previous.x)
          dy = abs(nextPoint.y - previous.y)
          cell = map.midpointCell(previous, nextPoint)
          baseCost = stepCost(combined[cell], dx != 0 and dy != 0)
        let priced = if cell == blockedCell: baseCost * 8 else: baseCost
        edgeCost += priced
        previous = nextPoint
      let candidate = currentG + edgeCost
      if workspace.state[target] != generation or
          candidate < workspace.g[target]:
        workspace.g[target] = candidate
        workspace.parent[target] = int32(node)
        workspace.parentBridge[target] = int32(sourceCell * 8 + direction)
        let heuristic = max(0'i32, octileQ4(previous,
          item.validatedGoal, 90) - allowance)
        workspace.queue.push(candidate + heuristic,
          candidate, int32(target))
        workspace.state[target] = generation
  if bestNode >= 0:
    result.reached = true
    var cursor = bestNode
    while cursor >= 0:
      result.route.add pointAt(cursor, graph.legality.width)
      let bridgeId = workspace.parentBridge[cursor].int
      if bridgeId >= 0:
        let
          cell = bridgeId div 8
          direction = bridgeId mod 8
          offset = graph.bridgeOffset[cell][direction].int
          pathLen = graph.bridgeLen[cell][direction].int
        if pathLen > 1:
          for pathIndex in countdown(pathLen - 2, 0):
            result.route.add pointAt(
              graph.bridgeNodes[offset + pathIndex].int,
              graph.legality.width)
      cursor = workspace.parent[cursor].int
    result.route.reverse()
    if result.route[0] != item.start: result.route.insert(item.start, 0)
    if result.route[^1] != item.validatedGoal:
      result.route.add item.validatedGoal

proc startDialJob*(job: var DialJob, graph: MixedGraph, map: BodyMap,
    item: NavCorpusCase, refined: openArray[uint8], combined,
    hazardCost: openArray[int32], workspace: var DialWorkspace) =
  workspace.begin()
  job = DialJob(active: true, generation: workspace.generation,
    bestNode: -1, bestCost: high(int32), item: item)
  job.blockedCell = if item.blockedCell.isSome:
      item.blockedCell.get.y * map.gridWidth + item.blockedCell.get.x else: -1
  let
    starts = graph.attachments(map, refined, combined, hazardCost,
      job.blockedCell, item.start)
    goals = graph.attachments(map, refined, combined, hazardCost,
      job.blockedCell, item.validatedGoal)
  job.startNode = if starts.len == 1 and starts[0].cost == 0: starts[0].node
    else: -1
  job.goalNode = if goals.len == 1 and goals[0].cost == 0: goals[0].node
    else: -1
  job.allowance = int32(PortalAnchorRingCells * NavCell * 23)
  if starts.len == 0 or goals.len == 0:
    job.complete = true
    return
  for goal in goals:
    if workspace.goalStamp[goal.node] != job.generation or
        goal.cost < workspace.goalCost[goal.node]:
      workspace.goalStamp[goal.node] = job.generation
      workspace.goalCost[goal.node] = goal.cost
  for start in starts:
    if workspace.state[start.node] != job.generation or
        start.cost < workspace.g[start.node]:
      workspace.g[start.node] = start.cost
      workspace.parent[start.node] = -1
      workspace.parentBridge[start.node] = -1
      let heuristic = max(0'i32, octileQ4(
        pointAt(start.node, graph.legality.width), item.validatedGoal, 90) -
        job.allowance)
      workspace.queue.push(start.cost + heuristic,
        start.cost, int32(start.node))
      workspace.state[start.node] = job.generation

proc stepDialJob*(job: var DialJob, graph: MixedGraph, map: BodyMap,
    refined: openArray[uint8], combined, hazardCost: openArray[int32],
    workspace: var DialWorkspace, popBudget: int): int =
  if not job.active or job.complete: return
  while result < popBudget and workspace.queue.len > 0:
    let entry = workspace.queue.pop()
    inc result
    let node = entry.node.int
    if workspace.state[node] != job.generation or workspace.g[node] != entry.g:
      continue
    if entry.f >= job.bestCost:
      job.complete = true
      break
    workspace.state[node] = job.generation or ClosedBit
    inc job.pops
    let currentG = workspace.g[node]
    if workspace.goalStamp[node] == job.generation:
      let total = currentG.int64 + workspace.goalCost[node].int64
      if total < job.bestCost.int64:
        job.bestCost = int32(total)
        job.bestNode = node
    let
      fineX = node mod graph.legality.width
      fineY = node div graph.legality.width
      legal = graph.legality.legal[node]
      fromPoint = pointAt(node, graph.legality.width)
    for direction, delta in NavNeighbors:
      if (legal and uint8(1 shl direction)) != 0:
        let nextNode = (fineY + delta.y) * graph.legality.width +
          fineX + delta.x
        if graph.active(refined, nextNode, job.startNode, job.goalNode) and
            workspace.state[nextNode] != (job.generation or ClosedBit):
          let
            toPoint = pointAt(nextNode, graph.legality.width)
            cell = map.midpointCell(fromPoint, toPoint)
            baseCost = stepCost(combined[cell], direction >= 4)
            edgeCost = if cell == job.blockedCell: baseCost * 8 else: baseCost
            candidate = currentG + edgeCost
          if workspace.state[nextNode] != job.generation or
              candidate < workspace.g[nextNode]:
            workspace.g[nextNode] = candidate
            workspace.parent[nextNode] = int32(node)
            workspace.parentBridge[nextNode] = -1
            let heuristic = max(0'i32, octileQ4(toPoint,
              job.item.validatedGoal, 90) - job.allowance)
            workspace.queue.push(candidate + heuristic,
              candidate, int32(nextNode))
            workspace.state[nextNode] = job.generation
      if graph.anchorNode[node] == 0: continue
      let sourceCell = graph.cellForNode[node].int
      let
        offset = graph.bridgeOffset[sourceCell][direction].int
        pathLen = graph.bridgeLen[sourceCell][direction].int
      if offset < 0 or pathLen == 0: continue
      let target = graph.bridgeNodes[offset + pathLen - 1].int
      if workspace.state[target] == (job.generation or ClosedBit): continue
      var
        edgeCost = 0'i32
        previous = fromPoint
      for pathIndex in 0 ..< pathLen:
        let nextPoint = pointAt(graph.bridgeNodes[offset + pathIndex].int,
          graph.legality.width)
        let
          dx = abs(nextPoint.x - previous.x)
          dy = abs(nextPoint.y - previous.y)
          cell = map.midpointCell(previous, nextPoint)
          baseCost = stepCost(combined[cell], dx != 0 and dy != 0)
          priced = if cell == job.blockedCell: baseCost * 8 else: baseCost
        edgeCost += priced
        previous = nextPoint
      let candidate = currentG + edgeCost
      if workspace.state[target] != job.generation or
          candidate < workspace.g[target]:
        workspace.g[target] = candidate
        workspace.parent[target] = int32(node)
        workspace.parentBridge[target] = int32(sourceCell * 8 + direction)
        let heuristic = max(0'i32, octileQ4(previous,
          job.item.validatedGoal, 90) - job.allowance)
        workspace.queue.push(candidate + heuristic,
          candidate, int32(target))
        workspace.state[target] = job.generation
  if workspace.queue.len == 0:
    job.complete = true

proc finishDialJob*(job: DialJob, graph: MixedGraph,
    workspace: DialWorkspace): DialResult =
  result.pops = job.pops
  if not job.complete or job.bestNode < 0: return
  result.reached = true
  var cursor = job.bestNode
  while cursor >= 0:
    result.route.add pointAt(cursor, graph.legality.width)
    let bridgeId = workspace.parentBridge[cursor].int
    if bridgeId >= 0:
      let
        cell = bridgeId div 8
        direction = bridgeId mod 8
        offset = graph.bridgeOffset[cell][direction].int
        pathLen = graph.bridgeLen[cell][direction].int
      if pathLen > 1:
        for pathIndex in countdown(pathLen - 2, 0):
          result.route.add pointAt(
            graph.bridgeNodes[offset + pathIndex].int,
            graph.legality.width)
    cursor = workspace.parent[cursor].int
  result.route.reverse()
  if result.route[0] != job.item.start:
    result.route.insert(job.item.start, 0)
  if result.route[^1] != job.item.validatedGoal:
    result.route.add job.item.validatedGoal

proc profile(pool: JsonNode, corpus: NavCorpus, id: string): JsonNode =
  let
    item = corpus.findCase(id)
    map = pool.loadMap(item.poolIndex)
    graph = map.buildMixedGraph()
    danger = map.buildOracleDanger(item)
    refined = graph.buildRefined(map.buildHot(danger))
    weights = danger.buildWeights(item.profile)
    hazard = newSeq[int32](map.gridWidth * map.gridHeight)
    combined = buildCombinedCellCost(weights, hazard)
    maxEdge = graph.maximumEdgeCost(combined, hazard)
  var rows = newJArray()
  for width in [1, 16]:
    var
      workspace = newDialWorkspace(graph.nodeCount, width, maxEdge)
      samplesNs, samplesPops, nsPerPop: seq[int64]
      routeHash = 0'u64
    for _ in 0 ..< Samples:
      let started = getMonoTime()
      let found = graph.searchDial(map, item, refined, combined, hazard,
        workspace)
      let elapsed = (getMonoTime() - started).inNanoseconds
      doAssert found.reached and map.routeLegal(item, found.route)
      samplesNs.add elapsed
      samplesPops.add found.pops.int64
      nsPerPop.add elapsed div max(1, found.pops).int64
      for point in found.route:
        routeHash = routeHash * 1_099_511_628_211'u64 xor
          uint64(point.x * 65537 + point.y)
    rows.add %*{"bucket_width_q4": width,
      "bucket_count": workspace.queue.bucketCount,
      "queue_bucket_headers_bytes": workspace.queue.bucketCount * sizeof(seq[BucketEntry]),
      "max_edge_cost_q4": maxEdge,
      "query_ns_p50": percentileInt(samplesNs, 0.50),
      "query_ns_p95": percentileInt(samplesNs, 0.95),
      "pops_p50": percentileInt(samplesPops, 0.50),
      "pops_p95": percentileInt(samplesPops, 0.95),
      "ns_per_pop_p50": percentileInt(nsPerPop, 0.50),
      "ns_per_pop_p95": percentileInt(nsPerPop, 0.95),
      "route_hash": routeHash}
  %*{"id": id, "rows": rows}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r42 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r42", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "combined_table_bytes_per_cell": sizeof(int32),
    "profiles": [
      pool.profile(corpus, "m09-br-gen-21450-r32-s9-default-blocked-far"),
      pool.profile(corpus, "m15-br-gen-22010-r16-s15-default-danger-far")]})

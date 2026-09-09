## P9B Round 4.4: combined winner quality and memory qualification.

import std/[algorithm, json, math, monotimes, options, os, strformat, tables,
  times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_planner]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r31
import investigate_body_nav_p9b_r33
import investigate_body_nav_p9b_r42

type Accum = object
  inflations, pops, nanoseconds: seq[float64]
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

proc rowJson(accum: Accum): JsonNode =
  var worstP95, worstMax = 0.0
  for values in accum.strata.values:
    worstP95 = max(worstP95, percentile(values, 0.95))
    if values.len > 0: worstMax = max(worstMax, max(values))
  %*{"name": "R4.4 R3.3 plus Dial width 1",
    "missing": accum.missing, "illegal": accum.illegal,
    "overall_p95_inflation_pct": percentile(accum.inflations, 0.95),
    "overall_max_inflation_pct": max(accum.inflations),
    "worst_stratum_p95_inflation_pct": worstP95,
    "worst_stratum_max_inflation_pct": worstMax,
    "pops_p50": percentile(accum.pops, 0.50),
    "pops_p95": percentile(accum.pops, 0.95),
    "pops_max": max(accum.pops),
    "query_ns_p50": percentile(accum.nanoseconds, 0.50),
    "query_ns_p95": percentile(accum.nanoseconds, 0.95)}

proc measureQuality(pool: JsonNode, corpus: NavCorpus): JsonNode =
  var accum: Accum
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"R4.4 quality map {poolIndex + 1}/{pool.len}"
    let
      map = pool.loadMap(poolIndex)
      graph = map.buildMixedGraph()
      hazard = newSeq[int32](map.gridWidth * map.gridHeight)
    var
      dangerByHash = initTable[string, BodyDangerField]()
      weightsByKey = initTable[string, seq[int32]]()
      mapMaxEdge = 1
    for item in corpus.cases:
      if item.poolIndex != poolIndex: continue
      if item.dangerHash notin dangerByHash:
        dangerByHash[item.dangerHash] = map.buildOracleDanger(item)
      let key = item.dangerHash & "/" & $item.profile
      if key notin weightsByKey:
        weightsByKey[key] = dangerByHash[item.dangerHash].buildWeights(item.profile)
      mapMaxEdge = max(mapMaxEdge,
        graph.maximumEdgeCost(weightsByKey[key], hazard))
    var workspace = newDialWorkspace(graph.nodeCount, 1, mapMaxEdge)
    for item in corpus.cases:
      if item.poolIndex != poolIndex: continue
      let
        danger = dangerByHash[item.dangerHash]
        key = item.dangerHash & "/" & $item.profile
        weights = weightsByKey[key]
        refined = graph.buildRefined(map.buildHot(danger))
        started = getMonoTime()
        found = graph.searchDial(map, item, refined, weights, hazard, workspace)
        elapsed = (getMonoTime() - started).inNanoseconds.float
      if not found.reached:
        inc accum.missing
        continue
      if not map.routeLegal(item, found.route):
        inc accum.illegal
        continue
      let inflation = routeInflationPct(
        oracleFloatCost(resampleRoute4px(found.route), map, danger,
          item.profile.corpusProfile, item.blockedCell), item.oracleCost)
      let stratum = &"r{item.rosterSize}/{item.profile}/{item.dynamic}/{item.distance}"
      accum.inflations.add inflation
      accum.strata.mgetOrPut(stratum, @[]).add inflation
      accum.pops.add found.pops.float
      accum.nanoseconds.add elapsed
  accum.rowJson()

proc memoryRow(): JsonNode =
  stderr.writeLine "R4.4 colossal memory"
  let
    map = colossalMap()
    graph = map.buildMixedGraph()
    nodes = graph.nodeCount
    navCells = map.gridWidth * map.gridHeight
    denseWorkspace = nodes * (sizeof(int32) * 4 + sizeof(uint32) * 2)
    legality = graph.legality.legal.len + graph.legality.standable.len
    int32PerSeat = navCells * sizeof(int32)
    int16PerSeat = navCells * sizeof(int16)
    int16AllSeats = int16PerSeat * 32
    compactSharedAllowance = 32 * 1024 * 1024 - legality - int16AllSeats
  %*{"map": "size:colossal", "fine_nodes": nodes,
    "nav_cells": navCells,
    "fine_legality_bytes": legality,
    "dense_workspace_bytes": denseWorkspace,
    "int32_weight_bytes_per_seat": int32PerSeat,
    "int32_weight_bytes_32_seats": int32PerSeat * 32,
    "int16_weight_bytes_per_seat": int16PerSeat,
    "int16_weight_bytes_32_seats": int16AllSeats,
    "smallest_fit": {
      "fine_legality_bytes": legality,
      "int16_8px_weight_bytes_32_seats": int16AllSeats,
      "maximum_compact_shared_workspace_and_topology_bytes": compactSharedAllowance,
      "requires": "drop dense full-board workspace and obsolete hierarchical portal next-hop/segment-cell fields"
    },
    "cap_bytes": 32 * 1024 * 1024,
    "caps_changed": false}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r44 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r44", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "quality": pool.measureQuality(corpus),
    "colossal_memory": memoryRow()})

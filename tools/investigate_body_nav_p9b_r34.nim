## P9B Round 3.4: deterministic per-tick query admission.

import std/[algorithm, json, math, monotimes, os, strformat, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_nav]
import ../tests/nav_route_corpus_support
import investigate_body_nav_p9b_r33

const
  WarmupWaves = 3
  SampleWaves = 30
  BodyP95LimitNs = 4_000_000'i64
  BodyMaxLimitNs = 5_000_000'i64

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc percentile(values: openArray[int64], fraction: float64): int64 =
  if values.len == 0: return high(int64)
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high,
    max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc measureBudget(pool: JsonNode, corpus: NavCorpus,
    rosterSize, queryBudget: int): JsonNode =
  let
    item = corpus.findCase(
      "m15-br-gen-22010-r16-s15-default-danger-far")
    map = pool.loadMap(item.poolIndex)
    graph = map.buildMixedGraph()
    danger = map.buildOracleDanger(item)
    hot = map.buildHot(danger)
    refined = graph.buildRefined(hot)
    weights = danger.buildWeights(item.profile)
    hazardCost = newSeq[int32](map.gridWidth * map.gridHeight)
    nav = newBodyNavSystem(map, rosterSize, GunRange)
  for seat in nav.seats:
    seat.danger = danger
  var
    workspace = newWorkspace(graph.nodeCount)
    bodySlices: seq[int64]
    routeTicks: seq[int]
    firstAdmission = newSeq[int](rosterSize)
    checksum = 0'u64
  for wave in 0 ..< WarmupWaves + SampleWaves:
    var
      pending = newSeq[bool](rosterSize)
      waypoints = newSeq[BodyPoint](rosterSize)
    for seat in 0 ..< rosterSize:
      pending[seat] = true
      waypoints[seat] = item.validatedGoal
    let ticksNeeded = (rosterSize + queryBudget - 1) div queryBudget
    for tick in 1 .. ticksNeeded:
      let started = getMonoTime()
      var admitted = 0
      for seat in 0 ..< rosterSize:
        if pending[seat] and admitted < queryBudget:
          let found = graph.search(map, item, refined, weights,
            hazardCost, workspace)
          doAssert found.reached and found.route.len >= 2
          pending[seat] = false
          waypoints[seat] = found.route[1]
          inc admitted
          checksum = checksum xor uint64(found.pops + seat + tick)
          if wave == 0: firstAdmission[seat] = tick
          if wave >= WarmupWaves: routeTicks.add tick
        elif pending[seat]:
          checksum = checksum xor uint64(nav.steeringMask(seat, item.start,
            item.validatedGoal, item.profile.corpusProfile, tick))
        else:
          checksum = checksum xor uint64(octantToward(item.start,
            waypoints[seat]))
      let elapsed = (getMonoTime() - started).inNanoseconds
      doAssert admitted == queryBudget
      if wave >= WarmupWaves: bodySlices.add elapsed
  let
    p50 = percentile(bodySlices, 0.50)
    p95 = percentile(bodySlices, 0.95)
    maximum = max(bodySlices)
    worstRouteTick = max(routeTicks)
  %*{"roster_size": rosterSize, "query_budget": queryBudget,
    "warmup_waves": WarmupWaves, "sample_waves": SampleWaves,
    "sample_ticks": bodySlices.len,
    "body_slice_p50_ns": p50, "body_slice_p95_ns": p95,
    "body_slice_max_ns": maximum,
    "body_slice_p95_limit_ns": BodyP95LimitNs,
    "body_slice_max_limit_ns": BodyMaxLimitNs,
    "body_slice_pass": p95 <= BodyP95LimitNs and maximum <= BodyMaxLimitNs,
    "worst_time_to_route_ticks": worstRouteTick,
    "first_wave_admission_tick_by_seat": firstAdmission,
    "over_budget_behavior": "local steering toward the requested goal",
    "checksum": checksum}

when isMainModule:
  if paramCount() != 1:
    quit("usage: investigate_body_nav_p9b_r34 CORPUS", 2)
  let
    corpus = loadNavRouteCorpus(paramStr(1))
    pool = loadBrS2PoolRaw()
  var rows = newJArray()
  for queryBudget in [2, 4, 8]:
    for rosterSize in [16, 32]:
      stderr.writeLine &"R3.4 K={queryBudget} roster={rosterSize}"
      rows.add pool.measureBudget(corpus, rosterSize, queryBudget)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r34", "v": 1,
    "platform": hostOS & "/" & hostCPU,
    "scenario": "simultaneous far-danger first-goal requests",
    "rows": rows})

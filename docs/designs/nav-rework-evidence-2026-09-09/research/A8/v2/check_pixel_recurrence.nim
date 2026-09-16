## A8 counts only. Every call executes the production search; no caching.
include ../src/shell/body_route_index
import std/json
import ../src/ctf/[arena, br_map_pool, sim_types]

proc inspect(label: string, gameMap: CtfMap): JsonNode =
  pixelRecurrenceSeen.clear()
  pixelRecurrenceWeakSeen.clear()
  pixelRecurrenceStages.setLen(0)
  pixelRecurrenceDequeues = 0
  pixelRecurrenceCalls.setLen(0)
  let map = newBodyMap(gameMap)
  let index = newBodyRouteIndex(map)
  var stages = newJArray()
  for stage, row in pixelRecurrenceStages:
    stages.add %*{"scratch": stage, "calls": row.calls, "dequeues": row.dequeues,
      "distinct_keys": row.distinctKeys, "key_payload_bytes": row.keyBytes,
      "outcomes_failed_reached_empty_success": row.outcomes,
      "outcome_dequeues": row.outcomeDequeues,
      "repeated_outcomes": row.repeats, "repeated_dequeues": row.repeatedDequeues,
      "exact_key_result_mismatches": row.mismatches,
      "exact_key_dequeue_mismatches": row.dequeueMismatches,
      "weak_key_repeats": row.weakRepeats, "weak_key_result_mismatches": row.weakMismatches}
    doAssert row.mismatches == 0 and row.dequeueMismatches == 0
  var calls = newJArray()
  for call in pixelRecurrenceCalls:
    calls.add %*{"stage": call.stage, "key": call.key, "weak_key": call.weakKey,
      "category": call.category, "dequeues": call.dequeues, "target_count": call.targetCount}
  %*{"map": label, "stages": stages, "calls": calls, "retained_index_bytes": index.stats.retainedBytes,
    "pockets": index.pockets.len, "segments": index.segments.len, "arcs": index.arcs.len}

var rows = newJArray()
let pool = loadBrS2PoolRaw()
for i in 0 ..< pool.len:
  stderr.writeLine "pool:", i
  rows.add inspect("pool:" & $i, mapFromSpecJson($pool[i]["spec"]))
let configured = parseJson(readFile(BrS2SoloMapPoolPath))
for i in 0 ..< configured.len:
  stderr.writeLine "configured:", i
  rows.add inspect("configured:" & $i, mapFromSpecJson($configured[i]))
stderr.writeLine "colossal"
rows.add inspect("colossal", generateCtfMap(4242,
  MapGenOverrides(size: "colossal", windows: -1, pits: -1, pitDensity: -1), 4))
echo %*{"diagnostic": "A8-exact-input-recurrence-v2", "always_executes_raw": true, "maps": rows}

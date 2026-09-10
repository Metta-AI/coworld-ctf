## Fixed-map constructor comparison. No profiling or counters in timed builds.
include ../src/shell/body_route_index
import std/[json, monotimes, os, strutils, times]
import ../src/ctf/[arena, br_map_pool]

const IndexArmLabel {.strdefine.} = "unspecified"
let pool = loadBrS2PoolRaw()
let poolIndex = parseInt(paramStr(1))
let repeats = parseInt(paramStr(2))
let map = newBodyMap(mapFromSpecJson($pool[poolIndex]["spec"]))
var samples: seq[int64]
var retained: seq[int64]
var transient: seq[int64]
for repeat in 0 ..< repeats:
  let started = getMonoTime()
  let index = newBodyRouteIndex(map)
  samples.add (getMonoTime() - started).inNanoseconds
  retained.add index.stats.retainedBytes
  transient.add index.stats.transientPeakBytes
var output = %*{"arm": IndexArmLabel, "map": map.name,
  "pool_index": poolIndex, "samples_ns": samples,
  "retained_bytes": retained, "transient_peak_bytes": transient}
when defined(pixelStandabilityCounters):
  output["pixel_standability"] = %*{
    "searches": pixelStandability.searches,
    "read_requests": pixelStandability.readRequests,
    "can_stand_evaluations": pixelStandability.canStandEvaluations,
    "eager_fills": pixelStandability.eagerFills}
echo output

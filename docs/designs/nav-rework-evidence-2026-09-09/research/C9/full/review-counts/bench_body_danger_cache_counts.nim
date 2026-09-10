## C2 mechanism timing: public danger rebuild, separated reuse regimes.
## This is not a whole-body acceptance gate. Counters are optional diagnostics.
import std/[json, monotimes, random, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_nav]

proc run(label: string; gameMap: CtfMap; gunRange: int): JsonNode =
  let map = newBodyMap(gameMap)
  var points: seq[BodyPoint]
  for y in countup(0, map.height - 1, 32):
    for x in countup(0, map.width - 1, 32):
      if map.canStand((x, y)): points.add((x, y))
  result = newJArray()
  for regime in ["changing_sources", "repeated_sources"]:
    let nav = newBodyNavSystem(map, 1, gunRange, prepareRouteQueries = false)
    var rng = initRand(401)
    var samples = newJArray()
    var input = DangerInput(selfXy: points[rng.rand(points.high)])
    for sample in 0 ..< 192:
      if sample == 0 or regime == "changing_sources":
        input.candidates.setLen(0)
        for source in 0 ..< 8:
          input.candidates.add DangerCandidate(seatIndex: source,
            pos: points[rng.rand(points.high)])
      let started = getMonoTime()
      nav.seats[0].rebuildDanger(map, input, sample)
      let elapsed = (getMonoTime() - started).inNanoseconds
      samples.add %elapsed
    var row = %*{"map": label, "range_px": gunRange, "regime": regime,
      "rebuilds": samples.len, "sources_per_rebuild": 8,
      "samples_ns": samples, "raster_fingerprint": $nav.seats[0].dangerFingerprint}
    when declared(dangerSourceCacheCounters):
      let counts = nav.dangerSourceCacheCounters
      row["hits"] = %counts.hits
      row["misses"] = %counts.misses
      row["conversions"] = %counts.conversions
    result.add row

var rows = newJArray()
for name in ["br-gen-5204", "br-gen-5263", "br-gen-5001"]:
  stderr.writeLine name
  for row in run(name, getBrMap(name), 1300): rows.add row
for row in run("colossal", generateCtfMap(4242,
  MapGenOverrides(size: "colossal", windows: -1, pits: -1, pitDensity: -1), 4), 1300): rows.add row
echo %*{"rows": rows, "whole_body_acceptance": false,
  "note": "Changing sources are not assumed to be all misses; inspect actual counters."}

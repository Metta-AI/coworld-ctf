## A8 full field-value identity: includes every retained sequence, not padding.
include ../src/shell/body_route_index
import std/json
import crunchy/[common, sha256]
import ../src/ctf/[arena, br_map_pool, sim_types]

proc inspect(label: string, gameMap: CtfMap): JsonNode =
  let map = newBodyMap(gameMap)
  let index = newBodyRouteIndex(map)
  var arrays = newJObject()
  for name, value in fieldPairs(index[]):
    when value is seq:
      arrays[name] = %*{"length": value.len,
        "field_values_sha256": sha256($(%value)).toHex()}
  var stats = newJObject()
  for name, value in fieldPairs(index.stats):
    when name != "transientPeakBytes":
      stats[name] = %value
  %*{"map": label, "arrays": arrays, "stats": stats,
    "transient_peak_bytes": index.stats.transientPeakBytes}

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
echo %*{"protocol": "all-retained-sequence-field-values-and-stats", "maps": rows}

## C6 tools-only replay microbench (DIAGNOSTIC, includes body_nav for the
## private replayVisibleCells). Build once per arm:
##   parent:    nim c -d:release ... tools/bench_danger_replay.nim
##   candidate: build against the candidate snapshot (or -d:DangerReplayFullWords=true
##   on the screen source) and pass -d:DangerReplayArmLabel=candidate
## Usage: bench_danger_replay <map-name> <gunRangePx> <origin-stride> <batches> <repeats>
## Every selected origin is warmed (miss path) OUTSIDE timing. A batch clears
## the raster (untimed), then times `repeats` replayVisibleCells calls over
## the whole sample set, then hashes the raster (untimed). Reports ns per
## replay per batch, the median, and a direct per-cell comparison of one
## replay against the per-set-bit reference formula. No clocks inside the
## replay. No counters.
include ../src/shell/body_nav

## Tools-only arm label for JSON metadata (the native runner passes
## -d:DangerReplayArmLabel=parent|candidate); independent of any production
## define so the tool builds against materialized snapshots unchanged.
const DangerReplayArmLabel {.strdefine.} = "unspecified"
import std/[os, strutils, json, monotimes, times, hashes, algorithm, bitops]
import ../src/ctf/[br_map_pool, sim_types]

proc referenceReplay(seat: BodyNavSeat, origin: BodyPoint, base: int,
    into: var seq[float32]) =
  ## The C2 per-set-bit formula, independent of the arm under test.
  let cache = seat.dangerSourceCache
  let radius = seat.dangerGeometry.radius
  let diameter = radius * 2 + 1
  let gridW = seat.danger.gridW
  for wordIndex in 0 ..< cache.words:
    var word = cache.bits[base + wordIndex]
    while word != 0:
      let k = wordIndex * 64 + countTrailingZeroBits(word)
      let ky = k div diameter
      let kx = k - ky * diameter
      into[(origin.y - radius + ky) * gridW + origin.x - radius + kx] +=
        seat.dangerGeometry.kernel[k]
      word = word and (word - 1)

proc rasterHash(values: seq[float32]): string =
  var h: Hash = 0
  for v in values: h = h !& hash(cast[uint32](v))
  toHex(int64(!$h), 16)

proc main() =
  if paramCount() != 5:
    quit("usage: bench_danger_replay <map> <range> <stride> <batches> <repeats>", 2)
  let
    mapName = paramStr(1)
    rangePx = parseInt(paramStr(2))
    stride = parseInt(paramStr(3))
    batches = parseInt(paramStr(4))
    repeats = parseInt(paramStr(5))
    map = newBodyMap(getBrMap(mapName))
    system = newBodyNavSystem(map, 1, rangePx, prepareRouteQueries = false)
    seat = system.seats[0]
    cache = seat.dangerSourceCache
  # v2 sampling: collect EVERY stride-selected cell whose centre is standable
  # (raster order), then keep at most DangerSourceCacheSlots of them at evenly
  # spaced indices including both ends, so the retained sample spans the whole
  # map instead of its top edge. At most one origin per slot keeps every
  # warmed bitmap resident (no eviction inside the timed loop). All selection
  # happens outside timing and the chosen coordinates are recorded below.
  var candidates: seq[BodyPoint]
  var n = 0
  for cy in 0 ..< map.gridHeight:
    for cx in 0 ..< map.gridWidth:
      inc n
      if n mod stride != 0: continue
      let center = cellCenter((cx, cy))
      if map.canStand(center): candidates.add center
  var origins: seq[BodyPoint]
  let keep = min(DangerSourceCacheSlots, candidates.len)
  for i in 0 ..< keep:
    let index = if keep == 1: 0 else: (i * (candidates.len - 1)) div (keep - 1)
    origins.add candidates[index]
  # Warm: one miss rebuild per origin (outside timing).
  var bases: seq[int]
  for p in origins:
    seat.selectedDangerPoints[0] = p; seat.selectedDangerCount = 1
    seat.rebuildSelectedDanger(map, 0)
    let o = map.cellOf(p)
    let slot = cache.sourceCacheSlot(int32(o.y * map.gridWidth + o.x))
    doAssert slot >= 0
    bases.add slot * cache.words
  doAssert bases.len == origins.len
  # Counts only: classify each nonempty four-cell group before optimization.
  var occupancy: array[5, int]
  var safeGroups, fallbackGroups, safeSetBits, fallbackSetBits: int
  var checkedIndices = 0
  let radius = seat.dangerGeometry.radius
  let diameter = radius * 2 + 1
  for i, p in origins:
    let origin = map.cellOf(p)
    for w in 0 ..< cache.words:
      let word = cache.bits[bases[i] + w]
      for group in 0 ..< 16:
        let nibble = (word shr (group * 4)) and 15
        let population = countSetBits(nibble)
        inc occupancy[population]
        if population == 0: continue
        let k = w * 64 + group * 4
        let ky = k div diameter
        let kx = k mod diameter
        let gx = origin.x - radius + kx
        let gy = origin.y - radius + ky
        let safe = k + 3 < seat.dangerGeometry.kernel.len and
          kx + 3 < diameter and gx >= 0 and gx + 3 < seat.danger.gridW and
          gy >= 0 and gy < seat.danger.gridH
        if safe:
          inc safeGroups
          safeSetBits += population
        else:
          inc fallbackGroups
          fallbackSetBits += population
        for lane in 0 ..< 4:
          if (nibble and (1'u64 shl lane)) == 0: continue
          let scalarK = k + lane
          let scalarY = scalarK div diameter
          let scalarX = scalarK mod diameter
          let scalarIndex = (origin.y - radius + scalarY) * seat.danger.gridW +
            origin.x - radius + scalarX
          doAssert scalarIndex >= 0 and scalarIndex < seat.danger.values.len
          if safe:
            doAssert scalarIndex == gy * seat.danger.gridW + gx + lane
          inc checkedIndices
  var originList = newJArray()
  for p in origins: originList.add %*[p.x, p.y]
  echo %*{"map": map.name, "range_px": rangePx, "origins": origins.len,
    "origin_list": originList, "occupancy": occupancy,
    "safe_groups": safeGroups, "fallback_groups": fallbackGroups,
    "safe_set_bits": safeSetBits, "fallback_set_bits": fallbackSetBits,
    "checked_indices": checkedIndices}

main()

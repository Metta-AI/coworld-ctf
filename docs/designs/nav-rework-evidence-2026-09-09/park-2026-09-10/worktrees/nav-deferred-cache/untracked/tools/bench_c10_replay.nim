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
include c10_replay

## Tools-only arm label for JSON metadata (the native runner passes
## -d:DangerReplayArmLabel=parent|candidate); independent of any production
## define so the tool builds against materialized snapshots unchanged.
const DangerReplayArmLabel {.strdefine.} = "unspecified"
import std/[os, strutils, json, monotimes, times, hashes, algorithm, bitops]
import ../src/ctf/[br_map_pool, sim_types]

template replayArm(seat: BodyNavSeat, origin: BodyPoint, base: int) =
  when DangerReplayArmLabel == "simd":
    seat.replayFourCellGroups(origin, base, true)
  elif DangerReplayArmLabel == "scalar":
    seat.replayFourCellGroups(origin, base, false)
  else:
    seat.replayVisibleCells(origin, base)

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
  # Direct comparison: one replay per origin on a zero raster versus the
  # reference formula, every cell compared as float bits.
  var mismatches = 0; var setBits = 0; var fullWords = 0
  for i, p in origins:
    for v in seat.danger.values.mitems: v = 0
    var reference = newSeq[float32](seat.danger.values.len)
    seat.replayArm(map.cellOf(p), bases[i])
    seat.referenceReplay(map.cellOf(p), bases[i], reference)
    for c in 0 ..< reference.len:
      if cast[uint32](reference[c]) != cast[uint32](seat.danger.values[c]): inc mismatches
    for w in 0 ..< cache.words:
      let word = cache.bits[bases[i] + w]
      setBits += countSetBits(word)
      if word == high(uint64): inc fullWords
  doAssert mismatches == 0, "reference raster mismatch before timing"
  # Timed batches.
  var perReplayNs: seq[float]
  var batchHashes: seq[string]
  for batch in 0 ..< batches:
    for v in seat.danger.values.mitems: v = 0
    let started = getMonoTime()
    for r in 0 ..< repeats:
      for i, p in origins:
        seat.replayArm(map.cellOf(p), bases[i])
    let elapsed = (getMonoTime() - started).inNanoseconds
    perReplayNs.add elapsed.float / float(repeats * origins.len)
    batchHashes.add rasterHash(seat.danger.values)
  var sorted = perReplayNs; sorted.sort()
  var originsJson = newJArray()
  for p in origins:
    let cell = map.cellOf(p)
    originsJson.add %*{"px": [p.x, p.y], "cell": [cell.x, cell.y]}
  echo %*{"arm": DangerReplayArmLabel,
    "sampling": "v2-even-spread", "candidate_cells": candidates.len,
    "map": map.name, "grid": [map.gridWidth, map.gridHeight], "range_px": rangePx,
    "origins": origins.len, "origin_list": originsJson,
    "stride": stride, "batches": batches, "repeats": repeats,
    "set_bits_per_origin": setBits.float / origins.len.float,
    "full_words_per_origin": fullWords.float / origins.len.float,
    "reference_cell_mismatches": mismatches,
    "per_replay_ns_by_batch": perReplayNs,
    "per_replay_ns_median": sorted[sorted.len div 2],
    "per_replay_ns_min": sorted[0],
    "batch_raster_hashes": batchHashes}

main()

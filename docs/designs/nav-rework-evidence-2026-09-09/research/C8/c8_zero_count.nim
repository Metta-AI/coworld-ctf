## C8 count screen (read-only include of the frozen C2 cache source). For each
## replayed/recorded source bitmap, split set bits into kernel-zero and
## kernel-nonzero, per hit/miss (sequential per-source LRU classification as
## in the C6 count tool). Also reports the kernel's nonzero support: count,
## max |dx|,|dy|, and the bounding square, for the requested ranges.
include "/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-source-cache/src/shell/body_nav"
import std/[os, strutils, json, bitops, tables, math]
import "/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-source-cache/src/ctf/br_map_pool"
import "/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-source-cache/src/ctf/sim_types"

type Tally = object
  sources, setBits, zeroBits, nonzeroBits: int
  maxZeroPerSource, maxNonzeroPerSource: int

proc scanSlot(cache: DangerSourceCache, slot: int, kernel: seq[float32], t: var Tally) =
  inc t.sources
  var z = 0; var nz = 0
  for w in 0 ..< cache.words:
    var word = cache.bits[slot * cache.words + w]
    while word != 0:
      let k = w * 64 + countTrailingZeroBits(word)
      if kernel[k] == 0'f32: inc z else: inc nz
      word = word and (word - 1)
  t.setBits += z + nz; t.zeroBits += z; t.nonzeroBits += nz
  t.maxZeroPerSource = max(t.maxZeroPerSource, z)
  t.maxNonzeroPerSource = max(t.maxNonzeroPerSource, nz)

proc tallyJson(t: Tally): JsonNode =
  %*{"sources": t.sources, "set_bits": t.setBits, "zero_kernel_bits": t.zeroBits,
     "nonzero_kernel_bits": t.nonzeroBits,
     "zero_share": (if t.setBits > 0: t.zeroBits.float / t.setBits.float else: 0.0),
     "max_zero_per_source": t.maxZeroPerSource,
     "max_nonzero_per_source": t.maxNonzeroPerSource}

proc kernelSupport(rangePx: int): JsonNode =
  ## Exact nonzero support of the production kernel at this range.
  let map = newBodyMap(getBrMap("br-gen-5120"))
  let system = newBodyNavSystem(map, 1, rangePx, prepareRouteQueries = false)
  let g = system.seats[0].dangerGeometry
  let d = g.radius * 2 + 1
  var nonzero = 0; var maxAbs = 0; var minVal = high(float32); var negative = 0; var nonfinite = 0
  for dy in -g.radius .. g.radius:
    for dx in -g.radius .. g.radius:
      let v = g.kernel[(dy + g.radius) * d + dx + g.radius]
      if v < 0: inc negative
      if v != v or v == Inf: inc nonfinite
      if v != 0'f32:
        inc nonzero; maxAbs = max(maxAbs, max(abs(dx), abs(dy))); minVal = min(minVal, v)
  let cutoffCells = min(DangerLosRangePx, rangePx) div NavCell
  %*{"range_px": rangePx, "radius_cells": g.radius, "box_cells": d * d,
     "nonzero_kernel_cells": nonzero, "max_abs_offset_nonzero": maxAbs,
     "square_bound_cells": (2 * maxAbs + 1) * (2 * maxAbs + 1),
     "predicted_max_abs_offset": cutoffCells,
     "min_nonzero_value": minVal, "negative_values": negative, "nonfinite_values": nonfinite,
     "perimeter_offsets": g.perimeter.len}

proc replayTrace(path, mapName: string, seats, rangePx: int): JsonNode =
  let map = newBodyMap(getBrMap(mapName))
  let system = newBodyNavSystem(map, seats, rangePx, prepareRouteQueries = false)
  let kernel = system.seats[0].dangerGeometry.kernel
  var hitT, missT: Tally
  for raw in lines(path):
    if not raw.startsWith("NAVSRC sched "): continue
    var kv = initTable[string, string]()
    for token in raw[13 .. ^1].split(' '):
      let eq = token.find('=')
      if eq > 0: kv[token[0 ..< eq]] = token[eq + 1 .. ^1]
    if kv["changed"] != "1": continue
    let seat = parseInt(kv["seat"]); let count = parseInt(kv["n"])
    var points: seq[BodyPoint]
    if count > 0:
      for item in kv["pts"].split(','):
        let p = item.split(':'); points.add((x: parseInt(p[0]), y: parseInt(p[1])))
    let target = system.seats[seat]; let cache = target.dangerSourceCache
    var wasHit: seq[bool]
    for p in points:
      let o = map.cellOf(p)
      wasHit.add cache.sourceCacheSlot(int32(o.y * map.gridWidth + o.x)) >= 0
    for i, p in points:
      target.selectedDangerPoints[i] = p; target.selectedDangerSeats[i] = -1
    target.selectedDangerCount = points.len
    target.rebuildSelectedDanger(map, parseInt(kv["tick"]))
    for i, p in points:
      let o = map.cellOf(p)
      let slot = cache.sourceCacheSlot(int32(o.y * map.gridWidth + o.x))
      doAssert slot >= 0
      if wasHit[i]: cache.scanSlot(slot, kernel, hitT) else: cache.scanSlot(slot, kernel, missT)
  %*{"trace": path.extractFilename, "map": map.name, "range_px": rangePx,
     "hits": tallyJson(hitT), "misses": tallyJson(missT)}

proc sampleMap(mapName: string, rangePx, stride: int): JsonNode =
  let map = newBodyMap(getBrMap(mapName))
  let system = newBodyNavSystem(map, 1, rangePx, prepareRouteQueries = false)
  let seat = system.seats[0]; let cache = seat.dangerSourceCache
  let kernel = seat.dangerGeometry.kernel
  var t: Tally; var n = 0
  for cy in 0 ..< map.gridHeight:
    for cx in 0 ..< map.gridWidth:
      inc n
      if n mod stride != 0: continue
      let center = cellCenter((cx, cy))
      if not map.canStand(center): continue
      seat.selectedDangerPoints[0] = center; seat.selectedDangerCount = 1
      seat.rebuildSelectedDanger(map, 0)
      cache.scanSlot(cache.sourceCacheSlot(int32(cy * map.gridWidth + cx)), kernel, t)
  %*{"map": map.name, "range_px": rangePx, "stride": stride, "sample": tallyJson(t)}

when isMainModule:
  var results = newJArray()
  if paramStr(1) == "--map":
    results.add sampleMap(paramStr(2), parseInt(paramStr(3)), parseInt(paramStr(4)))
  elif paramStr(1) == "--kernel":
    for i in 2 .. paramCount(): results.add kernelSupport(parseInt(paramStr(i)))
  else:
    var i = 1
    while i + 2 <= paramCount():
      results.add replayTrace(paramStr(i), paramStr(i + 1), parseInt(paramStr(i + 2)), 1300)
      i += 3
  echo results.pretty

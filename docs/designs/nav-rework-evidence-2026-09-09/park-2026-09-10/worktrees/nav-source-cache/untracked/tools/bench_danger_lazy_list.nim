## C9 tools-only micro (DIAGNOSTIC, includes the frozen C2 parent body_nav).
## Production bitmap recording is untouched. Three timed operations on the
## same C6 v2 evenly spread origins (precomputed cells, warmed by production
## misses outside timing):
##   bitmap     : production replayVisibleCells (C2)
##   conversion : simulated first hit: one row-major traversal of the bitmap
##                that adds every set cell to the raster AND appends its
##                nonzero (gridIndex, weight) entry to a preallocated list
##   list       : subsequent hit: replay the list entries
## One add per cell per source makes the row-major list exact regardless of
## ray order. Lists: one preallocated seq of origins * capacity entries with
## capacity = nonzero kernel count; lengths reset outside timing. Arms rotate
## order across batches; clear and hash outside timing; no clocks inside ops;
## no counters; no ref-owning local in the per-cell code (checked in C).
## Usage: bench_danger_lazy_list <map> <gunRangePx> <stride> <batches> <repeats>
include ../src/shell/body_nav
import std/[os, strutils, json, monotimes, times, hashes, algorithm, bitops]
import ../src/ctf/[br_map_pool, sim_types]

type
  ListEntry = object
    gridIndex: int32
    weight: float32
  ListStore = object
    capacity: int
    entries: seq[ListEntry]     # origins * capacity, preallocated once
    lengths: seq[int32]         # per origin

proc convertAndReplay(seat: BodyNavSeat, origin: BodyPoint, base: int,
    store: var ListStore, listIndex: int) =
  ## Simulated first hit: the C2 replay loop, row-major over the bitmap,
  ## plus one entry append per nonzero cell. `store` is a var parameter (no
  ## ownership copy); the cache is read through the seat field directly.
  let radius = seat.dangerGeometry.radius
  let diameter = radius * 2 + 1
  let gridW = seat.danger.gridW
  let outBase = listIndex * store.capacity
  var count = 0
  for wordIndex in 0 ..< seat.dangerSourceCache.words:
    var word = seat.dangerSourceCache.bits[base + wordIndex]
    while word != 0:
      let kernelIndex = wordIndex * 64 + countTrailingZeroBits(word)
      let kernelY = kernelIndex div diameter
      let kernelX = kernelIndex - kernelY * diameter
      let gridIndex = (origin.y - radius + kernelY) * gridW + origin.x - radius + kernelX
      let weight = seat.dangerGeometry.kernel[kernelIndex]
      seat.danger.values[gridIndex] += weight
      if weight != 0'f32:
        store.entries[outBase + count] = ListEntry(gridIndex: int32(gridIndex), weight: weight)
        inc count
      word = word and (word - 1)
  store.lengths[listIndex] = int32(count)

proc replayList(seat: BodyNavSeat, store: ListStore, listIndex: int) =
  let base = listIndex * store.capacity
  for offset in base ..< base + store.lengths[listIndex].int:
    let entry = store.entries[offset]
    seat.danger.values[entry.gridIndex] += entry.weight

proc rasterHash(values: seq[float32]): string =
  var h: Hash = 0
  for v in values: h = h !& hash(cast[uint32](v))
  toHex(int64(!$h), 16)

proc main() =
  if paramCount() != 5:
    quit("usage: bench_danger_lazy_list <map> <range> <stride> <batches> <repeats>", 2)
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
    geometry = seat.dangerGeometry
  var capacity = 0
  for v in geometry.kernel:
    if v != 0'f32: inc capacity
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
  var bases: seq[int]
  var cells: seq[BodyPoint]
  for p in origins:
    seat.selectedDangerPoints[0] = p; seat.selectedDangerCount = 1
    seat.rebuildSelectedDanger(map, 0)              # production miss: bitmap recorded
    let o = map.cellOf(p)
    let slot = cache.sourceCacheSlot(int32(o.y * map.gridWidth + o.x))
    doAssert slot >= 0
    bases.add slot * cache.words
    cells.add o
  var store = ListStore(capacity: capacity,
    entries: newSeq[ListEntry](origins.len * capacity),
    lengths: newSeq[int32](origins.len))
  # Proof per origin: bitmap replay, conversion+replay and list replay give
  # the same raster bits; the list holds exactly the bitmap's nonzero cells.
  var rasterMismatch = 0; var setMismatch = 0; var listCells = 0; var bitmapBits = 0
  let radius = geometry.radius; let diameter = radius * 2 + 1
  for i in 0 ..< origins.len:
    for v in seat.danger.values.mitems: v = 0
    seat.replayVisibleCells(cells[i], bases[i]); let a = seat.danger.values
    for v in seat.danger.values.mitems: v = 0
    seat.convertAndReplay(cells[i], bases[i], store, i); let b = seat.danger.values
    for v in seat.danger.values.mitems: v = 0
    seat.replayList(store, i); let c = seat.danger.values
    for k in 0 ..< a.len:
      if cast[uint32](a[k]) != cast[uint32](b[k]) or cast[uint32](a[k]) != cast[uint32](c[k]):
        inc rasterMismatch; break
    var expect: seq[int32]
    for w in 0 ..< cache.words:
      var word = cache.bits[bases[i] + w]
      while word != 0:
        let kk = w * 64 + countTrailingZeroBits(word)
        inc bitmapBits
        if geometry.kernel[kk] != 0'f32:
          let ky = kk div diameter; let kx = kk - ky * diameter
          expect.add int32((cells[i].y - radius + ky) * map.gridWidth + cells[i].x - radius + kx)
        word = word and (word - 1)
    var got: seq[int32]
    for off in i * capacity ..< i * capacity + store.lengths[i].int: got.add store.entries[off].gridIndex
    listCells += got.len
    expect.sort(); var g2 = got; g2.sort()
    if expect != g2: inc setMismatch
  # Timed batches; arm order rotates by batch index.
  var ns: array[3, seq[float]]; var hashes: array[3, seq[string]]; var order: seq[string]
  let names = ["bitmap", "conversion", "list"]
  proc runArm(arm: int) =
    for v in seat.danger.values.mitems: v = 0
    if arm == 1:
      for i in 0 ..< origins.len: store.lengths[i] = 0   # reset outside timing
    let started = getMonoTime()
    for r in 0 ..< repeats:
      for i in 0 ..< origins.len:
        case arm
        of 0: seat.replayVisibleCells(cells[i], bases[i])
        of 1: seat.convertAndReplay(cells[i], bases[i], store, i)
        else: seat.replayList(store, i)
    ns[arm].add (getMonoTime() - started).inNanoseconds.float / float(repeats * origins.len)
    hashes[arm].add rasterHash(seat.danger.values)
  for batch in 0 ..< batches:
    var seq3: seq[string]
    for k in 0 ..< 3:
      let arm = (batch + k) mod 3
      runArm(arm); seq3.add names[arm]
    order.add seq3.join(",")
  proc med(v: seq[float]): float =
    var s = v; s.sort(); s[s.len div 2]
  var originsJson = newJArray()
  for i, p in origins:
    originsJson.add %*{"px": [p.x, p.y], "cell": [cells[i].x, cells[i].y]}
  echo %*{"tool": "bench_danger_lazy_list", "protocol": "rotating-3-arms-precomputed-cells",
    "map": map.name, "grid": [map.gridWidth, map.gridHeight], "range_px": rangePx,
    "origins": origins.len, "origin_list": originsJson, "stride": stride,
    "batches": batches, "repeats": repeats, "batch_order": order,
    "list_capacity_nonzero_kernel": capacity,
    "bitmap_bits_per_origin": bitmapBits.float / origins.len.float,
    "list_cells_per_origin": listCells.float / origins.len.float,
    "set_mismatches": setMismatch, "raster_mismatches": rasterMismatch,
    "bitmap_ns_by_batch": ns[0], "conversion_ns_by_batch": ns[1], "list_ns_by_batch": ns[2],
    "bitmap_ns_median": med(ns[0]), "conversion_ns_median": med(ns[1]), "list_ns_median": med(ns[2]),
    "incremental_conversion_cost": (med(ns[1]) - med(ns[0])) / med(ns[0]),
    "list_over_bitmap": med(ns[2]) / med(ns[0]),
    "batch_hashes_bitmap": hashes[0], "batch_hashes_conversion": hashes[1], "batch_hashes_list": hashes[2],
    "hashes_equal": hashes[0] == hashes[1] and hashes[1] == hashes[2]}

main()

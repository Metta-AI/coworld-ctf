## C7 tools-only replay microbench (DIAGNOSTIC, includes body_nav for private
## state). Compares, on the same evenly spread origins as the C6 v2 tool:
##   bitmap  = the production replayVisibleCells of THIS build (C2 when built
##             without defines, C8 when built with -d:DangerOmitZeroWeights=true)
##   list    = a diagnostic per-origin list of (absolute grid index int32,
##             weight float32) captured in ACTUAL first-visit ray order by a
##             verbatim copy of the production ray walk during the untimed
##             warm rebuild, nonzero weights only (C8 rule), capacity equal to
##             the nonzero-kernel count computed from the real kernel.
## Before timing, every origin's list is checked against the production
## bitmap (set equality on nonzero cells) and its replayed raster against the
## production replay raster (float bits). Batches alternate bitmap/list; clear
## and hash are outside timing; no clocks inside replay; no counters.
## Usage: bench_danger_list_replay <map> <gunRangePx> <stride> <batches> <repeats>
include ../src/shell/body_nav
import std/[os, strutils, json, monotimes, times, hashes, algorithm, bitops]
import ../src/ctf/[br_map_pool, sim_types]

const DangerReplayArmLabel {.strdefine.} = "unspecified"

type
  ListEntry = object
    gridIndex: int32
    weight: float32
  SourceList = object
    entries: seq[ListEntry]   # preallocated to capacity; len = recorded count

# ---- verbatim copy of the production first-visit walk, recording a list ----
proc diagAddVisibleCell(seat: BodyNavSeat, origin: BodyPoint,
    kernel: openArray[float32], kernelRadius, gx, gy: int,
    list: var SourceList) {.inline.} =
  if gx < 0 or gx >= seat.danger.gridW or gy < 0 or gy >= seat.danger.gridH:
    return
  let index = gy * seat.danger.gridW + gx
  if seat.dangerWorkspace.visited[index] == seat.dangerWorkspace.visitGeneration:
    return
  seat.dangerWorkspace.visited[index] = seat.dangerWorkspace.visitGeneration
  let diameter = kernelRadius * 2 + 1
  let kernelX = gx - origin.x + kernelRadius
  let kernelY = gy - origin.y + kernelRadius
  let weight = kernel[kernelY * diameter + kernelX]
  if weight == 0'f32:
    return                       # C8 rule: zero contributions are not recorded
  list.entries.add ListEntry(gridIndex: int32(index), weight: weight)

proc diagCastRay(seat: BodyNavSeat, origin: BodyPoint,
    kernel: openArray[float32], kernelRadius, targetX, targetY: int,
    list: var SourceList) =
  let dx = targetX - origin.x
  let dy = targetY - origin.y
  let nx = abs(dx)
  let ny = abs(dy)
  let stepX = cmp(dx, 0)
  let stepY = cmp(dy, 0)
  var x = origin.x
  var y = origin.y
  var ix = 0
  var iy = 0
  let decisionX = 2 * ny
  let decisionY = 2 * nx
  var decision = ny - nx
  while ix < nx or iy < ny:
    if decision == 0:
      let sideX = x + stepX
      let sideY = y + stepY
      if seat.dangerGeometry.sightCellBlocked(sideX, y) or
          seat.dangerGeometry.sightCellBlocked(x, sideY):
        break
      seat.diagAddVisibleCell(origin, kernel, kernelRadius, sideX, y, list)
      seat.diagAddVisibleCell(origin, kernel, kernelRadius, x, sideY, list)
      x = sideX
      y = sideY
      inc ix
      inc iy
      decision += decisionX - decisionY
    elif decision < 0:
      x += stepX
      inc ix
      decision += decisionX
    else:
      y += stepY
      inc iy
      decision -= decisionY
    if seat.dangerGeometry.sightCellBlocked(x, y):
      break
    seat.diagAddVisibleCell(origin, kernel, kernelRadius, x, y, list)

proc captureList(seat: BodyNavSeat, map: BodyMap, origin: BodyPoint,
    capacity: int): SourceList =
  ## Same order as rebuildDangerFromPoints' miss path: origin cell first, then
  ## every perimeter ray. Uses the seat's own visited stamps (a fresh
  ## generation), so first-visit semantics are exactly production's.
  result.entries = newSeqOfCap[ListEntry](capacity)
  seat.nextVisitGeneration()
  seat.diagAddVisibleCell(origin, seat.dangerGeometry.kernel,
    seat.dangerGeometry.radius, origin.x, origin.y, result)
  for offset in seat.dangerGeometry.perimeter:
    seat.diagCastRay(origin, seat.dangerGeometry.kernel,
      seat.dangerGeometry.radius, origin.x + offset.x, origin.y + offset.y, result)
  doAssert result.entries.len <= capacity, "list exceeded nonzero-kernel capacity"

proc replayList(seat: BodyNavSeat, list: SourceList) {.inline.} =
  for entry in list.entries:
    seat.danger.values[entry.gridIndex] += entry.weight

proc rasterHash(values: seq[float32]): string =
  var h: Hash = 0
  for v in values: h = h !& hash(cast[uint32](v))
  toHex(int64(!$h), 16)

proc main() =
  if paramCount() != 5:
    quit("usage: bench_danger_list_replay <map> <range> <stride> <batches> <repeats>", 2)
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
  # Exact list capacity: nonzero entries of the actual kernel.
  var capacity = 0
  for v in geometry.kernel:
    if v != 0'f32: inc capacity
  # C6 v2 sampling: all stride-selected standable cells, then at most 64
  # evenly spaced including both ends. Selection outside timing, recorded.
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
  # Warm: production miss rebuild per origin (bitmap), then diagnostic capture.
  # v2: origin cells are precomputed here, outside timing, for both arms (the
  # production rebuild computes the origin before either replay).
  var bases: seq[int]
  var lists: seq[SourceList]
  var cells: seq[BodyPoint]
  for p in origins:
    seat.selectedDangerPoints[0] = p; seat.selectedDangerCount = 1
    seat.rebuildSelectedDanger(map, 0)
    let o = map.cellOf(p)
    let slot = cache.sourceCacheSlot(int32(o.y * map.gridWidth + o.x))
    doAssert slot >= 0
    bases.add slot * cache.words
    cells.add o
    lists.add seat.captureList(map, o, capacity)
  # Proof per origin: (a) list index set == production bitmap's nonzero cells;
  # (b) one list replay raster == one production bitmap replay raster, bitwise.
  var setMismatch = 0; var rasterMismatch = 0; var listCells = 0; var bitmapBits = 0
  var bitmapZeroBits = 0
  let radius = geometry.radius
  let diameter = radius * 2 + 1
  for i, p in origins:
    let o = map.cellOf(p)
    var bitmapNonzero: seq[int32]
    for w in 0 ..< cache.words:
      var word = cache.bits[bases[i] + w]
      while word != 0:
        let k = w * 64 + countTrailingZeroBits(word)
        let ky = k div diameter
        let kx = k - ky * diameter
        let gi = int32((o.y - radius + ky) * map.gridWidth + o.x - radius + kx)
        if geometry.kernel[k] == 0'f32: inc bitmapZeroBits else: bitmapNonzero.add gi
        inc bitmapBits
        word = word and (word - 1)
    var listSet: seq[int32]
    for e in lists[i].entries: listSet.add e.gridIndex
    listCells += listSet.len
    var a = bitmapNonzero; a.sort()
    var b = listSet; b.sort()
    if a != b: inc setMismatch
    for v in seat.danger.values.mitems: v = 0
    seat.replayVisibleCells(o, bases[i])
    let production = seat.danger.values
    for v in seat.danger.values.mitems: v = 0
    seat.replayList(lists[i])
    for c in 0 ..< production.len:
      if cast[uint32](production[c]) != cast[uint32](seat.danger.values[c]):
        inc rasterMismatch
        break
  # Timed batches. v2: the two arms alternate order on odd batches (bitmap
  # first on even batches, list first on odd), and results are stored by
  # arm, not by encounter order. Clear and hash stay outside timing.
  var bitmapNs, listNs: seq[float]
  var bitmapHashes, listHashes: seq[string]
  var batchOrder: seq[string]
  proc timeBitmap() =
    for v in seat.danger.values.mitems: v = 0
    let started = getMonoTime()
    for r in 0 ..< repeats:
      for i in 0 ..< origins.len:
        seat.replayVisibleCells(cells[i], bases[i])
    bitmapNs.add (getMonoTime() - started).inNanoseconds.float / float(repeats * origins.len)
    bitmapHashes.add rasterHash(seat.danger.values)
  proc timeList() =
    for v in seat.danger.values.mitems: v = 0
    let started = getMonoTime()
    for r in 0 ..< repeats:
      for i in 0 ..< origins.len:
        seat.replayList(lists[i])
    listNs.add (getMonoTime() - started).inNanoseconds.float / float(repeats * origins.len)
    listHashes.add rasterHash(seat.danger.values)
  for batch in 0 ..< batches:
    if batch mod 2 == 0:
      timeBitmap(); timeList(); batchOrder.add "bitmap,list"
    else:
      timeList(); timeBitmap(); batchOrder.add "list,bitmap"
  var bs = bitmapNs; bs.sort(); var ls = listNs; ls.sort()
  var originsJson = newJArray()
  for p in origins:
    let cell = map.cellOf(p)
    originsJson.add %*{"px": [p.x, p.y], "cell": [cell.x, cell.y]}
  echo %*{"bitmap_arm": DangerReplayArmLabel, "list_arm": "list-rayorder-nonzero",
    "map": map.name, "grid": [map.gridWidth, map.gridHeight], "range_px": rangePx,
    "origins": origins.len, "origin_list": originsJson, "stride": stride,
    "batches": batches, "repeats": repeats, "batch_order": batchOrder,
    "protocol": "v2-alternating-precomputed-cells",
    "list_capacity_nonzero_kernel": capacity,
    "list_cells_per_origin": listCells.float / origins.len.float,
    "bitmap_bits_per_origin": bitmapBits.float / origins.len.float,
    "bitmap_zero_weight_bits_per_origin": bitmapZeroBits.float / origins.len.float,
    "set_mismatches": setMismatch, "raster_mismatches": rasterMismatch,
    "bitmap_per_replay_ns_by_batch": bitmapNs, "list_per_replay_ns_by_batch": listNs,
    "bitmap_per_replay_ns_median": bs[bs.len div 2], "list_per_replay_ns_median": ls[ls.len div 2],
    "list_over_bitmap_median_ratio": ls[ls.len div 2] / bs[bs.len div 2],
    "bitmap_batch_hashes": bitmapHashes, "list_batch_hashes": listHashes,
    "hashes_equal": bitmapHashes == listHashes}

main()

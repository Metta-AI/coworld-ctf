## C7 tools-only proof diagnostic (includes body_nav and the list microbench's
## capture code by copy). On crafted maps with interior walls, for origins in
## the interior and at every map edge and corner (partial kernel boxes), at
## 331 px and 1300 px, checks for the diagnostic ray-order list:
##   (a) length never exceeds the nonzero-kernel capacity;
##   (b) no grid index repeats (one add per cell);
##   (c) the index set equals the production bitmap's nonzero-weight cells;
##   (d) replaying the list gives the production replay raster, float bits;
##   (e) the first entry is the origin cell (walk starts there);
##   (f) every entry's weight equals kernel[offset(entry, origin)] exactly.
## Order equality to production is by construction (verbatim copy of the
## production walk using the seat's own stamps) and is not independently
## re-derived here; (b)+(c)+(d) are what exactness needs.
include ../src/shell/body_nav
import std/[json, bitops, algorithm, sets]

## Tools-only arm label (-d:DangerReplayArmLabel=c2|c8); independent of any
## production define so the tool builds against materialized snapshots.
const DangerReplayArmLabel {.strdefine.} = "unspecified"

type
  ListEntry = object
    gridIndex: int32
    weight: float32
  SourceList = object
    entries: seq[ListEntry]

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
    return
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

proc captureList(seat: BodyNavSeat, origin: BodyPoint, capacity: int): SourceList =
  result.entries = newSeqOfCap[ListEntry](capacity)
  seat.nextVisitGeneration()
  seat.diagAddVisibleCell(origin, seat.dangerGeometry.kernel,
    seat.dangerGeometry.radius, origin.x, origin.y, result)
  for offset in seat.dangerGeometry.perimeter:
    seat.diagCastRay(origin, seat.dangerGeometry.kernel,
      seat.dangerGeometry.radius, origin.x + offset.x, origin.y + offset.y, result)

proc craft(width, height: int): BodyMap =
  var walkable = newSeq[bool](width * height)
  for y in 1 ..< height - 1:
    for x in 1 ..< width - 1:
      walkable[y * width + x] = true
  # interior walls so visibility is irregular
  for y in 200 ..< 260:
    for x in 300 ..< 310: walkable[y * width + x] = false
  for y in 500 ..< 510:
    for x in 100 ..< 600: walkable[y * width + x] = false
  newBodyMap(walkable, width, height, 2, @[(16, 16), (width - 17, height - 17)])

var results = newJArray()
let map = craft(1024, 768)
for rangePx in [331, 1300]:
  let system = newBodyNavSystem(map, 1, rangePx, prepareRouteQueries = false)
  let seat = system.seats[0]; let cache = seat.dangerSourceCache; let g = seat.dangerGeometry
  var capacity = 0
  for v in g.kernel:
    if v != 0'f32: inc capacity
  let W = map.gridWidth; let H = map.gridHeight
  let origins = [(1, 1), (W - 2, 1), (1, H - 2), (W - 2, H - 2), (W div 2, 1), (1, H div 2),
                 (W div 2, H div 2), (40, 30), (75, 66), (W - 5, H div 2)]
  for oc in origins:
    let cell: BodyPoint = (oc[0], oc[1])
    let point = cellCenter(cell)
    if not map.canStand(point): continue
    seat.selectedDangerPoints[0] = point; seat.selectedDangerCount = 1
    seat.rebuildSelectedDanger(map, 0)
    let slot = cache.sourceCacheSlot(int32(cell.y * W + cell.x)); doAssert slot >= 0
    let base = slot * cache.words
    let list = seat.captureList(cell, capacity)
    var indexSet = initHashSet[int32](); var duplicates = 0; var weightMismatch = 0
    let d = g.radius * 2 + 1
    for e in list.entries:
      if e.gridIndex in indexSet: inc duplicates
      indexSet.incl e.gridIndex
      let gy = e.gridIndex.int div W; let gx = e.gridIndex.int mod W
      let k = (gy - cell.y + g.radius) * d + (gx - cell.x + g.radius)
      if cast[uint32](g.kernel[k]) != cast[uint32](e.weight): inc weightMismatch
    var bitmapNonzero = initHashSet[int32](); var bitmapZero = 0
    for w in 0 ..< cache.words:
      var word = cache.bits[base + w]
      while word != 0:
        let k = w * 64 + countTrailingZeroBits(word)
        let ky = k div d; let kx = k - ky * d
        let gi = int32((cell.y - g.radius + ky) * W + cell.x - g.radius + kx)
        if g.kernel[k] == 0'f32: inc bitmapZero else: bitmapNonzero.incl gi
        word = word and (word - 1)
    for v in seat.danger.values.mitems: v = 0
    seat.replayVisibleCells(cell, base)
    let production = seat.danger.values
    for v in seat.danger.values.mitems: v = 0
    for e in list.entries: seat.danger.values[e.gridIndex] += e.weight
    var rasterMismatch = 0
    for c in 0 ..< production.len:
      if cast[uint32](production[c]) != cast[uint32](seat.danger.values[c]): inc rasterMismatch
    let boxClipped = cell.x - g.radius < 0 or cell.y - g.radius < 0 or
      cell.x + g.radius >= W or cell.y + g.radius >= H
    results.add %*{"range_px": rangePx, "origin_cell": [cell.x, cell.y], "box_clipped": boxClipped,
      "capacity": capacity, "list_len": list.entries.len, "within_capacity": list.entries.len <= capacity,
      "duplicates": duplicates, "weight_mismatches": weightMismatch,
      "first_entry_is_origin": list.entries.len > 0 and list.entries[0].gridIndex.int == cell.y * W + cell.x,
      "set_equals_bitmap_nonzero": indexSet == bitmapNonzero, "bitmap_zero_bits": bitmapZero,
      "raster_mismatches": rasterMismatch}
echo %*{"bitmap_arm": DangerReplayArmLabel, "cases": results}

## Shared source-visibility cache (C2 bitmap recording and LRU policy, C9
## first-hit list materialization): exactness against the uncached ray
## walk, source order, close floor, bounded deterministic eviction, range
## identity, the retained ledger, and the list-specific risks: capacity-
## exact sources, stale lists after slot reuse, first versus later hits,
## index mapping at map borders across supported ranges, and empty
## selections between hits.

import std/[algorithm, sequtils, unittest]
import ../src/shell/body_danger
import ../src/shell/body_map
import ../src/shell/body_nav

proc wallMap(): BodyMap =
  ## A room with interior walls so visibility sets differ by origin. Wide
  ## enough that the 190 px close floor does not cover the whole map.
  const
    Width = 480
    Height = 288
  var walkable = newSeq[bool](Width * Height)
  for y in 1 ..< Height - 1:
    for x in 1 ..< Width - 1:
      walkable[y * Width + x] = true
  for y in 20 ..< 70:
    for x in 60 ..< 66:
      walkable[y * Width + x] = false
  for y in 60 ..< 66:
    for x in 90 ..< 130:
      walkable[y * Width + x] = false
  newBodyMap(walkable, Width, Height, 2, @[(16, 48), (Width - 17, 48)])

proc input(self: BodyPoint, points: openArray[BodyPoint]): DangerInput =
  result.selfXy = self
  for index, point in points:
    result.candidates.add DangerCandidate(seatIndex: index + 1, pos: point)

proc floatBytes(values: seq[float32]): seq[uint32] =
  result = newSeq[uint32](values.len)
  for index, value in values:
    result[index] = cast[uint32](value)

proc rasterOf(map: BodyMap, points: openArray[BodyPoint], range: int,
    tick = 0): seq[float32] =
  ## Reference: a fresh system whose first rebuild is all misses, so it
  ## runs only the unchanged production ray walk.
  let nav = newBodyNavSystem(map, 1, range, prepareRouteQueries = false)
  nav.seats[0].rebuildDanger(map, input((8, 8), points), tick)
  nav.seats[0].dangerSnapshot

proc packedOf(nav: BodyNavSystem): seq[int16] =
  nav.seats[0].packedWeights

suite "shared danger source visibility cache":
  test "hits reproduce the uncached raster byte for byte across seats and rebuilds":
    let map = wallMap()
    let range = 331
    let nav = newBodyNavSystem(map, 3, range)
    let a = (x: 40, y: 30)
    let b = (x: 100, y: 60)
    let c = (x: 120, y: 20)
    # Seat 0 misses on a and b; seat 1 then hits both; seat 2 hits a, misses c.
    nav.seats[0].rebuildDanger(map, input((8, 8), [a, b]), 1)
    nav.seats[1].rebuildDanger(map, input((8, 8), [a, b]), 2)
    nav.seats[2].rebuildDanger(map, input((8, 8), [a, c]), 3)
    check nav.dangerSourceCacheOrder.len == 3
    check floatBytes(nav.seats[1].dangerSnapshot) ==
      floatBytes(rasterOf(map, [a, b], range))
    check floatBytes(nav.seats[2].dangerSnapshot) ==
      floatBytes(rasterOf(map, [a, c], range))
    # A later rebuild of seat 0 with all cached origins is all hits and
    # still matches the reference, including its packed view.
    nav.initializeDanger([input((8, 8), [c, b, a]), input((8, 8), []),
      input((8, 8), [])], 4)
    let reference = newBodyNavSystem(map, 1, range)
    reference.initializeDanger([input((8, 8), [c, b, a])], 4)
    check floatBytes(nav.seats[0].dangerSnapshot) ==
      floatBytes(reference.seats[0].dangerSnapshot)
    check packedOf(nav) == packedOf(reference)
    check nav.seats[0].dangerFingerprint == reference.seats[0].dangerFingerprint

  test "source order is preserved on hits":
    let map = wallMap()
    let range = 331
    let nav = newBodyNavSystem(map, 1, range, prepareRouteQueries = false)
    let a = (x: 40, y: 30)
    let b = (x: 44, y: 34)
    nav.seats[0].rebuildDanger(map, input((8, 8), [a, b]), 1)  # misses
    nav.seats[0].rebuildDanger(map, input((8, 8), [b, a]), 2)  # hits, reversed
    check floatBytes(nav.seats[0].dangerSnapshot) ==
      floatBytes(rasterOf(map, [b, a], range))
    nav.seats[0].rebuildDanger(map, input((8, 8), [a, b]), 3)  # hits, original
    check floatBytes(nav.seats[0].dangerSnapshot) ==
      floatBytes(rasterOf(map, [a, b], range))

  test "close floor stays exact-pixel while the kernel part is cached":
    let map = wallMap()
    let range = 331
    let p1 = (x: 40, y: 32)   # cell (5, 4) top-left pixel
    let p2 = (x: 47, y: 39)   # same 8 px cell, opposite corner pixel
    check map.cellOf(p1) == map.cellOf(p2)
    # Precondition: the exact-pixel floor differs between the two pixels,
    # so a cached floor would be detectable.
    check floatBytes(rasterOf(map, [p1], range)) !=
      floatBytes(rasterOf(map, [p2], range))
    let nav = newBodyNavSystem(map, 1, range, prepareRouteQueries = false)
    nav.seats[0].rebuildDanger(map, input((8, 8), [p1]), 1)
    nav.seats[0].rebuildDanger(map, input((8, 8), [p2]), 2)   # kernel hit
    check nav.dangerSourceCacheOrder.len == 1
    check floatBytes(nav.seats[0].dangerSnapshot) ==
      floatBytes(rasterOf(map, [p2], range))

  test "eviction follows an independent LRU model with deterministic order":
    let map = wallMap()
    let nav = newBodyNavSystem(map, 1, 64, prepareRouteQueries = false)
    var model: seq[int]   # least recent first
    proc request(cell: BodyPoint) =
      let key = cell.y * map.gridWidth + cell.x
      let point = (x: cell.x * NavCell + 2, y: cell.y * NavCell + 2)
      nav.seats[0].rebuildDanger(map, input((8, 8), [point]), 0)
      let at = model.find(key)
      if at >= 0:
        model.delete(at)
      elif model.len == DangerSourceCacheSlots:
        model.delete(0)
      model.add key
      check nav.dangerSourceCacheOrder == model
    # 65 distinct origins inside the 60 by 36 cell grid: the 65th evicts
    # the first.
    for index in 0 ..< DangerSourceCacheSlots + 1:
      request((2 + index mod 16, 2 + index div 16))
    # Re-requesting the first is a miss that evicts the second; the second
    # is then a miss too; the third is a hit.
    request((2, 2))
    request((3, 2))
    request((4, 2))
    check model.len == DangerSourceCacheSlots
    # A second system fed the same sequence lands in the same order.
    let again = newBodyNavSystem(map, 1, 64, prepareRouteQueries = false)
    for index in 0 ..< DangerSourceCacheSlots + 1:
      let cell = (x: 2 + index mod 16, y: 2 + index div 16)
      again.seats[0].rebuildDanger(map, input((8, 8),
        [(x: cell.x * NavCell + 2, y: cell.y * NavCell + 2)]), 0)
    for cell in [(x: 2, y: 2), (x: 3, y: 2), (x: 4, y: 2)]:
      again.seats[0].rebuildDanger(map, input((8, 8),
        [(x: cell.x * NavCell + 2, y: cell.y * NavCell + 2)]), 0)
    check again.dangerSourceCacheOrder == nav.dangerSourceCacheOrder

  test "entries are sized by the live range and owned per system":
    let map = wallMap()
    let near = newBodyNavSystem(map, 2, 331, prepareRouteQueries = false)
    let far = newBodyNavSystem(map, 2, 1300, prepareRouteQueries = false)
    # Bitmap entries as in C2 (words times 8) plus a list reservation whose
    # capacity is the nonzero-kernel count at the range (C8 kernel support):
    # 5,385 cells at 331 px, 54,173 at 1300 px, 8 bytes per entry.
    check near.dangerSourceCacheEntryBytes == 904
    check far.dangerSourceCacheEntryBytes == 13_368
    check near.dangerSourceCacheCapacity == 5_385
    check far.dangerSourceCacheCapacity == 54_173
    check near.dangerSourceCacheListBytes == 5_385 * 8
    check far.dangerSourceCacheListBytes == 54_173 * 8
    let a = (x: 40, y: 30)
    near.seats[0].rebuildDanger(map, input((8, 8), [a]), 1)
    check near.dangerSourceCacheOrder.len == 1
    check far.dangerSourceCacheOrder.len == 0
    far.seats[1].rebuildDanger(map, input((8, 8), [a]), 1)
    check far.dangerSourceCacheOrder == near.dangerSourceCacheOrder
    check floatBytes(far.seats[1].dangerSnapshot) ==
      floatBytes(rasterOf(map, [a], 1300))
    check floatBytes(near.seats[0].dangerSnapshot) ==
      floatBytes(rasterOf(map, [a], 331))

  test "ledger counts the shared cache by capacity":
    let map = wallMap()
    let nav = newBodyNavSystem(map, 4, 1300, prepareRouteQueries = false)
    let bytes = nav.retainedNavigationBytes
    let payload = int64(DangerSourceCacheSlots *
      (nav.dangerSourceCacheEntryBytes + nav.dangerSourceCacheListBytes))
    check bytes.sharedDangerSourceCache >= payload
    check bytes.sharedDangerSourceCache < payload + 4096
    var sum = bytes.systemOwner + bytes.routeIndex + bytes.safetyScratch +
      bytes.hazardOverlay + bytes.safeCache + bytes.mixedGraph +
      bytes.seatOwners + bytes.seatCaches + bytes.dangerRasters +
      bytes.dangerWorkspaces + bytes.packedWeights +
      bytes.packedWeightScratch + bytes.sharedDangerGeometry +
      bytes.sharedDangerSourceCache + bytes.trace + bytes.allocatorOverhead
    check sum == bytes.total

  test "scheduled rebuilds and empty selections leave the cache consistent":
    let map = wallMap()
    let nav = newBodyNavSystem(map, 2, 331, dangerK = 1)
    let a = (x: 40, y: 30)
    nav.initializeDanger([input((8, 8), [a]), input((8, 8), [])], 0)
    check nav.dangerSourceCacheOrder.len == 1
    nav.rebuildScheduledDanger(1, [input((8, 8), []), input((8, 8), [a])])
    check nav.dangerSourceCacheOrder.len == 1
    check floatBytes(nav.seats[1].dangerSnapshot) ==
      floatBytes(rasterOf(map, [a], 331))
    check nav.seats[0].dangerSnapshot.allIt(it == 0'f32)

proc bigOpenMap(widthPx, heightPx: int): BodyMap =
  var walkable = newSeq[bool](widthPx * heightPx)
  for y in 1 ..< heightPx - 1:
    for x in 1 ..< widthPx - 1:
      walkable[y * widthPx + x] = true
  newBodyMap(walkable, widthPx, heightPx, 2, @[(16, 16), (widthPx - 17, heightPx - 17)])

suite "shared danger source list risks":
  test "an all-visible source fills a slot to exactly its capacity":
    # Open map wide enough for the whole 327-cell kernel box at 1300 px, so
    # every nonzero kernel cell is visible from the centre: the recorded list
    # must be exactly capacity long (no overflow, nothing dropped).
    let map = bigOpenMap(2800, 2800)
    let nav = newBodyNavSystem(map, 1, 1300, prepareRouteQueries = false)
    let center = cellCenter((map.gridWidth div 2, map.gridHeight div 2))
    nav.seats[0].rebuildDanger(map, input((8, 8), [center]), 1)   # miss: bitmap only
    check nav.dangerSourceCacheListLengths == @[-1]
    check nav.dangerSourceCacheCapacity == 54_173
    let reference = newBodyNavSystem(map, 1, 1300, prepareRouteQueries = false)
    reference.seats[0].rebuildDanger(map, input((8, 8), [center]), 1)
    nav.seats[0].rebuildDanger(map, input((8, 8), [center]), 2)   # first hit: materializes
    check nav.dangerSourceCacheListLengths == @[nav.dangerSourceCacheCapacity]
    check floatBytes(nav.seats[0].dangerSnapshot) ==
      floatBytes(reference.seats[0].dangerSnapshot)
    nav.seats[0].rebuildDanger(map, input((8, 8), [center]), 3)   # later hit: full-length list
    check floatBytes(nav.seats[0].dangerSnapshot) ==
      floatBytes(reference.seats[0].dangerSnapshot)

  test "a reused slot is unmaterialized until its first hit and then replays only its new list":
    # Fill one slot with a long list, add 63 other unique origins so the
    # cache is full with the long source as the least recently used entry,
    # then miss on a short source: it must take exactly the long source's
    # slot. A later hit on the short source must replay only the short
    # list; stale entries from the long list must not be replayed.
    let map = wallMap()
    let range = 331
    let nav = newBodyNavSystem(map, 1, range, prepareRouteQueries = false)
    let long = (x: 240, y: 144)          # open centre, many visible cells
    let short = (x: 12, y: 12)           # corner, few visible cells
    let longKey = map.cellOf(long).y * map.gridWidth + map.cellOf(long).x
    nav.seats[0].rebuildDanger(map, input((8, 8), [long]), 1)   # miss
    nav.seats[0].rebuildDanger(map, input((8, 8), [long]), 1)   # first hit: materialize
    let longLength = nav.dangerSourceCacheListLengths[^1]
    check longLength > 0
    for index in 0 ..< DangerSourceCacheSlots - 1:
      let cell = (x: 3 + index mod 16, y: 3 + index div 16)   # never the long or short cell
      nav.seats[0].rebuildDanger(map, input((8, 8),
        [(x: cell.x * NavCell + 2, y: cell.y * NavCell + 2)]), 2 + index)
    check nav.dangerSourceCacheOrder.len == DangerSourceCacheSlots
    check nav.dangerSourceCacheOrder[0] == longKey                  # still cached, least recent
    nav.seats[0].rebuildDanger(map, input((8, 8), [short]), 100)     # miss: evicts the long slot
    check longKey notin nav.dangerSourceCacheOrder
    check nav.dangerSourceCacheOrder.len == DangerSourceCacheSlots
    check nav.dangerSourceCacheListLengths[^1] == -1                  # reused slot: list invalidated
    nav.seats[0].rebuildDanger(map, input((8, 8), [short]), 101)     # first hit on the reused slot
    let shortLength = nav.dangerSourceCacheListLengths[^1]
    check shortLength > 0 and shortLength < longLength
    nav.seats[0].rebuildDanger(map, input((8, 8), [short]), 102)     # later hit: list replay
    check floatBytes(nav.seats[0].dangerSnapshot) ==
      floatBytes(rasterOf(map, [short], range))

  test "border origins map every entry to the right cell across supported ranges":
    let map = wallMap()
    for range in [331, 1050, 1300, 1600]:
      let nav = newBodyNavSystem(map, 1, range, prepareRouteQueries = false)
      let corners = [(x: 6, y: 6), (x: map.width - 7, y: 6),
                     (x: 6, y: map.height - 7), (x: map.width - 7, y: map.height - 7),
                     (x: map.width div 2, y: 6)]
      for corner in corners:
        let expected = floatBytes(rasterOf(map, [corner], range))
        nav.seats[0].rebuildDanger(map, input((8, 8), [corner]), 1)   # miss (records bitmap)
        check floatBytes(nav.seats[0].dangerSnapshot) == expected
        nav.seats[0].rebuildDanger(map, input((8, 8), [corner]), 2)   # first hit (materializes)
        check floatBytes(nav.seats[0].dangerSnapshot) == expected
        nav.seats[0].rebuildDanger(map, input((8, 8), [corner]), 3)   # later hit (list)
        check floatBytes(nav.seats[0].dangerSnapshot) == expected
      check nav.dangerSourceCacheCapacity == (if range >= 1050: 54_173 else: 5_385)

  test "empty selections between hits leave lists and order untouched":
    let map = wallMap()
    let range = 331
    let nav = newBodyNavSystem(map, 2, range, dangerK = 1)
    let a = (x: 40, y: 30)
    nav.initializeDanger([input((8, 8), [a]), input((8, 8), [])], 0)   # seat 0 miss
    nav.rebuildScheduledDanger(1, [input((8, 8), [a]), input((8, 8), [])])  # unchanged: L0 skip
    check nav.dangerSourceCacheListLengths == @[-1]
    nav.rebuildScheduledDanger(2, [input((8, 8), []), input((8, 8), [a])])  # seat 1 first hit
    check nav.dangerSourceCacheListLengths.len == 1
    check nav.dangerSourceCacheListLengths[0] > 0
    let order = nav.dangerSourceCacheOrder
    for tick in 3 .. 6:                                                # repeated empty selections
      nav.rebuildScheduledDanger(tick, [input((8, 8), []), input((8, 8), [])])
    check nav.dangerSourceCacheOrder == order
    check nav.dangerSourceCacheListLengths.len == 1
    nav.rebuildScheduledDanger(7, [input((8, 8), [a]), input((8, 8), [])])  # seat 0 later hit
    check floatBytes(nav.seats[0].dangerSnapshot) ==
      floatBytes(rasterOf(map, [a], range))
    check nav.seats[1].dangerSnapshot.allIt(it == 0'f32)

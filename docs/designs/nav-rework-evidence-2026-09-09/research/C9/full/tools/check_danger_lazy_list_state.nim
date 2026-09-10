## C9 tools-only state diagnostic (includes body_nav for private access; an
## internal test seam, not a public mutation API). Proves the list-length
## states: -1 (not materialized) converts on a hit; a materialized length
## replays without reconverting; and a converted slot forced to length 0
## (unreachable in production because the origin cell always has weight 1,
## so a materialized list is never empty) adds nothing and does not
## reconvert. Build with -d:dangerSourceCacheCounters.
include ../src/shell/body_nav
import std/json

proc openMap(w, h: int): BodyMap =
  var walkable = newSeq[bool](w * h)
  for y in 1 ..< h - 1:
    for x in 1 ..< w - 1: walkable[y * w + x] = true
  newBodyMap(walkable, w, h, 2, @[(16, 16), (w - 17, h - 17)])

let map = openMap(480, 288)
let system = newBodyNavSystem(map, 1, 331, prepareRouteQueries = false)
let seat = system.seats[0]; let cache = seat.dangerSourceCache
let p: BodyPoint = (240, 144)
proc rebuild(tick: int) =
  seat.selectedDangerPoints[0] = p; seat.selectedDangerCount = 1
  seat.rebuildSelectedDanger(map, tick)
proc snapshot(): seq[uint32] =
  for v in seat.danger.values: result.add cast[uint32](v)
rebuild(0)                                   # miss
let o = map.cellOf(p); let slot = cache.sourceCacheSlot(int32(o.y * map.gridWidth + o.x))
let afterMiss = snapshot()
let state0 = cache.slots[slot].listLength.int
rebuild(1)                                   # first hit: converts
let conv1 = cache.conversions; let len1 = cache.slots[slot].listLength.int
let afterFirstHit = snapshot()
rebuild(2)                                   # later hit: no reconvert
let conv2 = cache.conversions
let afterLaterHit = snapshot()
cache.slots[slot].listLength = 0             # internal seam: force the (unreachable) empty converted state
rebuild(3)
let conv3 = cache.conversions; let len3 = cache.slots[slot].listLength.int
let afterEmpty = snapshot()
var allZero = true
for v in afterEmpty:
  if v != 0'u32 and v != cast[uint32](0.5'f32): allZero = false   # only the live close floor remains
echo %*{"state_after_miss": state0, "first_hit_conversions": conv1, "first_hit_length": len1,
  "later_hit_conversions": conv2, "raster_equal_miss_first_later": afterMiss == afterFirstHit and afterFirstHit == afterLaterHit,
  "forced_zero_length_conversions": conv3, "forced_zero_length_after": len3,
  "forced_zero_only_close_floor_remains": allZero,
  "pass": state0 == -1 and conv1 == 1 and len1 > 0 and conv2 == 1 and
    afterMiss == afterFirstHit and afterFirstHit == afterLaterHit and conv3 == 1 and len3 == 0 and allZero}

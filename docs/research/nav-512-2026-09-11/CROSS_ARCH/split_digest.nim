## Cross-architecture localisation probe (test support, public APIs only).
## Same workload as H1/crossbuild_fingerprints.nim, but prints separable
## digests so a native/local divergence can be attributed:
##   map_raster   : clearance, walkable and wall rasters (pure integers)
##   danger_bits  : float32 bits of every seat's danger field after activation
##   counters     : per-tick stage/unit/expansion/path-length integers only
##   floats       : per-tick route-field distances and path points
## and the per-tick counters digest, so the first diverging tick is visible.
## Build from the repo root with the production flags:
##   nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -o:/tmp/split docs/research/nav-512-2026-09-11/CROSS_ARCH/split_digest.nim
import std/[hashes, options]
import ../../../../src/ctf/arena
import ../../../../src/shell/body_cache
import ../../../../src/shell/body_map
import ../../../../src/shell/body_nav
import ../../../../src/shell/body_planner
import ../../../../src/shell/types as shellTypes

let map = newBodyMap(mapFromSpecJson(readFile("tests/fixtures/br-golden-map.json")))

var raster: Hash = 0
for y in 0 ..< map.height:
  for x in 0 ..< map.width:
    raster = raster !& map.clearanceAt((x, y)) !& int(map.isWall((x, y)))
for cy in 0 ..< map.gridHeight:
  for cx in 0 ..< map.gridWidth:
    raster = raster !& int(map.cellWalkable((cx, cy)))
echo "map_raster=", !$raster, " width=", map.width, " height=", map.height,
  " grid=", map.gridWidth, "x", map.gridHeight, " atlas=", map.atlasPostCount,
  " components=", map.componentCount, " rooms=", map.roomCount, " chokes=", map.chokeCount

let system = newBodyNavSystem(map, 32, 497)
let start: BodyPoint = (16, 16)
var input: DangerInput
input.selfXy = start
for source in 0 ..< 8:
  input.candidates.add(DangerCandidate(seatIndex: source,
    pos: (400 + source * 300, 300 + (source mod 3) * 400)))
var rows: seq[DangerInput]
for seat in 0 ..< 32: rows.add(input)
system.initializeDanger(rows)

var dangerBits: Hash = 0
for seat in system.seats:
  for value in seat.dangerSnapshot:
    dangerBits = dangerBits !& hash(cast[uint32](value))
  dangerBits = dangerBits !& hash(cast[uint32](seat.danger.maximum))
echo "danger_bits=", !$dangerBits

for seat in 0 ..< 32:
  let goal = map.validateGoal((3194 - (seat mod 8) * 16, 1696 - (seat div 8) * 16), start).get
  let profile = [shellTypes.cpDefault, shellTypes.cpCarrier, shellTypes.cpHunter][seat mod 3]
  system.replacePlan(seat, 1, start, goal, profile,
    if seat mod 4 == 0: some((800, 400)) else: none(BodyPoint))

var counters: Hash = 0
var floats: Hash = 0
var tick = 0
var perTick: seq[string]
while (system.pendingPlanCount > 0 or system.hasPendingMint) and tick < 6000:
  discard system.runPlanningTick(tick)
  var tickCounters: Hash = 0
  for seat in system.seats:
    tickCounters = tickCounters !& hash(ord(seat.job.stage)) !&
      hash(seat.job.workUnits) !& hash(seat.job.astarExpansions) !&
      hash(seat.job.fallbackStep) !& hash(seat.job.startSnapped) !&
      hash(ord(seat.mintJob.stage)) !& hash(seat.mintJob.workUnits) !&
      hash(seat.mintJob.expansions) !& hash(seat.mintJob.routeSlot) !&
      hash(seat.pathLen) !& hash(seat.cache.routeKeys) !&
      hash(seat.cache.readyRouteFieldCount)
    for slot in 0 ..< shellTypes.MaxRouteFieldsPerSeat:
      if seat.cache.routeSlots[slot].valid:
        for cell in countup(0, map.gridWidth * map.gridHeight - 1, 97):
          floats = floats !& hash(seat.cache.routeDistanceAt(slot, cell))
  counters = counters !& tickCounters
  perTick.add($tick & ":" & $(!$tickCounters))
  inc tick
var pathDigest: Hash = 0
var totalPoints = 0
for seat in system.seats:
  for point in seat.activePath:
    pathDigest = pathDigest !& hash(point)
    inc totalPoints
echo "ticks=", tick, " counters=", !$counters, " floats=", !$floats,
  " path_digest=", !$pathDigest, " points=", totalPoints
echo "per_tick_counters_begin"
for line in perTick: echo line
echo "per_tick_counters_end"

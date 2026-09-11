## First-state-divergence probe (diagnostic scratch, public workload).
##
## Same 32-seat golden-map workload as CROSS_ARCH/split_digest.nim, but
## after each of the first DumpTicks planning ticks it dumps, per seat,
## every A* heap entry and every search record with integer ordering
## fields and raw float bits, plus a heuristic decomposition per heap
## node, and the minter heap if it holds anything. Run on two hosts and
## diff the outputs; the first differing line is the first divergence.
##
## The planner's heap and search store are private. This probe reads them
## through a field-for-field mirror of the 6b6b3408 object layouts
## (unchanged by H1-H3), cast from the ref. Mirror types are declared
## below; if the production layout ever changes, rebuild the mirror.
##
## Build from the repo root with the production flags:
##   nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -d:noSignalHandler -o:/tmp/fd docs/research/nav-512-2026-09-11/CROSS_ARCH/first_divergence/first_divergence.nim
##   /tmp/fd > first_divergence-<host>.txt
import std/[hashes, math, options, strutils]
import ../../../../../src/ctf/arena
import ../../../../../src/shell/body_cache
import ../../../../../src/shell/body_map
import ../../../../../src/shell/body_nav
import ../../../../../src/shell/body_planner
import ../../../../../src/shell/types as shellTypes

const DumpTicks = 3

type
  HeapNodeM = object
    priority, cost: float
    tie1, tie2: int
    item: int
  FixedHeapM = object
    nodes: seq[HeapNodeM]
    positions: seq[int]
    positionGeneration: seq[uint64]
    generation: uint64
    len: int
  SearchStoreM = object
    hashKeys: seq[int]
    hashRecords: seq[int]
    hashGeneration: seq[uint64]
    keys: seq[int]
    closed: seq[bool]
    gScore: seq[float]
    cameFrom: seq[int]
    generation: uint64
    count: int
  BodyPlannerM = object
    map: BodyMap
    heap: FixedHeapM
    search: SearchStoreM
    resultPath: seq[BodyPoint]
    resultLen: int
    capacity: int
  BodyFieldMinterM = object
    map: BodyMap
    heap: FixedHeapM

proc bits(x: float): string = toHex(cast[uint64](x), 16)

proc plannerView(planner: BodyPlanner): ptr BodyPlannerM =
  cast[ptr BodyPlannerM](cast[pointer](planner))

proc minterView(minter: BodyFieldMinter): ptr BodyFieldMinterM =
  cast[ptr BodyFieldMinterM](cast[pointer](minter))

let map = newBodyMap(mapFromSpecJson(readFile("tests/fixtures/br-golden-map.json")))
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
for seat in 0 ..< 32:
  let goal = map.validateGoal((3194 - (seat mod 8) * 16, 1696 - (seat div 8) * 16), start).get
  let profile = [shellTypes.cpDefault, shellTypes.cpCarrier, shellTypes.cpHunter][seat mod 3]
  system.replacePlan(seat, 1, start, goal, profile,
    if seat mod 4 == 0: some((800, 400)) else: none(BodyPoint))

# Layout self-check: the mirror must see the constructor's capacities.
block:
  let v = plannerView(system.seats[0].planner)
  doAssert v.capacity == system.seats[0].planner.workspaceCapacity
  doAssert v.heap.nodes.len == v.capacity and v.search.keys.len == v.capacity
  doAssert v.map == map
  echo "mirror_ok capacity=", v.capacity, " hashCapacity=", v.search.hashKeys.len

let latticeW = (map.width - 1) div PlanStepPx + 1

for tick in 0 ..< DumpTicks:
  discard system.runPlanningTick(tick)
  echo "=== tick ", tick
  for seat in system.seats:
    let v = plannerView(seat.planner)
    let job = seat.job
    if v.search.count == 0 and v.heap.len == 0 and not job.planPending and job.stage == pjsIdle:
      continue
    var heapInts: Hash = 0
    var heapFloats: Hash = 0
    var recInts: Hash = 0
    var recFloats: Hash = 0
    for i in 0 ..< v.heap.len:
      let n = v.heap.nodes[i]
      heapInts = heapInts !& hash(i) !& hash(n.item) !& hash(n.tie1) !& hash(n.tie2)
      heapFloats = heapFloats !& hash(n.priority) !& hash(n.cost)
    for r in 0 ..< v.search.count:
      recInts = recInts !& hash(r) !& hash(v.search.keys[r]) !& hash(v.search.closed[r]) !& hash(v.search.cameFrom[r])
      recFloats = recFloats !& hash(v.search.gScore[r])
    echo "seat ", seat.index, " stage=", job.stage, " units=", job.workUnits,
      " pops=", job.astarExpansions, " heap_len=", v.heap.len, " records=", v.search.count,
      " gen=", v.search.generation, " goal=", job.goal, " planStart=", job.planStart,
      " heap_ints=", !$heapInts, " heap_floats=", !$heapFloats,
      " rec_ints=", !$recInts, " rec_floats=", !$recFloats
    for i in 0 ..< v.heap.len:
      let n = v.heap.nodes[i]
      let key = v.search.keys[n.item]
      let point: BodyPoint = ((key mod latticeW) * PlanStepPx, (key div latticeW) * PlanStepPx)
      let g = v.search.gScore[n.item]
      let dx = (point.x - job.goal.x).float
      let dy = (point.y - job.goal.y).float
      let hyp = hypot(dx, dy)
      let cr = sqrt(dx * dx + dy * dy)
      echo "H ", i, " item=", n.item, " key=", key, " pt=", point.x, ",", point.y,
        " tie=", n.tie1, ",", n.tie2, " pri=", bits(n.priority), " cost=", bits(n.cost),
        " g=", bits(g), " pri_minus_cost=", bits(n.priority - n.cost),
        " hypot_to_goal=", bits(hyp), " cr_sqrt_to_goal=", bits(cr),
        (if hyp == cr: "" else: " HYPOT_NOT_CR")
    for r in 0 ..< v.search.count:
      echo "R ", r, " key=", v.search.keys[r], " closed=", v.search.closed[r],
        " g=", bits(v.search.gScore[r]), " from=", v.search.cameFrom[r]
  let mv = minterView(system.minter)
  if mv.heap.len > 0:
    echo "minter heap_len=", mv.heap.len
    for i in 0 ..< mv.heap.len:
      let n = mv.heap.nodes[i]
      echo "M ", i, " item=", n.item, " tie=", n.tie1, ",", n.tie2,
        " pri=", bits(n.priority), " cost=", bits(n.cost)

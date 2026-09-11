## First-state-divergence probe (diagnostic scratch, public workload).
##
## Same 32-seat golden-map workload as CROSS_ARCH/split_digest.nim. After
## each of the first DumpTicks planning ticks it dumps, per seat, every
## A* heap entry and every search record with integer ordering fields and
## raw float bits, the exact heuristic input (the connector-chosen target
## lattice point, not the unsnapped goal), and the minter heap if it holds
## anything. Run on two hosts and diff; the first differing line is the
## first divergence within these ticks.
##
## Private planner fields are read through std/importutils.privateAccess
## in this scope only; nothing is exported from production modules.
##
## Build from the repo root with the production flags (see run.sh).
import std/[hashes, importutils, math, options, strutils]
import ../../../../../src/ctf/arena
import ../../../../../src/shell/body_cache
import ../../../../../src/shell/body_map
import ../../../../../src/shell/body_nav
import ../../../../../src/shell/body_planner
import ../../../../../src/shell/types as shellTypes

const DumpTicks = 3

proc bits(x: float): string = toHex(cast[uint64](x), 16)

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

privateAccess(BodyPlanner)
privateAccess(BodyPlanJob)
privateAccess(BodyFieldMinter)
privateAccess(typeof(system.seats[0].planner.heap))
privateAccess(typeof(system.seats[0].planner.search))
privateAccess(typeof(system.seats[0].planner.heap.nodes[0]))

echo "probe=privateAccess capacity=", system.seats[0].planner.capacity,
  " hashCapacity=", system.seats[0].planner.search.hashKeys.len

proc lattice(job: BodyPlanJob, index: int): BodyPoint =
  ((index mod job.latticeW) * job.step, (index div job.latticeW) * job.step)

for tick in 0 ..< DumpTicks:
  discard system.runPlanningTick(tick)
  echo "=== tick ", tick
  for seat in system.seats:
    let planner = seat.planner
    let job = seat.job
    if planner.search.count == 0 and planner.heap.len == 0 and job.stage == pjsIdle:
      continue
    var heapInts: Hash = 0
    var heapFloats: Hash = 0
    var recInts: Hash = 0
    var recFloats: Hash = 0
    for i in 0 ..< planner.heap.len:
      let n = planner.heap.nodes[i]
      heapInts = heapInts !& hash(i) !& hash(n.item) !& hash(n.tie1) !& hash(n.tie2)
      heapFloats = heapFloats !& hash(n.priority) !& hash(n.cost)
    for r in 0 ..< planner.search.count:
      recInts = recInts !& hash(r) !& hash(planner.search.keys[r]) !&
        hash(planner.search.closed[r]) !& hash(planner.search.cameFrom[r])
      recFloats = recFloats !& hash(planner.search.gScore[r])
    let searching = job.stage in {pjsAstarSearch, pjsReconstruct, pjsReverse, pjsComplete}
    let target: BodyPoint = if searching: job.lattice(job.targetIndex) else: (-1, -1)
    echo "seat ", seat.index, " stage=", job.stage, " step=", job.step,
      " units=", job.workUnits, " pops=", job.astarExpansions,
      " heap_len=", planner.heap.len, " records=", planner.search.count,
      " gen=", planner.search.generation, " goal=", job.goal.x, ",", job.goal.y,
      " target=", target.x, ",", target.y, " source=", (if searching: $job.sourceIndex else: "-"),
      " planStart=", job.planStart.x, ",", job.planStart.y,
      " heap_ints=", !$heapInts, " heap_floats=", !$heapFloats,
      " rec_ints=", !$recInts, " rec_floats=", !$recFloats
    for i in 0 ..< planner.heap.len:
      let n = planner.heap.nodes[i]
      let key = planner.search.keys[n.item]
      let point = job.lattice(key)
      let g = planner.search.gScore[n.item]
      let dx = (point.x - target.x).float
      let dy = (point.y - target.y).float
      let hyp = hypot(dx, dy)
      let cr = sqrt(dx * dx + dy * dy)
      let recomputed = n.cost + hyp
      echo "H ", i, " item=", n.item, " key=", key, " pt=", point.x, ",", point.y,
        " tie=", n.tie1, ",", n.tie2, " pri=", bits(n.priority), " cost=", bits(n.cost),
        " g=", bits(g), " hypot_to_target=", bits(hyp), " cr_sqrt_to_target=", bits(cr),
        " cost_plus_hypot=", bits(recomputed),
        (if recomputed == n.priority: " pri_is_cost_plus_hypot" else: " pri_differs_from_cost_plus_hypot"),
        (if hyp == cr: "" else: " HYPOT_NOT_CR")
    for r in 0 ..< planner.search.count:
      echo "R ", r, " key=", planner.search.keys[r], " closed=", planner.search.closed[r],
        " g=", bits(planner.search.gScore[r]), " from=", planner.search.cameFrom[r]
  if system.minter.heap.len > 0:
    echo "minter heap_len=", system.minter.heap.len
    for i in 0 ..< system.minter.heap.len:
      let n = system.minter.heap.nodes[i]
      echo "M ", i, " item=", n.item, " tie=", n.tie1, ",", n.tie2,
        " pri=", bits(n.priority), " cost=", bits(n.cost)

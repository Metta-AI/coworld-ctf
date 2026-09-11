## Cross-build exactness checker for H1 (test support, not a shard member).
## Build from the repo root with the production release flags against the
## pre-H1 planner and the H1 planner; both outputs must be byte-identical.
##   nim c -f -d:release --hints:off -o:/tmp/xb docs/research/nav-512-2026-09-11/H1/crossbuild_fingerprints.nim
## Runs a 32-seat golden-map drain with an eight-source danger field, all
## three cost profiles, avoid points on every fourth seat, and route-field
## mints, folding every seat's plan and mint fingerprint after every tick.
import std/[hashes, options]
import ../../../../src/ctf/arena
import ../../../../src/shell/body_cache
import ../../../../src/shell/body_map
import ../../../../src/shell/body_nav
import ../../../../src/shell/body_planner
import ../../../../src/shell/types as shellTypes

let gameMap = mapFromSpecJson(readFile("tests/fixtures/br-golden-map.json"))
let map = newBodyMap(gameMap)
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
var digest: Hash = 0
var tick = 0
while (system.pendingPlanCount > 0 or system.hasPendingMint) and tick < 6000:
  discard system.runPlanningTick(tick)
  for seat in system.seats:
    digest = digest !& seat.planner.jobFingerprint(seat.cache, seat.job) !&
      system.minter.mintFingerprint(seat.cache, seat.mintJob) !& hash(seat.pathLen)
  inc tick
var pathDigest: Hash = 0
var totalPoints = 0
for seat in system.seats:
  for point in seat.activePath:
    pathDigest = pathDigest !& hash(point)
    inc totalPoints
echo "ticks=", tick, " suspension_digest=", !$digest, " path_digest=", !$pathDigest, " points=", totalPoints

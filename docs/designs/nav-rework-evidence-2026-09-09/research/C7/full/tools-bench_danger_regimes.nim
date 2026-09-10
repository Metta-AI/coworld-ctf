## C7 tools-only regime diagnostic (includes body_nav): exactness and local
## timing of whole scheduled rebuilds under two source regimes, per map at
## 1300 px, 16 seats, cadence 32:
##   repeated_sources: the same 8 sources for every seat every rebuild
##   changing_sources: each seat's 8 sources rotate through a pool of 96
##                     standable positions so most sources are new
## Output per regime: rebuild count, hits/misses (counters build), a raster
## fingerprint chain over every rebuild (exactness across arms), and ns per
## rebuild with the raster hash computed outside timing. Build once per arm
## (parent/candidate snapshot in place) with -d:dangerSourceCacheCounters
## -d:DangerReplayArmLabel=<arm>. Mac timings are informational only.
include ../src/shell/body_nav
import std/[os, strutils, json, monotimes, times, hashes]
import ../src/ctf/[br_map_pool, sim_types]
const DangerReplayArmLabel {.strdefine.} = "unspecified"

proc standablePositions(map: BodyMap, count: int): seq[BodyPoint] =
  var n = 0
  let stride = max(1, (map.gridWidth * map.gridHeight) div (count * 3))
  for cy in 0 ..< map.gridHeight:
    for cx in 0 ..< map.gridWidth:
      inc n
      if n mod stride != 0: continue
      let c = cellCenter((cx, cy))
      if map.canStand(c):
        result.add c
        if result.len == count: return

proc runRegime(mapName: string, regime: string, ticks: int): JsonNode =
  let map = newBodyMap(getBrMap(mapName))
  let seats = 16
  let system = newBodyNavSystem(map, seats, 1300, prepareRouteQueries = false)
  let positions = map.standablePositions(96)
  doAssert positions.len >= 16
  var chain: Hash = 0
  var rebuilds = 0
  var totalNs: int64 = 0
  var maxNs: int64 = 0
  var inputs = newSeq[DangerInput](seats)
  for tick in 1 .. ticks:
    for seat in 0 ..< seats:
      inputs[seat] = DangerInput(selfXy: positions[seat mod positions.len])
      inputs[seat].candidates.setLen(0)
      for k in 0 ..< 8:
        let index = if regime == "repeated_sources": k
                    else: (seat * 8 + k + (tick div DangerCadenceK) * 8) mod positions.len
        inputs[seat].candidates.add DangerCandidate(seatIndex: 100 + k, pos: positions[index])
    let started = getMonoTime()
    system.rebuildScheduledDanger(tick, inputs)
    let elapsed = (getMonoTime() - started).inNanoseconds
    totalNs += elapsed; maxNs = max(maxNs, elapsed)
    for seat in 0 ..< seats:
      if dangerSeatDue(tick, seat, DangerCadenceK):
        inc rebuilds
        chain = chain !& system.seats[seat].dangerFingerprint
  var counters = newJNull()
  when defined(dangerSourceCacheCounters):
    let c = system.dangerSourceCacheCounters()
    counters = %*{"hits": c.hits, "misses": c.misses}
  %*{"arm": DangerReplayArmLabel, "map": map.name, "regime": regime, "seats": seats,
     "ticks": ticks, "scheduled_visits": rebuilds, "counters": counters,
     "fingerprint_chain": toHex(int64(!$chain), 16),
     "total_ns": totalNs, "ns_per_tick": totalNs.float / ticks.float, "max_tick_ns": maxNs}

var results = newJArray()
let ticks = if paramCount() >= 1: parseInt(paramStr(1)) else: 640
for mapName in ["br-gen-5204", "br-gen-5263", "br-gen-5001"]:
  for regime in ["repeated_sources", "changing_sources"]:
    results.add runRegime(mapName, regime, ticks)
echo results.pretty

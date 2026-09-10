## DIAGNOSTIC ONLY (C2). Replays a real-episode NAVSRC trace's changed
## scheduled rebuilds through the production selected-source seam on the
## trace's pool map, counts cache hits/misses, and proves every rebuild's
## raster equals a fresh uncached system's raster for the same ordered
## points. Build:
##   nim c -d:release -d:dangerSourceCacheCounters --hints:off \
##     -o:tmp/c2/replay tools/replay_danger_source_trace.nim
## Usage: replay <navsrc.txt> <map-name e.g. br-gen-5204> <seats> <gunRangePx>
import std/[os, strutils, hashes]
import ../src/ctf/[br_map_pool, sim_types]
import ../src/shell/body_map
import ../src/shell/body_nav_source_trace_replay

proc main() =
  if paramCount() != 4:
    quit("usage: replay <navsrc.txt> <map-name> <seats> <gunRangePx>", 2)
  let
    path = paramStr(1)
    mapName = paramStr(2)
    seats = parseInt(paramStr(3))
    rangePx = parseInt(paramStr(4))
    map = newBodyMap(getBrMap(mapName))
    system = newBodyNavSystem(map, seats, rangePx, prepareRouteQueries = false)
  var rebuilds, lookups, mismatches = 0
  var rasterHash: Hash = 0
  for raw in lines(path):
    if not raw.startsWith("NAVSRC sched "):
      continue
    var fields: seq[(string, string)]
    for token in raw[13 .. ^1].split(' '):
      let eq = token.find('=')
      if eq > 0: fields.add((token[0 ..< eq], token[eq + 1 .. ^1]))
    var tick, seat, count = 0
    var changed = false
    var pts = ""
    for (key, value) in fields:
      case key
      of "tick": tick = parseInt(value)
      of "seat": seat = parseInt(value)
      of "changed": changed = value == "1"
      of "n": count = parseInt(value)
      of "pts": pts = value
      else: discard
    if not changed:
      continue
    var points: seq[BodyPoint]
    if count > 0:
      for item in pts.split(','):
        let parts = item.split(':')
        points.add((x: parseInt(parts[0]), y: parseInt(parts[1])))
    doAssert points.len == count, raw
    system.replayRecordedSelection(seat, tick, points)
    inc rebuilds
    lookups += count
    # Reference: a fresh system (all misses, unchanged ray walk) for the
    # same ordered points on the same seat index.
    let reference = newBodyNavSystem(map, seats, rangePx,
      prepareRouteQueries = false)
    reference.replayRecordedSelection(seat, tick, points)
    let got = system.seats[seat].dangerSnapshot
    let want = reference.seats[seat].dangerSnapshot
    var same = got.len == want.len
    if same:
      for index in 0 ..< got.len:
        if cast[uint32](got[index]) != cast[uint32](want[index]):
          same = false
          break
    if not same:
      inc mismatches
      stderr.writeLine "RASTER MISMATCH tick=", tick, " seat=", seat
    rasterHash = rasterHash !& system.seats[seat].dangerFingerprint
  when defined(dangerSourceCacheCounters):
    let counters = system.sourceCacheHitsMisses()
    echo "hits=", counters.hits, " misses=", counters.misses,
      " conversions=", counters.conversions
  echo "map=", map.name, " grid=", map.gridWidth, "x", map.gridHeight,
    " range_px=", rangePx, " seats=", seats, " changed_rebuilds=", rebuilds,
    " lookups=", lookups, " raster_mismatches=", mismatches,
    " entry_bytes=", system.dangerSourceCacheEntryBytes,
    " raster_chain_hash=", toHex(int64(!$rasterHash), 16)
  if mismatches > 0:
    quit(1)

main()

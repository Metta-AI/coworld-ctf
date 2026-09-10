## Native C2 mechanism comparison on recorded selected-source order.
## Parsing, raster hashing and serialization are outside timed rebuilds.
include ../src/shell/body_nav
import std/[json, monotimes, os, strutils, times]
import ../src/ctf/br_map_pool

let lines = readFile(paramStr(1)).splitLines()
var header: seq[string]
for line in lines:
  if line.startsWith("NAVSRC sys "): header = line.splitWhitespace()
var mapName: string
var seats, gunRange: int
for token in header:
  let pair = token.split('=', 1)
  if pair.len != 2: continue
  case pair[0]
  of "map": mapName = pair[1]
  of "seats": seats = parseInt(pair[1])
  of "range_px": gunRange = parseInt(pair[1])
  else: discard
let map = newBodyMap(getBrMap(mapName))
let nav = newBodyNavSystem(map, seats, gunRange, prepareRouteQueries = false)
var samples = newJArray()
var digest = 14695981039346656037'u64
for line in lines:
  if not line.startsWith("NAVSRC sched "): continue
  var tick, seat, count: int
  var changed: bool
  var pointsText: string
  for token in line.splitWhitespace():
    let pair = token.split('=', 1)
    if pair.len != 2: continue
    case pair[0]
    of "tick": tick = parseInt(pair[1])
    of "seat": seat = parseInt(pair[1])
    of "n": count = parseInt(pair[1])
    of "changed": changed = pair[1] == "1"
    of "pts": pointsText = pair[1]
    else: discard
  if not changed: continue
  var points: seq[BodyPoint]
  if count > 0:
    for item in pointsText.split(','):
      let pair = item.split(':')
      points.add((parseInt(pair[0]), parseInt(pair[1])))
  doAssert points.len == count
  let started = getMonoTime()
  nav.seats[seat].rebuildDangerFromPoints(map, points, tick)
  let elapsed = (getMonoTime() - started).inNanoseconds
  for value in nav.seats[seat].danger.values:
    digest = (digest xor cast[uint32](value).uint64) * 1099511628211'u64
  samples.add %*{"tick": tick, "seat": seat, "sources": count,
    "rebuild_ns": elapsed}
var result = %*{"trace": paramStr(1), "map": mapName, "seats": seats,
  "range_px": gunRange, "samples": samples, "raster_chain_fnv64": $digest,
  "whole_body_acceptance": false}
when declared(dangerSourceCacheCounters):
  let counts = nav.dangerSourceCacheCounters
  result["hits"] = %counts.hits
  result["misses"] = %counts.misses
echo result

## Separate-process activation RSS and constructor payload accounting.
## No timing qualification. Linux /proc RSS includes allocator/page effects.
import std/[json, os, strutils]
import ../../../../src/ctf/[arena, replays]
import ../../../../src/shell/[body_map, body_nav, body_planner, body_cache]

proc residentStatus(): JsonNode =
  result = newJObject()
  for line in readFile("/proc/self/status").splitLines:
    let parts = line.splitWhitespace
    if parts.len >= 2 and parts[0] in ["VmRSS:", "VmHWM:"]:
      result[parts[0][0..^2] & "_bytes"] = %(parseBiggestInt(parts[1]) * 1024)

let path = paramStr(1)
let before = residentStatus()
let spec = if path.endsWith(".bitreplay"):
    parseJson(parseReplayBytes(readFile(path)).configJson)["mapSpec"]
  else: parseJson(readFile(path))
let gameMap = mapFromSpecJson($spec)
let map = newBodyMap(gameMap)
let afterMap = residentStatus()
let system = newBodyNavSystem(map, 32, 1050)
let afterNav = residentStatus()
let capacity = system.seats[0].planner.workspaceCapacity
let cells = map.gridWidth * map.gridHeight
var hashCapacity = 1
while hashCapacity < max(8, capacity * 2): hashCapacity *= 2
# amd64: HeapNode=40, int=8, uint64=8, bool=1, BodyPoint=16.
# Two path arrays include two extra points each. Route fields=4*(8+1)*cells;
# danger values+visited=(4+1)*cells. Excludes object/seq headers and shared map.
let perSeatPayload = 113'i64*capacity + 24'i64*hashCapacity + 41'i64*cells + 64
let sharedMintPayload = 56'i64*cells
let output = %*{"input": path, "width": map.width, "height": map.height,
  "seats": system.seatCount, "planner_capacity": capacity,
  "hash_capacity": hashCapacity, "grid_cells": cells,
  "per_seat_main_array_payload_bytes": perSeatPayload,
  "shared_mint_array_payload_bytes": sharedMintPayload,
  "validator_logical_bytes": map.validatorLogicalBytes,
  "seat_object_bytes": sizeof(system.seats[0][]),
  "planner_object_bytes": sizeof(system.seats[0].planner[]),
  "cache_object_bytes": sizeof(system.seats[0].cache[]),
  "minter_object_bytes": sizeof(system.minter[]),
  "before": before, "after_map": afterMap, "after_nav": afterNav}
echo $output

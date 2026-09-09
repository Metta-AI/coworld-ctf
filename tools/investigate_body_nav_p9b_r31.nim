## P9B Round 3.1: precomputed 4 px legality and standability.

import std/[algorithm, json, math, monotimes, os, strformat, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/body_map

const
  FineStep = 4
  PoolSamples = 5
  ColossalSamples = 3

type FineLegality = object
  width, height: int
  standable: seq[uint8]
  legal: seq[uint8]

proc loadMap(pool: JsonNode, poolIndex: int): BodyMap =
  let entry = pool[poolIndex]
  var gameMap = mapFromSpecJson($entry["spec"])
  gameMap.name = entry["name"].getStr()
  newBodyMap(gameMap)

proc colossalMap(): BodyMap =
  let overrides = MapGenOverrides(
    size: "colossal", windows: -1, pits: -1, pitDensity: -1)
  var gameMap = generateCtfMap(4242, overrides, 4)
  gameMap.name = "size:colossal"
  newBodyMap(gameMap)

proc setBit(bits: var seq[uint8], index: int) {.inline.} =
  bits[index shr 3] = bits[index shr 3] or uint8(1 shl (index and 7))

proc bitAt(bits: openArray[uint8], index: int): bool {.inline.} =
  (bits[index shr 3] and uint8(1 shl (index and 7))) != 0

proc pointAt(index, width: int): BodyPoint {.inline.} =
  (x: (index mod width) * FineStep, y: (index div width) * FineStep)

proc buildFineLegality(map: BodyMap): FineLegality =
  result.width = (map.width - 1) div FineStep + 1
  result.height = (map.height - 1) div FineStep + 1
  let count = result.width * result.height
  result.standable = newSeq[uint8]((count + 7) div 8)
  result.legal = newSeq[uint8](count)
  for node in 0 ..< count:
    if map.canStand(pointAt(node, result.width)):
      result.standable.setBit(node)
  for node in 0 ..< count:
    if not result.standable.bitAt(node): continue
    let
      point = pointAt(node, result.width)
      fine = (x: node mod result.width, y: node div result.width)
    for direction, delta in NavNeighbors:
      let next = (x: fine.x + delta.x, y: fine.y + delta.y)
      if next.x < 0 or next.x >= result.width or
          next.y < 0 or next.y >= result.height: continue
      let nextNode = next.y * result.width + next.x
      if result.standable.bitAt(nextNode) and
          map.segmentClear(point, pointAt(nextNode, result.width)):
        result.legal[node] = result.legal[node] or uint8(1 shl direction)

proc verify(map: BodyMap, table: FineLegality) =
  for node in 0 ..< table.legal.len:
    let
      point = pointAt(node, table.width)
      standable = map.canStand(point)
      fine = (x: node mod table.width, y: node div table.width)
    doAssert table.standable.bitAt(node) == standable
    var expected = 0'u8
    if standable:
      for direction, delta in NavNeighbors:
        let next = (x: fine.x + delta.x, y: fine.y + delta.y)
        if next.x < 0 or next.x >= table.width or
            next.y < 0 or next.y >= table.height: continue
        let nextNode = next.y * table.width + next.x
        if map.canStand(pointAt(nextNode, table.width)) and
            map.segmentClear(point, pointAt(nextNode, table.width)):
          expected = expected or uint8(1 shl direction)
    doAssert table.legal[node] == expected

proc percentile(values: openArray[float64], fraction: float64): float64 =
  if values.len == 0: return Inf
  var sorted = @values
  sorted.sort()
  sorted[min(sorted.high,
    max(0, int(ceil(fraction * sorted.len.float)) - 1))]

proc measureMap(map: BodyMap, label: string, samples: int): JsonNode =
  var buildNs: seq[float64]
  var table: FineLegality
  for _ in 0 ..< samples:
    let started = getMonoTime()
    table = map.buildFineLegality()
    buildNs.add (getMonoTime() - started).inNanoseconds.float
  map.verify(table)
  let
    nodes = table.width * table.height
    bytes = table.legal.len + table.standable.len
    navCells = map.gridWidth * map.gridHeight
  %*{"map": label, "width": table.width, "height": table.height,
    "nodes": nodes, "nav_cells": navCells,
    "nodes_per_nav_cell": nodes.float / navCells.float,
    "legal_bytes": table.legal.len,
    "standable_bit_bytes": table.standable.len,
    "retained_bytes": bytes,
    "build_ns_p50": percentile(buildNs, 0.50),
    "build_ns_p95": percentile(buildNs, 0.95),
    "build_ns_max": max(buildNs), "samples": buildNs}

when isMainModule:
  if paramCount() != 0:
    quit("usage: investigate_body_nav_p9b_r31", 2)
  let pool = loadBrS2PoolRaw()
  var rows = newJArray()
  for poolIndex in 0 ..< pool.len:
    stderr.writeLine &"r3.1 pool map {poolIndex + 1}/{pool.len}"
    rows.add measureMap(pool.loadMap(poolIndex),
      pool[poolIndex]["name"].getStr(), PoolSamples)
  stderr.writeLine "r3.1 colossal"
  let colossal = colossalMap()
  rows.add measureMap(colossal, "size:colossal", ColossalSamples)
  echo pretty(%*{"schema": "coworld_body_nav_p9b_r31", "v": 1,
    "fine_step_px": FineStep, "maps": rows})

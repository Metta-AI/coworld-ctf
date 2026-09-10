## Exact public-rebuild comparison against a freshly cleared visit workspace.
## Include exposes only the diagnostic's explicit reference reset; production
## retains its ordinary rollover. Timings exclude comparison and reference work.
include ../src/shell/body_nav
import std/[json, monotimes, random, times]
import ../src/ctf/[arena, br_map_pool]

proc checkMap(label: string; gameMap: CtfMap; gunRange: int): JsonNode =
  let map = newBodyMap(gameMap)
  let nav = newBodyNavSystem(map, 1, gunRange, prepareRouteQueries = false)
  let reference = newBodyNavSystem(map, 1, gunRange, prepareRouteQueries = false)
  var points: seq[BodyPoint]
  for y in countup(0, map.height - 1, 32):
    for x in countup(0, map.width - 1, 32):
      if map.canStand((x, y)): points.add((x, y))
  var rng = initRand(401)
  var samples = newJArray()
  var sourceCount = 0
  for sample in 0 ..< 96:
    var input = DangerInput(selfXy: points[rng.rand(points.high)])
    for source in 0 ..< 8:
      input.candidates.add DangerCandidate(seatIndex: source,
        pos: points[rng.rand(points.high)])
    let before = nav.seats[0].dangerWorkspace.visitGeneration.int
    let started = getMonoTime()
    nav.seats[0].rebuildDanger(map, input, sample)
    let elapsed = (getMonoTime() - started).inNanoseconds
    let after = nav.seats[0].dangerWorkspace.visitGeneration.int
    for value in reference.seats[0].dangerWorkspace.visited.mitems:
      value = 0
    reference.seats[0].dangerWorkspace.visitGeneration = 0
    reference.seats[0].rebuildDanger(map, input, sample)
    doAssert nav.seats[0].danger.maximum == reference.seats[0].danger.maximum
    for i, value in nav.seats[0].danger.values:
      doAssert cast[uint32](value) == cast[uint32](reference.seats[0].danger.values[i]),
        label & " raster mismatch at sample " & $sample & " cell " & $i
    let previousCount = sourceCount
    sourceCount += nav.seats[0].selectedDangerCount
    samples.add %*{"sample": sample, "sources": nav.seats[0].selectedDangerCount,
      "generation_before": before, "generation_after": after,
      "actual_rollover": after < before,
      "byte_rollover_boundary": (sourceCount - 1) div 255 !=
        max(0, previousCount - 1) div 255,
      "rebuild_ns": elapsed}
  %*{"map": label, "gun_range": gunRange, "grid_cells": map.gridWidth * map.gridHeight,
    "stamp_element_bytes": sizeof(nav.seats[0].dangerWorkspace.visitGeneration),
    "stamp_capacity": nav.seats[0].dangerWorkspace.visited.capacity,
    "sources": sourceCount, "exact": true, "samples": samples}

var rows = newJArray()
let pool = loadBrS2PoolRaw()
for i in 0 ..< pool.len:
  stderr.writeLine "rollover pool:", i
  rows.add checkMap("pool:" & $i, mapFromSpecJson($pool[i]["spec"]), 1300)
let configured = parseJson(readFile(BrS2SoloMapPoolPath))
for i in 0 ..< configured.len:
  stderr.writeLine "rollover configured:", i
  rows.add checkMap("configured:" & $i, mapFromSpecJson($configured[i]), 1300)
rows.add checkMap("colossal", generateCtfMap(4242,
  MapGenOverrides(size: "colossal", windows: -1, pits: -1, pitDensity: -1), 4), 1300)
echo %*{"rows": rows, "whole_body_acceptance": false,
  "reference": "same production rebuild with stamps cleared before each eight-source call"}

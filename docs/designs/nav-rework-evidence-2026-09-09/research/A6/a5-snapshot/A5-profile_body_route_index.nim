## Activation-only Fluffy attribution for the remaining map-48 ratio failure.
## Run from the repository root with --path:src/shell and ProfileTracePath set.
include ../src/shell/body_route_index
import std/json
import bitworld/profile
import ../src/ctf/[arena, br_map_pool]

proc profileIndex(map: BodyMap): BodyRouteIndex =
  new(result)
  result.map = map
  result.stats = BodyRouteIndexStats(
    navCells: map.gridWidth * map.gridHeight, rooms: map.roomCount)
  profileBlock("index.legalMoves"):
    result.buildLegalMoves()
  var maxRoomCells: int
  profileBlock("index.roomLayout"):
    maxRoomCells = result.buildRoomLayout()
  var crossings: seq[CrossingPath]
  profileBlock("index.sides"):
    crossings = result.buildSides()
  var counted: tuple[intraCount, intraCells: int]
  profileBlock("index.fieldsAndCountSegments"):
    counted = result.buildFieldsAndCountSegments(maxRoomCells)
  profileBlock("index.fillSegmentsAndArcs"):
    result.fillSegmentsAndArcs(crossings, counted.intraCount, counted.intraCells)
  profileBlock("index.graphComponents"):
    result.buildGraphComponents()
  profileBlock("index.seedPixelComponents"):
    result.seedUnrepresentedPixelComponents()
  profileBlock("index.validatorAnchors"):
    result.validateValidatorAnchors()
  profileBlock("index.pocketConnectors"):
    result.buildPocketConnectors()
  profileBlock("index.fineAnchorIndex"):
    result.buildFineAnchorIndex()
  result.stats.segments = result.segments.len
  result.stats.segmentCells = result.cells.len
  result.stats.arcs = result.arcs.len
  result.stats.retainedBytes = result.retainedBytes()
  profileBlock("index.validate"):
    result.validateRouteIndex()

import std/[os, strutils]
# A5: optional args <pool-index> <repeats>; defaults keep the A2 recipe (48, 5).
let poolIndex = if paramCount() >= 1: parseInt(paramStr(1)) else: 48
let repeats = if paramCount() >= 2: parseInt(paramStr(2)) else: 5
let pool = loadBrS2PoolRaw()
let map = newBodyMap(mapFromSpecJson($pool[poolIndex]["spec"]))
startProfileTrace()
for repeat in 0 ..< repeats:
  profileBlock("index.complete"):
    let index = profileIndex(map)
    doAssert index.stats.navCells == map.gridWidth * map.gridHeight
finishProfileTrace()
# A5 pocket counters, summed over all repeats (divide by repeats per build).
echo %*{"pool_index": poolIndex, "map": map.name, "repeats": repeats,
  "grid": [map.gridWidth, map.gridHeight],
  "pocket_counters_total": %*{
    "coverage_cells": pocketProfile.coverageCells,
    "pixel_scan_cells": pocketProfile.pixelScanCells,
    "secondary_cells": pocketProfile.secondaryCells,
    "scanned_pixels": pocketProfile.scannedPixels,
    "deferred_secondary": pocketProfile.deferredSecondary,
    "coverage_unresolved_before_resolve": pocketProfile.coverageUnresolved,
    "coverage_pending_out": pocketProfile.coveragePending,
    "resolve_passes": pocketProfile.resolvePasses,
    "resolve_seeds": pocketProfile.resolveSeeds,
    "join_candidates": pocketProfile.joinCandidates,
    "join_paths": pocketProfile.joinPaths,
    "final_pending_in": pocketProfile.finalPending,
    "paths": pocketProfile.paths, "pocket_points": pocketProfile.pocketPoints}}

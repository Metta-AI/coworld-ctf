## A6 diagnostic: whole-array identities of the ROUTE INDEX (not the mixed
## graph) for every pool, configured, and colossal map, plus the pixel
## standability counters when compiled with -d:pixelStandabilityCounters.
## Build once per arm (-d:PixelStandabilityArm=eager|direct|lazy) and diff.
include ../src/shell/body_route_index
import std/json
import crunchy/[common, sha256]
import ../src/ctf/[arena, br_map_pool, sim_types]

proc digest[T](values: seq[T]): string =
  if values.len == 0: return sha256("").toHex()
  sha256(unsafeAddr values[0], values.len * sizeof(T)).toHex()

proc inspectMap(label: string; gameMap: CtfMap): JsonNode =
  let map = newBodyMap(gameMap)
  let index = newBodyRouteIndex(map)
  %*{"map": label, "legal_moves": digest(index.legalMoves),
    "room_of": digest(index.roomOf), "local_index": digest(index.localIndex),
    "room_cells": digest(index.roomCells), "cell_component": digest(index.cellComponent),
    "side_component": digest(index.sideComponent), "cells": digest(index.cells),
    "pocket_cells": digest(index.pocketCells),
    "pockets": index.pockets.len, "segments": index.segments.len,
    "arcs": index.arcs.len, "sides": index.sides.len,
    "fine_points": index.stats.finePoints, "graph_components": index.stats.graphComponents,
    "retained_bytes": index.stats.retainedBytes,
    "transient_peak_bytes": index.stats.transientPeakBytes}

var rows = newJArray()
let pool = loadBrS2PoolRaw()
for i in 0 ..< pool.len:
  stderr.writeLine "pool:", i
  rows.add inspectMap("pool:" & $i, mapFromSpecJson($pool[i]["spec"]))
let configured = parseJson(readFile(BrS2SoloMapPoolPath))
for i in 0 ..< configured.len:
  stderr.writeLine "configured:", i
  rows.add inspectMap("configured:" & $i, mapFromSpecJson($configured[i]))
stderr.writeLine "colossal"
rows.add inspectMap("colossal", generateCtfMap(4242,
  MapGenOverrides(size: "colossal", windows: -1, pits: -1, pitDensity: -1), 4))
var counters = newJNull()
when defined(pixelStandabilityCounters):
  counters = %*{"searches": pixelStandability.searches,
    "exact_edge_searches": pixelStandability.exactEdgeSearches,
    "invalid_start_returns": pixelStandability.invalidStartReturns,
    "box_pixels": pixelStandability.boxPixels,
    "eager_fills": pixelStandability.eagerFills,
    "read_requests": pixelStandability.readRequests,
    "canstand_evaluations": pixelStandability.canStandEvaluations}
echo %*{"arm": PixelStandabilityArm, "maps": rows, "counters_all_maps": counters}

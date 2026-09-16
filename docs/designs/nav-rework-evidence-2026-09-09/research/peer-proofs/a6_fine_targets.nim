## Scratch diagnostic (read-only include of production source): sizes that
## bound the per-call linear scan in pixelPocketPath on map 48.
include "/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-throughput-research/src/shell/body_route_index"
import std/json
import "/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-throughput-research/src/ctf/arena"
import "/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-throughput-research/src/ctf/br_map_pool"
let pool = loadBrS2PoolRaw()
for poolIndex in [48, 0, 10]:
  let map = newBodyMap(mapFromSpecJson($pool[poolIndex]["spec"]))
  let index = newBodyRouteIndex(map)
  let canonical = index.canonicalGraphMapping()
  let targets = index.initialFineTargets(canonical.byGraph)
  var negCells = 0
  for c in index.cells:
    if c < 0: inc negCells
  echo %*{"pool": poolIndex, "map": map.name, "grid": [map.gridWidth, map.gridHeight],
    "crossings": index.stats.crossings, "segment_cells": index.cells.len,
    "segment_fine_points": negCells, "initial_fine_targets": targets.len,
    "graph_components": index.stats.graphComponents,
    "pocket_connectors": index.stats.pocketConnectors, "pocket_fine_points": index.stats.finePoints}

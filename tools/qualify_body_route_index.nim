## Exhaustive Phase-2 qualification for BodyRouteIndex.
##
## Prints one TSV row per map. The default covers every published Season 2
## spec plus arena and the supported 4-team colossal fixture. `--quick` runs
## the first published map and arena for development only.

import std/[json, monotimes, os, strformat, times]
import ../src/ctf/[arena, br_map_pool, sim_types]
import ../src/shell/[body_map, body_route_index]

const
  PoolRetainedLimit = 16'i64 * 1024 * 1024
  ColossalRetainedLimit = 32'i64 * 1024 * 1024

proc milliseconds(duration: Duration): float =
  duration.inNanoseconds.float / 1_000_000.0

proc qualify(label: string, gameMap: CtfMap, colossal = false) =
  let mapStart = getMonoTime()
  let map = newBodyMap(gameMap)
  let mapTime = getMonoTime() - mapStart
  let indexStart = getMonoTime()
  let index = newBodyRouteIndex(map)
  let indexTime = getMonoTime() - indexStart
  let coverage = index.routeIndexCoverage()
  let stats = index.routeIndexStats()
  let
    mapMs = mapTime.milliseconds
    indexMs = indexTime.milliseconds
    activationRatio = (mapMs + indexMs) / mapMs
    retainedLimit = if colossal: ColossalRetainedLimit else: PoolRetainedLimit
    ratioLimit = if colossal: 3.0 else: 2.0
  echo label, '\t', map.width, 'x', map.height, '\t', stats.navCells, '\t',
    stats.walkableCells, '\t', stats.rooms, '\t', map.chokeCount, '\t',
    stats.portals, '\t', stats.sides, '\t', stats.droppedChokes, '\t',
    stats.maxRoomDegree, '\t', stats.portalFieldCells, '\t', stats.segments, '\t',
    stats.crossings, '\t', stats.fineCrossings, '\t', stats.pocketConnectors,
    '\t', stats.finePoints, '\t', stats.finePointBytes, '\t',
    stats.segmentCells, '\t', stats.arcs, '\t',
    stats.graphComponents, '\t', coverage.standablePixels, '\t',
    coverage.coveredPixels, '\t', coverage.uncoveredPixels, '\t',
    &"0x{coverage.componentHash:016x}", '\t', stats.retainedBytes, '\t',
    stats.transientPeakBytes, '\t', &"{mapMs:.3f}", '\t',
    &"{indexMs:.3f}", '\t', &"{activationRatio:.4f}"
  flushFile(stdout)
  if coverage.uncoveredPixels != 0:
    raise newException(BodyMapError,
      &"body route index map '{label}' leaves {coverage.uncoveredPixels} " &
      &"standable pixels uncovered; first={coverage.firstUncovered}")
  if stats.retainedBytes > retainedLimit:
    raise newException(BodyMapError,
      &"body route index map '{label}' retains {stats.retainedBytes} bytes, " &
      &"over limit {retainedLimit}")
  if activationRatio > ratioLimit:
    raise newException(BodyMapError,
      &"body route index map '{label}' activation ratio {activationRatio:.4f}, " &
      &"over limit {ratioLimit:.1f}")

proc colossalMap(): CtfMap =
  let overrides = MapGenOverrides(
    size: "colossal", windows: -1, pits: -1, pitDensity: -1)
  result = generateCtfMap(4242, overrides, 4)
  result.name = "size:colossal"

when isMainModule:
  echo "map\tsize_px\tnav_cells\twalkable\trooms\tchokes\tportals\tsides\t" &
    "dropped_chokes\tmax_room_degree\t" &
    "portal_field_cells\tsegments\tcrossings\tfine_crossings\t" &
    "pocket_connectors\tfine_points\t" &
    "fine_point_bytes\tsegment_cells\tarcs\t" &
    "graph_components\tstandable_px\tcovered_px\tuncovered_px\t" &
    "component_hash\tretained_bytes\ttransient_bytes\tbody_map_ms\t" &
    "index_ms\tactivation_ratio"
  let pool = loadBrS2PoolRaw()
  let limit = if paramCount() == 1 and paramStr(1) == "--quick": 1 else: pool.len
  for poolIndex in 0 ..< limit:
    var gameMap = mapFromSpecJson($pool[poolIndex]["spec"])
    gameMap.name = pool[poolIndex]["name"].getStr()
    qualify(&"published:{poolIndex:02}:{gameMap.name}", gameMap)
  qualify("arena", loadCtfMapMetadata("arena"))
  if limit == pool.len:
    qualify("size:colossal", colossalMap(), colossal = true)

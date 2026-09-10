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

let pool = loadBrS2PoolRaw()
let map = newBodyMap(mapFromSpecJson($pool[48]["spec"]))
startProfileTrace()
for repeat in 0 ..< 5:
  profileBlock("index.complete"):
    let index = profileIndex(map)
    doAssert index.stats.navCells == map.gridWidth * map.gridHeight
finishProfileTrace()

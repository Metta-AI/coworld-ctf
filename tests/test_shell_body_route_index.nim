## Phase-2 laws for the immutable episode-shared navigation index.

import std/[json, strutils, unittest]
import ../src/ctf/[arena, br_map_pool]
import ../src/shell/body_map
import ../src/shell/body_route_index

proc openMap(): BodyMap =
  const Side = 96
  var walkable = newSeq[bool](Side * Side)
  for y in 1 ..< Side - 1:
    for x in 1 ..< Side - 1:
      walkable[y * Side + x] = true
  newBodyMap(walkable, Side, Side, 2, @[(16, 16), (80, 80)],
    mapName = "open-test")

proc referenceSegmentClear(map: BodyMap, start, goal: BodyPoint): bool =
  if not map.canStand(start):
    return false
  let
    dx = goal.x - start.x
    dy = goal.y - start.y
    nx = abs(dx)
    ny = abs(dy)
    stepX = cmp(dx, 0)
    stepY = cmp(dy, 0)
  var x = start.x
  var y = start.y
  var ix = 0
  var iy = 0
  while ix < nx or iy < ny:
    let decision = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
    if decision == 0:
      if not map.canStand((x + stepX, y)) or not map.canStand((x, y + stepY)):
        return false
      x += stepX
      y += stepY
      inc ix
      inc iy
    elif decision < 0:
      x += stepX
      inc ix
    else:
      y += stepY
      inc iy
    if not map.canStand((x, y)):
      return false
  true

proc assertLegality(map: BodyMap) =
  for y in 0 ..< map.gridHeight:
    for x in 0 ..< map.gridWidth:
      let fromCell: BodyPoint = (x, y)
      for delta in NavNeighbors:
        let toCell: BodyPoint = (x + delta.x, y + delta.y)
        var expected = map.cellWalkable(fromCell) and map.cellWalkable(toCell)
        if expected and delta.x != 0 and delta.y != 0:
          expected = map.cellWalkable((toCell.x, fromCell.y)) and
            map.cellWalkable((fromCell.x, toCell.y))
        if expected:
          expected = referenceSegmentClear(map,
            cellCenter(fromCell), cellCenter(toCell))
        check map.legalNavMove(fromCell, toCell) == expected

suite "immutable shared body route index":
  test "canonical legality matches the old planner predicate":
    let open = openMap()
    open.assertLegality()

    let pool = newBodyMap(poolCtfMap(0))
    pool.assertLegality()

    let published = loadBrS2PoolRaw()
    let battleRoyale = newBodyMap(mapFromSpecJson($published[0]["spec"]))
    battleRoyale.assertLegality()

  test "index validates and is deterministic":
    let map = openMap()
    let first = newBodyRouteIndex(map)
    let second = newBodyRouteIndex(map)
    first.validateRouteIndex()
    second.validateRouteIndex()
    check first.routeIndexFingerprint == second.routeIndexFingerprint
    check first.routeIndexStats.navCells == map.gridWidth * map.gridHeight

  test "edge width and named activation failures fail closed":
    expect BodyMapError:
      validateRouteEdgeCapacity("too-wide-test", 32_768, 1)
    try:
      validateRouteEdgeCapacity("too-wide-test", 32_768, 1)
      check false
    except BodyMapError as error:
      check "too-wide-test" in error.msg
      check "32767" in error.msg

  test "fine crossing fallback stays sparse and decodes to coarse sampling":
    check FineCrossingMaxPops == 256
    let published = loadBrS2PoolRaw()
    var gameMap = mapFromSpecJson($published[0]["spec"])
    gameMap.name = published[0]["name"].getStr()
    let index = newBodyRouteIndex(newBodyMap(gameMap))
    let stats = index.routeIndexStats()
    check stats.fineCrossings > 0
    check stats.finePoints > 0
    check stats.finePointBytes == stats.finePoints * sizeof(int32)
    var countedFinePoints = 0
    for segment in 0 ..< stats.segments:
      for pointRef in index.segmentCells(segment):
        if pointRef >= 0:
          continue
        inc countedFinePoints
        check segment < stats.crossings
        let point = index.routePoint(pointRef)
        check point.x mod FineNavCell == 0
        check point.y mod FineNavCell == 0
        let coarse = index.routeNavCell(pointRef)
        check coarse >= 0
        let cell = index.map.cellOf(point)
        check coarse.int == cell.y * index.map.gridWidth + cell.x
    for pocket in 0 ..< stats.pocketConnectors:
      let points = index.pocketConnectorPoints(pocket)
      check points.len >= 2
      check points[0] < 0
      check points[^1] >= 0
      let
        phaseX = index.routePoint(points[0]).x mod FineNavCell
        phaseY = index.routePoint(points[0]).y mod FineNavCell
      for offset, pointRef in points:
        if pointRef < 0:
          inc countedFinePoints
          let point = index.routePoint(pointRef)
          check point.x mod FineNavCell == phaseX
          check point.y mod FineNavCell == phaseY
        if offset > 0:
          check index.map.segmentClear(index.routePoint(points[offset - 1]),
            index.routePoint(pointRef))
    check countedFinePoints == stats.finePoints

  test "portal sides come from their own coarse room anchors":
    let index = newBodyRouteIndex(newBodyMap(loadCtfMapMetadata("arena")))
    let stats = index.routeIndexStats()
    check stats.portals > 0
    check stats.sides == stats.portals * 2
    check stats.maxRoomDegree > 0
    check stats.droppedChokes >= 0
    for portal in 0 ..< stats.portals:
      let
        sideA = index.portalSideAt(portal * 2)
        sideB = index.portalSideAt(portal * 2 + 1)
        crossing = index.segmentCells(portal)
      check sideA.room.int == index.roomForCell(sideA.anchorCell.int)
      check sideB.room.int == index.roomForCell(sideB.anchorCell.int)
      check sideA.room != sideB.room
      check crossing[0] == sideA.anchorCell
      check crossing[^1] == sideB.anchorCell

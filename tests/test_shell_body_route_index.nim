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

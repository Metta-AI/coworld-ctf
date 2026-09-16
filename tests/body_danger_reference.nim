## Literal pre-optimization danger raster oracle from bf5eadc8.
## Keep its per-cell wall queries and uint32 stamps independent of production.
import std/math
import ../src/shell/[body_map, body_planner]

const
  DangerLosFlatPx = 400
  DangerLosFarFactor = 0.6
  DangerLosRangePx = 1050
  DangerCloseFloor = 0.5
  DangerClosePx = 190
  DangerLosWeight = 1.0

type
  DangerWorkspace = object
    visited: seq[uint32]
    visitGeneration: uint32
  DangerOracle* = ref object
    danger*: BodyDangerField
    dangerWorkspace: DangerWorkspace
    dangerKernel: seq[float32]
    dangerPerimeter: seq[BodyPoint]
    dangerRadius: int
    dangerRangePx: int
    dangerTick: int

proc pyRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction < 0.5: lower
  elif fraction > 0.5: lower + 1
  elif (lower and 1) == 0: lower
  else: lower + 1

proc attenuation(distancePx: float, liveGunRangePx: int): float32 =
  if distancePx > min(DangerLosRangePx, liveGunRangePx).float:
    return 0'f32
  if distancePx <= DangerLosFlatPx.float:
    return 1'f32
  let fraction = (distancePx - DangerLosFlatPx.float) /
    (DangerLosRangePx - DangerLosFlatPx).float
  (1.0 - fraction * (1.0 - DangerLosFarFactor)).float32

proc initDanger(map: BodyMap): tuple[field: BodyDangerField,
                                     workspace: DangerWorkspace] =
  let size = map.gridWidth * map.gridHeight
  result.field = BodyDangerField(values: newSeq[float32](size),
    gridW: map.gridWidth, gridH: map.gridHeight)
  result.workspace.visited = newSeq[uint32](size)

proc initDangerGeometry(liveGunRangePx: int): tuple[kernel: seq[float32],
                                 perimeter: seq[BodyPoint], radius: int] =
  ## Immutable ray geometry shared by all seats; activation-time allocation.
  result.radius = max(1, (liveGunRangePx + NavCell - 1) div NavCell)
  let diameter = result.radius * 2 + 1
  result.kernel = newSeq[float32](diameter * diameter)
  for dy in -result.radius .. result.radius:
    for dx in -result.radius .. result.radius:
      result.kernel[(dy + result.radius) * diameter + dx + result.radius] =
        attenuation(hypot(dx.float, dy.float) * NavCell.float, liveGunRangePx)
  var included = newSeq[bool](diameter * diameter)
  template includeOffset(dx, dy: int) =
    let index = (dy + result.radius) * diameter + dx + result.radius
    if not included[index]:
      included[index] = true
      result.perimeter.add((dx, dy))
  let radiusSquared = result.radius * result.radius
  for dx in -result.radius .. result.radius:
    let dy = pyRound(sqrt(max(0, radiusSquared - dx * dx).float))
    includeOffset(dx, dy)
    includeOffset(dx, -dy)
  for dy in -result.radius .. result.radius:
    let dx = pyRound(sqrt(max(0, radiusSquared - dy * dy).float))
    includeOffset(dx, dy)
    includeOffset(-dx, dy)

proc nextVisitGeneration(seat: DangerOracle) =
  if seat.dangerWorkspace.visitGeneration == high(uint32):
    for value in seat.dangerWorkspace.visited.mitems:
      value = 0
    seat.dangerWorkspace.visitGeneration = 1
  else:
    inc seat.dangerWorkspace.visitGeneration

proc addVisibleCell(seat: DangerOracle, origin: BodyPoint,
                    kernel: openArray[float32], kernelRadius,
                    gx, gy: int) {.inline.} =
  if gx < 0 or gx >= seat.danger.gridW or
      gy < 0 or gy >= seat.danger.gridH:
    return
  let index = gy * seat.danger.gridW + gx
  if seat.dangerWorkspace.visited[index] ==
      seat.dangerWorkspace.visitGeneration:
    return
  seat.dangerWorkspace.visited[index] =
    seat.dangerWorkspace.visitGeneration
  let diameter = kernelRadius * 2 + 1
  let kernelX = gx - origin.x + kernelRadius
  let kernelY = gy - origin.y + kernelRadius
  seat.danger.values[index] += kernel[kernelY * diameter + kernelX]

proc sightCellBlocked(map: BodyMap, x, y: int): bool {.inline.} =
  if x < 0 or x >= map.gridWidth or y < 0 or y >= map.gridHeight:
    return true
  map.isWall(cellCenter((x, y)))

proc castRay(seat: DangerOracle, map: BodyMap, origin: BodyPoint,
             kernel: openArray[float32], kernelRadius,
             targetX, targetY: int) =
  let dx = targetX - origin.x
  let dy = targetY - origin.y
  let nx = abs(dx)
  let ny = abs(dy)
  let stepX = cmp(dx, 0)
  let stepY = cmp(dy, 0)
  var x = origin.x
  var y = origin.y
  var ix = 0
  var iy = 0
  while ix < nx or iy < ny:
    let decision = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
    if decision == 0:
      let sideX = x + stepX
      let sideY = y + stepY
      if map.sightCellBlocked(sideX, y) or map.sightCellBlocked(x, sideY):
        break
      seat.addVisibleCell(origin, kernel, kernelRadius, sideX, y)
      seat.addVisibleCell(origin, kernel, kernelRadius, x, sideY)
      x = sideX
      y = sideY
      inc ix
      inc iy
    elif decision < 0:
      x += stepX
      inc ix
    else:
      y += stepY
      inc iy
    if map.sightCellBlocked(x, y):
      break
    seat.addVisibleCell(origin, kernel, kernelRadius, x, y)

proc rebuildDangerFromPoints(seat: DangerOracle, map: BodyMap,
                             sources: openArray[BodyPoint], tick: int) =
  ## Stencil's complete from-scratch LOS field. This scheduled rebuild is not
  ## part of the cold-plan counter; K bounds its server-wide tick burst.
  for value in seat.danger.values.mitems:
    value = 0
  for source in sources:
    let origin = map.cellOf(source)
    seat.nextVisitGeneration()
    seat.addVisibleCell(origin, seat.dangerKernel, seat.dangerRadius,
      origin.x, origin.y)
    for offset in seat.dangerPerimeter:
      seat.castRay(map, origin, seat.dangerKernel, seat.dangerRadius,
        origin.x + offset.x, origin.y + offset.y)
    let closeRange = min(DangerClosePx, seat.dangerRangePx)
    let closeCells = (closeRange + NavCell - 1) div NavCell
    let closeSquared = closeRange * closeRange
    for gy in max(0, origin.y - closeCells) ..
        min(map.gridHeight - 1, origin.y + closeCells):
      for gx in max(0, origin.x - closeCells) ..
          min(map.gridWidth - 1, origin.x + closeCells):
        let center = cellCenter((gx, gy))
        let dx = center.x - source.x
        let dy = center.y - source.y
        if dx * dx + dy * dy <= closeSquared:
          seat.danger.values[gy * map.gridWidth + gx] +=
            DangerCloseFloor.float32
  seat.danger.maximum = 0
  for value in seat.danger.values.mitems:
    if DangerLosWeight != 1.0:
      value *= DangerLosWeight.float32
    seat.danger.maximum = max(seat.danger.maximum, value)
  seat.dangerTick = tick

proc newDangerOracle*(map: BodyMap, rangePx: int): DangerOracle =
  let geometry = initDangerGeometry(rangePx)
  let danger = initDanger(map)
  DangerOracle(danger: danger.field, dangerWorkspace: danger.workspace,
    dangerKernel: geometry.kernel, dangerPerimeter: geometry.perimeter,
    dangerRadius: geometry.radius, dangerRangePx: rangePx)

proc rebuildReference*(oracle: DangerOracle, map: BodyMap,
                       sources: openArray[BodyPoint], tick: int) =
  oracle.rebuildDangerFromPoints(map, sources, tick)

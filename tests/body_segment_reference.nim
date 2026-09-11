## Literal pre-H2 segmentClear oracle, copied from body_planner.nim at
## 6b6b3408: the full supercover scan with side-pixel checks on exact
## diagonal steps. Test support only; never imported by src/. Immutable.
import ../src/shell/body_map

proc referenceSegmentClear*(map: BodyMap, start, goal: BodyPoint): bool =
  if not map.canStand(start):
    return false
  let dx = goal.x - start.x
  let dy = goal.y - start.y
  let nx = abs(dx)
  let ny = abs(dy)
  let stepX = cmp(dx, 0)
  let stepY = cmp(dy, 0)
  var x = start.x
  var y = start.y
  var ix = 0
  var iy = 0
  while ix < nx or iy < ny:
    let decision = (1 + 2 * ix) * ny - (1 + 2 * iy) * nx
    if decision == 0:
      if not map.canStand((x + stepX, y)) or
          not map.canStand((x, y + stepY)):
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

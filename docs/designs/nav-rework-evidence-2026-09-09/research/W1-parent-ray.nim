proc rayClear*(map: BodyMap, a, b: BodyPoint): bool =
  ## Pixel ray check for body-side weapon gating. Endpoints outside the map
  ## are blocked; otherwise any wall pixel sampled along the segment blocks.
  if not map.inBounds(a) or not map.inBounds(b):
    return false
  let
    dx = b.x - a.x
    dy = b.y - a.y
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return not map.isWall(a)
  for step in 0 .. steps:
    let point = (
      x: pyRound(a.x.float + dx.float * step.float / steps.float),
      y: pyRound(a.y.float + dy.float * step.float / steps.float))
    if map.isWall(point):
      return false
  true


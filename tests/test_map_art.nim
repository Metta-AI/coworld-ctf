import
  std/[math, unittest],
  ctf/map_art

## The numeric kernel under BOTH wall materials (rooftop and glass) and under
## the spun centre diamonds: one Euclidean distance transform of the art mask,
## and the surface normal read off its gradient.
##
## Why this is worth pinning: the shading it replaced fired four axis RAYS and
## took their min, which is not a distance (it overshoots an edge tilted θ off
## an axis by 1/cos θ) and quantized the surface normal into two buckets. Both
## errors are INVISIBLE on a rectilinear board and show up only on the
## diagonal and curved colliders — exactly the kind of regression a screenshot
## of the default arena will not catch, and exactly what breaks if the board
## ever stops being a square lattice.

proc bruteForceDistance(wall: seq[bool], w, h, x, y: int): float =
  ## The definition: the distance to the NEAREST floor pixel, by looking at
  ## every one of them. O(n²) and therefore only for tests, but it is the
  ## thing wallDistField has to agree with.
  result = Inf
  for fy in 0 ..< h:
    for fx in 0 ..< w:
      if not wall[fy * w + fx]:
        let d = sqrt(float((fx - x) * (fx - x) + (fy - y) * (fy - y)))
        if d < result:
          result = d

suite "wall distance field":
  test "is the exact Euclidean distance transform below its saturation":
    ## A mask carrying all four edge families the arena actually draws —
    ## axis-aligned rect, 45° bar, disc, and the solid border frame — so the
    ## comparison covers the orientations the ray metric got wrong.
    const
      w = 61
      h = 61
      border = 4
    var wall = newSeq[bool](w * h)
    for y in 0 ..< h:
      for x in 0 ..< w:
        let
          onBorder = x < border or y < border or
            x >= w - border or y >= h - border
          inRect = x in 10 .. 21 and y in 10 .. 33
          onDiagonal = abs((x - 30) - (y - 12)) <= 5 and
            x in 28 .. 44 and y in 10 .. 26
          inDisc = (x - 42) * (x - 42) + (y - 44) * (y - 44) <= 100
        wall[y * w + x] = onBorder or inRect or onDiagonal or inDisc
    let
      field = wallDistField(wall, w, h, 1)
      sat = field.distSat()
    check sat > 0
    var sawSaturated = false
    for y in 0 ..< h:
      for x in 0 ..< w:
        let
          truth = bruteForceDistance(wall, w, h, x, y)
          got = field.distAt(x, y)
        if truth < sat:
          ## Exact, up to the field's 1/64 px fixed point.
          check abs(got - truth) < 0.02
        else:
          ## Past the saturation the field promises only "deeper than any band
          ## the materials draw", and says so by pinning the value.
          sawSaturated = true
          check got == sat
    check sawSaturated                 ## the mask really does have a deep spot

  test "reads a true distance where the 4-ray metric overshot":
    ## The concrete regression, stated as the ratio it actually is. Firing an
    ## axis ray at an edge tilted θ off that axis overshoots the perpendicular
    ## distance by 1/cos θ, so on a 45° face the old metric read √2 × the
    ## truth — and every band it gated (ink line, parapet, lip) closed √2 too
    ## early, leaving the arena's chevrons wearing a visibly narrower rim than
    ## the rects beside them.
    const n = 41
    var wall = newSeq[bool](n * n)
    for y in 0 ..< n:
      for x in 0 ..< n:
        wall[y * n + x] = y >= x       ## a 45° half-plane, floor above-right

    proc rayDistance(x, y: int): float =
      ## What the 4-axis metric this replaced would have reported here.
      result = Inf
      for (dx, dy) in [(0, -1), (-1, 0), (0, 1), (1, 0)]:
        for step in 1 .. n:
          let
            nx = x + dx * step
            ny = y + dy * step
          if nx < 0 or ny < 0 or nx >= n or ny >= n:
            continue
          if not wall[ny * n + nx]:
            result = min(result, step.float)
            break

    let
      field = wallDistField(wall, n, n, 1)
      probeX = 20
      probeY = 24
      trueDist = bruteForceDistance(wall, n, n, probeX, probeY)
      ray = rayDistance(probeX, probeY)
    check abs(field.distAt(probeX, probeY) - trueDist) < 0.02
    check ray > trueDist * 1.3          ## the old metric really did overshoot…
    check abs(ray / trueDist - sqrt(2.0)) < 0.1   ## …by almost exactly √2.

suite "wall surface lighting":
  ## The light is fixed at the up-left. The contract is that an AXIS-ALIGNED
  ## face still lands exactly on the full highlight / full shadow it has
  ## always had (the arena is ~90% axis-aligned rects and must not shift),
  ## while off-axis faces get the in-between tones the two-bucket test could
  ## not express.
  proc halfPlaneLit(faces: string): float =
    ## Builds a half-plane whose outward normal points `faces`, and reads the
    ## lit fraction a few pixels inside it.
    const n = 41
    var wall = newSeq[bool](n * n)
    for y in 0 ..< n:
      for x in 0 ..< n:
        wall[y * n + x] =
          case faces
          of "up": y >= 20
          of "down": y <= 20
          of "left": x >= 20
          of "right": x <= 20
          of "up-left": x + y >= 40
          of "down-right": x + y <= 40
          of "up-right": y >= x
          of "down-left": y <= x
          else: raise newException(ValueError, faces)
    let field = wallDistField(wall, n, n, 1)
    case faces
    of "up": field.surfaceLit(20, 22)
    of "down": field.surfaceLit(20, 18)
    of "left": field.surfaceLit(22, 20)
    of "right": field.surfaceLit(18, 20)
    of "up-left": field.surfaceLit(21, 21)
    of "down-right": field.surfaceLit(19, 19)
    of "up-right": field.surfaceLit(20, 22)
    of "down-left": field.surfaceLit(20, 18)
    else: 0.0

  test "axis-aligned faces keep the full highlight and full shadow":
    check halfPlaneLit("up") == 1.0
    check halfPlaneLit("left") == 1.0
    check halfPlaneLit("down") == 0.0
    check halfPlaneLit("right") == 0.0

  test "a face square-on to the light is the brightest, and its opposite the darkest":
    check halfPlaneLit("up-left") == 1.0
    check halfPlaneLit("down-right") == 0.0

  test "a face edge-on to the light reads exactly halfway":
    ## The tone the 4-ray test could not produce: it put BOTH of these in the
    ## lit bucket, which is why a chevron's two long faces came out identical
    ## and the shape read flat.
    check abs(halfPlaneLit("up-right") - 0.5) < 0.001
    check abs(halfPlaneLit("down-left") - 0.5) < 0.001

  test "the ridge of a wall thinner than two parapets is neutral":
    ## Where two faces meet there is no single normal, and the gradient
    ## vanishes. Neutral is the honest answer; anything else picks a side.
    const n = 41
    var wall = newSeq[bool](n * n)
    for y in 0 ..< n:
      for x in 0 ..< n:
        wall[y * n + x] = x in 19 .. 21   ## a 3-px vertical bar
    let field = wallDistField(wall, n, n, 1)
    check abs(field.surfaceLit(20, 20) - 0.5) < 0.001
    ## …and its two faces still read left-lit / right-shaded.
    check field.surfaceLit(19, 20) == 1.0
    check field.surfaceLit(21, 20) == 0.0

## Differential weapon visibility tests against the previous floating sampler.
import std/[math, random, unittest]
import ../src/shell/body_map

proc referenceRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction > 0.5 or (fraction == 0.5 and (lower and 1) != 0):
    lower + 1
  else:
    lower

proc referenceRay(map: BodyMap; a, b: BodyPoint): bool =
  if not map.inBounds(a) or not map.inBounds(b): return false
  let dx = b.x - a.x
  let dy = b.y - a.y
  let steps = max(abs(dx), abs(dy))
  if steps == 0: return not map.isWall(a)
  for step in 0 .. steps:
    let point = (
      x: referenceRound(a.x.float + dx.float * step.float / steps.float),
      y: referenceRound(a.y.float + dy.float * step.float / steps.float))
    if map.isWall(point): return false
  true

suite "weapon ray sampling":
  test "every small ray agrees for every single blocking pixel":
    const Side = 64
    for wallY in 20 .. 27:
      for wallX in 20 .. 27:
        var pixels = newSeq[bool](Side * Side)
        for value in pixels.mitems: value = true
        pixels[wallY * Side + wallX] = false
        let map = newBodyMap(pixels, Side, Side, 1, @[(48, 48)])
        for ay in 20 .. 27:
          for ax in 20 .. 27:
            for by in 20 .. 27:
              for bx in 20 .. 27:
                let a = (ax, ay)
                let b = (bx, by)
                check map.rayClear(a, b) == map.referenceRay(a, b)
        check not map.rayClear((-1, 20), (20, 20))
        check not map.rayClear((20, 20), (Side, 20))

  test "seeded long rays preserve sampled walls in both directions":
    const Width = 8192
    const Height = 96
    var pixels = newSeq[bool](Width * Height)
    for value in pixels.mitems: value = true
    for x in countup(100, Width - 1, 97):
      pixels[(20 + x mod 50) * Width + x] = false
    let map = newBodyMap(pixels, Width, Height, 1, @[(32, 48)])
    var rng = initRand(9092026)
    for sample in 0 ..< 10000:
      let a = (rng.rand(Width - 1), rng.rand(Height - 1))
      let b = (rng.rand(Width - 1), rng.rand(Height - 1))
      check map.rayClear(a, b) == map.referenceRay(a, b)
      check map.rayClear(b, a) == map.referenceRay(b, a)

  test "clearance jumps preserve walls, borders and saturated distances":
    const Side = 640
    var pixels = newSeq[bool](Side * Side)
    for value in pixels.mitems: value = true
    pixels[320 * Side + 600] = false
    pixels[600 * Side + 320] = false
    let map = newBodyMap(pixels, Side, Side, 1, @[(32, 32)])
    check map.clearanceAt((300, 300)) == 255
    check map.clearanceAt((500, 320)) == 100
    check map.clearanceAt((500, 220)) == 100
    check map.clearanceAt((501, 221)) == 99
    let points = [(0, 0), (0, 1), (1, 0), (2, 1), (1, 2),
      (300, 300), (500, 320), (500, 220), (501, 221),
      (600, 320), (320, 600), (639, 359), (359, 639), (639, 639)]
    for a in points:
      for b in points:
        check map.rayClear(a, b) == map.referenceRay(a, b)

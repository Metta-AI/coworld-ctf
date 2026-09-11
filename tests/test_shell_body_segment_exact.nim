## H2 differential test: the production segmentClear must agree with the
## full supercover scan on every segment, including invalid endpoints,
## boundary-hugging segments, narrow corridors, corners and segments long
## enough to exceed the saturated clearance byte.
import std/[random, unittest]
import body_segment_reference
include ../src/shell/body_planner

proc obstacleMap(width, height, seed: int): BodyMap =
  ## Bordered map with a scatter of small blocks, a one-pixel-wide slit and
  ## a diagonal wall so corners and narrow passages occur at many spans.
  var rng = initRand(seed)
  var pixels = newSeq[bool](width * height)
  for y in 1 ..< height - 1:
    for x in 1 ..< width - 1:
      pixels[y * width + x] = true
  for _ in 0 ..< max(4, width * height div 900):
    let bx = rng.rand(1 ..< width - 6)
    let by = rng.rand(1 ..< height - 6)
    let bw = rng.rand(1 .. 5)
    let bh = rng.rand(1 .. 5)
    for y in by ..< min(height - 1, by + bh):
      for x in bx ..< min(width - 1, bx + bw):
        pixels[y * width + x] = false
  let slitX = width div 2
  for y in 1 ..< height - 1:
    if y notin (height div 2 - 7) .. (height div 2 + 7):
      pixels[y * width + slitX] = false
  for step in 0 ..< min(width, height) div 3:
    pixels[(height div 4 + step) * width + width div 4 + step] = false
  # Keep a guaranteed-standable spawn pocket clear of every obstacle.
  for y in 1 .. 16:
    for x in 1 .. 16:
      pixels[y * width + x] = true
  newBodyMap(pixels, width, height, 1, @[(9, 9)])

proc agree(map: BodyMap, start, goal: BodyPoint): bool =
  map.segmentClear(start, goal) == map.referenceSegmentClear(start, goal)

suite "segment legality exactness":
  test "every short segment from every pixel agrees, both directions":
    let map = obstacleMap(96, 72, seed = 7)
    var certified = 0
    var scanned = 0
    for y in -1 .. map.height:
      for x in -1 .. map.width:
        for dy in -5 .. 5:
          for dx in -5 .. 5:
            let start: BodyPoint = (x, y)
            let goal: BodyPoint = (x + dx, y + dy)
            check map.agree(start, goal)
            if map.clearanceAt(start) > PlayerHalf + max(abs(dx), abs(dy)):
              inc certified
            else:
              inc scanned
    check certified > 0
    check scanned > 0

  test "invalid and boundary endpoints agree":
    let map = obstacleMap(64, 48, seed = 11)
    for start in [(-1, -1), (0, 0), (63, 47), (64, 48), (-3, 20), (20, -3),
                  (70, 20), (20, 60), (1, 1), (62, 46)]:
      for goal in [(-1, -1), (0, 0), (63, 47), (64, 48), (200, 200),
                   (-200, -200), (32, 24), (1, 46), (62, 1), (5, 5)]:
        check map.agree(start, goal)
        check map.agree(goal, start)

  test "long segments through open space and past saturated clearance agree":
    # 640 px of open floor: interior clearance saturates at 255 far from the
    # border, so long segments exercise both the certified and scanned paths.
    const Side = 640
    var pixels = newSeq[bool](Side * Side)
    for y in 1 ..< Side - 1:
      for x in 1 ..< Side - 1:
        pixels[y * Side + x] = true
    for y in 20 .. 22:
      for x in 100 .. 540:
        pixels[y * Side + x] = false
    let map = newBodyMap(pixels, Side, Side, 1, @[(12, 320)])
    check map.clearanceAt((320, 30)) == 8
    check map.clearanceAt((320, 330)) == 255
    var rng = initRand(3)
    var certified = 0
    for _ in 0 ..< 4000:
      let start: BodyPoint = (rng.rand(0 ..< Side), rng.rand(0 ..< Side))
      let span = rng.rand(1 .. 400)
      let goal: BodyPoint = (start.x + rng.rand(-span .. span),
                             start.y + rng.rand(-span .. span))
      check map.agree(start, goal)
      check map.agree(goal, start)
      if map.clearanceAt(start) > PlayerHalf + max(abs(goal.x - start.x),
                                                    abs(goal.y - start.y)):
        inc certified
    check certified > 0

  test "randomized segments on generated obstacle maps agree":
    for seed in 1 .. 6:
      let map = obstacleMap(160 + seed * 16, 120 + seed * 8, seed)
      var rng = initRand(seed * 101)
      for _ in 0 ..< 20000:
        let start: BodyPoint = (rng.rand(-2 .. map.width + 1),
                                rng.rand(-2 .. map.height + 1))
        let span = rng.rand(0 .. 40)
        let goal: BodyPoint = (start.x + rng.rand(-span .. span),
                               start.y + rng.rand(-span .. span))
        check map.agree(start, goal)

  test "the planner lattice neighbours of a walkable lattice agree":
    let map = obstacleMap(200, 120, seed = 5)
    for y in countup(0, map.height - 1, PlanStepPx):
      for x in countup(0, map.width - 1, PlanStepPx):
        for delta in Neighbors:
          let goal: BodyPoint = (x + delta[0] * PlanStepPx,
                                 y + delta[1] * PlanStepPx)
          check map.agree((x, y), goal)

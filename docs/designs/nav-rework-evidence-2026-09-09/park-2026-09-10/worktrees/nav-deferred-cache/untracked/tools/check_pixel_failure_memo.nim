## Experiment-only tests of failed-search reuse and admission boundaries.
include ../src/shell/body_route_index
import std/[json, unittest]

proc isolatedMap(): BodyMap =
  const Side = 256
  var pixels = newSeq[bool](Side * Side)
  for y in 1 ..< Side - 1:
    for x in 1 ..< Side - 1:
      pixels[y * Side + x] = true
  newBodyMap(pixels, Side, Side, 2, @[(16, 16), (240, 240)])

let index = newBodyRouteIndex(isolatedMap())
let start: BodyPoint = (100, 100)
let targets = @[int32(index.cellIndex(index.map.cellOf((240, 240))))]

suite "construction-local failure memo":
  test "repeat skips queue writes and preserves generation rollover":
    var scratch = index.initPixelSearchScratch()
    let first = index.pixelPathInBox(start, start, targets, scratch)
    check first == PixelPath()
    check scratch.failureCount == 1
    scratch.queue[0] = -123
    check index.pixelPathInBox(start, start, targets, scratch) == first
    check scratch.queue[0] == -123
    check scratch.generation == 2
    scratch.generation = high(uint32)
    check index.pixelPathInBox(start, start, targets, scratch) == first
    check scratch.generation == 1
    for marker in scratch.visitedGeneration: check marker == 0
    for marker in scratch.targetGeneration: check marker == 0
    check scratch.queue[0] == -123
  test "every key input distinguishes failures":
    var scratch = index.initPixelSearchScratch()
    let secondTarget = targets[0] - 1
    discard index.pixelPathInBox(start, start, targets, scratch)
    discard index.pixelPathInBox(start, start, targets, scratch, true)
    discard index.pixelPathInBox(start, (101, 100), targets, scratch)
    discard index.pixelPathInBox((101, 100), start, targets, scratch)
    discard index.pixelPathInBox(start, start, @[targets[0], secondTarget], scratch)
    discard index.pixelPathInBox(start, start, @[secondTarget, targets[0]], scratch)
    check scratch.failureCount == 6
  test "full cache executes the 129th unique failure without eviction":
    var scratch = index.initPixelSearchScratch()
    for i in 0 ..< 128:
      discard index.pixelPathInBox((40 + i, 100), (40 + i, 100), targets, scratch)
    check scratch.failureCount == 128
    scratch.queue[0] = -123
    check index.pixelPathInBox((168, 100), (168, 100), targets, scratch) == PixelPath()
    check scratch.queue[0] != -123
    check scratch.failureCount == 128
    scratch.queue[0] = -123
    discard index.pixelPathInBox((40, 100), (40, 100), targets, scratch)
    check scratch.queue[0] == -123
  test "oversize target lists run without admission":
    var scratch = index.initPixelSearchScratch()
    var oversized = newSeq[int32](65)
    for target in oversized.mitems: target = targets[0]
    check index.pixelPathInBox(start, start, oversized, scratch) == PixelPath()
    check scratch.failureCount == 0
    scratch.queue[0] = -123
    check index.pixelPathInBox(start, start, oversized, scratch) == PixelPath()
    check scratch.queue[0] != -123
  test "invalid starts and successful paths are never admitted":
    var scratch = index.initPixelSearchScratch()
    discard index.pixelPathInBox((0, 0), start, targets, scratch)
    check scratch.generation == 0
    let nearTarget = int32(index.cellIndex(index.map.cellOf((112, 100))))
    let path = index.pixelPathInBox(start, start, @[nearTarget], scratch)
    check path.reachedTarget
    check path.points.len > 0
    check scratch.failureCount == 0

echo %*{"record_bytes": sizeof(PixelSearchFailure),
  "memo_bytes": sizeof(default(PixelSearchScratch).failures) + sizeof(int),
  "scratch_bytes": sizeof(PixelSearchScratch)}

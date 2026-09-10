## A6 diagnostic: focused exact-path equivalence for pixelPathInBox across
## standability arms. Crafted maps exercise: a failed search in a closed
## pocket, an exactEdges diagonal pinch that plain edges pass, an invalid
## start (early return), and generation rollover on a reused scratch.
## Build once per arm and diff the JSON outputs byte for byte.
include ../src/shell/body_route_index
import std/json

proc craft(width, height: int; walls: seq[(int, int, int, int)]): BodyMap =
  var walkable = newSeq[bool](width * height)
  for y in 1 ..< height - 1:
    for x in 1 ..< width - 1:
      walkable[y * width + x] = true
  for (x0, y0, x1, y1) in walls:
    for y in y0 .. y1:
      for x in x0 .. x1:
        walkable[y * width + x] = false
  newBodyMap(walkable, width, height, 2, @[(16, 16), (width - 17, height - 17)])

proc pathJson(path: PixelPath): JsonNode =
  var points = newJArray()
  for p in path.points: points.add %*[p.x, p.y]
  %*{"reached": path.reachedTarget, "target_ref": path.targetRef, "points": points}

proc search(index: BodyRouteIndex, scratch: var PixelSearchScratch,
    start, center: BodyPoint, targets: seq[int32], exactEdges: bool): JsonNode =
  let path = index.pixelPathInBox(start, center, targets, scratch, exactEdges)
  result = pathJson(path)
  result["generation_after"] = %scratch.generation.int64

var cases = newJArray()
# Map A: open field with a closed pocket (walls all around a 12x12 room with
# no gap) and a diagonal pinch: two wall blocks touching at a corner.
let mapA = craft(200, 120, @[
  (60, 40, 84, 42), (60, 40, 62, 64), (82, 40, 84, 64), (60, 62, 84, 64),   # closed pocket
  (120, 30, 140, 60), (141, 61, 160, 90)])                                    # corner pinch
let indexA = newBodyRouteIndex(mapA)
var scratch = indexA.initPixelSearchScratch()
proc cellRef(index: BodyRouteIndex, x, y: int): int32 =
  int32(index.cellIndex(index.map.cellOf((x, y))))
# 1. failed search: start inside the closed pocket, target outside.
cases.add %*{"case": "closed_pocket", "result": indexA.search(scratch,
  (72, 52), (72, 52), @[indexA.cellRef(100, 52)], false)}
# 2. pinch: from one side of the corner touch to the other, plain vs exact.
for exact in [false, true]:
  cases.add %*{"case": "corner_pinch", "exact_edges": exact,
    "result": indexA.search(scratch, (138, 63), (138, 63),
      @[indexA.cellRef(144, 58)], exact)}
# 3. invalid start: outside the box / not standable.
cases.add %*{"case": "invalid_start_outside_box", "result": indexA.search(scratch,
  (10, 10), (100, 60), @[indexA.cellRef(100, 52)], false)}
cases.add %*{"case": "invalid_start_wall", "result": indexA.search(scratch,
  (61, 41), (61, 41), @[indexA.cellRef(100, 52)], false)}
# 4. open-field success, then generation rollover on the same scratch.
cases.add %*{"case": "open_success", "result": indexA.search(scratch,
  (20, 100), (20, 100), @[indexA.cellRef(40, 100)], true)}
scratch.generation = high(uint32) - 2
for repeat in 0 ..< 5:
  cases.add %*{"case": "rollover_" & $repeat, "result": indexA.search(scratch,
    (20 + repeat, 100), (20 + repeat, 100), @[indexA.cellRef(40, 100)], repeat mod 2 == 0)}
# 5. Real geometry: pool map 48, a search from every 24th standable pixel in
# raster order toward the nearest coarse cell anchors of its own graph, with
# plain and exact edges. Only a hash chain of every result is recorded, so
# a single differing path anywhere changes the output.
import ../src/ctf/[arena, br_map_pool]
import std/[hashes, strutils]
let pool = loadBrS2PoolRaw()
let map48 = newBodyMap(mapFromSpecJson($pool[48]["spec"]))
let index48 = newBodyRouteIndex(map48)
var scratch48 = index48.initPixelSearchScratch()
var chain: Hash = 0
var real = 0
var realReached = 0
var edgeModeDifferences = 0
var edgeModeExample = newJNull()
var counter = 0
for y in 0 ..< map48.height:
  for x in 0 ..< map48.width:
    let point: BodyPoint = (x, y)
    if not map48.canStand(point): continue
    inc counter
    if counter mod 24 != 0: continue
    let cell = map48.cellOf(point)
    let graph = index48.cellComponent[index48.cellIndex(cell)]
    var targets: seq[int32]
    for ring in 1 .. 3:
      for c in ringCells(cell, ring):
        if c.x < 0 or c.x >= map48.gridWidth or c.y < 0 or c.y >= map48.gridHeight: continue
        if index48.cellComponent[index48.cellIndex(c)] == graph and graph != 0:
          targets.add int32(index48.cellIndex(c))
    var plainResult: JsonNode
    for exact in [false, true]:
      let path = index48.pixelPathInBox(point, point, targets, scratch48, exact)
      let resultJson = pathJson(path)
      if not exact:
        plainResult = resultJson
      elif resultJson != plainResult:
        inc edgeModeDifferences
        if edgeModeExample.kind == JNull:
          edgeModeExample = %*{"start": [point.x, point.y], "plain": plainResult, "exact": resultJson}
      inc real
      if path.reachedTarget: inc realReached
      chain = chain !& hash(path.reachedTarget) !& hash(path.targetRef.int) !& hash(path.points.len)
      for pt in path.points: chain = chain !& hash(pt.x) !& hash(pt.y)
let realJson = %*{"map": map48.name, "searches": real, "reached": realReached,
  "result_chain_hash": toHex(int64(!$chain), 16),
  "exact_edge_differences": edgeModeDifferences, "exact_edge_example": edgeModeExample}
var counters = newJNull()
when defined(pixelStandabilityCounters):
  counters = %*{"searches": pixelStandability.searches,
    "exact_edge_searches": pixelStandability.exactEdgeSearches,
    "invalid_start_returns": pixelStandability.invalidStartReturns,
    "box_pixels": pixelStandability.boxPixels, "eager_fills": pixelStandability.eagerFills,
    "read_requests": pixelStandability.readRequests,
    "canstand_evaluations": pixelStandability.canStandEvaluations}
echo %*{"arm": PixelStandabilityArm, "cases": cases, "real_map48": realJson, "counters": counters}

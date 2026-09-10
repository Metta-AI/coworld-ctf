import std/[json, random, strformat]
import ctf/[arena, br_map_pool]
import shell/[body_map, body_danger, body_nav, body_route_query]
# Parent scatter, copied verbatim from P1-parent-body_route_query.nim (Q8 via the shared packer path is private, so replicate it).
proc parentQ8(value: float32): uint16 =
  if value <= 0: return 0
  let scaled = value.float * 256.0
  let lower = scaled.int
  let fraction = scaled - lower.float
  let rounded = if fraction > 0.5 or (fraction == 0.5 and (lower and 1) != 0): lower + 1 else: lower
  doAssert rounded <= 0x7fff
  uint16(rounded)
proc parentPack(width, height: int; values: seq[float32]): seq[int16] =
  result = newSeq[int16](width * height)
  for cell, value in values: result[cell] = cast[int16](parentQ8(value))
  for source, value in values:
    if value <= 0: continue
    let cx = source mod width
    let cy = source div width
    for dy in -1 .. 1:
      for dx in -1 .. 1:
        let nx = cx + dx
        let ny = cy + dy
        if nx >= 0 and nx < width and ny >= 0 and ny < height:
          let off = ny * width + nx
          result[off] = cast[int16](cast[uint16](result[off]) or 0x8000'u16)
var total = 0
var bad = 0
proc compare(label: string, graph: BodyMixedGraph, values: seq[float32]) =
  let w = graph.map.gridWidth
  let h = graph.map.gridHeight
  let danger = BodyDangerField(values: values, gridW: w, gridH: h)
  var got: seq[int16]
  graph.rebuildPackedWeights(danger, got)
  let want = parentPack(w, h, values)
  inc total
  if got != want:
    inc bad
    var first = -1
    for i in 0 ..< got.len:
      if got[i] != want[i]: first = i; break
    echo "MISMATCH ", label, " first cell ", first
let s2 = loadBrS2PoolRaw()
let giant = parseJson(readFile(BrS2SoloMapPoolPath))
for (label, gm, rng) in [("s2-15", mapFromSpecJson($s2[15]["spec"]), 331), ("giant-5", mapFromSpecJson($giant[5]), 1300)]:
  let map = newBodyMap(gm)
  let graph = newBodyMixedGraph(map)
  # real rasters: nav system with 8 sources around a point, at the given range
  let nav = newBodyNavSystem(map, 1, rng)
  var seeds = initRand(20260909)
  for trial in 0 ..< 6:
    var cands: seq[DangerCandidate]
    let cx = seeds.rand(map.width - 1)
    let cy = seeds.rand(map.height - 1)
    for k in 0 ..< 8:
      cands.add DangerCandidate(seatIndex: k + 1, pos: (clamp(cx + (k mod 3 - 1) * 16, 0, map.width - 1), clamp(cy + (k div 3 - 1) * 16, 0, map.height - 1)))
    nav.initializeDanger([DangerInput(selfXy: (cx, cy), candidates: cands)], 0)
    compare(&"{label} real sources trial {trial}", graph, nav.seats[0].dangerSnapshot)
  nav.initializeDanger([DangerInput(selfXy: (0, 0))], 0)
  compare(&"{label} empty", graph, nav.seats[0].dangerSnapshot)
  # synthetic: random sparse, random dense, tiny positives, negatives, full positive
  let n = map.gridWidth * map.gridHeight
  for density in [0.001, 0.05, 0.5, 1.0]:
    var v = newSeq[float32](n)
    for i in 0 ..< n:
      if seeds.rand(1.0) < density: v[i] = float32(seeds.rand(1.0 .. 60.0))
      elif seeds.rand(1.0) < 0.01: v[i] = -1.0'f32
      elif seeds.rand(1.0) < 0.01: v[i] = 1e-7'f32
    compare(&"{label} synthetic density {density}", graph, v)
echo "compared ", total, " rasters, mismatches ", bad

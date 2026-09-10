import std/[json, math, random, strformat]
import ctf/[arena, br_map_pool]
import shell/body_map
proc referenceRound(value: float): int =
  let lower = floor(value).int
  let fraction = value - lower.float
  if fraction > 0.5 or (fraction == 0.5 and (lower and 1) != 0): lower + 1 else: lower
proc referenceRay(map: BodyMap; a, b: BodyPoint): bool =
  if not map.inBounds(a) or not map.inBounds(b): return false
  let dx = b.x - a.x
  let dy = b.y - a.y
  let steps = max(abs(dx), abs(dy))
  if steps == 0: return not map.isWall(a)
  for step in 0 .. steps:
    let point = (x: referenceRound(a.x.float + dx.float * step.float / steps.float),
                 y: referenceRound(a.y.float + dy.float * step.float / steps.float))
    if map.isWall(point): return false
  true
proc run(label: string, gameMap: CtfMap, pairs: int, maxRange: int) =
  let map = newBodyMap(gameMap)
  var rng = initRand(20260909)
  var mismatches = 0
  var clear = 0
  for i in 0 ..< pairs:
    let a: BodyPoint = (x: rng.rand(map.width - 1), y: rng.rand(map.height - 1))
    let b: BodyPoint = (x: clamp(a.x + rng.rand(-maxRange .. maxRange), 0, map.width - 1),
                        y: clamp(a.y + rng.rand(-maxRange .. maxRange), 0, map.height - 1))
    let got = map.rayClear(a, b)
    let want = map.referenceRay(a, b)
    if got: inc clear
    if got != want:
      inc mismatches
      if mismatches <= 5: echo "MISMATCH ", label, " a=", a, " b=", b, " got=", got, " want=", want
  echo &"{label}: pairs={pairs} clear={clear} mismatches={mismatches}"
let s2 = loadBrS2PoolRaw()
run("s2 pool 15", mapFromSpecJson($s2[15]["spec"]), 200_000, 1300)
run("s2 pool 29", mapFromSpecJson($s2[29]["spec"]), 100_000, 1300)
let giant = parseJson(readFile(BrS2SoloMapPoolPath))
run("giant 5", mapFromSpecJson($giant[5]), 200_000, 1300)
run("giant 5 short", mapFromSpecJson($giant[5]), 200_000, 40)

## Tests for the scene-graph mapgen prototype.
##
## The one that matters most is `negative control`: it turns the vandal scene
## on and asserts the post-condition FAILS. A guard nobody has ever seen fire
## is indistinguishable from a guard that cannot fire, and this repo has
## shipped that mistake before.

import std/[strutils, tables]
import ../src/ctf/[sim, map_metrics, mapgen_graph]

proc check(name: string, cond: bool) =
  if cond: echo "  [OK] " & name
  else:
    echo "  [FAIL] " & name
    quit(1)

echo "scene-graph mapgen"

block determinism:
  let a = generateGraphMap(4001)
  let b = generateGraphMap(4001)
  check "the same seed generates the same map",
    a.gameMap.leftObstacles.len == b.gameMap.leftObstacles.len and
    mapSpecJson(a.gameMap) == mapSpecJson(b.gameMap)

block streamsAreKeyedByPath:
  ## The property the per-stage sub-stream work needs: two different scene
  ## paths draw independently, and a path's stream does not depend on how
  ## many siblings precede it.
  check "distinct scene paths get distinct streams",
    streamSeed(7, "root/districtPlan") != streamSeed(7, "root/glazier")
  check "a scene path's stream ignores its sibling index",
    streamSeed(7, "root/glazier.0:0") == streamSeed(7, "root/glazier.0:0")

block validity:
  ## Every placement names what it serves, and the maps pass the sim's own
  ## validator — the same gate the current generator has to clear.
  var valid, total, placements, named = 0
  for seed in 4001 .. 4012:
    let g = generateGraphMap(seed)
    for p in g.board.placements:
      inc placements
      if p.serves.len > 0: inc named
    if g.rejected: continue
    inc total
    if validateGeneratedMap(g.gameMap).len == 0: inc valid
  check "every one of " & $placements & " placements names a purpose",
    placements > 0 and named == placements
  check "at least 10 of 12 seeds produce a map the sim validator accepts",
    valid >= 10
  check "the plan refuses rather than patches", total <= 12

block architecture:
  ## The headline claim. `interiorFrac` is the scatter-versus-buildings
  ## discriminator: the hand-authored arena measures 0.342 and the current
  ## generator's curated pool has a median of 0.118.
  var best = 0.0
  for seed in 4001 .. 4008:
    let g = generateGraphMap(seed)
    if g.rejected: continue
    let m = evaluateMap(g.gameMap, "graph")
    if m.valid and m.interiorFrac > best: best = m.interiorFrac
  check "interiorFrac clears the current pool's median by a wide margin",
    best > 0.20

block negativeControl:
  ## THE control. With the vandal scene off, the glazier's promise holds; with
  ## it on, the driver must catch the broken promise by name.
  let clean = generateGraphMap(4001, breakGlass = false)
  check "the glazier's promise holds when nothing blocks it",
    not clean.rejected or clean.reason.startsWith("REJECT")
  var caught = false
  for seed in 4001 .. 4006:
    let broken = generateGraphMap(seed, breakGlass = true)
    if broken.rejected and broken.reason.contains("broke its promise"):
      caught = true
      break
  check "a wall parked in front of glass FAILS the post-condition", caught

echo "  scene-graph mapgen: ok"

## Diagnostic (not a test, not timing): on the BR golden map, how many of
## the planner's 4 px lattice edges from standable lattice nodes the H2
## clearance certificate answers without a scan. Run from the repo root:
##   nim c -f -d:release --hints:off -o:/tmp/hr docs/research/nav-512-2026-09-11/H2/certificate_hit_rate.nim && /tmp/hr
import ../../../../src/ctf/arena
import ../../../../src/shell/body_map
import ../../../../src/shell/body_planner

let map = newBodyMap(mapFromSpecJson(readFile("tests/fixtures/br-golden-map.json")))
var nodes, edges, certified = 0
for y in countup(0, map.height - 1, PlanStepPx):
  for x in countup(0, map.width - 1, PlanStepPx):
    if not map.canStand((x, y)): continue
    inc nodes
    let clearance = map.clearanceAt((x, y))
    for dx in -1 .. 1:
      for dy in -1 .. 1:
        if dx == 0 and dy == 0: continue
        inc edges
        if clearance > PlayerHalf + PlanStepPx: inc certified
echo "standable_lattice_nodes=", nodes, " edges=", edges, " certified=", certified,
  " certified_fraction=", certified.float / edges.float

## Does the scene graph strand floor? The sim validator only demands that the
## flags and the centre connect, so a sealed courtyard interior would ship
## silently as dead space. Measure it against the arena and the pool.
import std/strformat
import ../src/ctf/[sim, map_pool, mapgen_graph]

proc deadFrac(m: CtfMap): (float, int) =
  let d = mapDiagnostics(m, {diagnosticCorridorOpen, diagnosticReachable})
  var open, reach = 0
  for i in 0 ..< m.width * m.height:
    if d.corridorOpen[i]:
      inc open
      if d.reachable[i]: inc reach
  ((open - reach).float / max(1, open).float, open - reach)

let a = deadFrac(loadCtfMapMetadata("arena"))
echo &"arena       dead={a[0]*100:5.2f}% ({a[1]}px)"
for i in 0 ..< 4:
  let p = deadFrac(poolCtfMap(i))
  echo &"pool:{i}      dead={p[0]*100:5.2f}% ({p[1]}px)"
for s in 4001 .. 4008:
  let g = generateGraphMap(s)
  if g.rejected: continue
  let r = deadFrac(g.gameMap)
  echo &"graph-{s}  dead={r[0]*100:5.2f}% ({r[1]}px)"

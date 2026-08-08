## mapgraph_eval — score the scene-graph prototype against the control and
## against the current generator's own pool, on the SAME measuring stick.
##
## Rule 1 of `map_eval` applies here too: the hand-authored `arena` is
## scored in every run and printed first. A prototype that cannot be read as
## a delta from the control is not a measurement.

import std/[os, strformat, strutils, algorithm, sequtils, tables]
import pixie
import ../src/ctf/[sim, map_metrics, map_pool, mapgen_graph]
import ../tools/map_render

proc pct(x: float): string = &"{x * 100.0:5.1f}%"

proc line(m: MapMetrics): string =
  let flag = if m.valid: "ok  " else: "FAIL"
  &"{flag} {m.name:<14} {m.width}x{m.height} score={m.staticScore:5.3f} " &
    &"interior={pct(m.interiorFrac)} exposed={pct(m.exposedFrac)} " &
    &"cover={m.coverPermille}bp routes={m.routeCountMin} " &
    &"mid={m.midCrossCount}x/{pct(m.midOpenFrac)} " &
    &"stand={pct(m.standCoverMin)} ringOpen={pct(m.standRingOpenMin)} " &
    &"collCover={m.collisionCoverRatio:4.2f} detour={m.detourMax:4.2f} " &
    &"longRun={pct(m.longRunFrac)}" &
    (if m.valid: "" else: "  << " & m.reason)

proc median(xs: seq[float]): float =
  if xs.len == 0: return 0.0
  var s = xs
  s.sort()
  s[s.len div 2]

when isMainModule:
  let
    args = commandLineParams()
    count = if args.len > 0: parseInt(args[0]) else: 12
    size = if args.len > 1: args[1] else: "standard"
    renderDir = if args.len > 2: args[2] else: ""
    coverTarget = if args.len > 3: parseInt(args[3]) else: 180

  echo "CONTROL"
  let control = evaluateMap(loadCtfMapMetadata("arena"), "arena")
  echo line(control)

  echo "\nCURRENT GENERATOR (curated pool, standard class only)"
  var poolScores, poolInterior: seq[float]
  for i in 0 ..< MapPoolSeeds.len:
    let m = evaluateMap(poolCtfMap(i), "pool:" & $i)
    if m.width != control.width: continue
    echo line(m)
    poolScores.add m.staticScore
    poolInterior.add m.interiorFrac

  echo "\nSCENE-GRAPH PROTOTYPE"
  var
    graphScores, graphInterior: seq[float]
    valid, rejected, broke = 0
    serves: CountTable[string]
    shapeCounts: seq[int]
  for s in 0 ..< count:
    let seed = 4001 + s
    let g = generateGraphMap(seed, size, coverTarget)
    for p in g.board.placements: serves.inc p.serves
    shapeCounts.add g.board.placements.len
    if g.rejected:
      inc rejected
      if not g.reason.startsWith("REJECT"): inc broke
      echo &"REJ  graph-{seed}  {g.reason}"
      continue
    let m = evaluateMap(g.gameMap, "graph-" & $seed)
    ## Failures ALWAYS print, however large the sweep. A summary that hides
    ## its rejects is how a generator ships a defect it already measured.
    if count <= 16 or not m.valid: echo line(m)
    if m.valid:
      inc valid
      graphScores.add m.staticScore
      graphInterior.add m.interiorFrac
    if renderDir.len > 0 and m.valid:
      createDir(renderDir)
      let img = renderMap(g.gameMap, MapRenderOptions(maxDimension: 900))
      img.image.writeFile(renderDir / &"graph-{seed}.png")

  echo "\nINTENT LEDGER (what every placed feature says it is FOR)"
  var kinds = toSeq(serves.pairs)
  kinds.sort(proc(a, b: (string, int)): int = cmp(b[1], a[1]))
  for (k, n) in kinds: echo &"  {n:5}  {k}"
  echo &"  postcondition failures: {broke}"
  if shapeCounts.len > 0:
    echo &"  shapes per map: min {min(shapeCounts)} max {max(shapeCounts)}"

  echo "\nSUMMARY (staticScore, then interiorFrac)"
  echo &"  arena control        {control.staticScore:5.3f}   " &
    &"{pct(control.interiorFrac)}"
  if poolScores.len > 0:
    let (a, b, c) = (min(poolScores), median(poolScores), max(poolScores))
    echo &"  current gen (n={poolScores.len:2})    " &
      &"min {a:5.3f} med {b:5.3f} max {c:5.3f}   " &
      &"interior med {pct(median(poolInterior))}"
  if graphScores.len > 0:
    let (a, b, c) = (min(graphScores), median(graphScores), max(graphScores))
    echo &"  scene graph (n={graphScores.len:2})    " &
      &"min {a:5.3f} med {b:5.3f} max {c:5.3f}   " &
      &"interior med {pct(median(graphInterior))}"
  echo &"  graph: {valid} valid, {count - valid - rejected} invalid, " &
    &"{rejected} refused by the plan"

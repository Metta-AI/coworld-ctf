## Per-seed diagnostics for the ROOM generator, with the hand-authored arena
## as the control in every batch.
##
## The contact sheet shows what a map LOOKS like; this shows what it IS —
## which cells became rooms, how many independent routes the street network
## carries, whether the interval cover closed the scan band, and which
## validator gate rejected a first attempt. Read the two together: a
## generator that scores well and renders as wallpaper has optimised the
## metric and lost the game, and only the picture can tell you that.
##
## Usage: nim c -d:release -r tools/map_bench.nim [count] [teams] [firstSeed]
## Demo/curation tooling; not part of the server.
import
  std/[algorithm, math, os, sequtils, strformat, strutils, tables],
  ../src/ctf/[arena, map_metrics, sim]

proc pct(a, b: int): string =
  if b == 0: "  n/a" else: &"{100.0 * float(a) / float(b):5.1f}%"

when isMainModule:
  let
    count = if paramCount() >= 1: parseInt(paramStr(1)) else: 30
    teams = if paramCount() >= 2: parseInt(paramStr(2)) else: 2
    first = if paramCount() >= 3: parseInt(paramStr(3)) else: 1000
    ov = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)

  ## CONTROL FIRST, always. A metric that flags the control is wrong; a
  ## metric that skips it is worse. Both have happened here.
  block control:
    installDefaultArena()
    let
      ctrl = loadCtfMap()
      m = evaluateMap(ctrl, "arena")
    echo &"CONTROL arena  static {staticScore(m):.3f}  interior {m.interiorFrac:.3f}" &
      &"  routes {m.routeCountMin}  longRun {m.longRunFrac:.3f}" &
      &"  diagP95 {m.diagRunP95Px}  standRingOpenMin {m.standRingOpenMin:.3f}"

  var
    pass1, total = 0
    interiors, statics: seq[float]
    reasons = initCountTable[string]()
    patterns = initCountTable[string]()
    archetypes = initCountTable[string]()
    bySize = initCountTable[string]()
    passBySize = initCountTable[string]()
    routeFails, coverFails, screenPxTotal, wallPxTotal, rowGaps: int
    brokenPosts, glassPanes, glassRejected: int
    cellCounts: seq[int]
  echo "seed  size      sym    pattern   arch      cells rings hall blk plz rub apr " &
    "  door route gaps glass  cov‰  interior static  reason"
  for i in 0 ..< count:
    let seed = first + i
    var attemptMap: CtfMap
    try:
      attemptMap = generateMapAttempt(seed, ov, teams, 0)
    except CatchableError as e:
      echo &"{seed}  RAISED {e.msg}"
      continue
    inc total
    let
      board = buildRoomBoard(terrainHostFor(attemptMap, teams), seed, 0)
      st = board.stats
      diag = mapDiagnostics(attemptMap)
      reason = diag.reason
      sizeName = attemptMap.mapSizeClassName()
    bySize.inc sizeName
    if reason.len == 0:
      inc pass1
      passBySize.inc sizeName
    else:
      reasons.inc reason.split(':')[0].split(" at ")[0]
    patterns.inc $board.style.pattern
    archetypes.inc $board.style.archetype
    cellCounts.add st.cells
    screenPxTotal += st.screenPx
    wallPxTotal += st.wallPx
    rowGaps += st.uncoveredRows
    brokenPosts += st.brokenPosts.len
    glassPanes += st.glassPanes
    glassRejected += st.glassRejected
    if st.skeletonRoutes < 3: inc routeFails
    if diag.minCoverPermille < CoverPermilleMin or
        diag.coverPermille > CoverPermilleMax: inc coverFails

    ## The SELECTED map (best-of-K) is what ships, so score that one.
    var shipped: CtfMap
    try:
      shipped = generateCtfMap(seed, ov, teams)
    except CatchableError:
      shipped = attemptMap
    let m = evaluateMap(shipped, "gen")
    if m.valid:
      interiors.add m.interiorFrac
      statics.add staticScore(m)
    echo &"{seed} {sizeName:<9} {($attemptMap.symmetry)[3..^1]:<6} " &
      &"{($board.style.pattern)[2..^1]:<9} {($board.style.archetype)[2..^1]:<9} " &
      &"{st.cells:5} {st.rings:5} {st.halls:4} {st.blocks:3} {st.plazas:3} " &
      &"{st.rubble:3} {st.aprons:3} {st.doorways:5} {st.skeletonRoutes:5} " &
      &"{st.uncoveredRows:4} {st.glassPanes:5} {diag.coverPermille:5} " &
      &"{m.interiorFrac:8.3f} {staticScore(m):6.3f}  {reason}"

  echo ""
  echo &"first-attempt pass  {pass1}/{total} ({pct(pass1, total)})"
  for size in toSeq(bySize.keys).sorted:
    echo &"  {size:<10} {passBySize[size]}/{bySize[size]} " &
      &"({pct(passBySize[size], bySize[size])})"
  if interiors.len > 0:
    var iv = interiors
    iv.sort()
    var sv = statics
    sv.sort()
    echo &"interiorFrac  median {iv[iv.len div 2]:.3f}  " &
      &"min {iv[0]:.3f}  max {iv[^1]:.3f}   (control 0.342, old gen 0.210)"
    echo &"staticScore   median {sv[sv.len div 2]:.3f}  mean " &
      &"{sum(sv) / float(sv.len):.3f}   (old gen mean 0.939)"
  var cc = cellCounts
  cc.sort()
  if cc.len > 0:
    echo &"cells/domain  median {cc[cc.len div 2]}  min {cc[0]}  max {cc[^1]}"
  echo &"repair-plug share of wall  {pct(screenPxTotal, max(1, wallPxTotal))}" &
    "   (acceptance: 0%)"
  echo &"skeleton route count < 3   {routeFails}/{total}"
  echo &"uncovered scan rows, total {rowGaps}"
  echo &"broken post-conditions     {brokenPosts}"
  echo &"glass panes {glassPanes}, rejected for no sightline {glassRejected}"
  echo "patterns:   ", patterns
  echo "archetypes: ", archetypes
  if reasons.len > 0:
    echo "first-attempt rejections:"
    for r, n in reasons:
      echo &"  {n:4}  {r}"

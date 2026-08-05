## lane_probe — measures the length-aware corridor rule, the chokepoint
## detector, the isovist assertion and the collision point over a batch of
## maps, ALWAYS with the hand-authored `arena` as CONTROL.
##
## A metric that flags the control is wrong; one that SKIPS the control is
## worse. Both have happened in this repo, so the control is not optional
## here — it is row one of every batch.
##
##   nim c -d:release -r tools/lane_probe.nim [pool-count]

import std/[os, random, strformat, strutils]
import ../src/ctf/[sim, map_lanes, map_metrics, map_rules, mapgen_styles]

proc homesOf(gameMap: CtfMap): seq[MapPoint] =
  for t in gameMap.teams():
    result.add gameMap.flagHome(t)

proc probe(gameMap: CtfMap, label: string) =
  let diag = mapDiagnostics(gameMap, {diagnosticWallMasks})
  let
    w = gameMap.width
    h = gameMap.height
    homes = homesOf(gameMap)
    audit = auditCorridorPinches(diag.maxWall, w, h, homes)
    iso = chokepointsCovered(diag.maxWall, w, h, audit.chokepoints)
    coll = collisionFrontier(diag.maxWall, w, h, homes)
    m = evaluateMap(gameMap, label)

  var inBand, tooLong, tested = 0
  var narrowest = high(int)
  for r in audit.runs:
    if r.tested: inc tested
    if r.mandatory:
      narrowest = min(narrowest, r.minWidthPx)
      if r.inDesignBand: inc inBand
      if r.arcLenPx > r.allowedPx: inc tooLong
  if narrowest == high(int): narrowest = 0

  let rw = routeWidthPx(diag.maxWall, w, h, homes)
  echo &"{label:<14} {w}x{h} valid={m.valid}"
  echo &"   ROUTEWIDTH {rw}px  (corridor floor is {RecommendedCorridorWidthPx}px" &
       &", engine minimum {EngineMinCorridorPx}px)"
  echo &"   routes    k(min)={m.routeCountMin} k(max)={m.routeCountMax} " &
       &"bottleneck={m.bottleneckPx}px midCross={m.midCrossCount}"
  echo &"   pinches   sections={audit.runs.len} onRouteTested={tested} " &
       &"chokepoints={audit.chokepoints.len} inBand(30-45)={inBand} " &
       &"overlong={tooLong} worstExcess={audit.worstExcessPx}px"
  echo &"   verdict   ok={audit.ok} narrowestCut={narrowest}px  " &
       (if audit.reason.len > 0: "reason=" & audit.reason else: "reason=-")
  echo &"   isovist   allChokesCovered={iso.covered} " &
       (if iso.covered: &"from=({iso.x},{iso.y})" else: "from=-") &
       &"   (metrics: chokeCount={m.chokeCount} covered={m.chokeCovered})"
  echo &"   collision ({coll.x},{coll.y}) coverRatio=" &
       formatFloat(coll.coverRatio, ffDecimal, 2) &
       &" lobes={coll.components} ok={coll.ok}" &
       &"   (metrics: ratio=" & formatFloat(m.collisionCoverRatio, ffDecimal, 2) &
       &" routes={m.collisionRoutes})"
  if audit.runs.len > 0:
    let r = audit.runs[0]
    echo &"   worst     ({r.x},{r.y}) width={r.minWidthPx}px arc={r.arcLenPx}px " &
         &"allowed={r.allowedPx}px mandatory={r.mandatory} onRoute={r.onRoute}"
  echo ""

# --- the carved map -----------------------------------------------------------

proc carvedMap(seed: int): tuple[m: CtfMap, plan: LanePlan] =
  ## A carved map built on the arena's own shell, so the comparison against
  ## the control changes ONLY the obstacle set.
  var gameMap = loadCtfMapMetadata("arena")
  let
    rules = mapRules("standard", 2)
    base = gameMap.flagHome(Red)
    seamX = gameMap.width div 2
    region = MapRect(
      x: BorderPx, y: BorderPx,
      w: seamX - BorderPx, h: gameMap.height - 2 * BorderPx)
    coverRegion = MapRect(
      x: base.x + gameMap.spawnClearW + 30, y: BorderPx + 20,
      w: seamX - (base.x + gameMap.spawnClearW + 30) - 10,
      h: gameMap.height - 2 * BorderPx - 40)
  var rng = initRand(seed)
  let cover = generateShapes(styleScatter, seed, coverRegion,
    defaultParams(styleScatter))
  let carved = carveLanes(rng, region, base, seamX, rules, cover)
  gameMap.leftObstacles = carved.shapes
  gameMap.name = "carved:" & $seed
  gameMap.genSeed = seed
  (gameMap, carved.plan)

proc probeCarved(seed: int) =
  let (gameMap, plan) = carvedMap(seed)
  let diag = mapDiagnostics(gameMap, {diagnosticWallMasks})
  var homes: seq[MapPoint]
  for t in gameMap.teams(): homes.add gameMap.flagHome(t)
  let
    w = gameMap.width
    h = gameMap.height
    audit = auditCorridorPinches(diag.maxWall, w, h, homes)
    m = evaluateMap(gameMap, gameMap.name)
  echo &"{gameMap.name:<14} valid={m.valid} reason={m.reason}"
  echo &"   ROUTEWIDTH {audit.routeWidthPx}px  k(min)={m.routeCountMin} " &
       &"k(max)={m.routeCountMax} midCross={m.midCrossCount} " &
       &"cover={m.coverPermille}permille"
  echo "   lanes:"
  for lane in plan.lanes:
    echo &"      {lane.role:<10} width={lane.widthPx}px length={lane.lengthPx}px " &
         &"gates={lane.gates.len}"
  var gateDesc = ""
  for lane in plan.lanes:
    for g in lane.gates:
      gateDesc &= &"({g.x},{g.y}) {g.widthPx}x{g.runPx}px  "
  echo "   built gates: ", gateDesc
  echo &"   audit: ok={audit.ok} gates={audit.gates.len} " &
       &"chokes={audit.chokepoints.len} passes={audit.routePasses}"
  for r in audit.gates:
    echo &"      pass{r.pass} ({r.x},{r.y}) w={r.minWidthPx} exposed={r.exposedPx} " &
         &"allowed={r.allowedPx} band={r.inDesignBand} mand={r.mandatory}"
  var pts: seq[PinchRun]
  for lane in plan.lanes:
    for g in lane.gates:
      pts.add PinchRun(x: g.x, y: g.y, minWidthPx: g.widthPx)
  let isoBuilt = chokepointsCovered(diag.maxWall, w, h, pts)
  let isoFound = chokepointsCovered(diag.maxWall, w, h, audit.gates)
  echo &"   isovist: builtGatesCovered={isoBuilt.covered} " &
       &"foundGatesCovered={isoFound.covered}"
  let coll = collisionFrontier(diag.maxWall, w, h, homes)
  echo &"   collision ({coll.x},{coll.y}) coverRatio=" &
       formatFloat(coll.coverRatio, ffDecimal, 2) &
       &" lobes={coll.components}   (metrics ratio=" &
       formatFloat(m.collisionCoverRatio, ffDecimal, 2) &
       &" routes={m.collisionRoutes})"
  echo ""

when isMainModule:
  echo "--- maxPinchRunPx schedule (the derivation, evaluated) ---"
  for wpx in [26, 30, 34, 38, 40, 45, 50, 56, 62, 68, 80]:
    echo &"   width {wpx:>3}px -> accuracy {dodgeAccuracyPct(wpx):>3}% -> " &
         &"shots {shotsToKillAt(dodgeAccuracyPct(wpx))} -> " &
         &"maxPinchRun {maxPinchRunPx(wpx):>4}px"
  echo &"   (map_rules.MaxExposedRunPx = {MaxExposedRunPx}px, " &
       &"RecommendedCorridorWidthPx = {RecommendedCorridorWidthPx}px)"
  echo ""

  let count = if paramCount() >= 1: parseInt(paramStr(1)) else: 4
  echo "=== CONTROL ==="
  probe(loadCtfMapMetadata("arena"), "arena")
  echo "=== POOL ==="
  for i in 0 ..< count:
    probe(poolCtfMap(i), &"pool:{i}")
  echo "=== CARVED ==="
  for s in 1 .. 3:
    probeCarved(1000 + s)

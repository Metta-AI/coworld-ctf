## map_table — the static-metric table extractor for ANY map source.
##
## Computes the same columns used in the 9-map converter/non-converter diff
## (tasks#42 71322) for a `gen:<seed>`, a named map (`arena`), a `pool:<i>`, OR
## an arbitrary mapSpec JSON file (`--spec path.json`). Built so artifact [B]'s
## hand-authored base maps (operator directive, c71326) get the SAME table as
## the generated seeds, on the same instrument — apples to apples.
##
## Columns (one row per map): valid, symmetry, endzone, biome, staticScore,
## survivalWorst (return-route carrier survival, tools/return_exposure), and the
## circulation/route metrics from map_metrics (routeMin/Max, routeCapFrac,
## collisionRoutes, interiorFrac, visDegMean, midCross), plus the contract-gate
## diagnostics (windows pass/total, trench routed/total, item reach-imbalance)
## — REPORTED, not gated (71322: the contract gate is anti-correlated with
## conversion, so it is a diagnostic here, never an accept filter).
##
## The mapSpec path uses arena.mapFromSpecJson (the same loader replays use), so
## every field the metrics read (leftObstacles, trenches, medKitSpawns, symmetry)
## is populated. Verified round-trip: dump gen:N via mapSpecJson, reload via
## --spec, metrics are identical (see --verify).
##
## Build / run:
##   export PATH="$HOME/.nimby/nim/bin:$PATH"; cd ~/mirror
##   nim c -d:release --out:/tmp/map_table tools/map_table.nim
##   /tmp/map_table gen:4120 gen:4020 arena       # named / seed sources
##   /tmp/map_table --spec basemap_a.json         # a hand-authored spec
##   /tmp/map_table --spec-dir sheets/            # every *.json in a dir
##   /tmp/map_table --verify 4120                 # round-trip self-check
import
  std/[os, math, strformat, strutils],
  ../src/ctf/[arena, map_metrics, map_lanes, sim_types, map_rules]

const
  CoverReachPx = 20
  LethalPx = LethalEnvelopePx
  WindowSightlineMinPx = 15
  FaceProbePx = 40

type
  Row = object
    src: string
    valid: bool
    symmetry: string
    endzone: string
    biome: string
    staticScore: float
    survivalWorst: float
    routeMin, routeMax: int
    routeCapFrac: float
    collisionRoutes: int
    interiorFrac: float
    visDegMean: float
    midCross: int
    windowPass, windowTotal: int
    trenchRouted, trenchTotal: int
    itemImb: float

proc returnSurvivalSide(m: CtfMap, walk, wall: seq[bool], w, h: int,
                        team: Team): float =
  ## Cover-weighted return-route survival, identical composite to
  ## tools/return_exposure.nim (0.7 cover / 0.3 exposed-run).
  let enemy = if team == Red: Blue else: Red
  let grabAt = m.flagHome(enemy)
  let src = nearestWalkable(walk, w, h, m.flagHome(team).x, m.flagHome(team).y)
  if src < 0: return 0.0
  let field = geodesic(walk, w, h, [src])
  var cur = nearestWalkable(walk, w, h, grabAt.x, grabAt.y)
  if cur < 0 or field[cur] < 0: return 0.0
  var path = @[cur]
  var guard = 0
  while field[cur] > 0 and guard < w * h:
    inc guard
    let cx = cur mod w
    let cy = cur div w
    var best = cur
    var bestD = field[cur]
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      let nx = cx + dx
      let ny = cy + dy
      if nx < 0 or ny < 0 or nx >= w or ny >= h: continue
      let ni = ny * w + nx
      if not walk[ni] or field[ni] < 0: continue
      if field[ni] < bestD: bestD = field[ni]; best = ni
    if best == cur: break
    cur = best
    path.add cur
  if path.len < 2: return 0.0
  var covered = 0
  var run = 0
  var maxRun = 0
  for i in path:
    let px = i mod w
    let py = i div w
    var nearCover = CoverReachPx + 1
    for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
      for step in 1 .. CoverReachPx:
        let x = px + dx * step
        let y = py + dy * step
        if x < 0 or y < 0 or x >= w or y >= h or wall[y * w + x]:
          if step < nearCover: nearCover = step
          break
    if nearCover <= CoverReachPx: inc covered; run = 0
    else:
      inc run
      if run > maxRun: maxRun = run
  let coverFrac = covered.float / path.len.float
  let exposedPenalty = min(1.0, maxRun.float / float(LethalPx))
  max(0.0, min(1.0, 0.7 * coverFrac + 0.3 * (1.0 - exposedPenalty)))

proc windowDiag(m: CtfMap, walk, wall: seq[bool], w, h: int):
    tuple[pass, total: int] =
  for shape in buildArenaObstacles(m):
    if not shape.window: continue
    inc result.total
    let (x0, y0, x1, y1) = shapeBounds(shape)
    let cx = (x0 + x1) div 2
    let cy = (y0 + y1) div 2
    let horiz = (y1 - y0) >= (x1 - x0)
    let (dxA, dyA, dxB, dyB) = if horiz: (-1, 0, 1, 0) else: (0, -1, 0, 1)
    let shortHalf = (if horiz: x1 - x0 else: y1 - y0) div 2 + 1
    proc probe(dx, dy: int): tuple[sight: int, stand: bool] =
      let sx = cx + dx * shortHalf
      let sy = cy + dy * shortHalf
      for step in 1 .. FaceProbePx:
        let x = sx + dx * step
        let y = sy + dy * step
        if x < 0 or y < 0 or x >= w or y >= h or wall[y * w + x]: break
        inc result.sight
        if walk[y * w + x]: result.stand = true
    let a = probe(dxA, dyA)
    let b = probe(dxB, dyB)
    if a.stand and b.stand and a.sight >= WindowSightlineMinPx and
       b.sight >= WindowSightlineMinPx: inc result.pass

proc trenchDiag(m: CtfMap, walk: seq[bool], w, h: int):
    tuple[routed, total: int] =
  result.total = m.trenches.len
  let s = nearestWalkable(walk, w, h, m.flagHome(Red).x, m.flagHome(Red).y)
  let field = if s >= 0: geodesic(walk, w, h, [s]) else: newSeq[int32](0)
  for tr in m.trenches:
    let (x0, y0, x1, y1) = shapeBounds(tr)
    let tcx = (x0 + x1) div 2
    let tcy = (y0 + y1) div 2
    let ci = nearestWalkable(walk, w, h, tcx, tcy)
    if ci < 0 or (field.len > 0 and field[ci] < 0): continue
    proc openSide(dx, dy: int): bool =
      let x = tcx + dx * ((if dx != 0: x1 - x0 else: y1 - y0) div 2 + 4)
      let y = tcy + dy * ((if dy != 0: y1 - y0 else: x1 - x0) div 2 + 4)
      x >= 0 and y >= 0 and x < w and y < h and walk[y * w + x]
    if (openSide(-1, 0) and openSide(1, 0)) or (openSide(0, -1) and openSide(0, 1)):
      inc result.routed

proc itemImbalance(m: CtfMap, walk: seq[bool], w, h: int): float =
  proc reach(a, b: MapPoint): int =
    let s = nearestWalkable(walk, w, h, a.x, a.y)
    if s < 0: return -1
    let f = geodesic(walk, w, h, [s])
    let t = nearestWalkable(walk, w, h, b.x, b.y)
    if t < 0: return -1
    int(f[t])
  let rh = m.flagHome(Red)
  let bh = m.flagHome(Blue)
  var worst = 0.0
  for mk in m.medKitSpawns:
    let dR = reach(rh, mk)
    let dB = reach(bh, mk)
    if dR >= 0 and dB >= 0:
      let mean = (dR + dB).float / 2.0
      if mean > 0:
        let i = abs(dR - dB).float / mean
        if i > worst: worst = i
  worst

proc symText(s: MapSymmetry): string =
  case s
  of symMirror: "mirror"
  of symRot180: "rot180"
  of symRot90: "rot90"
  of symQuadMirror: "quadmirror"

proc ezText(e: EndzoneShape): string =
  case e
  of ezColumn: "column"
  of ezDisc: "disc"
  of ezSquare: "square"

proc rowFor(src: string, m: CtfMap): Row =
  result.src = src
  let e = evaluateMap(m, src)
  result.valid = e.valid
  result.symmetry = symText(m.symmetry)
  result.endzone = ezText(m.endzone)
  result.biome = $m.biome
  result.staticScore = e.staticScore()
  result.routeMin = e.routeCountMin
  result.routeMax = e.routeCountMax
  result.routeCapFrac = e.routeCapacityFrac
  result.collisionRoutes = e.collisionRoutes
  result.interiorFrac = e.interiorFrac
  result.visDegMean = e.visDegreeMean
  result.midCross = e.midCrossCount
  let diag = mapDiagnostics(m, {diagnosticWallMasks, diagnosticCorridorOpen})
  let walk = diag.corridorOpen
  let wall = diag.maxWall
  let w = m.width
  let h = m.height
  result.survivalWorst = min(returnSurvivalSide(m, walk, wall, w, h, Red),
                             returnSurvivalSide(m, walk, wall, w, h, Blue))
  (result.windowPass, result.windowTotal) = windowDiag(m, walk, wall, w, h)
  (result.trenchRouted, result.trenchTotal) = trenchDiag(m, walk, w, h)
  result.itemImb = itemImbalance(m, walk, w, h)

proc loadSource(src: string): CtfMap =
  ## A source is a spec file (ends .json / contains a path sep) or a named/seed
  ## map string. mapFromSpecJson is the replay loader — fully populates the map.
  if src.endsWith(".json") or '/' in src:
    mapFromSpecJson(readFile(src))
  else:
    loadCtfMapMetadata(src)

proc emitHeader() =
  echo "src,valid,symmetry,endzone,biome,staticScore,survivalWorst," &
    "routeMin,routeMax,routeCapFrac,collisionRoutes,interiorFrac,visDegMean," &
    "midCross,windows,trenchRouted,itemImb"

proc emit(r: Row) =
  echo &"{r.src},{r.valid},{r.symmetry},{r.endzone},{r.biome}," &
    &"{r.staticScore:.4f},{r.survivalWorst:.3f}," &
    &"{r.routeMin},{r.routeMax},{r.routeCapFrac:.3f},{r.collisionRoutes}," &
    &"{r.interiorFrac:.3f},{r.visDegMean:.2f},{r.midCross}," &
    &"{r.windowPass}/{r.windowTotal},{r.trenchRouted}/{r.trenchTotal},{r.itemImb:.3f}"

proc verify(seed: string): int =
  ## Round-trip: gen:seed direct vs the same map dumped to spec JSON and
  ## reloaded via mapFromSpecJson. Every metric must match, or the spec path
  ## is not equivalent to the generated map and the table is not comparable.
  let direct = loadCtfMapMetadata("gen:" & seed)
  let spec = mapSpecJson(direct)
  let reloaded = mapFromSpecJson(spec)
  let a = rowFor("gen:" & seed, direct)
  let b = rowFor("spec:" & seed, reloaded)
  stderr.writeLine "# VERIFY round-trip gen:" & seed & " (direct) vs reloaded-from-spec"
  emitHeader(); emit(a); emit(b)
  var ok = true
  template chk(field: untyped, nm: string) =
    if a.field != b.field:
      stderr.writeLine "#   MISMATCH " & nm & ": " & $a.field & " vs " & $b.field
      ok = false
  chk(staticScore, "staticScore"); chk(survivalWorst, "survivalWorst")
  chk(routeMin, "routeMin"); chk(collisionRoutes, "collisionRoutes")
  chk(interiorFrac, "interiorFrac"); chk(visDegMean, "visDegMean")
  chk(windowTotal, "windowTotal"); chk(trenchTotal, "trenchTotal")
  chk(itemImb, "itemImb")
  if ok:
    stderr.writeLine "# VERIFY PASS: spec-loaded map is metric-identical to the generated map."
    return 0
  stderr.writeLine "# VERIFY FAIL: spec path diverges — table not comparable across sources."
  return 1

when isMainModule:
  doAssert mapFitnessInstalled(),
    "map fitness not installed — generated maps would not match the shipping map"
  let args = commandLineParams()
  if args.len == 0:
    quit("usage: map_table <src...> | --spec <f.json...> | --spec-dir <dir> | --verify <seed>")
  if args[0] == "--verify":
    quit(verify(args[1]))
  var sources: seq[string]
  var i = 0
  while i < args.len:
    case args[i]
    of "--spec":
      inc i
      while i < args.len and not args[i].startsWith("--"): sources.add args[i]; inc i
    of "--spec-dir":
      inc i
      for f in walkFiles(args[i] / "*.json"): sources.add f
      inc i
    else:
      sources.add args[i]; inc i
  emitHeader()
  for s in sources:
    try: emit(rowFor(s, loadSource(s)))
    except CatchableError as e:
      stderr.writeLine &"# {s}: ERROR {e.msg}"

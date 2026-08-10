## p6_curate — generate-many → gate-hard → curate a P6 (disguised-rotation) wave.
##
## P6 is the disguised-rotation pattern (doctrine-06 Part IV): a core whose two
## halves are a 180° ROTATION of each other, not a mirror — it reads different
## left-to-right (rotated, not reflected) while staying functionally balanced by
## construction. The current generator ALREADY produces this class: 2-team seeds
## draw `symRot180` ~half the time (the other half are `symMirror`). So P6 is the
## one slate pattern buildable on the current generator TODAY — the structural
## disguised-rotation core exists; only the theming/decoration asymmetry pass
## that doctrine-06 layers on top is missing (a cosmetic follow-up, flagged).
##
## This is the operator loop (69605/69857): large candidate set → per-side gates
## + Balance Ledger accept-gate → curated shortlist for the dash seat to render →
## Maxwell picks. It runs the SAME instruments already validated on this branch
## (contract_gate window/item logic + balance_ledger five-currency gate + a
## timing sanity read), so a seed that survives here survived every gate.
##
## STATIC — no episodes. Emits a shortlist to stdout as a table plus a machine
## block (one line per accepted seed) the dash seat can render straight off.
##
## Build / run:
##   export PATH="$HOME/.nimby/nim/bin:$PATH"; cd ~/mirror
##   nim c -d:release --out:/tmp/p6_curate tools/p6_curate.nim
##   /tmp/p6_curate 4001 4200 12      # sweep 4001..4200, shortlist top 12
import
  std/[os, math, algorithm, strformat, strutils],
  ../src/ctf/[arena, map_metrics, map_lanes, sim_types]

const
  LedgerTol = 0.10
  InfoRays = 64
  InfoRayMaxPx = 400
  WindowSightlineMinPx = 15
  FaceProbePx = 40

type
  Candidate = object
    seed: int
    valid: bool
    endzone: EndzoneShape
    biome: MapBiome
    # ledger currencies, per side
    timeA, timeB: int
    coverA, coverB: float
    infoA, infoB: float
    routesA, routesB: int
    posA, posB: float
    ledgerAccept: bool
    ledgerWorst: float          ## worst per-currency imbalance (for ranking)
    # contract gate
    windowPass, windowFail: int
    itemImb: float
    itemOnFloor, itemReachBoth, itemTotal: int
    contractAccept: bool
    staticScore: float
    accepted: bool

proc imb(a, b: float): float =
  if a < 0 or b < 0: return -1.0
  let m = (a + b) / 2.0
  if m == 0: 0.0 else: abs(a - b) / m

proc infoOpenness(wall: seq[bool], w, h, sx, sy: int): float =
  var openRays = 0
  for k in 0 ..< InfoRays:
    let ang = 2.0 * PI * float(k) / float(InfoRays)
    let tx = sx + int(round(cos(ang) * float(InfoRayMaxPx)))
    let ty = sy + int(round(sin(ang) * float(InfoRayMaxPx)))
    if map_lanes.losClear(wall, w, h, sx, sy, tx, ty): inc openRays
  openRays.float / InfoRays.float

proc windowContract(m: CtfMap, walk, wall: seq[bool], w, h: int):
    tuple[pass, fail: int] =
  for shape in buildArenaObstacles(m):
    if not shape.window: continue
    let (x0, y0, x1, y1) = shapeBounds(shape)
    let cx = (x0 + x1) div 2
    let cy = (y0 + y1) div 2
    let paneW = x1 - x0 + 1
    let paneH = y1 - y0 + 1
    let horiz = paneH >= paneW
    let (dxA, dyA, dxB, dyB) = if horiz: (-1, 0, 1, 0) else: (0, -1, 0, 1)
    let shortHalf = (if horiz: paneW else: paneH) div 2 + 1
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
    let ok = a.stand and b.stand and
      a.sight >= WindowSightlineMinPx and b.sight >= WindowSightlineMinPx
    if ok: inc result.pass else: inc result.fail

proc reachablePx(walk: seq[bool], w, h: int, a, b: MapPoint): int =
  let s = nearestWalkable(walk, w, h, a.x, a.y)
  if s < 0: return -1
  let field = geodesic(walk, w, h, [s])
  let t = nearestWalkable(walk, w, h, b.x, b.y)
  if t < 0: return -1
  int(field[t])

proc evaluate(seed: int): Candidate =
  result.seed = seed
  let m = loadCtfMapMetadata(&"gen:{seed}")
  let metrics = evaluateMap(m, &"gen:{seed}")
  result.valid = metrics.valid
  result.endzone = m.endzone
  result.biome = m.biome
  result.staticScore = metrics.staticScore()
  let
    w = m.width
    h = m.height
    diag = mapDiagnostics(m, {diagnosticWallMasks, diagnosticCorridorOpen})
    walk = diag.corridorOpen
    wall = diag.maxWall
  var anchors: seq[MapPoint]
  for team in m.teams(): anchors.add m.flagHome(team)
  let cf = collisionFrontier(wall, w, h, anchors)
  let midStand = nearestWalkable(walk, w, h, cf.x, cf.y)
  # per-side ledger
  proc sideTime(team: Team): int =
    let home = m.flagHome(team)
    let src = nearestWalkable(walk, w, h, home.x, home.y)
    if src < 0 or midStand < 0: return -1
    int(geodesic(walk, w, h, [src])[midStand])
  result.timeA = sideTime(Red)
  result.timeB = sideTime(Blue)
  if metrics.standCover.len >= 2:
    result.coverA = metrics.standCover[0]; result.coverB = metrics.standCover[1]
  if metrics.standRingArcs.len >= 2:
    result.routesA = metrics.standRingArcs[0]; result.routesB = metrics.standRingArcs[1]
  if metrics.standRingOpen.len >= 2:
    result.posA = metrics.standRingOpen[0]; result.posB = metrics.standRingOpen[1]
  result.infoA = infoOpenness(wall, w, h, m.flagHome(Red).x, m.flagHome(Red).y)
  result.infoB = infoOpenness(wall, w, h, m.flagHome(Blue).x, m.flagHome(Blue).y)
  let currencies = [imb(result.timeA.float, result.timeB.float),
                    imb(result.coverA, result.coverB),
                    imb(result.infoA, result.infoB),
                    imb(result.routesA.float, result.routesB.float),
                    imb(result.posA, result.posB)]
  result.ledgerAccept = result.valid
  result.ledgerWorst = 0.0
  for c in currencies:
    if c < 0 or c > LedgerTol: result.ledgerAccept = false
    if c > result.ledgerWorst: result.ledgerWorst = c
  # contract gate: window + item
  let (wp, wf) = windowContract(m, walk, wall, w, h)
  result.windowPass = wp; result.windowFail = wf
  result.itemTotal = m.medKitSpawns.len
  let redHome = m.flagHome(Red)
  let blueHome = m.flagHome(Blue)
  var maxImb = 0.0
  for mk in m.medKitSpawns:
    if nearestWalkable(walk, w, h, mk.x, mk.y) >= 0: inc result.itemOnFloor
    let dR = reachablePx(walk, w, h, redHome, mk)
    let dB = reachablePx(walk, w, h, blueHome, mk)
    if dR >= 0 and dB >= 0:
      inc result.itemReachBoth
      let mean = (dR + dB).float / 2.0
      if mean > 0:
        let i = abs(dR - dB).float / mean
        if i > maxImb: maxImb = i
  result.itemImb = maxImb
  result.contractAccept = result.valid and wf == 0 and
    result.itemOnFloor == result.itemTotal and
    result.itemReachBoth == result.itemTotal and maxImb <= LedgerTol
  result.accepted = result.ledgerAccept and result.contractAccept

when isMainModule:
  # map_metrics installs the generator fitness hook at module init; without it
  # generateCtfMap ships first-valid maps, not the ranked shipping map, and the
  # whole curated wave would be off-map. Fail closed.
  doAssert mapFitnessInstalled(),
    "map fitness not installed — generated maps would not match the shipping map"
  let args = commandLineParams()
  if args.len < 2:
    quit("usage: p6_curate <loSeed> <hiSeed> [topN=12]")
  let
    lo = args[0].parseInt
    hi = args[1].parseInt
    topN = if args.len >= 3: args[2].parseInt else: 12
  stderr.writeLine &"# p6_curate: sweeping gen:{lo}..{hi}, P6=symRot180 (disguised " &
    &"rotation), gates=contract(window/item)+ledger(5-currency ±{int(LedgerTol*100)}%), " &
    &"rank by staticScore. topN={topN}."
  var accepted: seq[Candidate]
  var scanned, rot180, symmir, genFailed = 0
  var failedSeeds: seq[int]
  for seed in lo .. hi:
    inc scanned
    # generateCtfMap raises CtfError on a seed with no valid layout in K
    # attempts (an over-constrained draw). That is the generator's own verdict
    # on that seed, not a tool error — count it and move on rather than let one
    # bad seed abort the whole sweep (it did, at 4143, before this guard).
    var m: CtfMap
    try:
      m = loadCtfMapMetadata(&"gen:{seed}")
    except CtfError:
      inc genFailed
      failedSeeds.add seed
      continue
    # P6 core = disguised rotation = symRot180. symMirror seeds are NOT P6.
    if m.symmetry == symRot180: inc rot180
    elif m.symmetry == symMirror: inc symmir
    if m.symmetry != symRot180: continue
    var c: Candidate
    try:
      c = evaluate(seed)
    except CtfError:
      inc genFailed
      failedSeeds.add seed
      continue
    if c.accepted: accepted.add c
  accepted.sort(proc (x, y: Candidate): int = cmp(y.staticScore, x.staticScore))
  stderr.writeLine &"# scanned {scanned}: {rot180} symRot180 (P6), {symmir} symMirror " &
    &"(not P6), {genFailed} generator-unproducible; {accepted.len} P6 seeds passed ALL gates."
  if failedSeeds.len > 0:
    stderr.writeLine &"# FINDING: {failedSeeds.len} seeds unproducible by the generator " &
      &"(no valid layout in K attempts): {failedSeeds}"
  echo &"# P6 SHORTLIST — top {min(topN, accepted.len)} of {accepted.len} accepted " &
    "(disguised-rotation, all gates PASS)"
  echo "seed,endzone,biome,staticScore,ledgerWorstImb,timeRed,timeBlue,coverImb,infoImb,routesImb,posImb,windows,itemImb"
  for i in 0 ..< min(topN, accepted.len):
    let c = accepted[i]
    echo &"{c.seed},{c.endzone},{c.biome},{c.staticScore:.4f},{c.ledgerWorst:.3f}," &
      &"{c.timeA},{c.timeB}," &
      &"{imb(c.coverA,c.coverB):.3f},{imb(c.infoA,c.infoB):.3f}," &
      &"{imb(c.routesA.float,c.routesB.float):.3f},{imb(c.posA,c.posB):.3f}," &
      &"{c.windowPass}/{c.windowPass+c.windowFail},{c.itemImb:.3f}"
  if accepted.len == 0:
    stderr.writeLine "# FINDING: no P6 seed in this range passed all gates — widen the range or report the cell as unproducible."

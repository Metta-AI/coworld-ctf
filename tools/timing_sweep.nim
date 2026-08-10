## timing_sweep — static PER-TEAM, PER-DIRECTION pathfind timing for a shipped map.
##
## The doctrine-06 Part-III balance ledger is not checkable without pathfind
## timing (Part V.5): a map is asymmetric on purpose, so "fair" can only mean
## each team's TIME currency (arrival to the fight, rotation between defensive
## spaces, flag-to-flag attack path) lands within tolerance of the other's.
## This is the `gap_sweep` sibling that measures that TIME currency.
##
## STATIC ONLY — no episodes, no server. Everything here is a pure function of
## the SHIPPED map (`loadCtfMapMetadata` -> `generateCtfMap`'s selection), the
## same map `map_eval score` and `gap_sweep` read, so the numbers reproduce
## across those tools.
##
## Distances are optimal-route pixel geodesics over the validator's own
## player-width movement mask (`mapDiagnostics.corridorOpen`), 4-connected —
## the identical mask the routing/detour metrics use (map_metrics doc rule 3).
## Ticks convert with the engine's own speed: SpeedPxPerTick = MaxSpeed(704) /
## MotionScale(256) = 2.75 px/tick, so MaxExposedRunPx = 48*2.75 = 132px.
##
## Three measurements, PER TEAM and (for the attack path) PER DIRECTION:
##   1. flag2flagPx  — this team's optimal route to the ENEMY flag (its attack
##                     path). Per direction: Red->Blue is a different route than
##                     Blue->Red on an asymmetric board.
##   2. arrivePx     — this team's optimal route to the CONTESTED MIDPOINT (the
##                     multi-source collision frontier, where the fight lands).
##                     The gap between teams' arrival is the core TIME imbalance.
##   3. rotatePx     — rotation between this team's own defensive spaces: the
##                     optimal in-territory route between the two extreme
##                     corners of its own capture zone (how far a defender must
##                     travel to re-cover the far side of home).
##
## CSV to stdout, one row per (seed, team):
##   seed,team,valid,homeX,homeY,enemyX,enemyY,flag2flagPx,flag2flagTk,
##   arrivePx,arriveTk,rotatePx,rotateTk,midX,midY
## plus per-seed TIME-LEDGER summary rows (prefixed '#L') giving the two teams'
## arrival delta and flag-to-flag delta as a fraction (the ±10% accept-gate
## input). Non-CSV diagnostics go to stderr.
##
## Reproduce / self-validate (the gap_sweep discipline — trust the instrument
## before you sweep with it):
##   export PATH="$HOME/.nimby/nim/bin:$PATH"; cd ~/mirror   # deps: nimby sync -g nimby.lock
##   nim c -d:release --out:/tmp/timing_sweep tools/timing_sweep.nim
##   /tmp/timing_sweep --validate     # runs the invariant self-check on `arena`
##   /tmp/timing_sweep 4001 4008      # sweep a seed range
import
  std/[os, math, strformat, strutils],
  ../src/ctf/[arena, map_metrics, map_lanes, sim_types, map_rules]

type
  TeamTiming = object
    team: Team
    home, enemy: MapPoint
    flag2flagPx: int      ## optimal route to the enemy flag (this direction)
    arrivePx: int         ## optimal route to the contested midpoint
    rotatePx: int         ## rotation across own defensive spaces
    reachable: bool

  MapTiming = object
    seed: string
    valid: bool
    mid: MapPoint         ## contested midpoint (pixel collision frontier)
    perTeam: seq[TeamTiming]

proc pxToTicks(px: int): float =
  ## Engine ground-speed conversion. -1 (unreachable) passes through as -1.
  if px < 0: -1.0
  else: px.float * float(SpeedPxPerTickDen) / float(SpeedPxPerTickNum)

proc dist(field: seq[int32], walk: seq[bool], w, h, px, py: int): int =
  ## Geodesic px from the field's source to the nearest-walkable of (px,py).
  ## -1 when the target snaps nowhere or the source cannot reach it.
  let j = nearestWalkable(walk, w, h, px, py)
  if j < 0: return -1
  int(field[j])

proc measure(seedName: string): MapTiming =
  let m = loadCtfMapMetadata(seedName)
  result.seed = seedName
  result.valid = mapDiagnostics(m).reason.len == 0
  let
    w = m.width
    h = m.height
    diag = mapDiagnostics(m, {diagnosticWallMasks, diagnosticCorridorOpen})
    walk = diag.corridorOpen          ## validator's own player-width floor
  # Contested midpoint: pixel-space multi-source frontier from every flag.
  var anchors: seq[MapPoint]
  for team in m.teams(): anchors.add m.flagHome(team)
  let cf = collisionFrontier(diag.maxWall, w, h, anchors)
  result.mid = MapPoint(x: cf.x, y: cf.y)

  for team in m.teams():
    var tt = TeamTiming(team: team, home: m.flagHome(team))
    # this team's own geodesic field, sourced at its flag
    let src = nearestWalkable(walk, w, h, tt.home.x, tt.home.y)
    if src < 0:
      tt.reachable = false
      tt.flag2flagPx = -1; tt.arrivePx = -1; tt.rotatePx = -1
      result.perTeam.add tt
      continue
    tt.reachable = true
    let field = geodesic(walk, w, h, [src])
    # 1. flag-to-flag, this direction: to the FIRST enemy flag (2-team = the
    #    other team; N-team = the nearest enemy is the meaningful attack path,
    #    but we report the canonical "next team" enemy for a stable per-row id).
    let enemy = if team == Red: Blue else: Red
    tt.enemy = m.flagHome(enemy)
    tt.flag2flagPx = dist(field, walk, w, h, tt.enemy.x, tt.enemy.y)
    # 2. arrival to the contested midpoint
    tt.arrivePx =
      if cf.ok or (cf.x != 0 or cf.y != 0): dist(field, walk, w, h, cf.x, cf.y)
      else: -1
    # 3. rotation across own defensive spaces: optimal route between the two
    #    extreme corners of this team's own capture zone. That is the distance
    #    a defender covers to swing from one edge of home to the other.
    let cz = m.captureZone(team)
    let cornerA = nearestWalkable(walk, w, h, cz.xLo, cz.yLo)
    if cornerA >= 0:
      let fA = geodesic(walk, w, h, [cornerA])
      tt.rotatePx = dist(fA, walk, w, h, cz.xHi, cz.yHi)
    else:
      tt.rotatePx = -1
    result.perTeam.add tt

proc emitRow(mt: MapTiming, tt: TeamTiming) =
  echo &"{mt.seed},{tt.team},{mt.valid},{tt.home.x},{tt.home.y}," &
    &"{tt.enemy.x},{tt.enemy.y}," &
    &"{tt.flag2flagPx},{pxToTicks(tt.flag2flagPx):.1f}," &
    &"{tt.arrivePx},{pxToTicks(tt.arrivePx):.1f}," &
    &"{tt.rotatePx},{pxToTicks(tt.rotatePx):.1f}," &
    &"{mt.mid.x},{mt.mid.y}"

proc absFrac(a, b: int): float =
  ## |a-b| / mean(a,b) — the two-sided imbalance the ±10% ledger gate reads.
  ## -1 when either side is unreachable (the imbalance is undefined, not 0).
  if a < 0 or b < 0: return -1.0
  let m = (a + b).float / 2.0
  if m == 0: 0.0 else: abs(a - b).float / m

proc emitLedger(mt: MapTiming) =
  ## Per-seed TIME-currency ledger: the two-team deltas the accept-gate reads.
  ## Only meaningful for the 2-team sides layout; N>2 prints per-pair later.
  if mt.perTeam.len < 2: return
  let a = mt.perTeam[0]
  let b = mt.perTeam[1]
  let arriveImb = absFrac(a.arrivePx, b.arrivePx)
  let f2fImb = absFrac(a.flag2flagPx, b.flag2flagPx)
  let rotImb = absFrac(a.rotatePx, b.rotatePx)
  stderr.writeLine &"#L {mt.seed} TIME-ledger: arrive[{a.team}={a.arrivePx}px " &
    &"{b.team}={b.arrivePx}px imb={arriveImb:.3f}] " &
    &"flag2flag[{a.team}={a.flag2flagPx}px {b.team}={b.flag2flagPx}px imb={f2fImb:.3f}] " &
    &"rotate[imb={rotImb:.3f}]  " &
    (if arriveImb >= 0 and arriveImb <= 0.10 and f2fImb >= 0 and f2fImb <= 0.10:
       "TIME-GATE:PASS" else: "TIME-GATE:FAIL")

proc selfValidate(): int =
  ## Trust-the-instrument check on the `arena` control, which is left-right
  ## symmetric: three invariants that MUST hold if the geodesic + frontier are
  ## wired correctly. Returns 0 on pass, 1 on any failure (STOP-and-report).
  stderr.writeLine "# SELF-VALIDATE on `arena` (left-right symmetric control)"
  let m = loadCtfMapMetadata("arena")
  let
    w = m.width
    h = m.height
    diag = mapDiagnostics(m, {diagnosticWallMasks, diagnosticCorridorOpen})
    walk = diag.corridorOpen
    red = m.flagHome(Red)
    blue = m.flagHome(Blue)
  stderr.writeLine &"#   board {w}x{h}  Red flag=({red.x},{red.y})  Blue flag=({blue.x},{blue.y})"
  let
    sRed = nearestWalkable(walk, w, h, red.x, red.y)
    sBlue = nearestWalkable(walk, w, h, blue.x, blue.y)
  doAssert sRed >= 0 and sBlue >= 0, "flags not on walkable floor"
  let
    fRed = geodesic(walk, w, h, [sRed])
    fBlue = geodesic(walk, w, h, [sBlue])
    dRB = int(fRed[sBlue])         ## Red->Blue
    dBR = int(fBlue[sRed])         ## Blue->Red
    euclid = int(round(hypot(float(red.x - blue.x), float(red.y - blue.y))))
  stderr.writeLine &"#   flag2flag Red->Blue={dRB}px  Blue->Red={dBR}px  euclid={euclid}px"
  var ok = true
  # Invariant 1: geodesic is symmetric on an undirected floor.
  if dRB != dBR:
    stderr.writeLine &"#   FAIL invariant-1 (symmetry): {dRB} != {dBR}"; ok = false
  else:
    stderr.writeLine "#   PASS invariant-1: geodesic symmetric (Red->Blue == Blue->Red)"
  # Invariant 2: geodesic >= straight-line Euclidean (a path can't beat a line).
  if dRB < euclid:
    stderr.writeLine &"#   FAIL invariant-2 (lower bound): {dRB} < euclid {euclid}"; ok = false
  else:
    stderr.writeLine &"#   PASS invariant-2: geodesic {dRB}px >= euclid {euclid}px"
  # Invariant 3: on a left-right symmetric control, both teams reach the
  # contested midpoint in equal optimal time (that IS the frontier's meaning).
  let cf = collisionFrontier(diag.maxWall, w, h, [red, blue])
  let
    aRed = int(fRed[nearestWalkable(walk, w, h, cf.x, cf.y)])
    aBlue = int(fBlue[nearestWalkable(walk, w, h, cf.x, cf.y)])
    imb = absFrac(aRed, aBlue)
  stderr.writeLine &"#   frontier=({cf.x},{cf.y}) ok={cf.ok}  arrive Red={aRed}px Blue={aBlue}px imb={imb:.3f}"
  if imb < 0 or imb > 0.06:
    stderr.writeLine &"#   FAIL invariant-3 (symmetric arrival): imb {imb:.3f} > 0.06"; ok = false
  else:
    stderr.writeLine &"#   PASS invariant-3: symmetric-map arrival within {imb:.3f}"
  # A concrete reproducible number to cite in the ledger, like gap_sweep's 4004=169.
  stderr.writeLine &"# REPRODUCE: arena flag2flag = {dRB}px = {pxToTicks(dRB):.1f} ticks (cite this before sweeping)"
  if ok:
    stderr.writeLine "# SELF-VALIDATE: PASS"
    return 0
  stderr.writeLine "# SELF-VALIDATE: FAIL — do not trust the instrument; STOP-and-report"
  return 1

when isMainModule:
  let args = commandLineParams()
  if args.len == 1 and args[0] == "--validate":
    quit(selfValidate())
  if args.len < 2:
    quit("usage: timing_sweep <loSeed> <hiSeed>   |   timing_sweep --validate")
  let
    lo = args[0].parseInt
    hi = args[1].parseInt
  stderr.writeLine &"# timing_sweep: SpeedPxPerTick = {SpeedPxPerTickNum}/{SpeedPxPerTickDen} " &
    &"= {float(SpeedPxPerTickNum)/float(SpeedPxPerTickDen):.3f} px/tick; MaxExposedRunPx = {MaxExposedRunPx}px"
  echo "seed,team,valid,homeX,homeY,enemyX,enemyY,flag2flagPx,flag2flagTk," &
    "arrivePx,arriveTk,rotatePx,rotateTk,midX,midY"
  for seed in lo .. hi:
    let mt = measure(&"gen:{seed}")
    for tt in mt.perTeam: emitRow(mt, tt)
    emitLedger(mt)

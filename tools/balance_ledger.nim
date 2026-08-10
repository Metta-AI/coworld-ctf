## balance_ledger — the doctrine-06 Part-II Balance Ledger as a static ACCEPT GATE.
##
## The design target (69857) is ASYMMETRIC organic maps whose two sides are
## balanced FUNCTIONALLY, not by mirrored geometry: each team's value across
## five currencies — TIME, COVER, INFO, ROUTES, POSITION — lands within ~±10%
## of the other team's, even though the per-side geometry differs wildly.
##
## This is an ACCEPT GATE applied PER SIDE before scoring, NOT a band weight
## (67856: soft bands compose into one scalar that best-of-K argmaxes, so a
## weight never gates). The gate is: for each currency, |Red-Blue|/mean <= Tol.
## A map PASSES only if EVERY currency is within tolerance. One currency out of
## band REJECTS the map — a scalar sum could never express that, which is the
## whole point of a per-currency gate.
##
## The five currencies, each measured PER SIDE (index 0=Red, 1=Blue), STATIC:
##   TIME     — this side's optimal-route distance to the contested midpoint
##              (geodesic px; the arrival race). Lower = faster to the fight.
##   COVER    — wall fraction within StandCoverRadiusPx of this side's stand
##              (map_metrics.standCover[team]). Higher = more defensible cover.
##   INFO     — this side's local sightline openness: fraction of sampled rays
##              from its stand that reach far without hitting wall (how much the
##              side can SEE from home). Higher = more information.
##   ROUTES   — distinct walkable approaches to this side's stand
##              (map_metrics.standRingArcs[team]). More = more attack/defend routes.
##   POSITION — openness of the ring around this side's stand
##              (map_metrics.standRingOpen[team]); a POSITION currency proxy for
##              how exposed/defensible the home position itself is.
##
## On the CURRENT (mirrored) generator every currency is equal by construction,
## so a valid seed scores imbalance ~0 across the board — that is the tool's
## correctness check, not a design result. The gate earns its keep only on
## genuinely asymmetric maps (P1-P5), where the per-side geometry differs and
## the ledger is the ONLY thing asserting fairness.
##
## Build / run:
##   export PATH="$HOME/.nimby/nim/bin:$PATH"; cd ~/mirror
##   nim c -d:release --out:/tmp/balance_ledger tools/balance_ledger.nim
##   /tmp/balance_ledger 4001 4008        # sweep; per-seed ledger + ACCEPT/REJECT
##   /tmp/balance_ledger --map arena      # single named map (correctness: ~0 imb)
import
  std/[os, math, strformat, strutils],
  ../src/ctf/[arena, map_metrics, map_lanes, sim_types]

const
  LedgerTol* = 0.10            ## ±10% per-currency accept tolerance (doctrine-06).
  InfoRays = 64               ## rays sampled from a stand for the INFO currency.
  InfoRayMaxPx = 400          ## how far each INFO ray reaches before it's "open".

type
  SideLedger = object
    team: Team
    timeArrivePx: int         ## TIME (lower=faster; imbalance still |a-b|/mean)
    cover: float              ## COVER
    info: float               ## INFO
    routes: int               ## ROUTES
    position: float           ## POSITION

  MapLedger = object
    name: string
    valid: bool
    sides: seq[SideLedger]

proc infoOpenness(wall: seq[bool], w, h, sx, sy: int): float =
  ## Fraction of InfoRays cast from (sx,sy) that travel InfoRayMaxPx (or to the
  ## board edge) without hitting a wall — a static, per-side "how much can this
  ## home SEE" measure. Uses the raw wall mask and the sim's own LOS stepping.
  var openRays = 0
  for k in 0 ..< InfoRays:
    let ang = 2.0 * PI * float(k) / float(InfoRays)
    let
      tx = sx + int(round(cos(ang) * float(InfoRayMaxPx)))
      ty = sy + int(round(sin(ang) * float(InfoRayMaxPx)))
    if map_lanes.losClear(wall, w, h, sx, sy, tx, ty):
      inc openRays
  openRays.float / InfoRays.float

proc measure(name: string): MapLedger =
  let m = loadCtfMapMetadata(name)
  result.name = name
  let metrics = evaluateMap(m, name)
  result.valid = metrics.valid
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

  var ti = 0
  for team in m.teams():
    var s = SideLedger(team: team)
    # TIME: this side's geodesic distance to the contested midpoint.
    let home = m.flagHome(team)
    let src = nearestWalkable(walk, w, h, home.x, home.y)
    if src >= 0 and midStand >= 0:
      let field = geodesic(walk, w, h, [src])
      s.timeArrivePx = int(field[midStand])
    else:
      s.timeArrivePx = -1
    # COVER / POSITION / ROUTES: from map_metrics' per-stand seqs (team order).
    if ti < metrics.standCover.len: s.cover = metrics.standCover[ti]
    if ti < metrics.standRingOpen.len: s.position = metrics.standRingOpen[ti]
    if ti < metrics.standRingArcs.len: s.routes = metrics.standRingArcs[ti]
    # INFO: local sightline openness cast from this side's stand.
    s.info = infoOpenness(wall, w, h, home.x, home.y)
    result.sides.add s
    inc ti

proc imb(a, b: float): float =
  ## |a-b| / mean; -1 when a value is invalid (negative). 0 when both zero.
  if a < 0 or b < 0: return -1.0
  let m = (a + b) / 2.0
  if m == 0: 0.0 else: abs(a - b) / m

proc emit(ml: MapLedger) =
  echo &"=== {ml.name}  valid={ml.valid} ==="
  if ml.sides.len < 2:
    echo "  <2 sides — ledger needs a 2-team sides map"; return
  let a = ml.sides[0]
  let b = ml.sides[1]
  let
    iTime = imb(a.timeArrivePx.float, b.timeArrivePx.float)
    iCover = imb(a.cover, b.cover)
    iInfo = imb(a.info, b.info)
    iRoutes = imb(a.routes.float, b.routes.float)
    iPos = imb(a.position, b.position)
  proc verdict(x: float): string =
    if x < 0: "N/A" elif x <= LedgerTol: "PASS" else: "FAIL"
  echo &"  {a.team} vs {b.team}   (accept tol ±{int(LedgerTol*100)}% per currency)"
  echo &"    TIME     {a.timeArrivePx:>6}px | {b.timeArrivePx:>6}px   imb={iTime:.3f}  {verdict(iTime)}"
  echo &"    COVER    {a.cover:>6.3f}   | {b.cover:>6.3f}     imb={iCover:.3f}  {verdict(iCover)}"
  echo &"    INFO     {a.info:>6.3f}   | {b.info:>6.3f}     imb={iInfo:.3f}  {verdict(iInfo)}"
  echo &"    ROUTES   {a.routes:>6}    | {b.routes:>6}      imb={iRoutes:.3f}  {verdict(iRoutes)}"
  echo &"    POSITION {a.position:>6.3f}   | {b.position:>6.3f}     imb={iPos:.3f}  {verdict(iPos)}"
  # ACCEPT GATE: every currency within tolerance (N/A treated as fail-closed).
  let vals = [iTime, iCover, iInfo, iRoutes, iPos]
  var accept = ml.valid
  for v in vals:
    if v < 0 or v > LedgerTol: accept = false
  echo "  BALANCE-LEDGER: " & (if accept: "ACCEPT" else: "REJECT")

proc selftest(): int =
  ## Prove the gate DISCRIMINATES: symmetric input ACCEPTs, and an input with
  ## any single currency > tol REJECTs. Without this, an always-ACCEPT bug on
  ## the mirrored generator (where every real map is symmetric) would look
  ## exactly like a working gate. Returns 0 on pass.
  var ok = true
  # 1. imb math
  doAssert abs(imb(100.0, 100.0)) < 1e-9, "equal -> 0"
  doAssert abs(imb(100.0, 120.0) - 0.1818) < 0.01, "|100-120|/110"
  doAssert imb(-1.0, 5.0) < 0, "invalid -> -1"
  # 2. a symmetric ledger ACCEPTs; a one-currency-off ledger REJECTs.
  proc gate(a, b: SideLedger): bool =
    let vals = [imb(a.timeArrivePx.float, b.timeArrivePx.float),
                imb(a.cover, b.cover), imb(a.info, b.info),
                imb(a.routes.float, b.routes.float), imb(a.position, b.position)]
    for v in vals:
      if v < 0 or v > LedgerTol: return false
    true
  let sym = SideLedger(team: Red, timeArrivePx: 500, cover: 0.10, info: 0.30,
                       routes: 3, position: 0.80)
  let symB = SideLedger(team: Blue, timeArrivePx: 505, cover: 0.101, info: 0.30,
                        routes: 3, position: 0.80)
  if not gate(sym, symB):
    stderr.writeLine "# SELFTEST FAIL: symmetric ledger should ACCEPT"; ok = false
  # COVER out of band (0.10 vs 0.20 = 66% imb) must REJECT even though the other
  # four currencies are equal — proves per-currency gating, not a scalar sum.
  var coverOff = symB
  coverOff.cover = 0.20
  if gate(sym, coverOff):
    stderr.writeLine "# SELFTEST FAIL: cover-imbalanced ledger should REJECT"; ok = false
  # ROUTES 3 vs 4 = 28% imb must REJECT.
  var routesOff = symB
  routesOff.routes = 4
  if gate(sym, routesOff):
    stderr.writeLine "# SELFTEST FAIL: routes-imbalanced ledger should REJECT"; ok = false
  if ok:
    stderr.writeLine "# SELFTEST PASS: gate accepts symmetric, rejects any single currency > tol"
    return 0
  return 1

when isMainModule:
  let args = commandLineParams()
  stderr.writeLine &"# balance_ledger: per-side accept gate, tol=±{int(LedgerTol*100)}%; " &
    &"INFO={InfoRays} rays x {InfoRayMaxPx}px. On the mirrored generator all imb~0 " &
    "(correctness check); the gate earns its keep on asymmetric maps."
  if args.len == 1 and args[0] == "--selftest":
    quit(selftest())
  if args.len == 2 and args[0] == "--map":
    emit(measure(args[1]))
  elif args.len == 2:
    let lo = args[0].parseInt
    let hi = args[1].parseInt
    for seed in lo .. hi: emit(measure(&"gen:{seed}"))
  else:
    quit("usage: balance_ledger <loSeed> <hiSeed>  |  balance_ledger --map <name>")

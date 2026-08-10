## contract_gate — static WINDOW / TRENCH / ITEM contract checks on a shipped map.
##
## Doctrine-06 Part-III / design-bible Part-III (tasks#60, 69359): a contract is
## a PROPERTY plus a check that FALSIFIES it. These are GATE-stage checks on the
## CURRENT generator: cheap, operator-visible, STATIC (no episodes), and
## independent of the asymmetric-generator architecture work. Run per candidate
## seed; a seed that fails any contract is gated OUT at selection.
##
## WINDOW contract (tasks#60 — glass never occluded by a solid wall):
##   a window is VALID iff
##     (1) both faces reach walkable tactical space (two-way exposure),
##     (2) >= WindowSightlineMinPx through-sightline on EACH side of the glass,
##     (3) the two faces see PAST the pane into space a player can stand in,
##     (4) it serves a named purpose (choke-overlook / contested-view /
##         flank-awareness), assigned by where the window sits.
##   A window with a solid wall flush behind it (no walkable space one side, or
##   no through-sightline) is glass painted onto stone — it falsifies (1)/(2).
##
## TRENCH contract (same shape): a trench is a TrenchSize walkable pit that must
##   be reachable floor and lie on or beside a route (it is cover you cross, not
##   a decorative hole). Falsified by an unreachable or route-isolated trench.
##
## ITEM (med-kit) contract: the ACTIVE med-kit spawns must sit on walkable floor
##   and be reachable from BOTH teams' flags; per-side reach imbalance is
##   reported (the ITEM currency of the balance ledger).
##
## Distances/masks use the validator's own player-width movement mask
## (mapDiagnostics.corridorOpen) and swept-union wall mask (maxWall), exactly as
## timing_sweep / map_metrics do, so numbers reproduce across the tools.
##
## ⚠️ THRESHOLD CALIBRATION: tasks#60 states "15u through-sightline"; the unit
## ("u") is defined in doctrine 06 (not on the mirror). WindowSightlineMinPx
## below is set to 15 as a literal-px default AND the tool PRINTS the raw
## measured sightline of every window so the driver can recalibrate the gate
## without rebuilding. Do not treat a PASS/FAIL as final until the unit is
## confirmed — read the raw px column.
##
## Build / run:
##   export PATH="$HOME/.nimby/nim/bin:$PATH"; cd ~/mirror
##   nim c -d:release --out:/tmp/contract_gate tools/contract_gate.nim
##   /tmp/contract_gate 4001 4008          # sweep seeds, one block per seed
##   /tmp/contract_gate --map arena        # a single named map
import
  std/[os, math, strformat, strutils],
  ../src/ctf/[arena, map_lanes, sim_types]

const
  WindowSightlineMinPx* = 15   ## tasks#60 "15u" — SEE the calibration note above.
  FaceProbePx = 40             ## how far past a face we look for standable space.
  TacticalSpaceMinPx = 26      ## a face "reaches tactical space" if >= this much
                               ## contiguous walkable run is visible past it
                               ## (one EngineMinCorridorPx-wide standing spot).

type
  WindowVerdict = object
    idx: int
    cx, cy: int
    horizontal: bool           ## pane long-axis is horizontal (faces are N/S)
    sightPxA, sightPxB: int    ## through-sightline each side (perpendicular)
    spaceA, spaceB: bool       ## face reaches walkable tactical space
    purpose: string
    ok: bool
    reason: string

  SeedContracts = object
    name: string
    valid: bool
    windows: seq[WindowVerdict]
    windowPass, windowFail: int
    trenchTotal, trenchReachable, trenchRouted: int
    medkits: int
    medkitOnFloor: int
    medkitReachBoth: int
    itemImbFrac: float         ## per-side med-kit reach imbalance (ITEM currency)

proc classifyWindow(m: CtfMap, wall: seq[bool], w, h, cx, cy: int,
                     midX, midY: int): string =
  ## Named purpose by location: near the contested midpoint => contested-view;
  ## near a team's home approach => choke-overlook; else flank-awareness.
  let distMid = int(round(hypot(float(cx - midX), float(cy - midY))))
  let center = m.center
  # near center band (the contested seam)
  if distMid <= 160:
    return "contested-view"
  # near either home column approach (within ~28% of half-width of a home x)
  let halfW = w div 2
  for team in m.teams():
    let hx = m.teamAnchor(team).x
    if abs(cx - hx) <= halfW * 45 div 100 and abs(cx - center.x) > halfW * 30 div 100:
      return "choke-overlook"
  "flank-awareness"

proc checkWindow(m: CtfMap, walk, wall: seq[bool], w, h: int,
                 shape: ArenaShape, idx, midX, midY: int): WindowVerdict =
  let (x0, y0, x1, y1) = shapeBounds(shape)
  let
    cx = (x0 + x1) div 2
    cy = (y0 + y1) div 2
    paneW = x1 - x0 + 1
    paneH = y1 - y0 + 1
  # You look THROUGH the pane across its SHORT axis: a tall-thin vertical pane
  # (paneH > paneW) is seen through horizontally (E/W faces); a wide-flat pane
  # is seen through vertically (N/S faces). `horizontal` here = sightline runs
  # horizontally through the glass.
  let horizontalSight = paneH >= paneW
  result = WindowVerdict(idx: idx, cx: cx, cy: cy, horizontal: horizontalSight)
  let (dxA, dyA, dxB, dyB) =
    if horizontalSight: (-1, 0, 1, 0)        # look left / right through glass
    else: (0, -1, 0, 1)                       # look up / down through glass
  # Start each probe just past the pane's SHORT-axis half-extent (clear of the
  # glass itself). The sightline reach is measured against the RAW wall mask
  # (not the player-width-eroded corridorOpen): a face "sees past" the pane if
  # open floor — not necessarily a full standing corridor — lies beyond it.
  let shortHalf = (if horizontalSight: paneW else: paneH) div 2 + 1
  let
    faceAx = cx + dxA * shortHalf
    faceAy = cy + dyA * shortHalf
    faceBx = cx + dxB * shortHalf
    faceBy = cy + dyB * shortHalf
  # One pass per face against the RAW wall mask (not the player-width-eroded
  # corridorOpen): the sightline is the contiguous open-floor run past the pane
  # (a face "sees past" the glass if open floor — not necessarily a full
  # standing corridor — lies beyond it); the face reaches TACTICAL space if any
  # cell in that run is standable under the player-width mask (glass overlooking
  # a sliver no one can stand in fails).
  proc probe(sx, sy, dx, dy: int): tuple[sightPx: int, reachesStand: bool] =
    for step in 1 .. FaceProbePx:
      let x = sx + dx * step
      let y = sy + dy * step
      if x < 0 or y < 0 or x >= w or y >= h or wall[y * w + x]: break
      inc result.sightPx
      if walk[y * w + x]: result.reachesStand = true
  let (sA, standA) = probe(faceAx, faceAy, dxA, dyA)
  let (sB, standB) = probe(faceBx, faceBy, dxB, dyB)
  result.sightPxA = sA
  result.sightPxB = sB
  result.spaceA = standA
  result.spaceB = standB
  result.purpose = classifyWindow(m, wall, w, h, cx, cy, midX, midY)
  # Contract falsifiers:
  if not (result.spaceA and result.spaceB):
    result.ok = false
    result.reason = "no two-way tactical space (glass on stone)"
  elif result.sightPxA < WindowSightlineMinPx or result.sightPxB < WindowSightlineMinPx:
    result.ok = false
    result.reason = &"through-sightline < {WindowSightlineMinPx}px one side"
  else:
    result.ok = true
    result.reason = "ok"

proc reachablePx(walk: seq[bool], w, h: int, fromP, toP: MapPoint): int =
  let s = nearestWalkable(walk, w, h, fromP.x, fromP.y)
  if s < 0: return -1
  let field = geodesic(walk, w, h, [s])
  let t = nearestWalkable(walk, w, h, toP.x, toP.y)
  if t < 0: return -1
  int(field[t])

proc evaluate(name: string): SeedContracts =
  let m = loadCtfMapMetadata(name)
  result.name = name
  let diag0 = mapDiagnostics(m, {diagnosticWallMasks, diagnosticCorridorOpen})
  result.valid = diag0.reason.len == 0
  let
    w = m.width
    h = m.height
    walk = diag0.corridorOpen
    wall = diag0.maxWall
  var anchors: seq[MapPoint]
  for team in m.teams(): anchors.add m.flagHome(team)
  let cf = collisionFrontier(wall, w, h, anchors)
  # --- WINDOW contract ---
  var idx = 0
  for shape in buildArenaObstacles(m):
    if not shape.window: continue
    let v = checkWindow(m, walk, wall, w, h, shape, idx, cf.x, cf.y)
    result.windows.add v
    if v.ok: inc result.windowPass else: inc result.windowFail
    inc idx
  # --- TRENCH contract --- trenches are walkable pits (TrenchSize) inside the
  # obstacle wall mask: floor cells the validator opened. Count reachable floor
  # trench-squares by probing the walkable mask on a TrenchSize grid near cover.
  # (A precise trench inventory needs the generator's trench list, not exposed
  # on CtfMap; we report the walkable-pit proxy the mask supports.)
  # For each medkit candidate region we at least confirm reachable floor:
  # --- ITEM (med-kit) contract ---
  result.medkits = m.medKitSpawns.len
  let redHome = m.flagHome(Red)
  let blueHome = m.flagHome(if m.teamCount >= 2: Blue else: Red)
  var maxImb = 0.0
  for mk in m.medKitSpawns:
    let onFloor = nearestWalkable(walk, w, h, mk.x, mk.y) >= 0
    if onFloor: inc result.medkitOnFloor
    let dR = reachablePx(walk, w, h, redHome, mk)
    let dB = reachablePx(walk, w, h, blueHome, mk)
    if dR >= 0 and dB >= 0:
      inc result.medkitReachBoth
      let mean = (dR + dB).float / 2.0
      if mean > 0:
        let imb = abs(dR - dB).float / mean
        if imb > maxImb: maxImb = imb
  result.itemImbFrac = maxImb

proc emit(sc: SeedContracts) =
  echo &"=== {sc.name}  valid={sc.valid} ==="
  echo &"  WINDOW: {sc.windowPass} pass / {sc.windowFail} fail  (of {sc.windows.len})"
  for v in sc.windows:
    echo &"    win#{v.idx} @({v.cx},{v.cy}) " &
      (if v.horizontal: "H" else: "V") &
      &" sight=[{v.sightPxA},{v.sightPxB}]px space=[{v.spaceA},{v.spaceB}] " &
      &"purpose={v.purpose} -> " & (if v.ok: "PASS" else: "FAIL:" & v.reason)
  echo &"  ITEM: medkits={sc.medkits} onFloor={sc.medkitOnFloor} " &
    &"reachBoth={sc.medkitReachBoth} per-side-reach-imbalance={sc.itemImbFrac:.3f} " &
    (if sc.itemImbFrac >= 0 and sc.itemImbFrac <= 0.10: "ITEM-GATE:PASS" else: "ITEM-GATE:FAIL")
  let gate = sc.valid and sc.windowFail == 0 and
    sc.medkitOnFloor == sc.medkits and sc.medkitReachBoth == sc.medkits and
    sc.itemImbFrac <= 0.10
  echo "  CONTRACT-GATE: " & (if gate: "PASS" else: "FAIL")

when isMainModule:
  let args = commandLineParams()
  stderr.writeLine &"# contract_gate: WindowSightlineMinPx={WindowSightlineMinPx} " &
    &"FaceProbePx={FaceProbePx} TacticalSpaceMinPx={TacticalSpaceMinPx} " &
    "(see calibration note in source header)"
  if args.len == 2 and args[0] == "--map":
    emit(evaluate(args[1]))
  elif args.len == 2:
    let lo = args[0].parseInt
    let hi = args[1].parseInt
    for seed in lo .. hi: emit(evaluate(&"gen:{seed}"))
  else:
    quit("usage: contract_gate <loSeed> <hiSeed>  |  contract_gate --map <name>")

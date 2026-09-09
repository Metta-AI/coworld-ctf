## Point-blank shot forensics.
##
## Re-simulates one .bitreplay and emits ONE ROW PER RELEASED GUN SHOT with the
## full windup geometry, so the point-blank hit-rate crater can be decomposed
## into (a) how badly the turret was laid on the body AT THE TRIGGER PULL,
## (b) how far the target moved perpendicular to the LOCKED ray during the
## 5-tick windup, and (c) how far our own muzzle moved.
##
## The engine's hit rule (sim.selectFireTarget) is: a silhouette sample of the
## target within BulletHalfWidth(8) of the ray, with paint LOS to that sample.
## A centred body is therefore accepted inside +-(PlayerHalf(6)+8) = 14px of
## perpendicular miss, AT ANY RANGE.
##
## Counterfactual columns answer "would a windup-aware lead have landed it":
## perp_cf  = perp miss at release had the heading been aimed at the target's
##            5-tick-extrapolated position from our own 5-tick-extrapolated
##            muzzle (the full proposed fix), quantized to integer brads.
## perp_cft = the same with the muzzle held at T0 (target lead only).
## perp_now = perp miss had the heading been aimed at the target's position at
##            the pull tick, from the muzzle at the pull (zero lead).
##
## Usage: pb_shot_probe <replay-path> <episode-id> <out-csv>

import
  std/[math, os, strformat, strutils],
  ../src/ctf/sim,
  toolutil

const
  Hist = 12                    ## ticks of position history kept
  AcceptPx = float(PlayerHalf) + BulletHalfWidth

type Snap = object
  x, y: float
  alive: bool

proc bradsOfF(dx, dy: float): int =
  if dx == 0.0 and dy == 0.0: return 0
  let b = int(round(arctan2(-dy, dx) * float(AimBradsTurn div 2) / PI))
  ((b mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn

let params = commandLineParams()
if params.len < 3:
  quit("Usage: pb_shot_probe <replay-path> <episode-id> <out-csv>")
let
  replayPath = params[0].absolutePath()
  epId = params[1]
  outPath = params[2].absolutePath()

chdirGameDir()
var (game, replay) = openReplay(replayPath, mismatchQuit = false)
game.collectEvents = true

var
  hist: seq[seq[Snap]] = @[]     ## hist[tickMod][player]
  lastWb: seq[int] = @[]
  mismatchTick = -1
  buf = ""

proc snapAt(t: int, i: int): Snap =
  hist[t mod Hist][i]

var firstTick = -1
var outFile: File
if not open(outFile, outPath, fmWrite):
  quit("cannot open " & outPath)

while replay.playing:
  replay.stepReplay(game)
  if mismatchTick < 0 and replay.hashValidationFailed:
    mismatchTick = replay.hashMismatchTick
  let t = game.tickCount
  if firstTick < 0: firstTick = t
  while hist.len < Hist: hist.add(@[])
  let slot = t mod Hist
  hist[slot].setLen(game.players.len)
  for i, p in game.players:
    hist[slot][i] = Snap(
      x: float(p.x + CollisionW div 2),
      y: float(p.y + CollisionH div 2),
      alive: p.alive)
  while lastWb.len < game.players.len: lastWb.add(-1)

  for ev in game.events:
    if ev.kind != Shot or ev.weapon != "gun" or ev.source < 0: continue
    let sh = ev.source
    let locked =
      if lastWb[sh] >= 0: lastWb[sh] else: game.players[sh].aimBrads
    let t0 = t - game.config.fireWindupTicks
    if t0 < firstTick + Hist or t - firstTick < Hist: continue
    if mismatchTick >= 0: continue          # only pre-divergence ticks are truth
    # engine verdict for this shot: the paired ShotImpact carries the target.
    var engTgt = -1
    for e2 in game.events:
      if e2.kind == ShotImpact and e2.source == sh and e2.actionId == ev.actionId:
        engTgt = e2.target
        break
    let
      (ux, uy) = aimVector(locked)
      m1 = snapAt(t, sh)
      m0 = snapAt(t0, sh)
      mp = snapAt(t0 - 1, sh)
      shTeam = game.players[sh].team
    # --- pick the INTENDED target: the enemy closest to the LOCKED bearing at
    # the pull tick (that bearing was laid on it by the policy at T0).
    var
      best = -1
      bestAbs = 1e18
      bestAlong0 = 0.0
      bestPerp0 = 0.0
    for j in 0 ..< game.players.len:
      if j == sh: continue
      if game.players[j].team == shTeam: continue
      let s0 = snapAt(t0, j)
      if not s0.alive: continue
      if not snapAt(t, j).alive: continue
      let
        vx = s0.x - m0.x
        vy = s0.y - m0.y
        along = vx * ux + vy * uy
        perp = vx * uy - vy * ux
      if along <= 0.0 or along > float(game.config.gunRange): continue
      if abs(perp) < bestAbs:
        bestAbs = abs(perp); best = j; bestAlong0 = along; bestPerp0 = perp
    if best < 0: continue
    let
      j = best
      s0 = snapAt(t0, j)
      s1 = snapAt(t, j)
      s3 = snapAt(t0 - 3, j)
      rel1x = s1.x - m1.x
      rel1y = s1.y - m1.y
      along1 = rel1x * ux + rel1y * uy
      perp1 = rel1x * uy - rel1y * ux
      d0 = sqrt((s0.x - m0.x) * (s0.x - m0.x) + (s0.y - m0.y) * (s0.y - m0.y))
      # windup decomposition, all perpendicular to the LOCKED ray
      dTgt = (s1.x - s0.x) * uy - (s1.y - s0.y) * ux
      dMuz = (m1.x - m0.x) * uy - (m1.y - m0.y) * ux
      tvx = (s0.x - s3.x) / 3.0
      tvy = (s0.y - s3.y) / 3.0
      ovx = m0.x - mp.x
      ovy = m0.y - mp.y
      wu = float(game.config.fireWindupTicks)
    # counterfactual headings (integer brads, like the engine's aim)
    let
      hCf = bradsOfF((s0.x + tvx * wu) - (m0.x + ovx * wu),
                     (s0.y + tvy * wu) - (m0.y + ovy * wu))
      hCft = bradsOfF((s0.x + tvx * wu) - m0.x, (s0.y + tvy * wu) - m0.y)
      hNow = bradsOfF(s0.x - m0.x, s0.y - m0.y)
      (cx, cy) = aimVector(hCf)
      (tx2, ty2) = aimVector(hCft)
      (nx, ny) = aimVector(hNow)
      perpCf = rel1x * cy - rel1y * cx
      perpCft = rel1x * ty2 - rel1y * tx2
      perpNow = rel1x * ny - rel1y * nx
    # obstruction diagnostics at the RELEASE tick
    let
      los1 = game.paintPathClear(int(m1.x), int(m1.y), int(s1.x), int(s1.y))
    var
      screenIdx = -1
      screenAlong = 1e18
    for k in 0 ..< game.players.len:
      if k == sh or not game.players[k].alive: continue
      let sk = snapAt(t, k)
      let
        vx = sk.x - m1.x
        vy = sk.y - m1.y
        al = vx * ux + vy * uy
        pe = abs(vx * uy - vy * ux)
      if al <= 0.0 or al > float(game.config.gunRange): continue
      if pe > AcceptPx: continue
      if al < screenAlong: screenAlong = al; screenIdx = k
    let
      screenTeam =
        if screenIdx < 0: "-"
        elif game.players[screenIdx].team == shTeam: "mate"
        else: "foe"
      engHit = (if engTgt >= 0: 1 else: 0)
      engMate = (if engTgt >= 0 and game.players[engTgt].team == shTeam: 1 else: 0)
    let who = game.players[sh].address.replace(",", ";")
    buf.add(&"{epId},{t},{sh},{who},{ord(shTeam)},{locked}," &
      &"{d0:.1f},{along1:.1f},{perp1:.2f},{bestPerp0:.2f},{dTgt:.2f},{dMuz:.2f}," &
      &"{perpCf:.2f},{perpCft:.2f},{perpNow:.2f}," &
      &"{engHit},{engTgt},{engMate},{ord(los1)},{screenIdx},{screenTeam}," &
      &"{sqrt(tvx*tvx+tvy*tvy):.2f},{sqrt(ovx*ovx+ovy*ovy):.2f},{j}\n")
    if buf.len > 1 shl 16:
      outFile.write(buf); buf.setLen(0)
  game.events.setLen(0)
  for i, p in game.players: lastWb[i] = p.windupBrads

outFile.write(buf)
outFile.close()
stderr.write(&"{epId} ticks={game.tickCount} mismatchTick={mismatchTick}\n")

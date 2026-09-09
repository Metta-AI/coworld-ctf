## Defensive windup-mirror forensics — the VICTIM side of pb_shot_probe.nim.
##
## O-28 (~/projects/ctf-latency AUDIT.md): the gun locks its aim ray at the
## trigger pull and releases the hitscan shot FireWindupTicks(5) later, so a
## shot that lands on a target was aimed at where that target stood ~5 ticks
## before impact. A target that does not move makes the stale ray exactly
## correct. This tool re-simulates one .replay and emits ONE ROW PER RELEASED
## GUN SHOT that had a live opposing candidate on the ray, from the TARGET's
## point of view:
##   dTgt   = the target's own perpendicular displacement, relative to the
##            shooter's LOCKED ray, over the shooter's windup window
##            (t0 = pull tick .. t = release tick). This is the mirror-curve
##            x-axis: how far the victim moved while the ray was already
##            locked on them.
##   hit    = did this exact shot land on this exact target (ENGINE TRUTH via
##            the paired ShotImpact event's target field — never a geometric
##            guess when a real impact exists).
##   fatal  = did this exact shot carry a same-tick Kill event crediting the
##            shooter with this target (ENGINE TRUTH via the Kill event).
##
## For a MISS (ShotImpact.target == -1, nobody was hit), there is no ground
## truth for "who was this aimed at" — this tool falls back to the same
## closest-to-the-locked-ray heuristic pb_shot_probe.nim uses, restricted to
## enemies alive at both t0 and t. Rows carry a `gt` flag (1 = ground-truth
## target from a real impact, 0 = geometric guess for a miss) so downstream
## analysis can weight or exclude guesses.
##
## Usage: pb_def_probe <replay-path> <episode-id> <out-csv>

import
  std/[math, os, strformat, strutils],
  ../src/ctf/sim,
  toolutil

const
  Hist = 12 ## ticks of position history kept (>= fireWindupTicks + 2)

type Snap = object
  x, y: float
  alive: bool

proc bradsOfF(dx, dy: float): int =
  if dx == 0.0 and dy == 0.0: return 0
  let b = int(round(arctan2(-dy, dx) * float(AimBradsTurn div 2) / PI))
  ((b mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn

let params = commandLineParams()
if params.len < 3:
  quit("Usage: pb_def_probe <replay-path> <episode-id> <out-csv>")
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
    hist[slot][i] = Snap(x: float(p.x), y: float(p.y), alive: p.alive)
  while lastWb.len < game.players.len: lastWb.add(-1)

  for ev in game.events:
    if ev.kind != Shot or ev.weapon != "gun" or ev.source < 0: continue
    let sh = ev.source
    let locked =
      if lastWb[sh] >= 0: lastWb[sh] else: game.players[sh].aimBrads
    let t0 = t - game.config.fireWindupTicks
    if t0 < firstTick + Hist or t - firstTick < Hist: continue
    if mismatchTick >= 0: continue          # only pre-divergence ticks are truth
    let shTeam = game.players[sh].team

    # Ground truth for this exact shot: the paired ShotImpact (target = -1
    # for a clean miss). A same-tick Kill crediting (sh -> target) marks it
    # fatal.
    var engTgt = -1
    var haveImpact = false
    for e2 in game.events:
      if e2.kind == ShotImpact and e2.source == sh and e2.actionId == ev.actionId:
        engTgt = e2.target
        haveImpact = true
        break
    if not haveImpact: continue   # no paired ShotImpact this tick — cannot score
    var fatal = false
    if engTgt >= 0:
      for e3 in game.events:
        if e3.kind == Kill and e3.source == sh and e3.target == engTgt:
          fatal = true
          break

    var
      targetIdx = -1
      gt = 0
    if engTgt >= 0:
      targetIdx = engTgt
      gt = 1
    else:
      # Miss: no ground-truth target. Fall back to the closest-to-the-locked
      # -ray heuristic among enemies alive at both t0 and t (pb_shot_probe's
      # approach) so the miss side of the mirror curve still has a row.
      let (ux0, uy0) = aimVector(locked)
      let m0g = snapAt(t0, sh)
      var bestAbs = 1e18
      for j in 0 ..< game.players.len:
        if j == sh: continue
        if game.players[j].team == shTeam: continue
        let s0g = snapAt(t0, j)
        if not s0g.alive: continue
        if not snapAt(t, j).alive: continue
        let
          vx = s0g.x - m0g.x
          vy = s0g.y - m0g.y
          along = vx * ux0 + vy * uy0
          perp = vx * uy0 - vy * ux0
        if along <= 0.0 or along > float(game.config.gunRange): continue
        if abs(perp) < bestAbs:
          bestAbs = abs(perp); targetIdx = j
      if targetIdx < 0: continue

    let s0 = snapAt(t0, targetIdx)
    if not s0.alive: continue     # no valid pre-windup position — skip
    let
      (ux, uy) = aimVector(locked)
      m1 = snapAt(t, sh)
      s1raw = snapAt(t, targetIdx)
      # A fatal hit can leave alive=false in the SAME tick's snapshot; fall
      # back one tick to the last live position (<=1 tick of drift, inside
      # the noise this tool already averages over).
      s1 = if s1raw.alive: s1raw else: snapAt(t - 1, targetIdx)
      rel1x = s1.x - m1.x
      rel1y = s1.y - m1.y
      along1 = rel1x * ux + rel1y * uy
      perp1 = rel1x * uy - rel1y * ux
      d0 = sqrt((s0.x - m1.x) * (s0.x - m1.x) + (s0.y - m1.y) * (s0.y - m1.y))
      dTgt = (s1.x - s0.x) * uy - (s1.y - s0.y) * ux   ## the mirror-curve x-axis
      tgtTeam = game.players[targetIdx].team
      sameTeam = (tgtTeam == shTeam)
      who = game.players[sh].address.replace(",", ";")
      tgtWho = game.players[targetIdx].address.replace(",", ";")
      hitFlag = (if engTgt == targetIdx: 1 else: 0)
      fatalFlag = (if fatal: 1 else: 0)
    buf.add(&"{epId},{t},{sh},{who},{ord(shTeam)},{targetIdx},{tgtWho}," &
      &"{ord(tgtTeam)},{ord(sameTeam)},{gt},{hitFlag},{fatalFlag}," &
      &"{d0:.1f},{along1:.1f},{perp1:.2f},{dTgt:.2f}\n")
    if buf.len > 1 shl 16:
      outFile.write(buf); buf.setLen(0)
  game.events.setLen(0)
  for i, p in game.players: lastWb[i] = p.windupBrads

outFile.write(buf)
outFile.close()
stderr.write(&"{epId} ticks={game.tickCount} mismatchTick={mismatchTick}\n")

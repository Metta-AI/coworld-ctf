## ⭐ ENTRY-Y FROM A REAL LEAGUE REPLAY (one-door break, 2026-08-14).
##
## The mirror harness cannot score the one-door funnel: on generated maps
## against a copy of ourselves the BEFORE entry-y stdev is already 140-205px,
## while the field defect shows as 5-31px. The defect is a property of a
## SPECIFIC map's nav funnel plus a SPECIFIC opponent camping it, so it has to
## be measured where it happened.
##
## This re-simulates a recorded league replay and reports, per slot, the y at
## which that seat crossed INTO the enemy half. `openReplay` runs with
## mismatchQuit=true, so a clean run is also a proof that the re-simulation is
## byte-faithful to the recording (a replay only re-sims on its recording
## GameVersion — check that before believing any number out of this).
##
## ⚠️ THIS IS THE *BEFORE* ARM AND CAN NEVER BE THE AFTER ARM. A replay
## replays recorded INPUTS, so it reproduces exactly what happened and can
## never show what a different policy would have done on the same board. The
## AFTER has to come from re-running the policy on the same generated MAP.
##
## ⚠️ "Entry" is not self-evident, and the choice changes the answer. Depth 0
## (the midline) is where a seat first stands in enemy ground. The DOOR is the
## gap in the mirrored obstacle band, which on gen-57711 starts ~90px past
## centre — the replay forensics reported entries at x~707-716 against a centre
## of 617. Measuring at several depths separates "we spread at the line and are
## then funnelled into one gap" from "we never spread at all", and those two
## want different fixes.
##
## Usage (repo root):
##   nim c -d:release --hints:off -o:/tmp/door_entry.out tools/door_replay_entry.nim
##   /tmp/door_entry.out <replay> --ours 0,2,4,6 --theirs 1,3,5,7 --depth 0,45,90,135
import std/[os, strutils, strformat, math, algorithm]
import ../src/ctf/sim
import toolutil

type Sample = object
  y*, x*: float
  tick*: int

proc statOf(v: seq[float]): (float, float) =
  if v.len == 0: return (0.0, 0.0)
  var m = 0.0
  for x in v: m += x
  m /= v.len.float
  if v.len < 2: return (m, 0.0)
  var s = 0.0
  for x in v: s += (x - m) * (x - m)
  (m, sqrt(s / (v.len - 1).float))

proc parseInts(s: string): seq[int] =
  for tok in s.split(','):
    if tok.strip().len > 0: result.add parseInt(tok.strip())

proc main() =
  var
    path = ""
    ours: seq[int] = @[]
    theirs: seq[int] = @[]
    label = ""
    dumpSpec = ""
    depths: seq[int] = @[]
  let p = commandLineParams()
  var i = 0
  while i < p.len:
    case p[i]
    of "--ours": inc i; ours = parseInts(p[i])
    of "--theirs": inc i; theirs = parseInts(p[i])
    of "--label": inc i; label = p[i]
    of "--dump-mapspec": inc i; dumpSpec = p[i].absolutePath()
    of "--depth": inc i; depths = parseInts(p[i])
    else:
      if path.len == 0: path = p[i]
    inc i
  if path.len == 0: quit("usage: door_replay_entry <replay> [--ours 0,2,4,6]")
  let src = path.absolutePath()
  chdirGameDir()
  if depths.len == 0: depths = @[0]
  if 0 notin depths: depths = @[0] & depths
  depths.sort()

  # One playback, every threshold measured in the same pass — a second
  # openReplay would re-run the hash check for nothing and the arms must see
  # byte-identical state anyway.
  var (game, replay) = openReplay(src)
  let
    w = game.gameMap.width
    h = game.gameMap.height
    cx = w div 2
  echo &"replay {label}"
  echo &"  map {game.gameMap.name} {w}x{h}  centreX {cx}  depths {depths}"
  # ⭐ The AFTER arm's handle. A replay replays recorded INPUTS, so it can only
  # ever show what DID happen; the counterfactual has to come from re-running
  # the policy on the SAME BOARD. That board rides in the recording as an
  # expanded mapSpec, and the engine round-trips it exactly
  # (resolveCtfMapMetadata prefers mapSpec over any seed), so dumping it here
  # is what lets the mirror rig play the real defect map.
  if dumpSpec.len > 0:
    writeFile(dumpSpec, game.gameMap.mapSpecJson())
    echo &"  wrote mapSpec -> {dumpSpec}"

  var
    nSlots = 0
    prevDepth: seq[float] = @[]
    live: seq[bool] = @[]           # had a valid previous ALIVE reading
    # samples[d][slot]
    samples: seq[seq[seq[Sample]]] = @[]
    deaths: seq[int] = @[]
  for _ in depths: samples.add @[]

  proc grow(n: int) =
    while nSlots < n:
      prevDepth.add 0.0; live.add false; deaths.add 0
      for d in 0 ..< depths.len: samples[d].add @[]
      inc nSlots

  var tick = 0
  while replay.playing:
    replay.stepReplay(game)
    inc tick
    grow(game.players.len)
    for s in 0 ..< game.players.len:
      let pl = game.players[s]
      if not pl.alive:
        # A death ends the segment: a respawn must never read as a crossing.
        if live[s]: inc deaths[s]
        live[s] = false
        continue
      # + = into the ENEMY half. homeX is this seat's OWN home point, so the
      # sign is read off the board instead of assumed from team colour (which
      # is a parity guess on anything but a 2-team board).
      let sign = (if pl.homeX < cx: 1.0 else: -1.0)
      let depth = sign * float(pl.x - cx)
      if live[s]:
        for di, thr in depths:
          if prevDepth[s] <= float(thr) and depth > float(thr):
            samples[di][s].add Sample(y: float(pl.y), x: float(pl.x), tick: tick)
      prevDepth[s] = depth
      live[s] = true

  echo &"  re-simulated {tick} ticks, hash-checked OK -> the recording is faithful"

  proc report(di: int, thr: int, name: string, slots: seq[int]) =
    var ys, xs: seq[float] = @[]
    var ts: seq[int] = @[]
    for s in slots:
      if s < nSlots:
        for smp in samples[di][s]:
          ys.add smp.y; xs.add smp.x; ts.add smp.tick
    let (my, sy) = statOf(ys)
    let (mx, sx) = statOf(xs)
    var lo = 1e9
    var hi = -1e9
    for y in ys:
      lo = min(lo, y); hi = max(hi, y)
    if ys.len == 0: (lo, hi) = (0.0, 0.0)
    echo &"  depth {thr:>4}  {name:<7} n={ys.len:<3} ENTRY-Y mean {my:>6.1f} " &
      &"STDEV {sy:>6.1f}  span {lo:>5.0f}..{hi:<5.0f} ({hi-lo:>4.0f}px)   " &
      &"x mean {mx:>6.1f} sd {sx:>4.1f}"

  echo ""
  echo "=== ENTRY-Y BY DEPTH (the target metric) ==="
  for di, thr in depths:
    report(di, thr, "OURS", ours)
    if theirs.len > 0: report(di, thr, "THEIRS", theirs)
  echo ""
  echo "=== PER-SLOT at depth 0 ==="
  echo "slot  entries  meanY   stdevY   deaths"
  for s in 0 ..< nSlots:
    var ys: seq[float] = @[]
    for smp in samples[0][s]: ys.add smp.y
    let (my, sy) = statOf(ys)
    echo &"{s:>4} {ys.len:>8} {my:>7.1f} {sy:>8.1f} {deaths[s]:>8}"

main()

## stuck_census — per-seat STATIONARY-TIME census from one re-simulated replay.
##
## WHY a new tool instead of tools/stuck_analysis.nim: that one reports a single
## percentage per seat with no identity, no mode geometry, no INPUT MASK and no
## context. The question this instrument exists to answer is not "how long was a
## seat still" but "was the seat PRESSING THE D-PAD while it was still" — a seat
## holding still with a zero d-pad is IDLE BY CHOICE, a seat holding still with a
## live d-pad is a PATHING FAILURE, and the two need opposite fixes. The replay's
## recorded input masks carry exactly that, so both classes come out of the same
## hash-validated walk.
##
## Traps this defends against:
##   * A DEAD seat's position is frozen and reads as perfectly stuck. Every stall
##     here requires `alive` on EVERY tick of the interval, never just the ends.
##   * The Lobby holds everyone on their pedestal for hundreds of ticks. Only
##     `Playing` ticks are counted, and the phase is read per tick.
##   * Identity comes from `player.address` (the recorded join name), never from
##     a seat-parity rule.
##
## Output: one JSON object per replay on stdout (JSONL when many are piped in).
##
## Usage: nim r tools/stuck_census.nim <replay-path> [<replay-path>...]

import
  std/[json, math, os, strutils],
  ../src/ctf/[sim, sim_types, sim_state],
  toolutil

const
  # A cog's ceiling is MaxSpeed/MotionScale = 2.75 px/tick, so an unobstructed
  # seat covers ~165 px in 60 ticks. The sweep is reported so the primary
  # threshold can be argued from the curve rather than asserted.
  SweepWin = [30, 60, 90, 120, 180]
  SweepRad = [4, 8, 16, 32]
  PrimWin = 60          ## 2.0 s
  PrimRad = 16          ## under 10% of one window's free travel
  MinStall = 45         ## a stall shorter than 1.5 s is not reported
  LocalR = 300.0        ## "local" numbers radius, ~1/4 of the map width
  LocalR2 = LocalR * LocalR
  # ffa4 is decided in the opening: lives spent by T=1200 is the scoring metric,
  # so every rate is also cut into the same buckets rather than reported flat.
  Bucket = [0, 1200, 3000, 1_000_000]

type
  Snap = object
    x, y: int
    alive: bool
    hp: int
    mask: uint8
    carry: bool
    homeX, homeY: int

proc dist(ax, ay, bx, by: int): float =
  let dx = float(ax - bx)
  let dy = float(ay - by)
  sqrt(dx * dx + dy * dy)

proc censusOne(path: string): JsonNode =
  var (game, replay) = openReplay(path, mismatchQuit = false)
  let seatCap = game.config.playerSlotLimit()
  var
    hist: seq[seq[Snap]] = newSeq[seq[Snap]](seatCap)
    tickPhase: seq[bool] = @[]     ## Playing?
    teamOf = newSeq[int](seatCap)
    addrOf = newSeq[string](seatCap)
    deathsAt: seq[seq[int]] = newSeq[seq[int]](seatCap)  ## ticks a seat died
    prevDeaths = newSeq[int](seatCap)
    joined = newSeq[bool](seatCap)

  while replay.playing:
    replay.stepReplay(game)
    let playing = game.phase == Playing
    tickPhase.add(playing)
    let idx = tickPhase.len - 1
    for i in 0 ..< seatCap:
      if i < game.players.len:
        let p = game.players[i]
        joined[i] = true
        teamOf[i] = ord(p.team)
        addrOf[i] = p.address
        hist[i].add(Snap(x: p.x, y: p.y, alive: p.alive and playing, hp: p.hp,
                         mask: replay.lastAppliedMasks[i],
                         carry: p.carryingFlag,
                         homeX: p.homeX, homeY: p.homeY))
        if p.deaths > prevDeaths[i]:
          for _ in prevDeaths[i] ..< p.deaths:
            deathsAt[i].add(idx)
          prevDeaths[i] = p.deaths
      else:
        hist[i].add(Snap(x: 0, y: 0, alive: false, hp: 0, mask: 0, carry: false))

  let n = tickPhase.len
  var nSeats = 0
  for i in 0 ..< seatCap:
    if joined[i]: inc nSeats

  # med-kit and flag geometry, read at the end (spawn points are static)
  var kitPts: seq[(int, int)]
  for k in game.medKitSpawns:
    kitPts.add((k.x, k.y))
  var flagPts: seq[(int, int)]
  let nTeams = game.gameMap.teamCount()
  for t in activeTeams(nTeams):
    flagPts.add((game.flags[t].x, game.flags[t].y))

  proc nearestPt(pts: seq[(int, int)], x, y: int): float =
    result = 1e9
    for (px, py) in pts:
      let d = dist(x, y, px, py)
      if d < result: result = d

  # ---- per-seat alive/stuck sweep -----------------------------------------
  var seats = newJArray()
  var stalls = newJArray()
  for i in 0 ..< seatCap:
    if not joined[i]: continue
    let h = hist[i]
    var alive = 0
    var dpadAliveTicks = 0
    var pathLen = 0.0
    var bAlive = [0, 0, 0]
    var bDpad = [0, 0, 0]
    proc bucketOf(t: int): int =
      for k in 0 .. 2:
        if t >= Bucket[k] and t < Bucket[k + 1]: return k
      2
    for t in 0 ..< n:
      if h[t].alive:
        inc alive
        inc bAlive[bucketOf(t)]
        if (h[t].mask and 0x0F'u8) != 0:
          inc dpadAliveTicks
          inc bDpad[bucketOf(t)]
        if t > 0 and h[t - 1].alive:
          pathLen += dist(h[t].x, h[t].y, h[t - 1].x, h[t - 1].y)

    # threshold sweep: displacement over a trailing window, alive throughout
    var sweep = newJObject()
    var sweepB = newJObject()
    for w in SweepWin:
      for r in SweepRad:
        var c = 0
        var cb = [0, 0, 0]
        for t in w ..< n:
          if not h[t].alive: continue
          var ok = true
          for u in (t - w) .. t:
            if not h[u].alive:
              ok = false
              break
          if not ok: continue
          if dist(h[t].x, h[t].y, h[t - w].x, h[t - w].y) < float(r):
            inc c
            inc cb[bucketOf(t)]
        sweep[$w & "_" & $r] = %c
        if w == PrimWin and r == PrimRad:
          sweepB["b"] = %cb

    # ---- DISPERSION: is this seat fighting with its team or alone? ---------
    # Sampled every 8 ticks over alive Playing ticks, per opening/mid/late
    # bucket. This is the control the stall census needs: a policy that holds
    # still in a tight block is not "stuck", it is CONCENTRATED, and that is a
    # different thing from a seat frozen alone in a corner.
    var
      dN = [0, 0, 0]
      dHome = [0.0, 0.0, 0.0]     ## distance to own spawn
      dMate = [0.0, 0.0, 0.0]     ## distance to nearest live team-mate
      dAllyN = [0.0, 0.0, 0.0]    ## live allies within LocalR
      dFoeN = [0.0, 0.0, 0.0]     ## live enemies within LocalR
    var t = 0
    while t < n:
      if h[t].alive:
        let k = bucketOf(t)
        inc dN[k]
        dHome[k] += dist(h[t].x, h[t].y, h[t].homeX, h[t].homeY)
        var nm = 1e9
        for j in 0 ..< seatCap:
          if j == i or not joined[j]: continue
          let q = hist[j][t]
          if not q.alive: continue
          let dd = dist(h[t].x, h[t].y, q.x, q.y)
          if teamOf[j] == teamOf[i]:
            if dd < nm: nm = dd
            if dd < LocalR: dAllyN[k] += 1.0
          else:
            if dd < LocalR: dFoeN[k] += 1.0
        if nm < 1e8: dMate[k] += nm
      t += 8

    var disp = newJObject()
    disp["n"] = %dN
    for (nm, arr) in {"home": dHome, "mate": dMate, "ally": dAllyN, "foe": dFoeN}:
      var a2 = newJArray()
      for k in 0 .. 2:
        a2.add(%round(arr[k] / float(max(1, dN[k])), 2))
      disp[nm] = a2

    seats.add(%*{
      "i": i, "a": addrOf[i], "t": teamOf[i],
      "alive": alive, "dpad": dpadAliveTicks, "path": round(pathLen, 1),
      "deaths": deathsAt[i].len, "sweep": sweep,
      "balive": bAlive, "bdpad": bDpad, "bstuck": sweepB["b"],
      "dtick": deathsAt[i], "disp": disp
    })

    # ---- stall episodes: maximal alive runs inside a PrimRad circle --------
    var a = 0
    while a < n:
      if not h[a].alive:
        inc a
        continue
      var b = a
      while b + 1 < n and h[b + 1].alive and
            dist(h[b + 1].x, h[b + 1].y, h[a].x, h[a].y) < float(PrimRad):
        inc b
      let dur = b - a + 1
      if dur >= MinStall:
        # ---- stall context -------------------------------------------------
        var dpadOn = 0
        var fireOn = 0
        var slen = 0.0
        var maxDisp = 0.0
        var carryT = 0
        var flips = 0
        var sumDx = 0
        var sumDy = 0
        for t in a .. b:
          let m = h[t].mask
          if (m and 0x0F'u8) != 0:
            inc dpadOn
            if (m and 0x08'u8) != 0: inc sumDx
            if (m and 0x04'u8) != 0: dec sumDx
            if (m and 0x02'u8) != 0: inc sumDy
            if (m and 0x01'u8) != 0: dec sumDy
          if (m and 0x20'u8) != 0: inc fireOn
          if h[t].carry: inc carryT
          if t > a:
            if (m and 0x0F'u8) != (h[t - 1].mask and 0x0F'u8): inc flips
            slen += dist(h[t].x, h[t].y, h[t - 1].x, h[t - 1].y)
          let d = dist(h[t].x, h[t].y, h[a].x, h[a].y)
          if d > maxDisp: maxDisp = d
        # Is the seat pressing INTO geometry? Probe the wall mask along the
        # stall's mean d-pad heading. A high blocked fraction with a live d-pad
        # is a corner/wall trap; a zero blocked fraction with a live d-pad is a
        # nav target the feet never commit to.
        var wallHit = 0
        var wallProbe = 0
        if dpadOn > 0 and (sumDx != 0 or sumDy != 0):
          let mag = sqrt(float(sumDx * sumDx + sumDy * sumDy))
          let ux = float(sumDx) / mag
          let uy = float(sumDy) / mag
          for k in [10, 14, 18, 22, 26, 30]:
            let px = clamp(h[a].x + int(ux * float(k)), 0, MapWidth - 1)
            let py = clamp(h[a].y + int(uy * float(k)), 0, MapHeight - 1)
            inc wallProbe
            if game.wallMask[mapIndex(px, py)]: inc wallHit
        let mid = (a + b) div 2
        var
          nearEnemy = 1e9
          nearAlly = 1e9
          minNearEnemy = 1e9
          enemAlive = 0
          allyAlive = 0
          enemNear = 0
          allyNear = 0
          mateAdvSum = 0.0
          mateAdvN = 0
        for j in 0 ..< seatCap:
          if j == i or not joined[j]: continue
          let q = hist[j][mid]
          let foe = teamOf[j] != teamOf[i]
          if q.alive:
            let d = dist(h[mid].x, h[mid].y, q.x, q.y)
            if foe:
              inc enemAlive
              if d < nearEnemy: nearEnemy = d
              if d * d < LocalR2: inc enemNear
            else:
              inc allyAlive
              if d < nearAlly: nearAlly = d
              if d * d < LocalR2: inc allyNear
        # nearest live enemy at ANY tick of the stall (was help ever adjacent?)
        for t in a .. b:
          for j in 0 ..< seatCap:
            if j == i or not joined[j] or teamOf[j] == teamOf[i]: continue
            let q = hist[j][t]
            if q.alive:
              let d = dist(h[t].x, h[t].y, q.x, q.y)
              if d < minNearEnemy: minNearEnemy = d
        # teammates' local numbers while THIS seat is parked
        for j in 0 ..< seatCap:
          if j == i or not joined[j] or teamOf[j] != teamOf[i]: continue
          let q = hist[j][mid]
          if not q.alive: continue
          var af = 0
          var ef = 0
          for k in 0 ..< seatCap:
            if k == j or not joined[k]: continue
            let z = hist[k][mid]
            if not z.alive: continue
            if dist(q.x, q.y, z.x, z.y) < LocalR:
              if teamOf[k] == teamOf[j]: inc af else: inc ef
          mateAdvSum += float(af - ef)
          inc mateAdvN
        # team deaths inside the window
        var teamDeaths = 0
        for j in 0 ..< seatCap:
          if not joined[j] or teamOf[j] != teamOf[i]: continue
          for dt in deathsAt[j]:
            if dt >= a and dt <= b: inc teamDeaths

        stalls.add(%*{
          "i": i, "a": addrOf[i], "t": teamOf[i],
          "s": a, "e": b, "d": dur,
          "x": h[a].x, "y": h[a].y, "hp": h[mid].hp,
          "dpad": dpadOn, "fire": fireOn, "carry": carryT,
          "path": round(slen, 1), "maxd": round(maxDisp, 1),
          "flips": flips, "dx": sumDx, "dy": sumDy,
          "wall": wallHit, "wallp": wallProbe,
          "ne": round(if nearEnemy > 1e8: -1.0 else: nearEnemy, 1),
          "nemin": round(if minNearEnemy > 1e8: -1.0 else: minNearEnemy, 1),
          "na": round(if nearAlly > 1e8: -1.0 else: nearAlly, 1),
          "ea": enemAlive, "aa": allyAlive,
          "enear": enemNear, "anear": allyNear,
          "madv": (if mateAdvN > 0: round(mateAdvSum / float(mateAdvN), 2) else: 0.0),
          "madvn": mateAdvN,
          "tdeath": teamDeaths,
          "kit": round(nearestPt(kitPts, h[a].x, h[a].y), 1),
          "flag": round(nearestPt(flagPts, h[a].x, h[a].y), 1),
          "home": round(dist(h[a].x, h[a].y, h[a].homeX, h[a].homeY), 1)
        })
      a = if b > a: b else: a + 1

  var playTicks = 0
  for p in tickPhase:
    if p: inc playTicks

  result = %*{
    "ep": path.splitFile().name,
    "ticks": n, "play": playTicks,
    "teams": nTeams, "slots": nSeats,
    "finished": game.phase == GameOver,
    "winner": (if game.isDraw: "" else: teamText(game.winner)),
    "draw": game.isDraw,
    "hashfail": replay.hashValidationFailed,
    "mapw": MapWidth,
    "seats": seats, "stalls": stalls
  }

when isMainModule:
  chdirGameDir()
  let args = commandLineParams()
  if args.len == 0:
    echo "Usage: stuck_census <replay-path> [...]"
    quit(1)
  for p in args:
    try:
      echo $censusOne(p.absolutePath())
    except CatchableError as e:
      stderr.writeLine("FAIL " & p & ": " & e.msg)

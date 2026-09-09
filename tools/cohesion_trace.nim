## cohesion_trace — per-tick TEAM COHESION trajectories from one re-simulated
## replay.
##
## THE QUESTION. The opening-concentration finding says rivals sit 141-173 px
## from their own spawn with their nearest mate 94-95 px away while we sit
## 274 px out with our nearest mate 170 px away. That single snapshot is
## consistent with TWO opposite stories:
##   HOLD                  rivals stay near spawn through the decisive window.
##   ADVANCE-IN-FORMATION  rivals walk out just as far as us, but keep their
##                         mutual spacing tight; the low from-spawn number is a
##                         mid-traverse artifact or a closer objective.
## These imply opposite levers (a staging clamp vs a group advance), so the
## discriminator is the TIME SERIES, not the snapshot.
##
## What this emits, per seat and per team, binned at 25 ticks over t=0..1200:
##   1. FROM-SPAWN     distance from the seat's own `homeX/homeY` (the engine's
##      own per-seat spawn point, set once in `arrangeHomePositions`).
##   2. NEAREST LIVE MATE  distance to the closest ALIVE same-team seat.
##   3. TEAM SPREAD    mean pairwise distance among that team's live seats, and
##      mean distance from their live centroid.
##   4. COMMIT-OUTWARD tick of the FIRST crossing of 200/300/400/500 px.
##   5. MOVE-AS-A-UNIT  mean cosine between teammates' displacement vectors
##      over a 50-tick window, WITH a cross-team pair control in the same
##      episode (if everyone converges on the map centre, within-team cosine is
##      high for a reason that has nothing to do with formation).
##   6. ROLE STRUCTURE  each seat's mean opening position (t in [200,400),
##      first life) plus checkpoint positions, so the four seats' destinations
##      can be clustered offline. This is an inference from the OUTSIDE about
##      code we cannot read, and is reported as such.
##
## Traps this defends against:
##   * A DEAD SEAT'S POSITION IS FROZEN AT ITS DEATH SPOT and a RESPAWNED seat
##     is sitting exactly on its spawn. Either would fake "holding near spawn",
##     which is the very conclusion under test. Every tick counted here
##     requires `alive` on THAT tick, and every quantity is ALSO emitted in a
##     FIRST-LIFE-ONLY variant (ticks strictly before the seat's first death),
##     which no respawn can contaminate.
##   * Only `Playing` ticks count; the lobby parks everyone on a pedestal.
##   * Identity is `player.address`, never the API `player_name` and never a
##     seat-parity rule.
##   * The displacement-correlation window requires BOTH seats alive on EVERY
##     tick of the window (via a consecutive-alive run length), not just at the
##     endpoints, and drops pairs that barely moved (a 2 px jitter has a
##     meaningless direction) — the dropped counts are emitted so the
##     denominator is auditable.
##
## Output: one JSON object per replay on stdout (JSONL when many are passed).
## Usage: cohesion_trace <replay-path> [<replay-path>...]

import
  std/[json, math, os, sequtils, strutils],
  ../src/ctf/[sim, sim_types, sim_state, arena],
  toolutil

const
  BinW = 25
  NBin = 48                 ## 25 * 48 = ticks 0..1199
  TEnd = BinW * NBin
  CBounds = [0, 200, 400, 800, 1200]
  NCB = 4                   ## opening / decisive / mid / late-first-minute
  HBinPx = 50.0
  HBins = 24                ## 0..1200 px
  DispWin = 50              ## ticks over which a displacement is measured
  DispStep = 25
  MoveMin = 15.0            ## px; below this a displacement has no direction
  Thresh = [200.0, 300.0, 400.0, 500.0]
  NTh = 4
  OpenLo = 200              ## "opening destination" window, first life only
  OpenHi = 400
  CPs = [0, 100, 200, 300, 400, 600, 800, 1000, 1200]

type
  Snap = object
    x, y: int32
    alive: bool

proc dist(ax, ay, bx, by: int): float =
  let dx = float(ax - bx)
  let dy = float(ay - by)
  sqrt(dx * dx + dy * dy)

proc hbin(d: float): int =
  result = int(d / HBinPx)
  if result < 0: result = 0
  if result >= HBins: result = HBins - 1

proc cbucket(t: int): int =
  for k in 0 ..< NCB:
    if t >= CBounds[k] and t < CBounds[k + 1]: return k
  -1

proc traceOne(path: string): JsonNode =
  var (game, replay) = openReplay(path, mismatchQuit = false)
  let seatCap = game.config.playerSlotLimit()
  var
    hist: seq[seq[Snap]] = newSeq[seq[Snap]](seatCap)
    tickPhase: seq[bool] = @[]
    teamOf = newSeq[int](seatCap)
    addrOf = newSeq[string](seatCap)
    joined = newSeq[bool](seatCap)
    homeX = newSeq[int](seatCap)
    homeY = newSeq[int](seatCap)
    prevDeaths = newSeq[int](seatCap)
    firstDeath = newSeq[int](seatCap)
    nDeaths = newSeq[int](seatCap)
  for i in 0 ..< seatCap: firstDeath[i] = -1

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
        homeX[i] = p.homeX
        homeY[i] = p.homeY
        hist[i].add(Snap(x: int32(p.x), y: int32(p.y),
                         alive: p.alive and playing))
        if p.deaths > prevDeaths[i]:
          if firstDeath[i] < 0: firstDeath[i] = idx
          nDeaths[i] = p.deaths
          prevDeaths[i] = p.deaths
      else:
        hist[i].add(Snap(x: 0, y: 0, alive: false))

  let n = tickPhase.len
  ## REBASE TIME ON THE FIRST `Playing` TICK. The lobby is ~144 ticks and its
  ## length is NOT constant across replays; binning on the raw replay index
  ## would smear every trajectory by that offset and would put an all-lobby
  ## (zero-count) bin at the front of every series.
  var t0 = -1
  for t in 0 ..< n:
    if tickPhase[t]: t0 = t; break
  if t0 < 0: t0 = 0
  let tCap = min(n - t0, TEnd)
  var nSeats = 0
  for i in 0 ..< seatCap:
    if joined[i]: inc nSeats

  # ---- consecutive-alive run length ending at each tick --------------------
  var runLen: seq[seq[int32]] = newSeq[seq[int32]](seatCap)
  for i in 0 ..< seatCap:
    runLen[i] = newSeq[int32](n)
    var r = 0'i32
    for t in 0 ..< n:
      if joined[i] and hist[i][t].alive: inc r else: r = 0
      runLen[i][t] = r

  proc firstLife(i, t: int): bool {.closure.} =
    firstDeath[i] < 0 or t < firstDeath[i]

  # ---- per-seat accumulators ----------------------------------------------
  var
    sCnt = newSeq[seq[int]](seatCap)       ## alive ticks per bin
    sFs = newSeq[seq[float]](seatCap)      ## sum from-spawn
    sFs2 = newSeq[seq[float]](seatCap)     ## sum from-spawn squared
    sNm = newSeq[seq[float]](seatCap)      ## sum nearest-live-mate
    sNmN = newSeq[seq[int]](seatCap)       ## ticks a live mate existed
    fCnt = newSeq[seq[int]](seatCap)       ## first-life variants
    fFs = newSeq[seq[float]](seatCap)
    fNm = newSeq[seq[float]](seatCap)
    fNmN = newSeq[seq[int]](seatCap)
    fsHist = newSeq[seq[int]](seatCap)     ## NCB * HBins
    nmHist = newSeq[seq[int]](seatCap)
    cross = newSeq[seq[int]](seatCap)      ## first crossing tick per threshold
    fcross = newSeq[seq[int]](seatCap)     ## same, first life only
    opX = newSeq[float](seatCap)
    opY = newSeq[float](seatCap)
    opN = newSeq[int](seatCap)
  for i in 0 ..< seatCap:
    sCnt[i] = newSeq[int](NBin); sFs[i] = newSeq[float](NBin)
    sFs2[i] = newSeq[float](NBin)
    sNm[i] = newSeq[float](NBin); sNmN[i] = newSeq[int](NBin)
    fCnt[i] = newSeq[int](NBin); fFs[i] = newSeq[float](NBin)
    fNm[i] = newSeq[float](NBin); fNmN[i] = newSeq[int](NBin)
    fsHist[i] = newSeq[int](NCB * HBins); nmHist[i] = newSeq[int](NCB * HBins)
    cross[i] = newSeq[int](NTh); fcross[i] = newSeq[int](NTh)
    for z in 0 ..< NTh:
      cross[i][z] = -1; fcross[i][z] = -1

  # ---- per-team accumulators ----------------------------------------------
  const NTeam = 4
  var
    tCnt = newSeq[int](NTeam * NBin)       ## ticks with >= 2 live seats
    tPair = newSeq[float](NTeam * NBin)    ## sum of mean pairwise distance
    tRad = newSeq[float](NTeam * NBin)     ## sum of mean distance to centroid
    tLive = newSeq[float](NTeam * NBin)    ## sum of live-seat count
    tLiveN = newSeq[int](NTeam * NBin)     ## ticks with >= 1 live seat
    tCos = newSeq[float](NTeam * NBin)     ## sum of pair displacement cosine
    tCosN = newSeq[int](NTeam * NBin)      ## pairs contributing
    tPairAlive = newSeq[int](NTeam * NBin) ## pairs alive through the window
    xCos = newSeq[float](NBin)             ## CROSS-team control
    xCosN = newSeq[int](NBin)
    xPairAlive = newSeq[int](NBin)

  for tp in 0 ..< tCap:
    let t = tp + t0
    let b = tp div BinW
    let cb = cbucket(tp)
    # per-seat
    for i in 0 ..< seatCap:
      if not joined[i] or not hist[i][t].alive: continue
      let fs = dist(int(hist[i][t].x), int(hist[i][t].y), homeX[i], homeY[i])
      inc sCnt[i][b]
      sFs[i][b] += fs
      sFs2[i][b] += fs * fs
      if cb >= 0: inc fsHist[i][cb * HBins + hbin(fs)]
      var nm = 1e9
      for j in 0 ..< seatCap:
        if j == i or not joined[j] or teamOf[j] != teamOf[i]: continue
        if not hist[j][t].alive: continue
        let d = dist(int(hist[i][t].x), int(hist[i][t].y),
                     int(hist[j][t].x), int(hist[j][t].y))
        if d < nm: nm = d
      let hasMate = nm < 1e8
      if hasMate:
        sNm[i][b] += nm
        inc sNmN[i][b]
        if cb >= 0: inc nmHist[i][cb * HBins + hbin(nm)]
      let fl = firstLife(i, t)
      if fl:
        inc fCnt[i][b]
        fFs[i][b] += fs
        if hasMate:
          fNm[i][b] += nm
          inc fNmN[i][b]
        if tp >= OpenLo and tp < OpenHi:
          opX[i] += float(hist[i][t].x); opY[i] += float(hist[i][t].y)
          inc opN[i]
      for z in 0 ..< NTh:
        if cross[i][z] < 0 and fs >= Thresh[z]: cross[i][z] = tp
        if fcross[i][z] < 0 and fl and fs >= Thresh[z]: fcross[i][z] = tp
    # per-team spread
    for tm in 0 ..< NTeam:
      var xs: seq[int]
      var ys: seq[int]
      for i in 0 ..< seatCap:
        if joined[i] and teamOf[i] == tm and hist[i][t].alive:
          xs.add(int(hist[i][t].x)); ys.add(int(hist[i][t].y))
      if xs.len >= 1:
        tLive[tm * NBin + b] += float(xs.len)
        inc tLiveN[tm * NBin + b]
      if xs.len >= 2:
        var sp = 0.0
        var np = 0
        for a in 0 ..< xs.len:
          for c in a + 1 ..< xs.len:
            sp += dist(xs[a], ys[a], xs[c], ys[c]); inc np
        var cx = 0.0
        var cy = 0.0
        for a in 0 ..< xs.len: cx += float(xs[a]); cy += float(ys[a])
        cx /= float(xs.len); cy /= float(xs.len)
        var sr = 0.0
        for a in 0 ..< xs.len:
          sr += sqrt((float(xs[a]) - cx) ^ 2 + (float(ys[a]) - cy) ^ 2)
        inc tCnt[tm * NBin + b]
        tPair[tm * NBin + b] += sp / float(np)
        tRad[tm * NBin + b] += sr / float(xs.len)

  # ---- displacement correlation -------------------------------------------
  var tp = 0
  while tp + DispWin < tCap:
    let t = tp + t0
    let b = tp div BinW
    for i in 0 ..< seatCap:
      if not joined[i]: continue
      if runLen[i][t + DispWin] < int32(DispWin + 1): continue
      let dix = float(hist[i][t + DispWin].x - hist[i][t].x)
      let diy = float(hist[i][t + DispWin].y - hist[i][t].y)
      let mi = sqrt(dix * dix + diy * diy)
      for j in i + 1 ..< seatCap:
        if not joined[j]: continue
        if runLen[j][t + DispWin] < int32(DispWin + 1): continue
        let djx = float(hist[j][t + DispWin].x - hist[j][t].x)
        let djy = float(hist[j][t + DispWin].y - hist[j][t].y)
        let mj = sqrt(djx * djx + djy * djy)
        let same = teamOf[i] == teamOf[j]
        if same:
          inc tPairAlive[teamOf[i] * NBin + b]
        else:
          inc xPairAlive[b]
        if mi < MoveMin or mj < MoveMin: continue
        let cs = (dix * djx + diy * djy) / (mi * mj)
        if same:
          tCos[teamOf[i] * NBin + b] += cs
          inc tCosN[teamOf[i] * NBin + b]
        else:
          xCos[b] += cs
          inc xCosN[b]
    tp += DispStep

  # ---- emit ----------------------------------------------------------------
  var seats = newJArray()
  for i in 0 ..< seatCap:
    if not joined[i]: continue
    var cp = newJArray()
    for c in CPs:
      let ci = c + t0
      if ci < n:
        cp.add(%*[hist[i][ci].x, hist[i][ci].y,
                  (if hist[i][ci].alive: 1 else: 0)])
      else:
        cp.add(%*[0, 0, -1])
    seats.add(%*{
      "i": i, "a": addrOf[i], "t": teamOf[i],
      "hx": homeX[i], "hy": homeY[i],
      "d1": (if firstDeath[i] < 0: -1 else: firstDeath[i] - t0),
      "nd": nDeaths[i],
      "cnt": sCnt[i], "sfs": sFs[i].mapIt(round(it, 1)),
      "sfs2": sFs2[i].mapIt(round(it, 1)),
      "snm": sNm[i].mapIt(round(it, 1)), "nmn": sNmN[i],
      "fcnt": fCnt[i], "ffs": fFs[i].mapIt(round(it, 1)),
      "fnm": fNm[i].mapIt(round(it, 1)), "fnmn": fNmN[i],
      "fshist": fsHist[i], "nmhist": nmHist[i],
      "cross": cross[i], "fcross": fcross[i],
      "opx": (if opN[i] > 0: round(opX[i] / float(opN[i]), 1) else: -1.0),
      "opy": (if opN[i] > 0: round(opY[i] / float(opN[i]), 1) else: -1.0),
      "opn": opN[i],
      "cp": cp
    })

  var teams = newJArray()
  for tm in 0 ..< NTeam:
    var any = false
    for i in 0 ..< seatCap:
      if joined[i] and teamOf[i] == tm: any = true
    if not any: continue
    let lo = tm * NBin
    let hi = lo + NBin
    var anchor = game.gameMap.teamAnchor(Team(tm))
    teams.add(%*{
      "t": tm,
      "ax": anchor.x, "ay": anchor.y,
      "fx": game.flags[Team(tm)].x, "fy": game.flags[Team(tm)].y,
      "cnt": tCnt[lo ..< hi],
      "spair": tPair[lo ..< hi].mapIt(round(it, 1)),
      "srad": tRad[lo ..< hi].mapIt(round(it, 1)),
      "slive": tLive[lo ..< hi].mapIt(round(it, 1)), "nlive": tLiveN[lo ..< hi],
      "dcos": tCos[lo ..< hi].mapIt(round(it, 3)), "dcosn": tCosN[lo ..< hi],
      "dpalive": tPairAlive[lo ..< hi]
    })

  var playTicks = 0
  for p in tickPhase:
    if p: inc playTicks

  result = %*{
    "ep": path.splitFile().name,
    "ticks": n, "play": playTicks, "t0": t0,
    "teams": game.gameMap.teamCount(), "slots": nSeats,
    "finished": game.phase == GameOver,
    "winner": (if game.isDraw: "" else: teamText(game.winner)),
    "draw": game.isDraw, "hashfail": replay.hashValidationFailed,
    "binw": BinW, "nbin": NBin, "cbounds": @CBounds, "hbin": HBinPx,
    "thresh": @Thresh, "dispwin": DispWin, "movemin": MoveMin,
    "xcos": xCos.mapIt(round(it, 3)), "xcosn": xCosN, "xpalive": xPairAlive,
    "seats": seats, "tm": teams
  }

when isMainModule:
  chdirGameDir()
  let args = commandLineParams()
  if args.len == 0:
    echo "Usage: cohesion_trace <replay-path> [...]"
    quit(1)
  for p in args:
    try:
      echo $traceOne(p.absolutePath())
    except CatchableError as e:
      stderr.writeLine("FAIL " & p & ": " & e.msg)

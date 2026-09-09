## relevance_census — per-seat RELEVANCE census from one re-simulated replay.
##
## WHY a new tool instead of tools/stuck_census.nim: that instrument asks
## "was the seat STILL?" (net displacement under a radius over a trailing
## window). A unit pacing a 200 px arc with a period longer than the window
## scores as maximally MOBILE, and a unit sprinting flat-out on the far side
## of the map from every enemy scores as perfectly healthy. Motion was never
## the variable of interest. The variable of interest is RELEVANCE.
##
## Three measures, all per ALIVE tick:
##   1. PATH EFFICIENCY  net displacement / path length over rolling windows
##      at 60/120/240/480 ticks. A committed traverse -> 1.0, pacing -> 0.
##      Split into PACING (low efficiency while genuinely travelling) and
##      PARKED (low efficiency because the path length is ~0) so this can
##      never be confused with the stationarity metric it replaces.
##   2. OUT-OF-CONTEST  no live enemy within R, not closing on one, not near
##      a live objective, not carrying, not escorting a carrier. R is swept.
##      A "strict" variant (enemy range only) is reported alongside so the
##      composite's extra terms can be priced.
##   3. DISTANCE TO THE ACTION  distance to the centroid of the last 120
##      ticks of damage, binned per 100 ticks for a trajectory, plus the
##      nearest-live-enemy distance over ALL alive time (not only stalls).
##
## Traps this defends against:
##   * A DEAD seat's position is frozen: it reads as both stationary AND
##     path-efficiency 0. Every window here requires `alive` on EVERY tick of
##     the window (via a consecutive-alive run length), never just the ends.
##   * The Lobby parks everyone on a pedestal. Only `Playing` ticks count.
##   * Identity is `player.address`, never a seat-parity rule.
##   * The contest radius is not asserted: the tool emits the nearest-enemy
##     distance distribution AT THE TICK DAMAGE LANDS and at the tick of
##     death, so R can be argued from where harm actually happens.
##   * A gate must DISCRIMINATE: every alive tick is labelled with whether
##     the seat is involved in combat within the next 150 ticks, so the
##     out-of-contest label can be scored on its lift, not just its rate.
##
## Output: one JSON object per replay on stdout (JSONL when many are piped).
## Usage: relevance_census <replay-path> [<replay-path>...]

import
  std/[json, math, os, sequtils, strutils],
  ../src/ctf/[sim, sim_types, sim_state],
  toolutil

const
  EffWin = [60, 120, 240, 480]
  EffThr = [0.10, 0.20, 0.35, 0.50]
  ## "travelling" = mean speed over the window >= 0.5 px/tick, ~18% of the
  ## 2.75 px/tick ceiling. Below that the seat is PARKED, not pacing.
  MovePxPerTick = 0.5
  RSweep = [250.0, 300.0, 400.0, 500.0, 600.0, 800.0]
  EscortR = 250.0        ## within this of a live friendly carrier = escorting
  ObjR = 175.0           ## "on/at" a live objective. NOT swept with R: four
                         ## pedestals on a 1235 px board make an 800 px
                         ## objective radius cover the whole map.
  ContactR = 300.0       ## a seat with an enemy this close is IN CONTACT
  CloseWin = 45          ## ticks back for the closing test
  ClosePx = 25.0         ## px of ground closed on the SAME enemy to count
  CentWin = 300          ## trailing damage window for the damage centroid
  SoonWin = 150          ## look-ahead for the discrimination check
  SoonR = 400.0          ## an enemy hurt inside this = we were in that fight
  LocalR = 300.0
  ## time buckets: opening / DECISIVE / rest-of-first-40s / mid / late
  Bounds = [0, 200, 400, 1200, 3000, 1_000_000]
  NB = 5
  DBinPx = 50.0          ## distance histogram bin
  DBins = 32             ## 0..1600 px
  NV = 5                 ## nested out-of-contest definitions V0..V3 + V2kit
  RunBins = [30, 60, 120, 240, 480, 960, 1920, 1_000_000]
  TrajBin = 100
  NTraj = 30             ## 0..3000

type
  Snap = object
    x, y: int
    alive: bool
    hp: int
    carry: bool

proc dist(ax, ay, bx, by: int): float =
  let dx = float(ax - bx)
  let dy = float(ay - by)
  sqrt(dx * dx + dy * dy)

proc bucketOf(t: int): int =
  for k in 0 ..< NB:
    if t >= Bounds[k] and t < Bounds[k + 1]: return k
  NB - 1

proc dbin(d: float): int =
  result = int(d / DBinPx)
  if result < 0: result = 0
  if result >= DBins: result = DBins - 1

proc censusOne(path: string): JsonNode =
  var (game, replay) = openReplay(path, mismatchQuit = false)
  let seatCap = game.config.playerSlotLimit()
  var
    hist: seq[seq[Snap]] = newSeq[seq[Snap]](seatCap)
    tickPhase: seq[bool] = @[]
    teamOf = newSeq[int](seatCap)
    addrOf = newSeq[string](seatCap)
    joined = newSeq[bool](seatCap)
    deathsAt: seq[seq[int]] = newSeq[seq[int]](seatCap)
    prevDeaths = newSeq[int](seatCap)
    prevHp = newSeq[int](seatCap)
    # damage events derived from hp drops on a seat that stayed alive
    dmgT: seq[int] = @[]
    dmgSeat: seq[int] = @[]
    dmgX: seq[int] = @[]
    dmgY: seq[int] = @[]
    flagPts: seq[seq[(int, int)]] = @[]   ## per tick, live (uncaptured) flags

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
        let al = p.alive and playing
        hist[i].add(Snap(x: p.x, y: p.y, alive: al, hp: p.hp,
                         carry: p.carryingFlag))
        if p.deaths > prevDeaths[i]:
          for _ in prevDeaths[i] ..< p.deaths:
            deathsAt[i].add(idx)
          prevDeaths[i] = p.deaths
          if playing:
            dmgT.add(idx); dmgSeat.add(i); dmgX.add(p.x); dmgY.add(p.y)
        elif al and idx > 0 and hist[i][idx - 1].alive and p.hp < prevHp[i]:
          dmgT.add(idx); dmgSeat.add(i); dmgX.add(p.x); dmgY.add(p.y)
        prevHp[i] = p.hp
      else:
        hist[i].add(Snap(x: 0, y: 0, alive: false, hp: 0, carry: false))
    var fp: seq[(int, int)]
    for t in activeTeams(game.gameMap.teamCount()):
      if not game.flags[t].captured:
        fp.add((game.flags[t].x, game.flags[t].y))
    flagPts.add(fp)

  let n = tickPhase.len
  var nSeats = 0
  for i in 0 ..< seatCap:
    if joined[i]: inc nSeats

  var kitPts: seq[(int, int)]
  for k in game.medKitSpawns:
    kitPts.add((k.x, k.y))

  # ---- combat centroid per tick: mean of damage positions in (t-CentWin, t]
  var centX = newSeq[float](n)
  var centY = newSeq[float](n)
  var centN = newSeq[int](n)
  block:
    var lo = 0
    var sx = 0.0
    var sy = 0.0
    var cnt = 0
    var hi = 0
    for t in 0 ..< n:
      while hi < dmgT.len and dmgT[hi] <= t:
        sx += float(dmgX[hi]); sy += float(dmgY[hi]); inc cnt; inc hi
      while lo < hi and dmgT[lo] <= t - CentWin:
        sx -= float(dmgX[lo]); sy -= float(dmgY[lo]); dec cnt; inc lo
      centN[t] = cnt
      if cnt > 0:
        centX[t] = sx / float(cnt); centY[t] = sy / float(cnt)

  # ---- CONTACT centroid per tick: mean position of every live seat that
  # currently has an enemy inside ContactR. Dense (defined almost every tick)
  # where the damage centroid is sparse, and it is what "where the action is"
  # actually means. Computed per (tick, seat) EXCLUDING the seat itself, so a
  # lone seat cannot be its own action.
  # (filled below, after nearest-enemy pass)

  # ---- per-seat per-tick nearest-enemy / nearest-ally -----------------------
  var nEd: seq[seq[float32]] = newSeq[seq[float32]](seatCap)
  var nEi: seq[seq[int16]] = newSeq[seq[int16]](seatCap)
  var nAd: seq[seq[float32]] = newSeq[seq[float32]](seatCap)
  var allyN: seq[seq[int8]] = newSeq[seq[int8]](seatCap)
  var foeN: seq[seq[int8]] = newSeq[seq[int8]](seatCap)
  for i in 0 ..< seatCap:
    nEd[i] = newSeq[float32](n); nEi[i] = newSeq[int16](n)
    nAd[i] = newSeq[float32](n); allyN[i] = newSeq[int8](n); foeN[i] = newSeq[int8](n)
  for t in 0 ..< n:
    for i in 0 ..< seatCap:
      if not joined[i] or not hist[i][t].alive:
        nEd[i][t] = 1e9'f32; nEi[i][t] = -1'i16; nAd[i][t] = 1e9'f32
        continue
      var be = 1e9
      var bi = -1
      var ba = 1e9
      var an = 0
      var fn = 0
      for j in 0 ..< seatCap:
        if j == i or not joined[j] or not hist[j][t].alive: continue
        let d = dist(hist[i][t].x, hist[i][t].y, hist[j][t].x, hist[j][t].y)
        if teamOf[j] == teamOf[i]:
          if d < ba: ba = d
          if d < LocalR: inc an
        else:
          if d < be: be = d; bi = j
          if d < LocalR: inc fn
      nEd[i][t] = float32(be); nEi[i][t] = int16(bi); nAd[i][t] = float32(ba)
      allyN[i][t] = int8(min(an, 120)); foeN[i][t] = int8(min(fn, 120))

  # contact set per tick: seats with a live enemy inside ContactR
  var conSumX = newSeq[float](n)
  var conSumY = newSeq[float](n)
  var conN = newSeq[int](n)
  for t in 0 ..< n:
    for i in 0 ..< seatCap:
      if not joined[i] or not hist[i][t].alive: continue
      if float(nEd[i][t]) < ContactR:
        conSumX[t] += float(hist[i][t].x)
        conSumY[t] += float(hist[i][t].y)
        inc conN[t]

  # ---- combat involvement per seat per tick, then "involved within SoonWin"
  var involved: seq[seq[bool]] = newSeq[seq[bool]](seatCap)
  for i in 0 ..< seatCap: involved[i] = newSeq[bool](n)
  for e in 0 ..< dmgT.len:
    let t = dmgT[e]
    let v = dmgSeat[e]
    involved[v][t] = true
    for i in 0 ..< seatCap:
      if i == v or not joined[i] or not hist[i][t].alive: continue
      if teamOf[i] == teamOf[v]: continue
      if dist(hist[i][t].x, hist[i][t].y, dmgX[e], dmgY[e]) < SoonR:
        involved[i][t] = true
  var soon: seq[seq[bool]] = newSeq[seq[bool]](seatCap)
  for i in 0 ..< seatCap:
    soon[i] = newSeq[bool](n)
    var nextT = -1
    for t in countdown(n - 1, 0):
      if involved[i][t]: nextT = t
      soon[i][t] = nextT >= 0 and nextT > t and nextT - t <= SoonWin
      if involved[i][t]: soon[i][t] = true

  # ---- per-seat measures ----------------------------------------------------
  var seats = newJArray()
  for i in 0 ..< seatCap:
    if not joined[i]: continue
    let h = hist[i]
    var aliveRun = newSeq[int](n)
    var pathPre = newSeq[float](n)
    for t in 0 ..< n:
      aliveRun[t] = (if h[t].alive: (if t > 0: aliveRun[t - 1] else: 0) + 1 else: 0)
      var step = 0.0
      if t > 0 and h[t].alive and h[t - 1].alive:
        step = dist(h[t].x, h[t].y, h[t - 1].x, h[t - 1].y)
      pathPre[t] = (if t > 0: pathPre[t - 1] else: 0.0) + step

    # --- 1. path efficiency ---------------------------------------------
    var effOut = newJObject()
    for w in EffWin:
      var
        nWin = 0
        nMove = 0                        ## travelling windows
        sumEff = 0.0
        sumEffMove = 0.0
        hist20 = newSeq[int](21)
        loMove = newSeq[int](EffThr.len)   ## PACING: eff<thr AND travelling
        loPark = newSeq[int](EffThr.len)   ## PARKED: eff<thr AND not travelling
        bMove = newSeq[int](NB * EffThr.len)
        bPark = newSeq[int](NB * EffThr.len)
        bWin = newSeq[int](NB)
        bMoveWin = newSeq[int](NB)
        bSumEffMove = newSeq[float](NB)
      for t in w ..< n:
        if aliveRun[t] < w + 1: continue
        let pl = pathPre[t] - pathPre[t - w]
        let nd = dist(h[t].x, h[t].y, h[t - w].x, h[t - w].y)
        let k = bucketOf(t)
        inc nWin
        inc bWin[k]
        let travelling = pl >= MovePxPerTick * float(w)
        let eff = (if pl > 1e-6: min(nd / pl, 1.0) else: 0.0)
        sumEff += eff
        if travelling:
          inc nMove
          inc bMoveWin[k]
          sumEffMove += eff
          bSumEffMove[k] += eff
          inc hist20[int(eff * 20.0)]
        for z in 0 ..< EffThr.len:
          if eff < EffThr[z]:
            if travelling:
              inc loMove[z]; inc bMove[k * EffThr.len + z]
            else:
              inc loPark[z]; inc bPark[k * EffThr.len + z]
      effOut[$w] = %*{
        "n": nWin, "nmove": nMove,
        "sumeff": round(sumEff, 2), "sumeffmove": round(sumEffMove, 2),
        "h20": hist20, "pace": loMove, "park": loPark,
        "bn": bWin, "bnmove": bMoveWin,
        "bpace": bMove, "bpark": bPark,
        "bsumeffmove": bSumEffMove.mapIt(round(it, 2))
      }

    # --- 2/3. out-of-contest + distance to action ------------------------
    # Five NESTED definitions, each strictly harder to trip than the last:
    #   V0 strict   : no live enemy within R
    #   V1          : V0 and not CLOSING on that enemy
    #   V2 composite: V1 and not carrying, no live objective within ObjR,
    #                 not within EscortR of a live friendly carrier
    #   V3 generous : V2 and no live ALLY-IN-CONTACT within R (supporting
    #                 nobody) - the hardest bar, most favourable to the seat
    #   V4          : V2 and no med kit within R (a heal detour is relevant)
    var
      bAlive = newSeq[int](NB)
      bV = newSeq[int](NV * NB * RSweep.len)
      bSumNE = newSeq[float](NB)
      bSumNA = newSeq[float](NB)
      bSumCent = newSeq[float](NB)
      bNCent = newSeq[int](NB)
      bSumCon = newSeq[float](NB)
      bNCon = newSeq[int](NB)
      bSumAllyN = newSeq[float](NB)
      bSumFoeN = newSeq[float](NB)
      bContact = newSeq[int](NB)          ## own nearest enemy < ContactR
      bCarry = newSeq[int](NB)
      bClose = newSeq[int](NB)
      neHist = newSeq[int](DBins)
      neHistDmg = newSeq[int](DBins)
      neHistDeath = newSeq[int](DBins)
      centHist = newSeq[int](DBins)
      conHist = newSeq[int](DBins)
      objHist = newSeq[int](DBins)
      trajN = newSeq[int](NTraj)
      trajCent = newSeq[float](NTraj)
      trajCon = newSeq[float](NTraj)
      trajNCon = newSeq[int](NTraj)
      trajNE = newSeq[float](NTraj)
      trajOOC = newSeq[int](NTraj)
      disc = newSeq[int](4)               ## OOC(V3,R=500) x combat-within-150
      runHist = newSeq[int](RunBins.len)
      oocRun = 0
      oocRunsTot = 0
      oocLongest = 0
      oocRunAliveTicks = 0
    let R500 = 3

    proc closeRun(r: var int) =
      if r <= 0: return
      var b = 0
      while b < RunBins.len - 1 and r >= RunBins[b]: inc b
      inc runHist[b]
      inc oocRunsTot
      oocRunAliveTicks += r
      if r > oocLongest: oocLongest = r
      r = 0

    # nearest-enemy distance in the tick BEFORE each death (the death tick
    # itself is already not-alive, so it can never appear in the alive loop)
    for dt in deathsAt[i]:
      let u = dt - 1
      if u >= 0 and h[u].alive and float(nEd[i][u]) < 1e8:
        inc neHistDeath[dbin(float(nEd[i][u]))]

    for t in 0 ..< n:
      if not h[t].alive:
        closeRun(oocRun)
        continue
      let k = bucketOf(t)
      inc bAlive[k]
      let ne = float(nEd[i][t])
      let na = float(nAd[i][t])
      let neOk = ne < 1e8
      let naOk = na < 1e8
      if neOk:
        inc neHist[dbin(ne)]
        bSumNE[k] += ne
        if ne < ContactR: inc bContact[k]
      if naOk: bSumNA[k] += na
      bSumAllyN[k] += float(allyN[i][t])
      bSumFoeN[k] += float(foeN[i][t])
      if h[t].carry: inc bCarry[k]
      var closing = false
      let j = int(nEi[i][t])
      if j >= 0 and t >= CloseWin and h[t - CloseWin].alive and hist[j][t - CloseWin].alive:
        let d0 = dist(h[t - CloseWin].x, h[t - CloseWin].y,
                      hist[j][t - CloseWin].x, hist[j][t - CloseWin].y)
        closing = ne < d0 - ClosePx
      if closing: inc bClose[k]
      var dObj = 1e9
      for (px, py) in flagPts[t]:
        let d = dist(h[t].x, h[t].y, px, py)
        if d < dObj: dObj = d
      if dObj < 1e8: inc objHist[dbin(dObj)]
      var dEsc = 1e9
      var allyContact = 1e9
      for j2 in 0 ..< seatCap:
        if j2 == i or not joined[j2] or teamOf[j2] != teamOf[i]: continue
        if not hist[j2][t].alive: continue
        let d = dist(h[t].x, h[t].y, hist[j2][t].x, hist[j2][t].y)
        if hist[j2][t].carry and d < dEsc: dEsc = d
        if float(nEd[j2][t]) < ContactR and d < allyContact: allyContact = d
      var dKit = 1e9
      for (px, py) in kitPts:
        let d = dist(h[t].x, h[t].y, px, py)
        if d < dKit: dKit = d
      var dCent = -1.0
      if centN[t] > 0:
        dCent = sqrt((float(h[t].x) - centX[t]) ^ 2 + (float(h[t].y) - centY[t]) ^ 2)
        bSumCent[k] += dCent
        inc bNCent[k]
        inc centHist[dbin(dCent)]
      # contact centroid EXCLUDING self
      var dCon = -1.0
      block:
        var cn = conN[t]
        var sx = conSumX[t]
        var sy = conSumY[t]
        if neOk and ne < ContactR:
          dec cn; sx -= float(h[t].x); sy -= float(h[t].y)
        if cn > 0:
          dCon = sqrt((float(h[t].x) - sx / float(cn)) ^ 2 +
                      (float(h[t].y) - sy / float(cn)) ^ 2)
          bSumCon[k] += dCon
          inc bNCon[k]
          inc conHist[dbin(dCon)]
      var ooc500 = false
      for z in 0 ..< RSweep.len:
        let R = RSweep[z]
        let v0 = (not neOk) or ne >= R
        let v1 = v0 and (not closing)
        let v2 = v1 and (not h[t].carry) and (dObj >= ObjR) and (dEsc >= EscortR)
        let v3 = v2 and (allyContact >= R)
        let v4 = v2 and (dKit >= R)
        if v0: inc bV[0 * NB * RSweep.len + k * RSweep.len + z]
        if v1: inc bV[1 * NB * RSweep.len + k * RSweep.len + z]
        if v2: inc bV[2 * NB * RSweep.len + k * RSweep.len + z]
        if v3: inc bV[3 * NB * RSweep.len + k * RSweep.len + z]
        if v4: inc bV[4 * NB * RSweep.len + k * RSweep.len + z]
        if z == R500: ooc500 = v3
      let tb = t div TrajBin
      if tb < NTraj:
        inc trajN[tb]
        if dCent >= 0: trajCent[tb] += dCent
        if dCon >= 0:
          trajCon[tb] += dCon
          inc trajNCon[tb]
        if neOk: trajNE[tb] += ne
        if ooc500: inc trajOOC[tb]
      inc disc[(if ooc500: 2 else: 0) + (if soon[i][t]: 1 else: 0)]
      if involved[i][t] and neOk: inc neHistDmg[dbin(ne)]
      if ooc500: inc oocRun else: closeRun(oocRun)
    closeRun(oocRun)

    seats.add(%*{
      "i": i, "a": addrOf[i], "t": teamOf[i],
      "alive": bAlive, "deaths": deathsAt[i].len, "dtick": deathsAt[i],
      "eff": effOut,
      "v": bV,
      "sumne": bSumNE.mapIt(round(it, 1)),
      "sumna": bSumNA.mapIt(round(it, 1)),
      "sumcent": bSumCent.mapIt(round(it, 1)), "ncent": bNCent,
      "sumcon": bSumCon.mapIt(round(it, 1)), "ncon": bNCon,
      "sumally": bSumAllyN.mapIt(round(it, 1)),
      "sumfoe": bSumFoeN.mapIt(round(it, 1)),
      "contact": bContact, "carry": bCarry, "close": bClose,
      "nehist": neHist, "nehistdmg": neHistDmg, "nehistdeath": neHistDeath,
      "centhist": centHist, "conhist": conHist, "objhist": objHist,
      "trajn": trajN,
      "trajcent": trajCent.mapIt(round(it, 1)),
      "trajcon": trajCon.mapIt(round(it, 1)), "trajncon": trajNCon,
      "trajne": trajNE.mapIt(round(it, 1)),
      "trajooc": trajOOC,
      "disc": disc, "runs": runHist, "nruns": oocRunsTot,
      "runmax": oocLongest, "runticks": oocRunAliveTicks
    })

  var playTicks = 0
  for p in tickPhase:
    if p: inc playTicks

  result = %*{
    "ep": path.splitFile().name,
    "ticks": n, "play": playTicks,
    "teams": game.gameMap.teamCount(), "slots": nSeats,
    "finished": game.phase == GameOver,
    "winner": (if game.isDraw: "" else: teamText(game.winner)),
    "draw": game.isDraw, "hashfail": replay.hashValidationFailed,
    "ndmg": dmgT.len,
    "rsweep": @RSweep, "effwin": @EffWin, "effthr": @EffThr,
    "objr": ObjR, "contactr": ContactR, "runbins": @RunBins, "nv": NV,
    "bounds": @Bounds,
    "seats": seats
  }

when isMainModule:
  chdirGameDir()
  let args = commandLineParams()
  if args.len == 0:
    echo "Usage: relevance_census <replay-path> [...]"
    quit(1)
  for p in args:
    try:
      echo $censusOne(p.absolutePath())
    except CatchableError as e:
      stderr.writeLine("FAIL " & p & ": " & e.msg)

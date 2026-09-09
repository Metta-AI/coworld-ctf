## spray_census — the CARRIED-CAN FUNNEL, measured off re-simulated field replays.
##
## WHY. 50% of our lives that CARRY a spray can never fire it once (field 32%).
## The can is permanent-for-life and rechargeable every 25 ticks, so an unfired
## carry is not a supply problem. The question this tool answers is which stage
## of the policy's own fire funnel eats the opportunity, using GROUND TRUTH from
## the engine rather than the policy's own counters:
##
##   carrying tick
##     -> a live enemy exists at all
##     -> ... with clear LOS
##     -> ... inside the CURRENT fire gate  (ArcBreachFireReach = 128 px)
##     -> ... inside the TRUE cone reach    (PlasmaArcReach     = 170 px)
##     -> ... and a >= 2 CLUSTER (ArcConeMinCluster) around it
##     -> ... and the gun is off cooldown
##     -> ... and our aim is within ArcBreachConeBrads (12) of it
##     -> a spray actually fired
##
## Every count is per CARRY SEGMENT (one life's possession of one can), because
## the headline defect is stated per LIFE, not per frame.
##
## Perception model. The policy fires at TRACKS, not at ground truth: a track is
## usable only while `bot.tick - lastSeen <= FreshShotTicks (24)`. So every
## reach counter is emitted twice — once on raw LOS (an upper bound on
## opportunity) and once on FRESH (seen by this carrier within 24 ticks under
## the engine's own bubble/range/cone model). A finding that only survives on
## the LOS variant is a finding about the fog, not about the trigger.
##
## Traps defended:
##   * Identity is `player.address`; NEVER a seat-parity rule and never the API
##     player_name (which lies on filler seats).
##   * Only `Playing` ticks count.
##   * A carry SEGMENT ends the moment `hasPlasmaArc` goes false — that is
##     death (killPlayer clears it) or nothing else, since firing does not
##     consume the can.
##   * A fire is detected as a RISE in `arcTicksLeft` (startArcFire sets it to
##     PlasmaArcActiveTicks), not from `spray_use.amount`, which is always 0.
##   * `fovBlocked` is re-read every tick (the diamonds rotate).
##
## Output: one JSON object per replay on stdout (JSONL when many are passed).
## Usage: spray_census <replay-path> [<replay-path>...]

import
  std/[json, math, os, strutils],
  ../src/ctf/[sim, sim_types, sim_state],
  toolutil

const
  FireGatePx = 128        ## players/baseline ArcBreachFireReach — what we use now.
  TrueReachPx = 170       ## sim_types PlasmaArcReach = 5 * PlasmaArcSquare.
  ClusterRadiusPx = 136   ## players/baseline PlasmaArcReachPx (the STALE const)
                          ## as used for the peer-cluster radius at L10915.
  MinCluster = 2          ## players/baseline ArcConeMinCluster.
  ConeBrads = 12          ## players/baseline ArcBreachConeBrads.
  ApproachPx = 300        ## players/baseline ArcApproachRadius.
  FreshTicks = 24         ## players/baseline FreshShotTicks.
  WideBrads = 24          ## a RELAXED bearing gate, to price ArcBreachConeBrads.

type
  Seg = object
    seat: int
    address: string
    team: int
    t0: int
    t1: int
    ticks: int
    fires: int              ## sprays actually ignited during this carry.
    sprayDmg: int           ## hp of spray damage dealt during it.
    sprayKills: int
    endedDeath: bool
    readyTicks: int         ## ticks with fireCooldown <= 0 (a press could fire).
    ## --- opportunity, RAW LOS (upper bound) ---
    losAnyTicks: int        ## any live enemy with clear LOS, any range.
    los300Ticks: int        ## ... within ArcApproachRadius.
    los170Ticks: int        ## ... within the TRUE cone reach.
    los128Ticks: int        ## ... within the CURRENT fire gate.
    ## --- opportunity, FRESH TRACK (what the policy can act on) ---
    frAnyTicks: int
    fr300Ticks: int
    fr170Ticks: int
    fr128Ticks: int
    ## --- the gates, on fresh tracks ---
    clu128Ticks: int        ## a fresh enemy inside 128 whose peer-cluster >= 2.
    clu170Ticks: int        ## same at the true reach.
    aim128Ticks: int        ## fresh enemy inside 128, ready, aim err <= 12.
    aim170Ticks: int        ## fresh enemy inside 170, ready, aim err <= 12.
    aimClu128Ticks: int     ## the FULL current gate: cluster >= 2 AND on-bearing AND ready.
    fr128rTicks: int        ## fresh inside 128 AND off cooldown (a press could fire).
    fr170rTicks: int
    aimW128Ticks: int       ## fresh inside 128, ready, aim err <= WideBrads.
    aimW170Ticks: int
    ## --- THE ENGINE-EXACT GATE. A press RIGHT NOW, at the aim we already
    ## hold, resolved through the sim's own selectArcVictims geometry
    ## (forward <= 187, perpendicular <= forward*0.25 + 17, paintPathClear).
    engT: int               ## ready ticks whose cone would hit >=1 FRESH enemy.
    engAnyT: int            ## ... >=1 enemy, fresh or not (upper bound).
    engCleanT: int          ## ... >=1 fresh enemy AND no teammate in the cone.
    engMateT: int           ## ready ticks whose cone would hit a TEAMMATE.
    engEnemySum: int        ## sum of enemies covered over engT ticks.
    firesProd: int          ## fires whose cone covered an enemy AT THE PRESS TICK.
    firesFf: int            ## fires whose cone covered a teammate at the press tick.
    ## A cone is a FIVE-TICK persistent field that rides its owner, so a press
    ## that covers nobody at tick T still pays if a cog walks into it by T+4.
    ## `firesLanded` is the honest yield denominator: presses that dealt at
    ## least one point of spray damage inside their own active window.
    firesLanded: int
    ## ATTRIBUTION. On every ready tick where the ENGINE's cone would damage a
    ## fresh enemy, re-test that same enemy against the POLICY's two hand-tuned
    ## constants, so the funnel names which one closed a shot the weapon had.
    engOursOk: int          ## engine-valid AND passes d<=128 and err<=12.
    engFailReach: int       ## engine-valid, blocked ONLY by ArcBreachFireReach.
    engFailBear: int        ## engine-valid, blocked ONLY by ArcBreachConeBrads.
    engFailBoth: int
    ## COOLDOWN-AWARE REALIZABILITY. A 25-tick recharge means a run of N
    ## consecutive opportunity ticks can yield at most 1 + N div 25 presses,
    ## so raw tick counts OVERSTATE any bound. These count maximal runs and
    ## the presses those runs could actually have carried.
    engRuns: int
    engCap: int
    oursRuns: int
    oursCap: int
    inEngRun: bool
    inOursRun: bool
    engRunLen: int
    oursRunLen: int
    ## FF exposure of the ENGINE gate: opportunity ticks that also put a
    ## teammate in the wedge, split by whether our own constants allowed it.
    engMateOurs: int
    engMateNew: int
    ffDmg: int              ## spray hp this carrier put into its OWN team.
    ffHits: int
    ## --- geometry ---
    minLosD: int            ## closest an LOS enemy ever got. -1 = never any.
    minFrD: int             ## closest a FRESH enemy ever got.
    minAimErr: int          ## smallest aim error to a fresh enemy inside 170.

proc bradsErrAbs(a, b: int): int =
  var d = (a - b + 256) mod 256
  if d > 128: d = 256 - d
  d

proc losClearCells(blocked: openArray[bool], x0, y0, x1, y1: int): bool =
  ## Bresenham over the fog occlusion grid; both ENDPOINT cells exempt (a seat
  ## with its back to a wall sits in a mostly-wall cell).
  var
    cx = x0
    cy = y0
    dx = abs(x1 - x0)
    dy = -abs(y1 - y0)
    sx = if x0 < x1: 1 else: -1
    sy = if y0 < y1: 1 else: -1
    err = dx + dy
  while true:
    if cx == x1 and cy == y1:
      return true
    let e2 = 2 * err
    if e2 >= dy:
      err += dy
      cx += sx
    if e2 <= dx:
      err += dx
      cy += sy
    if cx == x1 and cy == y1:
      return true
    if cx < 0 or cy < 0 or cx >= FovGridW or cy >= FovGridH:
      return false
    if not (cx == x0 and cy == y0):
      if blocked[fovCellIndex(cx, cy)]:
        return false

proc coneCovers(game: SimServer, ax, ay, aimB, bx, by: int): bool =
  ## The sim's OWN victim test (sim.nim selectArcVictims), reproduced exactly:
  ## forward along the locked aim <= PlasmaArcReach + body, perpendicular
  ## inside the linear half-width + body, and the paint path clear of wall.
  let
    (ux, uy) = aimVector(aimB)
    vx = float(bx - ax)
    vy = float(by - ay)
    forward = vx * ux + vy * uy
    perp = abs(vx * uy - vy * ux)
    slope = float(PlasmaArcMaxWidth) / (2.0 * float(PlasmaArcReach))
  if forward <= 0 or forward > float(PlasmaArcReach) + float(PlasmaArcBodyRadius):
    return false
  if perp > forward * slope + float(PlasmaArcBodyRadius):
    return false
  game.paintPathClear(ax, ay, bx, by)

proc runOne(path: string): JsonNode =
  var (game, replay) = openReplay(path.absolutePath(), mismatchQuit = false)
  game.collectEvents = true
  var slotCount = game.config.slots.len
  if slotCount == 0:
    slotCount = game.config.playerSlotLimit()

  var
    segs = newJArray()
    open = newSeq[Seg](slotCount)      ## the live carry segment per seat.
    carrying = newSeq[bool](slotCount)
    prevArc = newSeq[int](slotCount)
    lastSeenAt = newSeq[int](slotCount * slotCount)  ## viewer*n + subject
    addrOf = newSeq[string](slotCount)
    teamOf = newSeq[int](slotCount)
    # per-tick scratch
    seatOf = newSeq[int](slotCount)
    px = newSeq[int](slotCount)
    py = newSeq[int](slotCount)
    pcx = newSeq[int](slotCount)
    pcy = newSeq[int](slotCount)
    palive = newSeq[bool](slotCount)
    pteam = newSeq[int](slotCount)
    paim = newSeq[int](slotCount)
    parc = newSeq[bool](slotCount)
    pcool = newSeq[int](slotCount)
    lastFireTick = newSeq[int](slotCount)
    landedFlag = newSeq[bool](slotCount)
  for i in 0 ..< slotCount * slotCount:
    lastSeenAt[i] = -100_000
  for s in 0 ..< slotCount:
    lastFireTick[s] = -100_000

  proc flush(s: int, tick: int, died: bool) =
    if not carrying[s]:
      return
    carrying[s] = false
    var g = open[s]
    if g.inEngRun: g.engCap += 1 + g.engRunLen div 25
    if g.inOursRun: g.oursCap += 1 + g.oursRunLen div 25
    g.t1 = tick
    g.endedDeath = died
    g.address = addrOf[s]
    g.team = teamOf[s]
    segs.add(%*{
      "seat": g.seat, "addr": g.address, "team": g.team,
      "t0": g.t0, "t1": g.t1, "ticks": g.ticks,
      "fires": g.fires, "spray_dmg": g.sprayDmg, "spray_kills": g.sprayKills,
      "ended_death": g.endedDeath, "ready_ticks": g.readyTicks,
      "los_any": g.losAnyTicks, "los300": g.los300Ticks,
      "los170": g.los170Ticks, "los128": g.los128Ticks,
      "fr_any": g.frAnyTicks, "fr300": g.fr300Ticks,
      "fr170": g.fr170Ticks, "fr128": g.fr128Ticks,
      "clu128": g.clu128Ticks, "clu170": g.clu170Ticks,
      "aim128": g.aim128Ticks, "aim170": g.aim170Ticks,
      "aimclu128": g.aimClu128Ticks,
      "fr128r": g.fr128rTicks, "fr170r": g.fr170rTicks,
      "aimw128": g.aimW128Ticks, "aimw170": g.aimW170Ticks,
      "eng": g.engT, "eng_any": g.engAnyT, "eng_clean": g.engCleanT,
      "eng_mate": g.engMateT, "eng_esum": g.engEnemySum,
      "fires_prod": g.firesProd, "fires_ff": g.firesFf,
      "fires_landed": g.firesLanded, "ff_dmg": g.ffDmg, "ff_hits": g.ffHits,
      "eng_ours_ok": g.engOursOk, "eng_fail_reach": g.engFailReach,
      "eng_fail_bear": g.engFailBear, "eng_fail_both": g.engFailBoth,
      "eng_runs": g.engRuns, "eng_cap": g.engCap,
      "ours_runs": g.oursRuns, "ours_cap": g.oursCap,
      "eng_mate_ours": g.engMateOurs, "eng_mate_new": g.engMateNew,
      "min_los_d": g.minLosD, "min_fr_d": g.minFrD, "min_aim_err": g.minAimErr
    })

  while replay.playing:
    replay.stepReplay(game)
    let tick = game.tickCount

    for s in 0 ..< slotCount:
      seatOf[s] = -1
      palive[s] = false
      parc[s] = false
    for index, player in game.players:
      let s = player.joinOrder
      if s < 0 or s >= slotCount:
        continue
      seatOf[s] = index
      px[s] = player.x + CollisionW div 2
      py[s] = player.y + CollisionH div 2
      let (cx, cy) = fovCellAt(px[s], py[s])
      pcx[s] = cx
      pcy[s] = cy
      palive[s] = player.alive
      pteam[s] = ord(player.team)
      paim[s] = player.aimBrads
      parc[s] = player.hasPlasmaArc
      pcool[s] = player.fireCooldown
      if addrOf[s].len == 0:
        addrOf[s] = player.address
      teamOf[s] = ord(player.team)

    # NOTE the tier-2 drain is deliberately AFTER the segment update below:
    # a cone's FIRST damage lands on the very tick of the press, so crediting
    # it before `lastFireTick` is stamped would lose every same-tick landing.

    if game.phase != Playing:
      for s in 0 ..< slotCount:
        prevArc[s] = (if seatOf[s] >= 0: game.players[seatOf[s]].arcTicksLeft else: 0)
      game.events.setLen(0)
      continue

    let
      blocked = game.fovBlocked
      bubble = float(game.config.visionBubble)
      vrange = float(game.visionRange())
      coneCos = cos(float(game.config.visionConeDeg) * PI / 180.0)
      bubbleSq = bubble * bubble
      rangeSq = vrange * vrange

    # Refresh the per-viewer sighting clock (the track model's `lastSeen`).
    for a in 0 ..< slotCount:
      if not palive[a]:
        continue
      for b in 0 ..< slotCount:
        if a == b or not palive[b] or pteam[a] == pteam[b]:
          continue
        if not losClearCells(blocked, pcx[a], pcy[a], pcx[b], pcy[b]):
          continue
        let
          vx = float(px[b] - px[a])
          vy = float(py[b] - py[a])
          d2 = vx * vx + vy * vy
        var seen = d2 <= bubbleSq
        if not seen and d2 <= rangeSq:
          let (ax, ay) = aimVector(paim[a])
          let d = sqrt(d2)
          if d > 0.0 and (vx * ax + vy * ay) / d >= coneCos:
            seen = true
        if seen:
          lastSeenAt[a * slotCount + b] = tick

    # --- carry segments -------------------------------------------------
    for s in 0 ..< slotCount:
      if seatOf[s] < 0:
        continue
      let arcNow = palive[s] and parc[s]
      if arcNow and not carrying[s]:
        carrying[s] = true
        open[s] = Seg(seat: s, t0: tick, minLosD: -1, minFrD: -1, minAimErr: 999)
      elif carrying[s] and not arcNow:
        flush(s, tick, not palive[s])
      if not carrying[s]:
        prevArc[s] = game.players[seatOf[s]].arcTicksLeft
        continue

      # A fire = a RISE in arcTicksLeft (startArcFire sets it to 5).
      let arcT = game.players[seatOf[s]].arcTicksLeft
      let firedThisTick = arcT > prevArc[s]
      if firedThisTick:
        inc open[s].fires
        lastFireTick[s] = tick
        landedFlag[s] = false
      prevArc[s] = arcT

      inc open[s].ticks
      if pcool[s] <= 0:
        inc open[s].readyTicks

      var
        anyLos = false
        los300 = false
        los170 = false
        los128 = false
        frAny = false
        fr300 = false
        fr170 = false
        fr128 = false
        clu128 = false
        clu170 = false
        aim128 = false
        aim170 = false
        aimClu128 = false
        aimW128 = false
        aimW170 = false
        bestLosD = 1_000_000
        bestFrD = 1_000_000
        bestAimErr = 999
        fr128r = false
        fr170r = false
      let ready = pcool[s] <= 0

      for e in 0 ..< slotCount:
        if e == s or not palive[e] or pteam[e] == pteam[s]:
          continue
        let
          dx = float(px[e] - px[s])
          dy = float(py[e] - py[s])
          d = sqrt(dx * dx + dy * dy)
          di = int(d)
        if not losClearCells(blocked, pcx[s], pcy[s], pcx[e], pcy[e]):
          continue
        anyLos = true
        if di < bestLosD: bestLosD = di
        if d <= float(ApproachPx): los300 = true
        if d <= float(TrueReachPx): los170 = true
        if d <= float(FireGatePx): los128 = true
        # FRESH track?
        if tick - lastSeenAt[s * slotCount + e] > FreshTicks:
          continue
        frAny = true
        if di < bestFrD: bestFrD = di
        if d <= float(ApproachPx): fr300 = true
        let
          inR170 = d <= float(TrueReachPx)
          inR128 = d <= float(FireGatePx)
        if inR170: fr170 = true
        if inR128: fr128 = true
        if not inR170:
          continue
        # peer cluster around THIS enemy, fresh peers only, within the radius
        # the policy actually uses (the stale 136 const).
        var cluster = 1
        for f in 0 ..< slotCount:
          if f == e or f == s or not palive[f] or pteam[f] == pteam[s]:
            continue
          if tick - lastSeenAt[s * slotCount + f] > FreshTicks:
            continue
          let
            ex = float(px[f] - px[e])
            ey = float(py[f] - py[e])
          if sqrt(ex * ex + ey * ey) <= float(ClusterRadiusPx):
            inc cluster
        if cluster >= MinCluster:
          clu170 = true
          if inR128: clu128 = true
        # Bearing error, computed off the ENGINE's own aim vector so no brads
        # sign/zero convention can silently invert it.
        let (avx, avy) = aimVector(paim[s])
        var cosang = 0.0
        if d > 0.0: cosang = clamp((dx * avx + dy * avy) / d, -1.0, 1.0)
        let err = int(arccos(cosang) * 128.0 / PI + 0.5)
        if err < bestAimErr: bestAimErr = err
        if ready:
          if inR128: fr128r = true
          fr170r = true
          if err <= ConeBrads:
            aim170 = true
            if inR128:
              aim128 = true
              if cluster >= MinCluster:
                aimClu128 = true
          if err <= WideBrads:
            aimW170 = true
            if inR128: aimW128 = true

      # --- THE ENGINE-EXACT GATE, evaluated on the aim we already hold ---
      # NOTE the fire tick itself reads fireCooldown = 25 (startArcFire just set
      # it), so `ready` is false there — it must be scanned explicitly or every
      # productive press would be invisible. On that tick the bearing to use is
      # `arcAimBrads`, the aim the engine LOCKED at the press.
      if ready or firedThisTick:
        let coneAim =
          if firedThisTick: game.players[seatOf[s]].arcAimBrads else: paim[s]
        var
          engE = 0
          engEFresh = 0
          engMate = false
          engOurs = false
          engReach = false
          engBear = false
          engBoth = false
        for e in 0 ..< slotCount:
          if e == s or not palive[e]:
            continue
          if not coneCovers(game, px[s], py[s], coneAim, px[e], py[e]):
            continue
          if pteam[e] == pteam[s]:
            engMate = true
          else:
            inc engE
            if tick - lastSeenAt[s * slotCount + e] <= FreshTicks:
              inc engEFresh
              # Would the POLICY's own two constants have let this shot go?
              let
                ddx = float(px[e] - px[s])
                ddy = float(py[e] - py[s])
                dd = sqrt(ddx * ddx + ddy * ddy)
                (uvx, uvy) = aimVector(coneAim)
              var cs = 0.0
              if dd > 0.0: cs = clamp((ddx * uvx + ddy * uvy) / dd, -1.0, 1.0)
              let
                er = int(arccos(cs) * 128.0 / PI + 0.5)
                reachOk = dd <= float(FireGatePx)
                bearOk = er <= ConeBrads
              if reachOk and bearOk: engOurs = true
              elif reachOk and not bearOk: engBear = true
              elif bearOk and not reachOk: engReach = true
              else: engBoth = true
        if ready:
          if engE > 0: inc open[s].engAnyT
          if engEFresh > 0:
            inc open[s].engT
            open[s].engEnemySum += engEFresh
            if not engMate: inc open[s].engCleanT
            # A tick is attributed to the LEAST restrictive verdict any single
            # engine-valid enemy earned on it: if ANY of them cleared both
            # policy constants the tick was ours to take.
            if engOurs: inc open[s].engOursOk
            elif engReach: inc open[s].engFailReach
            elif engBear: inc open[s].engFailBear
            else: inc open[s].engFailBoth
            if engMate:
              if engOurs: inc open[s].engMateOurs
              else: inc open[s].engMateNew
          # maximal-run bookkeeping, one for the ENGINE gate and one for ours
          if engEFresh > 0:
            if not open[s].inEngRun:
              open[s].inEngRun = true
              open[s].engRunLen = 0
              inc open[s].engRuns
            inc open[s].engRunLen
          elif open[s].inEngRun:
            open[s].inEngRun = false
            open[s].engCap += 1 + open[s].engRunLen div 25
          if engEFresh > 0 and engOurs:
            if not open[s].inOursRun:
              open[s].inOursRun = true
              open[s].oursRunLen = 0
              inc open[s].oursRuns
            inc open[s].oursRunLen
          elif open[s].inOursRun:
            open[s].inOursRun = false
            open[s].oursCap += 1 + open[s].oursRunLen div 25
          if engMate: inc open[s].engMateT
        if firedThisTick:
          if engE > 0: inc open[s].firesProd
          if engMate: inc open[s].firesFf

      if anyLos: inc open[s].losAnyTicks
      if los300: inc open[s].los300Ticks
      if los170: inc open[s].los170Ticks
      if los128: inc open[s].los128Ticks
      if frAny: inc open[s].frAnyTicks
      if fr300: inc open[s].fr300Ticks
      if fr170: inc open[s].fr170Ticks
      if fr128: inc open[s].fr128Ticks
      if clu128: inc open[s].clu128Ticks
      if clu170: inc open[s].clu170Ticks
      if aim128: inc open[s].aim128Ticks
      if aim170: inc open[s].aim170Ticks
      if aimClu128: inc open[s].aimClu128Ticks
      if fr128r: inc open[s].fr128rTicks
      if fr170r: inc open[s].fr170rTicks
      if aimW128: inc open[s].aimW128Ticks
      if aimW170: inc open[s].aimW170Ticks
      if bestLosD < 1_000_000 and
          (open[s].minLosD < 0 or bestLosD < open[s].minLosD):
        open[s].minLosD = bestLosD
      if bestFrD < 1_000_000 and
          (open[s].minFrD < 0 or bestFrD < open[s].minFrD):
        open[s].minFrD = bestFrD
      if bestAimErr < open[s].minAimErr:
        open[s].minAimErr = bestAimErr


    # Tier-2 events: spray damage/kills are credited to the live segment.
    for event in game.events:
      case event.kind
      of Damage:
        if event.weapon == "spray" and event.source >= 0 and
            event.source < slotCount and carrying[event.source]:
          let src = event.source
          if event.target >= 0 and event.target < slotCount and
              pteam[event.target] == pteam[src] and event.target != src:
            open[src].ffDmg += event.amount
            inc open[src].ffHits
          else:
            open[src].sprayDmg += event.amount
          if tick - lastFireTick[src] <= PlasmaArcActiveTicks and
              not landedFlag[src]:
            landedFlag[src] = true
            inc open[src].firesLanded
      of Kill:
        if event.weapon == "spray" and event.source >= 0 and
            event.source < slotCount and carrying[event.source]:
          inc open[event.source].sprayKills
      else:
        discard
    game.events.setLen(0)

  for s in 0 ..< slotCount:
    flush(s, game.tickCount, false)

  var seats = newJArray()
  for s in 0 ..< slotCount:
    if addrOf[s].len > 0:
      seats.add(%*{"seat": s, "addr": addrOf[s], "team": teamOf[s]})

  %*{
    "replay": path.extractFilename,
    "ticks": game.tickCount,
    "teams": game.config.teams,
    "slots": slotCount,
    "seats": seats,
    "segs": segs
  }

proc main() =
  if paramCount() < 1:
    quit("usage: spray_census <replay-path> [<replay-path>...]", 1)
  chdirGameDir()
  for i in 1 .. paramCount():
    let p = paramStr(i)
    try:
      echo $runOne(p)
    except CatchableError as e:
      echo $(%*{"replay": p.extractFilename, "error": e.msg})

main()

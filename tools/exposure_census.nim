## exposure_census — per-seat VISIBILITY EXPOSURE census from one re-simulated
## replay.
##
## WHY. Every existing instrument in tools/ asks about POSITION (where was the
## seat, how far did it move, who was near it). None asks about VISIBILITY: how
## many live enemies could actually SEE this seat on this tick. That number is
## the quantity the policy has no representation of, and it is the quantity this
## tool measures, straight off the engine's own occlusion grid.
##
## The engine's sight model, reproduced exactly (sim.nim 2213-2365):
##   * `sim.fovBlocked` is an FovCellSize(8) px occlusion grid; a cell is opaque
##     when at least half its pixels are wall. GLASS WINDOWS are wall in
##     `wallMask` but are NOT opaque here, so sight passes through them and
##     paint does not. Live spinning diamonds re-bake it, so it is read fresh
##     every tick rather than cached.
##   * A viewer sees a cell when the shadowcast reaches it AND (it is inside
##     `visionBubble` px, OR it is inside `visionRange` px = 1.5x gunRange AND
##     inside the `visionConeDeg` half-angle cone about the viewer's aim).
## Shadowcast is replaced here by a symmetric Bresenham walk over the SAME
## fovBlocked grid: 120 seat-pairs per tick instead of 16 full 155x83 casts,
## and symmetry is a property the analysis wants (LOS(a,b) == LOS(b,a)).
##
## Three families of output, all per ALIVE tick:
##   1. EXPOSURE. Per alive tick per seat: how many live ENEMIES hold clear LOS
##      to it (`exp_los`), and how many actually SEE it under the full cone
##      model (`exp_see`). Histogrammed, so the DISTRIBUTION is available and
##      not only the mean.
##   2. SIGHTLINE ECONOMY. Where the seat is actually looking: the free
##      distance along its own aim ray before an opaque cell, and how much of
##      its turning happens while that ray is short. This is the "panning at a
##      wall" quantity.
##   3. THE COWER TEST. Every Damage event opens a row; the row is resolved
##      60 and 120 ticks later against LIVE state: is the victim still inside
##      the damager's LOS, is it still inside the damager's CONE, and how far
##      did the range change. This is the user's "we retreat into the corner
##      the shooter is already looking at" claim, stated as a measurement.
##
## Traps this defends against:
##   * A DEAD seat's position is frozen and its aim is stale. EVERY tick
##     counted here requires `alive`; every cower row requires BOTH the victim
##     and the damager alive at BOTH endpoints of its window, and drops
##     otherwise (recorded as `dropped`, so the denominator is auditable).
##   * Only `Playing` ticks count. The lobby parks everyone on a pedestal with
##     a spawn aim.
##   * Identity is `player.address` (the recorded league join name), never a
##     seat-parity rule. Seats are `joinOrder`; sim player INDICES shift when a
##     player leaves and must never be stored.
##   * `fovBlocked` is re-read every tick: the diamonds rotate and a cached
##     grid would silently freeze the map's occlusion at tick 0.
##   * Endpoint cells are excluded from the block test. A seat standing with
##     its back against a wall sits in a cell that is itself opaque; testing it
##     would report "no LOS" for a seat in the open.
##
## Output: one JSON object per replay on stdout (JSONL when many are passed).
## Usage: exposure_census <replay-path> [<replay-path>...]

import
  std/[json, math, os, strutils],
  ../src/ctf/[sim, sim_types, sim_state],
  toolutil

const
  CowerLagA = 60             ## ticks after a Damage event: ~2 s at 30 Hz.
  CowerLagB = 120            ## ~4 s, one full disengage.
  UnderFireTicks = 60        ## a tick is "under fire" within this of a hit.
  CoverRingPx = 48           ## compass probe radius for the cover ring.
  CoverRingDirs = 8
  ShortSightPx = 250         ## "staring at a wall" threshold.
  MidSightPx = 600
  ExpBins = 13               ## 0..12 enemies, ffa4 seats 12 enemies max.
  NorthStarTick = 1200       ## attrition margin @T=1200 is the scored precursor.
  EarlyWin = 400             ## deconfounded behaviour window, from Playing.
  RingCover = 2              ## "cover is adjacent" = >=2 blocked compass dirs.
  ## Reach for the counterfactual: 2.75 px/tick ceiling x CowerLagA ticks, cut
  ## to 60% for turning, acceleration and walls. Deliberately CONSERVATIVE —
  ## a futility bound must not be inflated by unreachable candidates.
  ReachPx = 100
  ReachStepPx = 12

type
  SeatAgg = object
    seat: int
    address: string
    team: string
    aliveTicks: int
    expLosSum: int
    expSeeSum: int
    expLosHist: array[ExpBins, int]
    expSeeHist: array[ExpBins, int]
    losZeroTicks: int          ## ticks with NO enemy holding LOS.
    seeZeroTicks: int
    aimFreeSum: int            ## sum of free px along own aim ray.
    aimShortTicks: int         ## ticks with aim ray blocked under ShortSightPx.
    aimMidTicks: int
    turnBrads: int             ## total |delta aim| in brads over alive ticks.
    turnShortBrads: int        ## of that, brads turned while the ray was short.
    coverRingSum: int          ## sum over alive ticks of blocked compass dirs.
    nearEnemySum: int
    ufTicks: int               ## alive ticks within UnderFireTicks of a hit.
    ufExpLosSum: int
    ufExpSeeSum: int
    ufCoverRingSum: int
    ufNearEnemySum: int
    ufAimFreeSum: int
    dmgTaken: int
    deaths: int
    kills: int
    ## North-star window (ticks <= NorthStarTick), so exposure can be
    ## regressed on the attrition margin over exactly the window that scores.
    nsAliveTicks: int
    nsExpLosSum: int
    nsExpSeeSum: int
    nsDeaths: int
    nsKills: int
    ## EARLY WINDOW: the first EarlyWin ticks of Playing. Exposure per ALIVE
    ## tick is contaminated by survival — a seat that dies early spends all of
    ## its alive time in fights, so a low exposure RATE can be nothing but a
    ## long quiet life. The early window is the deconfounded version: almost
    ## nobody is dead yet, `earlyAliveTicks` is near-saturated at 4x EarlyWin
    ## per team, and it is measured strictly BEFORE the margin it predicts.
    earlyAliveTicks: int
    earlyExpSee: int
    earlyExpLos: int
    earlyMulti: int
    ## JOINT: hugging geometry is not the same as being out of sight. These
    ## two count alive ticks WITH cover adjacent (ring >= 2), and how many of
    ## those an enemy could still see — the "wrong side of the wall" rate.
    ringTicks: int
    ringSeenTicks: int
    ## ANGLE DISCIPLINE. `multiRuns` counts maximal runs of consecutive alive
    ## ticks with >=2 enemies seeing us; `earlyDeaths` splits the north-star
    ## deaths at the early boundary so the margin can be recomputed over
    ## (EarlyWin, 1200] ONLY — a window strictly AFTER the early exposure that
    ## is supposed to predict it. A contemporaneous correlation cannot tell a
    ## cause from an effect; this split can.
    multiRuns: int
    inMultiRun: bool
    earlyDeaths: int

  CowerRow = object
    tick: int
    attacker: int
    victim: int
    resolveTick: int
    lag: int
    d0: int
    los0: bool
    see0: bool
    cover0: int
    hpAfter: int
    breakAvail0: bool          ## a LOS-breaking spot existed within ReachPx.
    breakDist0: int            ## px to the nearest such spot, -1 if none.

proc bradsDelta(a, b: int): int =
  ## Shortest signed-magnitude turn between two brad headings, 0..128.
  var d = (a - b + 256) mod 256
  if d > 128: d = 256 - d
  d

proc losClearCells(blocked: openArray[bool], x0, y0, x1, y1: int): bool =
  ## Bresenham over the fog occlusion grid. Both ENDPOINT cells are exempt: a
  ## seat with its back to a wall occupies a mostly-wall cell and would
  ## otherwise read as permanently unseeable.
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

proc rayFreePx(blocked: openArray[bool], px, py, brads, capPx: int): int =
  ## Free distance in px from a map point along one aim heading before the
  ## first opaque cell, capped. This is "how far can I actually see the way I
  ## am pointing" — the sightline-economy quantity.
  let (ax, ay) = aimVector(brads)
  var step = FovCellSize
  while step <= capPx:
    let
      qx = px + int(ax * float(step))
      qy = py + int(ay * float(step))
    if qx < 0 or qy < 0 or qx >= MapWidth or qy >= MapHeight:
      return step
    let (cx, cy) = fovCellAt(qx, qy)
    if blocked[fovCellIndex(cx, cy)]:
      return step
    step += FovCellSize
  capPx

proc coverRing(blocked: openArray[bool], px, py: int): int =
  ## How many of 8 compass directions hit an opaque cell within CoverRingPx.
  ## 0 = standing in the open, 8 = boxed in.
  for i in 0 ..< CoverRingDirs:
    let brads = i * (256 div CoverRingDirs)
    if rayFreePx(blocked, px, py, brads, CoverRingPx) < CoverRingPx:
      inc result

proc nearestBreakSpot(
  blocked: openArray[bool], walk: openArray[bool],
  vx, vy, ax, ay: int
): int =
  ## THE COUNTERFACTUAL. Distance in px from the victim at (vx,vy) to the
  ## nearest WALKABLE point within ReachPx that BREAKS line of sight from the
  ## attacker at (ax,ay). -1 when no such point exists inside the reach disc.
  ##
  ## This is what turns "we stayed visible" into a futility bound: a seat that
  ## stayed visible with no LOS-breaking spot within reach did nothing wrong,
  ## and no exposure primitive could have helped it.
  ##
  ## Conservative by construction: a candidate must be walkable, the straight
  ## line to it must be walkable at every 8 px step (so the spot is not on the
  ## far side of a wall the victim would have to path around), and the reach
  ## disc is 60% of the raw movement ceiling.
  let (acx, acy) = fovCellAt(ax, ay)
  result = -1
  var best = ReachPx * ReachPx + 1
  var dy = -ReachPx
  while dy <= ReachPx:
    var dx = -ReachPx
    while dx <= ReachPx:
      let d2 = dx * dx + dy * dy
      if d2 > ReachPx * ReachPx or d2 >= best or d2 == 0:
        dx += ReachStepPx
        continue
      let
        qx = vx + dx
        qy = vy + dy
      if qx < 0 or qy < 0 or qx >= MapWidth or qy >= MapHeight or
          not walk[mapIndex(qx, qy)]:
        dx += ReachStepPx
        continue
      # straight-line walkability from the victim to the candidate
      var
        ok = true
        step = 8
      let dist = sqrt(float(d2))
      while float(step) < dist:
        let
          sx = vx + int(float(dx) * float(step) / dist)
          sy = vy + int(float(dy) * float(step) / dist)
        if sx < 0 or sy < 0 or sx >= MapWidth or sy >= MapHeight or
            not walk[mapIndex(sx, sy)]:
          ok = false
          break
        step += 8
      if not ok:
        dx += ReachStepPx
        continue
      let (qcx, qcy) = fovCellAt(qx, qy)
      if not losClearCells(blocked, acx, acy, qcx, qcy):
        best = d2
        result = int(dist)
      dx += ReachStepPx
    dy += ReachStepPx

proc runOne(path: string): JsonNode =
  var (game, replay) = openReplay(path.absolutePath(), mismatchQuit = false)
  game.collectEvents = true
  var slotCount = game.config.slots.len
  if slotCount == 0:
    slotCount = game.config.playerSlotLimit()
  var
    aggs = newSeq[SeatAgg](slotCount)
    lastAim = newSeq[int](slotCount)
    lastHitTick = newSeq[int](slotCount)
    seatSeen = newSeq[bool](slotCount)
    pending: seq[CowerRow]
    rows = newJArray()
    dropped = 0
    playStart = -1
    teamCount = game.config.teams
  for s in 0 ..< slotCount:
    aggs[s].seat = s
    lastAim[s] = -1
    lastHitTick[s] = -10_000

  # Live per-tick scratch, reallocated never.
  var
    seatOf = newSeq[int](slotCount)
    px = newSeq[int](slotCount)
    py = newSeq[int](slotCount)
    pcx = newSeq[int](slotCount)
    pcy = newSeq[int](slotCount)
    palive = newSeq[bool](slotCount)
    pteam = newSeq[int](slotCount)
    paim = newSeq[int](slotCount)
    losPair = newSeq[bool](slotCount * slotCount)
    seePair = newSeq[bool](slotCount * slotCount)

  while replay.playing:
    replay.stepReplay(game)
    let tick = game.tickCount

    for s in 0 ..< slotCount:
      seatOf[s] = -1
      palive[s] = false
    for index, player in game.players:
      let s = player.joinOrder
      if s < 0 or s >= slotCount:
        continue
      seatOf[s] = index
      seatSeen[s] = true
      px[s] = player.x + CollisionW div 2
      py[s] = player.y + CollisionH div 2
      let (cx, cy) = fovCellAt(px[s], py[s])
      pcx[s] = cx
      pcy[s] = cy
      palive[s] = player.alive
      pteam[s] = ord(player.team)
      paim[s] = player.aimBrads
      if aggs[s].address.len == 0:
        aggs[s].address = player.address
        aggs[s].team = teamText(player.team)
      aggs[s].kills = player.kills
      aggs[s].deaths = player.deaths

    # Drain the tier-2 sink BEFORE using it, every tick, so it never grows.
    var dmgThisTick: seq[(int, int, int)]
    for event in game.events:
      case event.kind
      of Damage:
        if event.source >= 0 and event.target >= 0 and
            event.source < slotCount and event.target < slotCount and
            pteam[event.source] != pteam[event.target]:
          dmgThisTick.add((event.source, event.target, event.hp))
          inc aggs[event.target].dmgTaken
      of Death:
        ## source = victim (sim_types 1420). Counted inside the north-star
        ## window only; the full-episode totals come off the sim counters.
        if event.source >= 0 and event.source < slotCount:
          if tick <= NorthStarTick:
            inc aggs[event.source].nsDeaths
          if playStart >= 0 and tick <= playStart + EarlyWin:
            inc aggs[event.source].earlyDeaths
      of Kill:
        if event.source >= 0 and event.source < slotCount and
            tick <= NorthStarTick:
          inc aggs[event.source].nsKills
      else:
        discard
    game.events.setLen(0)

    if game.phase != Playing:
      for s in 0 ..< slotCount:
        lastAim[s] = paim[s]
      continue
    if playStart < 0:
      playStart = tick

    let
      blocked = game.fovBlocked
      bubble = float(game.config.visionBubble)
      vrange = float(game.visionRange())
      coneCos = cos(float(game.config.visionConeDeg) * PI / 180.0)
      bubbleSq = bubble * bubble
      rangeSq = vrange * vrange

    # --- pairwise LOS / SEE, computed once per unordered pair -------------
    for a in 0 ..< slotCount:
      for b in 0 ..< slotCount:
        losPair[a * slotCount + b] = false
        seePair[a * slotCount + b] = false
    for a in 0 ..< slotCount:
      if not palive[a]:
        continue
      for b in a + 1 ..< slotCount:
        if not palive[b]:
          continue
        if pteam[a] == pteam[b]:
          continue
        let clear = losClearCells(blocked, pcx[a], pcy[a], pcx[b], pcy[b])
        losPair[a * slotCount + b] = clear
        losPair[b * slotCount + a] = clear
        if not clear:
          continue
        let
          vx = float(px[b] - px[a])
          vy = float(py[b] - py[a])
          d2 = vx * vx + vy * vy
          d = sqrt(d2)
        # a sees b
        if d2 <= bubbleSq:
          seePair[a * slotCount + b] = true
        elif d2 <= rangeSq:
          let (ax, ay) = aimVector(paim[a])
          if vx * ax + vy * ay >= coneCos * d:
            seePair[a * slotCount + b] = true
        # b sees a
        if d2 <= bubbleSq:
          seePair[b * slotCount + a] = true
        elif d2 <= rangeSq:
          let (bx, by) = aimVector(paim[b])
          if (-vx) * bx + (-vy) * by >= coneCos * d:
            seePair[b * slotCount + a] = true

    # --- per-seat accumulation -------------------------------------------
    for s in 0 ..< slotCount:
      if not palive[s]:
        lastAim[s] = -1
        continue
      var
        nLos = 0
        nSee = 0
        nearest = 10_000
      for e in 0 ..< slotCount:
        if e == s or not palive[e] or pteam[e] == pteam[s]:
          continue
        let
          dx = float(px[e] - px[s])
          dy = float(py[e] - py[s])
          dist = int(sqrt(dx * dx + dy * dy))
        if dist < nearest:
          nearest = dist
        if losPair[e * slotCount + s]:
          inc nLos
        if seePair[e * slotCount + s]:
          inc nSee
      let
        aimFree = rayFreePx(blocked, px[s], py[s], paim[s], game.visionRange())
        ring = coverRing(blocked, px[s], py[s])
      template a: untyped = aggs[s]
      inc a.aliveTicks
      a.expLosSum += nLos
      a.expSeeSum += nSee
      a.expLosHist[min(nLos, ExpBins - 1)] += 1
      a.expSeeHist[min(nSee, ExpBins - 1)] += 1
      if nLos == 0: inc a.losZeroTicks
      if nSee == 0: inc a.seeZeroTicks
      a.aimFreeSum += aimFree
      if aimFree < ShortSightPx: inc a.aimShortTicks
      if aimFree < MidSightPx: inc a.aimMidTicks
      a.coverRingSum += ring
      if nearest < 10_000:
        a.nearEnemySum += nearest
      if lastAim[s] >= 0:
        let turn = bradsDelta(paim[s], lastAim[s])
        a.turnBrads += turn
        if aimFree < ShortSightPx:
          a.turnShortBrads += turn
      lastAim[s] = paim[s]
      if nSee >= 2:
        if not a.inMultiRun:
          inc a.multiRuns
          a.inMultiRun = true
      else:
        a.inMultiRun = false
      if ring >= RingCover:
        inc a.ringTicks
        if nSee > 0:
          inc a.ringSeenTicks
      if tick <= NorthStarTick:
        inc a.nsAliveTicks
        a.nsExpLosSum += nLos
        a.nsExpSeeSum += nSee
      if playStart >= 0 and tick <= playStart + EarlyWin:
        inc a.earlyAliveTicks
        a.earlyExpSee += nSee
        a.earlyExpLos += nLos
        if nSee >= 2:
          inc a.earlyMulti
      if tick - lastHitTick[s] <= UnderFireTicks:
        inc a.ufTicks
        a.ufExpLosSum += nLos
        a.ufExpSeeSum += nSee
        a.ufCoverRingSum += ring
        a.ufAimFreeSum += aimFree
        if nearest < 10_000:
          a.ufNearEnemySum += nearest

    # --- resolve cower rows whose window closes on THIS tick --------------
    ## Every opened row is REPORTED, with an outcome class. Silently dropping
    ## the rows where the victim died would keep only the disengages that
    ## worked and manufacture a flattering number out of selection on outcome.
    var keep: seq[CowerRow]
    for row in pending:
      if row.resolveTick > tick:
        keep.add(row)
        continue
      var node = %*{
        "t": row.tick, "lag": row.lag, "a": row.attacker, "v": row.victim,
        "d0": row.d0, "los0": row.los0, "see0": row.see0, "cov0": row.cover0,
        "hp": row.hpAfter, "brk0": row.breakAvail0, "brkd0": row.breakDist0
      }
      if not palive[row.victim]:
        node["out"] = %"v_dead"
        inc dropped
      elif not palive[row.attacker]:
        node["out"] = %"a_dead"
        inc dropped
      else:
        let
          dx = float(px[row.victim] - px[row.attacker])
          dy = float(py[row.victim] - py[row.attacker])
          d = int(sqrt(dx * dx + dy * dy))
        node["out"] = %"live"
        node["d1"] = %d
        node["los1"] = %losPair[row.attacker * slotCount + row.victim]
        node["see1"] = %seePair[row.attacker * slotCount + row.victim]
        node["cov1"] = %coverRing(blocked, px[row.victim], py[row.victim])
      rows.add(node)
    pending = keep

    # --- open new cower rows ---------------------------------------------
    for (src, tgt, hpAfter) in dmgThisTick:
      lastHitTick[tgt] = tick
      if not (palive[src] and palive[tgt]):
        continue
      let
        dx = float(px[tgt] - px[src])
        dy = float(py[tgt] - py[src])
        d = int(sqrt(dx * dx + dy * dy))
        brk = nearestBreakSpot(blocked, game.walkMask,
          px[tgt], py[tgt], px[src], py[src])
      for lag in [CowerLagA, CowerLagB]:
        pending.add(CowerRow(
          tick: tick, attacker: src, victim: tgt,
          resolveTick: tick + lag, lag: lag, d0: d,
          los0: losPair[src * slotCount + tgt],
          see0: seePair[src * slotCount + tgt],
          cover0: coverRing(blocked, px[tgt], py[tgt]),
          hpAfter: hpAfter,
          breakAvail0: brk >= 0, breakDist0: brk
        ))
  dropped += pending.len

  var seats = newJArray()
  for s in 0 ..< slotCount:
    if not seatSeen[s]:
      continue
    template a: untyped = aggs[s]
    var lh = newJArray()
    var sh = newJArray()
    for i in 0 ..< ExpBins:
      lh.add(%a.expLosHist[i])
      sh.add(%a.expSeeHist[i])
    seats.add(%*{
      "seat": s, "addr": a.address, "team": a.team,
      "alive_ticks": a.aliveTicks,
      "exp_los_sum": a.expLosSum, "exp_see_sum": a.expSeeSum,
      "exp_los_hist": lh, "exp_see_hist": sh,
      "los0_ticks": a.losZeroTicks, "see0_ticks": a.seeZeroTicks,
      "aim_free_sum": a.aimFreeSum,
      "aim_short_ticks": a.aimShortTicks, "aim_mid_ticks": a.aimMidTicks,
      "turn_brads": a.turnBrads, "turn_short_brads": a.turnShortBrads,
      "cover_ring_sum": a.coverRingSum,
      "near_enemy_sum": a.nearEnemySum,
      "uf_ticks": a.ufTicks, "uf_exp_los_sum": a.ufExpLosSum,
      "uf_exp_see_sum": a.ufExpSeeSum, "uf_cover_ring_sum": a.ufCoverRingSum,
      "uf_near_enemy_sum": a.ufNearEnemySum, "uf_aim_free_sum": a.ufAimFreeSum,
      "dmg_taken": a.dmgTaken, "deaths": a.deaths, "kills": a.kills,
      "ns_alive_ticks": a.nsAliveTicks, "ns_exp_los_sum": a.nsExpLosSum,
      "ns_exp_see_sum": a.nsExpSeeSum, "ns_deaths": a.nsDeaths,
      "ns_kills": a.nsKills,
      "early_alive_ticks": a.earlyAliveTicks, "early_exp_see": a.earlyExpSee,
      "early_exp_los": a.earlyExpLos, "early_multi": a.earlyMulti,
      "ring_ticks": a.ringTicks, "ring_seen_ticks": a.ringSeenTicks,
      "multi_runs": a.multiRuns, "early_deaths": a.earlyDeaths
    })

  result = %*{
    "replay": path.extractFilename().changeFileExt(""),
    "ticks": game.tickCount,
    "teams": teamCount,
    "finished": game.phase == GameOver,
    "winner": (if game.phase == GameOver and not game.isDraw: teamText(game.winner) else: ""),
    "vision_cone_deg": game.config.visionConeDeg,
    "vision_bubble": game.config.visionBubble,
    "vision_range": game.visionRange(),
    "gun_range": game.config.gunRange,
    "play_start": playStart, "early_win": EarlyWin,
    "seats": seats,
    "cower_rows": rows,
    "cower_dropped": dropped
  }

proc main() =
  chdirGameDir()
  for path in commandLineParams():
    try:
      echo $runOne(path)
    except CatchableError as err:
      echo $(%*{"replay": path.extractFilename().changeFileExt(""),
                "error": err.msg})

main()

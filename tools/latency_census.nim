## latency_census — HOW MUCH OF A DECISION'S PREMISE IS STILL TRUE WHEN THE
## CONSEQUENCE RESOLVES.
##
## WHY. Four separate defects this session share one shape: the policy decides
## at tick T and the consequence lands at T+k, and the decision is evaluated
## against T-state. The gun's windup (6 ticks from the observed frame to the
## bullet), the grenade's charge+fuse (13-34), the arc's 5-tick sweep, a comms
## bubble that can be 72 ticks old and is then held for another 90. Each of
## those was argued separately. This tool answers the question ONCE, for every
## horizon at the same time, on GROUND TRUTH, and WITHOUT running the policy —
## so the answer cannot be contaminated by the very estimator under audit.
##
## THE INSTRUMENT. Re-simulate a hosted replay, bank every seat's centre on
## every Playing tick, then for each horizon k report:
##   * mean/median |pos(t+k) - pos(t)| for a body (how far it travels), and
##   * the FOUR-ARM freeze for the shooter/target pair inside an engagement:
##       (a) both frozen at T0        (b) target advanced only
##       (c) self advanced only       (d) both advanced to T0+k
##     scored as the PERPENDICULAR offset of the target from the aim ray, which
##     is the quantity a hitscan gun, a blast disc and a cone all reduce to.
## The gap between (a) and (d) IS the unmodelled latency; (b) vs (c) says which
## body's motion carries it.
##
## Traps defended against:
##   * Only `Playing` ticks; both endpoints must be ALIVE (a dead seat's
##     position is frozen and a respawn TELEPORTS — both would fake motion).
##     A respawn inside the window is excluded by the `lives` guard.
##   * Identity is `player.address` (never the API player_name); seats are
##     `joinOrder` because sim indices shift.
##   * The engagement condition is symmetric ground truth (range + engine LOS),
##     never the policy's own track table.
##   * `sim.events` is never rescanned from 0 (this tool does not read events).
##
## Output: one JSON object per replay on stdout (JSONL when many are passed).
## Usage: latency_census <replay-path> [<replay-path>...]

import
  std/[json, math, os, strutils],
  ../src/ctf/[sim, sim_types, sim_state],
  toolutil

const
  ## Every horizon in the audit's latency table, in ticks.
  ##   1   the universal frame lag (observe end of T, mask applies during T+1)
  ##   5   FireWindupTicks / PlasmaArcActiveTicks
  ##   6   observed-frame -> bullet (1 + 5): the gun's REAL horizon
  ##   10  GrenadeFlightMultiple(2) * FireWindupTicks(5): the fuse
  ##   12  FireCooldownTicks
  ##   17  cooldown + windup: our own next shot
  ##   20  PlasmaArcResetTicks / LocalFreshTicks
  ##   24  FreshShotTicks / GrenadeChargeTicks
  ##   34  a full-charge grenade: 24 charge + 10 fuse
  ##   36  FfMateFreshTicks
  ##   48  LockTtl (the commit lock)
  ##   72  RespawnTicks
  ##   90  CommsPlayTtl
  ##   120 TrackTtl
  ##   162 a 72-tick-old shout held for a further CommsPlayTtl(90)
  Horizons = [1, 5, 6, 10, 12, 17, 20, 24, 34, 36, 48, 72, 90, 120, 162]
  NH = Horizons.len
  MaxTicksCap = 7_400
  EngageRange = 400.0    ## the band where the gun actually lands damage
  PointBlank = 150.0     ## the band that owns 48% of our shots
  GunHalfWidth = 14.0    ## the engine's aim acceptance window, in px at the body
  BlastR = 76.0          ## NadeFfBlastPx: blast radius + body half, diagonal
  ConeHalfBrads = 12.0   ## the arc's bearing gate

type
  Agg = object
    seat: int
    address: string
    team: int
    seen: bool
    aliveTicks: int
    ## --- unconditional body travel over each horizon -------------------
    dispN: array[NH, int]
    dispSum: array[NH, float]
    dispSq: array[NH, float]
    dispOver14: array[NH, int]   ## travelled past the gun's acceptance window
    dispOver76: array[NH, int]   ## travelled out of a blast disc
    ## --- travel while INSIDE an engagement (this seat is the SHOOTER) ---
    engN: array[NH, int]
    ## the four-arm freeze, scored as perpendicular offset from the aim ray
    armAsum, armBsum, armCsum, armDsum: array[NH, float]
    ## ...and as "still inside the envelope" counts
    armAin, armBin, armCin, armDin: array[NH, int]
    ## blast-disc survival: target still within BlastR of the T0 aim point
    blastIn: array[NH, int]
    ## point-blank slice (the band that owns our loss)
    pbN: array[NH, int]
    pbArmAin, pbArmDin: array[NH, int]
    pbArmDsum: array[NH, float]
    ## own-motion share: |self travel| inside an engagement
    selfSum: array[NH, float]
    tgtSum: array[NH, float]

proc perpOffset(sx, sy, ax, ay, tx, ty: float): float =
  ## Perpendicular distance of (tx,ty) from the ray that leaves (sx,sy) on the
  ## bearing of (ax,ay) - (sx,sy). This is the miss a locked heading produces:
  ## the gun traces it, the cone's wedge is a widening version of it, and the
  ## blast disc is its radial twin.
  let
    dx = ax - sx
    dy = ay - sy
    L = sqrt(dx * dx + dy * dy)
  if L < 1e-6: return 0.0
  let
    ux = dx / L
    uy = dy / L
    rx = tx - sx
    ry = ty - sy
    along = rx * ux + ry * uy
  if along <= 0.0: return 1e9         # behind the muzzle: never a hit
  abs(rx * uy - ry * ux)

proc runOne(path: string): JsonNode =
  var (game, replay) = openReplay(path.absolutePath(), mismatchQuit = false)
  var slotCount = game.config.slots.len
  if slotCount == 0:
    slotCount = game.config.playerSlotLimit()

  var
    aggs = newSeq[Agg](slotCount)
    # per-tick banked ground truth, indexed [tick * slotCount + seat]
    bx = newSeq[float](MaxTicksCap * slotCount)
    by = newSeq[float](MaxTicksCap * slotCount)
    bal = newSeq[bool](MaxTicksCap * slotCount)
    blv = newSeq[int16](MaxTicksCap * slotCount)
    bteam = newSeq[int8](slotCount)
    firstTick = -1
    lastTick = -1
  for s in 0 ..< slotCount:
    aggs[s].seat = s
    aggs[s].team = -1
    bteam[s] = -1

  while replay.playing:
    replay.stepReplay(game)
    let tick = game.tickCount
    if game.phase != Playing: continue
    if tick >= MaxTicksCap: break
    if firstTick < 0: firstTick = tick
    lastTick = tick
    for index, player in game.players:
      let s = player.joinOrder
      if s < 0 or s >= slotCount: continue
      let o = tick * slotCount + s
      bx[o] = float(player.x + CollisionW div 2)
      by[o] = float(player.y + CollisionH div 2)
      bal[o] = player.alive
      blv[o] = int16(player.lives)
      if aggs[s].address.len == 0:
        aggs[s].address = player.address
        aggs[s].team = ord(player.team)
        bteam[s] = int8(ord(player.team))
      aggs[s].seen = true
      if player.alive: inc aggs[s].aliveTicks

  if firstTick < 0:
    return newJObject()

  # ---- pass 2: the horizons -------------------------------------------
  for t in firstTick .. lastTick:
    for s in 0 ..< slotCount:
      let o0 = t * slotCount + s
      if not bal[o0]: continue
      for hi, k in Horizons:
        let t1 = t + k
        if t1 > lastTick: continue
        let o1 = t1 * slotCount + s
        # ALIVE at both ends AND the same life: a respawn teleport is not travel.
        if not bal[o1] or blv[o1] != blv[o0]: continue
        let d = hypot(bx[o1] - bx[o0], by[o1] - by[o0])
        inc aggs[s].dispN[hi]
        aggs[s].dispSum[hi] += d
        aggs[s].dispSq[hi] += d * d
        if d > GunHalfWidth: inc aggs[s].dispOver14[hi]
        if d > BlastR: inc aggs[s].dispOver76[hi]

      # ---- the four-arm freeze, this seat as SHOOTER --------------------
      for e in 0 ..< slotCount:
        if e == s or bteam[e] < 0 or bteam[e] == bteam[s]: continue
        let e0 = t * slotCount + e
        if not bal[e0]: continue
        let d0 = hypot(bx[e0] - bx[o0], by[e0] - by[o0])
        if d0 > EngageRange: continue
        if not game.lineOfSightClear(int(bx[o0]), int(by[o0]),
                                     int(bx[e0]), int(by[e0])): continue
        for hi, k in Horizons:
          let t1 = t + k
          if t1 > lastTick: continue
          let
            o1 = t1 * slotCount + s
            e1 = t1 * slotCount + e
          if not bal[o1] or blv[o1] != blv[o0]: continue
          if not bal[e1] or blv[e1] != blv[e0]: continue
          # (a) both frozen at T0 — by construction the offset is 0, so it is
          #     the CONTROL that proves the scorer is not manufacturing error.
          let
            armA = perpOffset(bx[o0], by[o0], bx[e0], by[e0], bx[e0], by[e0])
            # (b) target advanced only: heading locked at T0, muzzle at T0
            armB = perpOffset(bx[o0], by[o0], bx[e0], by[e0], bx[e1], by[e1])
            # (c) self advanced only: the muzzle has moved, the target has not
            armC = perpOffset(bx[o1], by[o1],
                              bx[o1] + (bx[e0] - bx[o0]),
                              by[o1] + (by[e0] - by[o0]), bx[e0], by[e0])
            # (d) both advanced: what the engine actually resolves
            armD = perpOffset(bx[o1], by[o1],
                              bx[o1] + (bx[e0] - bx[o0]),
                              by[o1] + (by[e0] - by[o0]), bx[e1], by[e1])
          inc aggs[s].engN[hi]
          aggs[s].armAsum[hi] += armA
          aggs[s].armBsum[hi] += armB
          aggs[s].armCsum[hi] += armC
          aggs[s].armDsum[hi] += armD
          if armA <= GunHalfWidth: inc aggs[s].armAin[hi]
          if armB <= GunHalfWidth: inc aggs[s].armBin[hi]
          if armC <= GunHalfWidth: inc aggs[s].armCin[hi]
          if armD <= GunHalfWidth: inc aggs[s].armDin[hi]
          # blast disc: is the body still under a burst aimed at its T0 spot?
          if hypot(bx[e1] - bx[e0], by[e1] - by[e0]) <= BlastR:
            inc aggs[s].blastIn[hi]
          aggs[s].selfSum[hi] += hypot(bx[o1] - bx[o0], by[o1] - by[o0])
          aggs[s].tgtSum[hi] += hypot(bx[e1] - bx[e0], by[e1] - by[e0])
          if d0 <= PointBlank:
            inc aggs[s].pbN[hi]
            if armA <= GunHalfWidth: inc aggs[s].pbArmAin[hi]
            if armD <= GunHalfWidth: inc aggs[s].pbArmDin[hi]
            aggs[s].pbArmDsum[hi] += armD

  result = newJObject()
  result["replay"] = %path.extractFilename()
  result["ticks"] = %(lastTick - firstTick + 1)
  block:
    var hz = newJArray()
    for k in Horizons: hz.add(%k)
    result["horizons"] = hz
  var seats = newJArray()
  for s in 0 ..< slotCount:
    if not aggs[s].seen: continue
    var o = newJObject()
    o["seat"] = %s
    o["address"] = %aggs[s].address
    o["team"] = %aggs[s].team
    o["alive"] = %aggs[s].aliveTicks
    template arr(name: string, f: untyped) =
      var a = newJArray()
      for hi in 0 ..< NH: a.add(%f[hi])
      o[name] = a
    arr("dispN", aggs[s].dispN)
    arr("dispSum", aggs[s].dispSum)
    arr("dispSq", aggs[s].dispSq)
    arr("dispOver14", aggs[s].dispOver14)
    arr("dispOver76", aggs[s].dispOver76)
    arr("engN", aggs[s].engN)
    arr("armBsum", aggs[s].armBsum)
    arr("armCsum", aggs[s].armCsum)
    arr("armDsum", aggs[s].armDsum)
    arr("armAin", aggs[s].armAin)
    arr("armBin", aggs[s].armBin)
    arr("armCin", aggs[s].armCin)
    arr("armDin", aggs[s].armDin)
    arr("blastIn", aggs[s].blastIn)
    arr("selfSum", aggs[s].selfSum)
    arr("tgtSum", aggs[s].tgtSum)
    arr("pbN", aggs[s].pbN)
    arr("pbArmAin", aggs[s].pbArmAin)
    arr("pbArmDin", aggs[s].pbArmDin)
    arr("pbArmDsum", aggs[s].pbArmDsum)
    seats.add o
  result["seats"] = seats

when isMainModule:
  chdirGameDir()
  for i in 1 .. paramCount():
    try:
      let j = runOne(paramStr(i))
      if j.len > 0: echo j
    except CatchableError as err:
      stderr.writeLine "FAIL " & paramStr(i) & ": " & err.msg

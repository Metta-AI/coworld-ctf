## `fire_superiority` -- MONET custom controller #2.
##
## Picasso's SEAL lever #9 (press-vs-break): the league is winner-take-all,
## so this play exists to FINISH fights we are winning and survive the ones
## we are losing -- the engine's default stalls at full health and lets the
## zone draw the game, and a draw pays nobody.
##
## Fog-honest superiority estimate, per step:
## - our guns   = self alive, +1 when the duo partner has a fresh live track
##   WITHIN engageDist of self (the duo partner rides its own unconditional
##   grant row -- view.nim partnerTelemetry, landed 9511b240 -- separate
##   from the ordinary same-team-excluded track loop the "their guns" count
##   below still uses; the grant carries pos/aim/downed every tick both
##   seats are alive). The engageDist gate is v-next (stranger-partner
##   audit): since S2 the second seat is a re-drawn stranger every episode
##   (measured forum change, R3746/47), not our own second Monet instance --
##   a fresh-but-distant partner track proves they are alive somewhere on
##   the map, never that they are IN this fight. Presence used to be
##   treated as proof of a second gun unconditionally; it is now held to
##   the exact distance the enemy count already uses, so a partner off
##   fighting their own battle elsewhere no longer flips an actual 1v2 into
##   a false "superior" read. This still cannot tell whether the stranger
##   is even armed (self.hasGun/hasHopper are never exposed to a policy,
##   same gap loot.nim's own header documents) -- proximity is the
##   cheapest honest proxy available given that blind spot, not a fix for
##   it,
## - their guns = fresh enemy tracks within engageDist,
## - wounded    = counted enemies with KNOWN hp <= 2; unknown hp is HEALTHY.
##
## Superior (outnumber, or match numbers with enough of them wounded):
## PRESS -- navigate to a pressRange band off a chosen enemy track, never
## melting into point-blank against a target that can still fight back
## (point-blank accuracy is inverted on this engine). EXCEPTION -- v10,
## measured gap: leaders bank dPointBlankKill 3x our rate, and the accuracy
## inversion is a risk against a live gun, not against one already known
## wounded (hp <= WoundedHpMax) and unlikely to out-trade us even at reduced
## accuracy. When the chosen press target is confirmed wounded, close to
## finishRange instead -- a fixed approximation of the engine's own
## `pointBlankPxFor` band (not exposed to plays, so not exactly reproduced;
## see glory.nim PointBlankPx/scaledByGunRange). Unknown-hp and full-health
## targets keep the wider pressRange band.
##
## PRESS band is now TWO-SIDED for a healthy target (v-next, owner
## range-discipline directive 2026-09-06, measured no-op fix): pressRange
## used to be a ceiling only -- close to it, then HOLD once inside, no
## matter how much closer than that we ended up. Measured median tag
## distance came back at 339px against an 866-900px pressRange, so in
## practice we were essentially always already inside the band and the
## same directive's ceiling raise (500->900) changed nothing on its own. A
## tag inside the band prices as commons class 1 no matter how many land; a
## LONGSHOT tag beyond two-thirds of gun range prices class 3 (4 on enemy
## ground) -- 3-4x the payout for the SAME kill. Below PressBackoffPct (85)
## of the band we now back a healthy target off instead of holding; a
## deadband between PressBackoffPct and the band itself still just holds,
## so a target drifting on the edge of the band cannot flip the decision
## every tick. The finisher's finishRange stays exactly as one-sided as
## before (see the EXCEPTION above) -- a target this close to done is worth
## closing on, never backing off.
##
## Press-target choice among several live enemies (v11, the duo-partner
## grant closing a real safety gap): a wide spray that catches N enemies at
## once mints per-victim, compounding (our biggest single scoring events are
## clustered tags) -- but catching our OWN partner in that same cone is an
## uncapped compounding HALVING of the whole duo's take, and the engine's
## spray gate (`sprayContains`, src/shell/body.nim, ArcFireRangePx=170px
## reach / ArcMaxWidthPx=85px full width at max reach) has no partner
## exclusion of its own. `withinFireCone` below mirrors that exact gate
## (sqrt-free -- see tests/test_shell_body_spray_cone.nim for the pin
## against the real engine proc) to pick, among the enemies we could press
## toward, the one whose stand-and-fire position (a) never also catches our
## partner and, failing a tie, (b) catches the most OTHER enemies. This is a
## preference among targets we are already pressing, not a reason to wait --
## an all-candidates-catch-partner fallback keeps the old
## lowest-hp/nearest choice rather than holding off the fight.
##
## Partner-line exposure (v-next, stranger-partner audit -- the inverse of
## the paragraph above): that check only ever protects the partner from OUR
## spray. A stranger partner can just as easily spray THROUGH us toward
## their own chosen target, and the same uncapped compounding halving lands
## on their fire, not ours. Their actual aim cannot be read -- aimBrads
## only ever rides the wire as an opaque int and this SDK exposes no
## cos/sin table to turn it into a direction, so this cannot be the
## mirror-exact gate `clean` above is. The proxy used instead: treat every
## OTHER visible enemy as a plausible aim target FOR the partner
## (withinFireCone(partnerPos, thatEnemy, ourCandidateStand)) and
## deprioritize -- never forbid, an all-exposed field still has to fight --
## a stand position that falls in any of those lines, once `clean` is
## already tied. Positioning hygiene, not a promise: a stranger aiming at a
## THIRD target we cannot see at all stays unmodelled.
## Inferior by breakDeficit or more:
## BREAK -- facing cover, never navigating through the enemy bearing
## (composes with hold_vs_gun's never-turn-your-back doctrine). Even or no
## contact: hold at cover.

import ../../../play_sdk/play

const
  # pressRange max RAISED 500->900 (owner range-discipline directive,
  # 2026-09-06): LONGSHOT prices past two-thirds of the LIVE map's gun
  # range (src/ctf/glory.nim scaledByGunRange), and the field's gun range
  # has measured as high as ~1300px -- two-thirds of that is ~866px, which
  # 500 could never reach. policy.py's adjust_entries floors pressRange at
  # that same two-thirds figure every episode; this ceiling only has to be
  # able to hold the number it computes. Move together with the
  # `value > 500` bound in readParams below and the transcribed copy in
  # policies/starters/common/plays.py -- three places, one number.
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"press-vs-break: count the guns you can see -- press a winning fight to a range band, break off only when truly outgunned\",\"modes\":[\"br\"],\"name\":\"fire_superiority\",\"params\":{\"breakDeficit\":{\"default\":2,\"integer\":true,\"kind\":\"number\",\"max\":8,\"min\":1},\"coverMax\":{\"default\":260,\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":0},\"engageDist\":{\"default\":600,\"integer\":true,\"kind\":\"number\",\"max\":1200,\"min\":100},\"finishRange\":{\"default\":140,\"integer\":true,\"kind\":\"number\",\"max\":260,\"min\":40},\"pressRange\":{\"default\":220,\"integer\":true,\"kind\":\"number\",\"max\":900,\"min\":60},\"woundedPct\":{\"default\":50,\"integer\":true,\"kind\":\"number\",\"max\":100,\"min\":0}},\"retune\":true}"

  # src/shell/cover_scorer.nim's half-sector slope thresholds (16 sectors).
  SlopeScale = 1_000_000'i64
  Tan1125 = 198_912'i64
  Tan3375 = 668_179'i64
  Tan5625 = 1_496_606'i64
  Tan7875 = 5_027_339'i64

  FreshGunTicks = 60'i32   ## a track older than this is not a live gun
  WoundedHpMax = 2'i32     ## known hp+shield at or below this = wounded

  # Two-sided pressRange hysteresis (owner range-discipline directive,
  # 2026-09-06, measured no-op fix -- see the file header's "PRESS band is
  # now TWO-SIDED" paragraph). Below PressBackoffPct of the band a healthy
  # target is "meaningfully" inside it and gets backed off; between that
  # and the band itself is a deliberate deadband where we just hold.
  # Without a deadband, a target sitting exactly on the band edge would
  # flip the decision every tick (advance past it, retreat back out,
  # repeat) -- that thrash (wasted travel, a broken firing solution) would
  # cost more than the one-sided hold this replaces, which never
  # oscillated because it never moved once inside. 85 leaves a real
  # deadband (15% of pressRange, ~135px at the 900px ceiling) without so
  # much slack that a target can sit deep inside the nominal band
  # uncontested.
  PressBackoffPct = 85'i32

  # src/shell/body.nim: ArcFireRangePx (spray reach) / ArcMaxWidthPx (full
  # cone width AT that reach; width scales linearly with distance from 0 at
  # the muzzle). Pinned against the real engine proc `sprayContains` by
  # tests/test_shell_body_spray_cone.nim -- if the host retunes the cone,
  # that test catches the drift before this file goes stale silently.
  ArcFireRangePx = 170'i64
  ArcMaxWidthPx = 85'i64
  MaxCandidates = 32'i32  ## matches play_sdk MaxViewTracks

type
  DecisionKind = enum
    dkNone
    dkHold
    dkPress
    dkCover
    dkZone

  FsParams = object
    valid: bool
    breakDeficit: int32
    coverMax: int32
    engageDist: int32
    finishRange: int32
    pressRange: int32
    woundedPct: int32

var
  params: FsParams
  selfTeam: SdkTeam
  selfSeat: int32
  partnerSeat: int32
  lastKind: DecisionKind
  lastX, lastY: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc absI64(value: int64): int64 {.inline.} =
  if value < 0: -value else: value

proc minI(a, b: int32): int32 {.inline.} =
  if a < b: a else: b

proc maxI(a, b: int32): int32 {.inline.} =
  if a > b: a else: b

proc clampI(value, lo, hi: int32): int32 {.inline.} =
  if value < lo: lo
  elif value > hi: hi
  else: value

proc sq(value: int32): int64 {.inline.} =
  int64(value) * int64(value)

proc distSq(a, b: SdkPoint): int64 {.inline.} =
  sq(a.x - b.x) + sq(a.y - b.y)

proc withinFireCone(origin, aimAt, other: SdkPoint): bool =
  ## Mirrors the engine's `sprayContains` (src/shell/body.nim) for the case
  ## that matters here: a body standing at `origin` and aiming straight at
  ## `aimAt` (an actual track position, exactly what happens once this play
  ## presses into range and the phase-4 selector commits to that seat).
  ## `other` is caught if it falls in the same forward-widening triangle.
  ## No sqrt (this runtime carries no libm): the shared |aimAt-origin|
  ## factor is cancelled algebraically instead of normalized away --
  ## tests/test_shell_body_spray_cone.nim cross-checks this against the
  ## real `sprayContains` across a grid of points and aim angles.
  let
    dx = int64(aimAt.x - origin.x)
    dy = int64(aimAt.y - origin.y)
    dSq = dx * dx + dy * dy
  if dSq <= 0:
    return false
  let
    vx = int64(other.x - origin.x)
    vy = int64(other.y - origin.y)
    forward = vx * dx + vy * dy
    cross = vx * dy - vy * dx
  if forward <= 0:
    return false
  if forward * forward > ArcFireRangePx * ArcFireRangePx * dSq:
    return false
  2'i64 * ArcFireRangePx * absI64(cross) <= ArcMaxWidthPx * forward

proc quadrantSector(adx, ady: int64): int32 =
  if ady * SlopeScale <= adx * Tan1125: 0
  elif ady * SlopeScale < adx * Tan3375: 1
  elif ady * SlopeScale <= adx * Tan5625: 2
  elif ady * SlopeScale < adx * Tan7875: 3
  else: 4

proc sectorTo(a, b: SdkPoint): int32 =
  ## Same 16-sector classification as the host cover scorer.
  let dx = b.x - a.x
  let dy = b.y - a.y
  let offset = quadrantSector(absI64(int64(dx)), absI64(int64(dy)))
  if dx == 0 and dy == 0: 0
  elif dx >= 0:
    if dy >= 0: offset else: (16 - offset) mod 16
  elif dy >= 0: 8 - offset
  else: 8 + offset

proc sectorGap(a, b: int32): int32 =
  let d = ((a - b) mod 16 + 16) mod 16
  if d > 8: 16 - d else: d

proc projectFrom(origin, toward: SdkPoint; distance: int32): SdkPoint =
  ## `distance` px from `origin` toward `toward`, Manhattan-normalized
  ## (jackal's own helper; exact bearing precision is not load-bearing --
  ## the goal goes through nearestReachable anyway).
  result = origin
  let
    dx = toward.x - origin.x
    dy = toward.y - origin.y
    ax = if dx < 0: -dx else: dx
    ay = if dy < 0: -dy else: dy
  if ax + ay <= 0:
    return
  result.x = origin.x + int32((int64(dx) * int64(distance)) div int64(ax + ay))
  result.y = origin.y + int32((int64(dy) * int64(distance)) div int64(ax + ay))

proc clampToZone(point: SdkPoint; zone: SdkRect): SdkPoint =
  ## Soft zone preference for a computed stand point (used by the PRESS
  ## branch's back-off case below): `nearestReachable` only ever resolves
  ## WALLS, never the storm (same fact `zoneTargets` below already leans
  ## on), so a stand point built purely from the target's bearing can land
  ## outside the current safe rect even while we are retreating FROM a
  ## fight, not into one. Clamp first, same as `zoneTargets` does for the
  ## outside-zone case, and still route the clamped point through
  ## `nearestReachable` afterward rather than trusting a bare clamp alone
  ## -- that combination is exactly what keeps `zoneTargets`'s own clamp
  ## from beelining into a building pocket (owner field report
  ## 2026-09-02), and the same protection applies here. This is a
  ## preference, not the safety net: if we are ever actually caught outside
  ## the zone, `zoneTargets`'s HARD OVERRIDE at the top of play_step (and
  ## the matching "outside the zone you are ESCAPING" lines in
  ## system_prompt.md) still owns getting back in, unchanged by this.
  result = point
  if not zone.present:
    return
  result.x = clampI(point.x, minI(zone.x1, zone.x2), maxI(zone.x1, zone.x2))
  result.y = clampI(point.y, minI(zone.y1, zone.y2), maxI(zone.y1, zone.y2))

proc keyIs(buf: ptr UncheckedArray[byte]; start, length: int32;
           expected: static[string]): bool =
  if length != expected.len.int32:
    return false
  for index in 0 ..< expected.len:
    if char(buf[start + index.int32]) != expected[index]:
      return false
  true

proc readParams(dataPtr, dataLen: int32): FsParams =
  ## Strict reader over the canonical params bytes; missing keys keep the
  ## manifest defaults, anything undeclared or out of range is invalid.
  result = FsParams(valid: true, breakDeficit: 2, coverMax: 260,
    engageDist: 600, finishRange: 140, pressRange: 220, woundedPct: 50)
  if dataLen <= 0:
    return
  let buf = cast[ptr UncheckedArray[byte]](dataPtr)
  var pos = 0'i32
  template cur(): char =
    (if pos < dataLen: char(buf[pos]) else: '\0')
  template fail() =
    result.valid = false
    return
  if cur() != '{': fail()
  inc pos
  if cur() == '}':
    inc pos
    result.valid = pos == dataLen
    return
  while true:
    if cur() != '"': fail()
    inc pos
    let keyStart = pos
    while pos < dataLen and char(buf[pos]) != '"':
      inc pos
    if pos >= dataLen: fail()
    let keyLen = pos - keyStart
    inc pos
    if cur() != ':': fail()
    inc pos
    var value = 0'i32
    var digits = 0
    while cur() in {'0' .. '9'}:
      if digits >= 6: fail()
      value = value * 10 + int32(ord(cur()) - ord('0'))
      inc digits
      inc pos
    if digits == 0: fail()
    if buf.keyIs(keyStart, keyLen, "breakDeficit"):
      result.breakDeficit = value
      if value < 1 or value > 8: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "coverMax"):
      result.coverMax = value
      if value > 600: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "engageDist"):
      result.engageDist = value
      if value < 100 or value > 1200: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "finishRange"):
      result.finishRange = value
      if value < 40 or value > 260: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "pressRange"):
      result.pressRange = value
      if value < 60 or value > 900: result.valid = false  # see ManifestBytes
    elif buf.keyIs(keyStart, keyLen, "woundedPct"):
      result.woundedPct = value
      if value > 100: result.valid = false
    else:
      result.valid = false
    if cur() == ',':
      inc pos
      continue
    break
  if cur() != '}': fail()
  inc pos
  if pos != dataLen: result.valid = false

proc sameDecision(kind: DecisionKind; x = 0'i32; y = 0'i32): bool =
  lastKind == kind and (kind == dkHold or (lastX == x and lastY == y))

proc remember(kind: DecisionKind; x = 0'i32; y = 0'i32) =
  lastKind = kind
  lastX = x
  lastY = y

proc emitHoldIfChanged(): int32 =
  if sameDecision(dkHold):
    resetArena()
    return 0
  let code = emitHoldController("fire_superiority:hold")
  if code < 0:
    return code
  remember(dkHold)
  resetArena()
  0

proc emitGoal(kind: DecisionKind; goal: ValidatedGoal;
              reason: static[string]): int32 =
  if sameDecision(kind, goal.x, goal.y):
    resetArena()
    return 0
  let code = emitNavigateController(goal, "24.0", reason)
  if code < 0:
    return code
  remember(kind, goal.x, goal.y)
  resetArena()
  0

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readParams(dataPtr, dataLen)
  if not decoded.valid:
    return 1
  params = decoded
  if clearCache:
    lastKind = dkNone
    lastX = 0
    lastY = 0
  0

proc loadContext(ctxPtr, ctxLen: int32) =
  var decoded: SdkContext
  selfTeam = stUnknown
  selfSeat = -1
  partnerSeat = -1
  if readBinaryContextInto(context(ctxPtr, ctxLen), decoded):
    if decoded.selfTeamPresent:
      selfTeam = decoded.selfTeam
    if decoded.selfSeatPresent:
      selfSeat = decoded.selfSeat
    if decoded.duoPartnerPresent:
      partnerSeat = decoded.duoPartner

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  resetArena()
  loadContext(ctxPtr, ctxLen)
  loadParams(paramsPtr, paramsLen, true)

const ZoneInsetPx = 64'i32

proc zoneTargets(decoded: SdkView; clamped, biased: var SdkPoint) =
  ## Outside the current safe zone nothing else matters: the re-entry point
  ## is self clamped into the rect (inset), plus a center-biased variant --
  ## both are only ever emitted through nearest_reachable, which resolves to
  ## self's own connectivity component (owner field report 2026-09-02: raw
  ## clamp beelines cornered us in building pockets).
  clamped.present = false
  biased.present = false
  let zone = decoded.world.zone.current
  if not zone.present or not decoded.self.pos.present:
    return
  let
    lox = minI(zone.x1, zone.x2)
    hix = maxI(zone.x1, zone.x2)
    loy = minI(zone.y1, zone.y2)
    hiy = maxI(zone.y1, zone.y2)
  if decoded.self.pos.x >= lox and decoded.self.pos.x <= hix and
      decoded.self.pos.y >= loy and decoded.self.pos.y <= hiy:
    return                        # already inside: no zone move
  let
    ix = minI(ZoneInsetPx, (hix - lox) div 2)
    iy = minI(ZoneInsetPx, (hiy - loy) div 2)
  clamped.present = true
  clamped.x = clampI(decoded.self.pos.x, lox + ix, hix - ix)
  clamped.y = clampI(decoded.self.pos.y, loy + iy, hiy - iy)
  biased.present = true
  biased.x = (clamped.x + (lox + hix) div 2) div 2
  biased.y = (clamped.y + (loy + hiy) div 2) div 2

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: SdkView
  if not readBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1
  if not decoded.self.pos.present or
      (decoded.self.alivePresent and not decoded.self.alive):
    return emitHoldIfChanged()

  # Zone discipline first: no press and no break is worth standing in the
  # storm for -- walk back inside by reachable targets only (center-biased
  # request first, raw clamp second; 2 calls = MaxSpatialCallsPerStep).
  var zClamped, zBiased: SdkPoint
  zoneTargets(decoded, zClamped, zBiased)
  if zClamped.present:
    var goal = nearestReachable(zBiased.x, zBiased.y)
    if not goal.ok:
      goal = nearestReachable(zClamped.x, zClamped.y)
    if goal.ok:
      return emitGoal(dkZone, goal, "fire_superiority:zone")
    return emitHoldIfChanged()

  # Count the guns we can SEE (fog-honest; unknown hp is HEALTHY).
  var theirGuns = 0'i32
  var wounded = 0'i32
  var partnerFresh = false
  var partnerPos: SdkPoint
  var nearestFound = false
  var nearest: SdkPoint
  var nearestDistSq = high(int64)
  var candCount = 0'i32
  var candPos: array[MaxCandidates, SdkPoint]
  var candHp: array[MaxCandidates, int32]
  for index in 0 ..< decoded.trackCount:
    let track = decoded.tracks[index]
    if not track.pos.present:
      continue
    let fresh = not (track.freshTickPresent and decoded.tickPresent and
      decoded.tick - track.freshTick > FreshGunTicks)
    let ally = (track.seatPresent and track.seat == partnerSeat and
        partnerSeat >= 0) or
      (track.teamPresent and selfTeam != stUnknown and track.team == selfTeam)
    if track.seatPresent and track.seat == selfSeat:
      continue
    if ally:
      # v-next: alive somewhere on the map is not "in this fight" -- hold
      # the partner to the same engageDist enemies already clear (see the
      # file header's "our guns" note).
      if fresh and not (track.hpPresent and track.hp <= 0) and
          distSq(decoded.self.pos, track.pos) <= sq(params.engageDist):
        partnerFresh = true
        partnerPos = track.pos
      continue
    if not fresh:
      continue
    let d = distSq(decoded.self.pos, track.pos)
    if d > sq(params.engageDist):
      continue
    inc theirGuns
    let hpKnown = track.hpPresent
    if hpKnown and track.hp <= WoundedHpMax:
      inc wounded
    if not nearestFound or d < nearestDistSq:
      nearestFound = true
      nearest = track.pos
      nearestDistSq = d
    if candCount < MaxCandidates:
      candPos[candCount] = track.pos
      candHp[candCount] = if hpKnown: track.hp else: high(int32)
      inc candCount

  if theirGuns == 0:
    # No live contact: the ladder guard normally keeps us from owning this.
    return emitHoldIfChanged()

  let ourGuns = 1'i32 + (if partnerFresh: 1'i32 else: 0'i32)
  let superior = ourGuns > theirGuns or
    (ourGuns >= theirGuns and wounded * 100 >= params.woundedPct * theirGuns)
  let inferior = theirGuns - ourGuns >= params.breakDeficit

  if superior:
    # Choose which live enemy to press, among candCount options, by the
    # actual fire-cone consequence of standing at that press band and
    # aiming at them: never a candidate that would also catch our partner
    # (uncapped compounding loss) unless every candidate does, then prefer
    # whichever candidate's cone also catches the most OTHER enemies
    # (compounding gain) -- see the file header and withinFireCone above.
    # Ties, and the all-unsafe fallback, keep the original lowest-hp /
    # nearest tie-break so behavior is unchanged whenever there is only one
    # live enemy or no partner/cluster distinction to make.
    var bestIdx = 0'i32
    var bestClean = false
    var bestExposed = true
    var bestCluster = -1'i32
    var bestHp = high(int32)
    var bestDistSq = high(int64)
    for i in 0 ..< candCount:
      let band = if candHp[i] <= WoundedHpMax: params.finishRange
                 else: params.pressRange
      let stand = projectFrom(candPos[i], decoded.self.pos, band)
      var cluster = 0'i32
      for j in 0 ..< candCount:
        if j != i and withinFireCone(stand, candPos[i], candPos[j]):
          inc cluster
      let clean = not (partnerFresh and
        withinFireCone(stand, candPos[i], partnerPos))
      # PARTNER-LINE EXPOSURE (v-next): would this stand point sit in a
      # plausible partner fire line -- the partner aiming at some OTHER
      # visible enemy? See the file header; a proxy, not a read of their
      # actual aim. Ranked below `clean` (protecting the partner from OUR
      # fire still comes first) but above the cluster/hp/distance ties.
      var exposed = false
      if partnerFresh:
        for k in 0 ..< candCount:
          if k != i and withinFireCone(partnerPos, candPos[k], stand):
            exposed = true
            break
      let d = distSq(decoded.self.pos, candPos[i])
      let better =
        if i == 0: true
        elif clean != bestClean: clean
        elif exposed != bestExposed: not exposed
        elif cluster != bestCluster: cluster > bestCluster
        elif candHp[i] != bestHp: candHp[i] < bestHp
        else: d < bestDistSq
      if better:
        bestIdx = i
        bestClean = clean
        bestExposed = exposed
        bestCluster = cluster
        bestHp = candHp[i]
        bestDistSq = d

    # PRESS to the range band. A target we KNOW is wounded (hp <=
    # WoundedHpMax) is worth closing to finishRange for -- the
    # inverted-accuracy risk is against a live gun that can still out-trade
    # us, not one already this close to done -- and that band stays
    # ONE-SIDED: once inside it, hold and finish the work, never back off a
    # target this close to done. Unknown-hp and healthy targets keep the
    # wider pressRange band, but pressRange itself is now TWO-SIDED (see
    # the file header's "PRESS band is now TWO-SIDED" paragraph and
    # PressBackoffPct above): it is a standoff to HOLD, not just a ceiling
    # to approach.
    let target = candPos[bestIdx]
    let targetHp = candHp[bestIdx]
    let targetWounded = targetHp <= WoundedHpMax
    let band = if targetWounded: params.finishRange else: params.pressRange
    if bestDistSq > sq(band):
      # Beyond the band either way: close in. Unchanged from before this
      # fix for both the finisher and the (now two-sided) press band.
      let stand = projectFrom(target, decoded.self.pos, band)
      let goal = nearestReachable(stand.x, stand.y)
      if not goal.ok:
        return emitHoldIfChanged()
      return emitGoal(dkPress, goal, "fire_superiority:press")
    if targetWounded:
      return emitHoldIfChanged()   # finisher: one-sided, close and hold
    # Healthy and already inside pressRange: back off, but only once
    # MEANINGFULLY inside it (below PressBackoffPct of the band) -- the
    # deadband between that and the band itself holds instead, so a target
    # sitting right on the edge doesn't flip us between advancing and
    # retreating every tick (see PressBackoffPct's own comment).
    if bestDistSq >= sq(band * PressBackoffPct div 100):
      return emitHoldIfChanged()
    # projectFrom(target, self, band) already does the right thing
    # unchanged: called with self CLOSER than `band`, it extrapolates PAST
    # self's own current position along the target->self bearing out to
    # `band` px -- i.e. AWAY from the target. The same call that pulls us
    # IN when far now pushes us OUT when near; no separate "opening"
    # formula needed. clampToZone keeps that push from walking us into the
    # storm while we retreat (see its own comment) -- nearestReachable
    # still owns walls, same as every other goal this play emits.
    let stand = clampToZone(projectFrom(target, decoded.self.pos, band),
                             decoded.world.zone.current)
    let goal = nearestReachable(stand.x, stand.y)
    if not goal.ok:
      return emitHoldIfChanged()
    return emitGoal(dkPress, goal, "fire_superiority:backoff")

  if inferior:
    # BREAK to facing cover; never navigate through the enemy bearing.
    if params.coverMax > 0:
      let bearing = sectorTo(decoded.self.pos, nearest) * 16
      let goal = nearestCover(decoded.self.pos.x, decoded.self.pos.y,
        params.coverMax, bearing)
      if goal.ok:
        let goalPoint = SdkPoint(present: true, x: goal.x, y: goal.y)
        if sectorGap(sectorTo(decoded.self.pos, goalPoint),
            sectorTo(decoded.self.pos, nearest)) > 1:
          return emitGoal(dkCover, goal, "fire_superiority:break")
    return emitHoldIfChanged()

  # Even: hold at cover -- no advancing across open toward the enemy.
  if params.coverMax > 0:
    let bearing = sectorTo(decoded.self.pos, nearest) * 16
    let goal = nearestCover(decoded.self.pos.x, decoded.self.pos.y,
      params.coverMax, bearing)
    if goal.ok:
      let goalPoint = SdkPoint(present: true, x: goal.x, y: goal.y)
      let closes = distSq(goalPoint, nearest) < nearestDistSq
      if not (closes and sectorGap(sectorTo(decoded.self.pos, goalPoint),
          sectorTo(decoded.self.pos, nearest)) <= 1):
        return emitGoal(dkCover, goal, "fire_superiority:cover")
  emitHoldIfChanged()

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, true)

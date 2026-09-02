## `fire_superiority` -- MONET custom controller #2.
##
## Picasso's SEAL lever #9 (press-vs-break): the league is winner-take-all,
## so this play exists to FINISH fights we are winning and survive the ones
## we are losing -- the engine's default stalls at full health and lets the
## zone draw the game, and a draw pays nobody.
##
## Fog-honest superiority estimate, per step:
## - our guns   = self alive, +1 when the duo partner has a fresh live track
##   (on today's server same-team tracks are never emitted --
##   src/ctf/server.nim:3545 skips them -- so this degrades to 1 until
##   partner perception lands; that is the ledger's own discipline: count
##   only guns you can SEE),
## - their guns = fresh enemy tracks within engageDist,
## - wounded    = counted enemies with KNOWN hp <= 2; unknown hp is HEALTHY.
##
## Superior (outnumber, or match numbers with enough of them wounded):
## PRESS -- navigate to a pressRange band off the weakest/nearest track,
## never melting into point-blank (point-blank accuracy is inverted on this
## engine). Inferior by breakDeficit or more: BREAK -- facing cover, never
## navigating through the enemy bearing (composes with hold_vs_gun's
## never-turn-your-back doctrine). Even or no contact: hold at cover.

import ../../../play_sdk/play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"press-vs-break: count the guns you can see -- press a winning fight to a range band, break off only when truly outgunned\",\"modes\":[\"br\"],\"name\":\"fire_superiority\",\"params\":{\"breakDeficit\":{\"default\":2,\"integer\":true,\"kind\":\"number\",\"max\":8,\"min\":1},\"coverMax\":{\"default\":260,\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":0},\"engageDist\":{\"default\":600,\"integer\":true,\"kind\":\"number\",\"max\":1200,\"min\":100},\"pressRange\":{\"default\":220,\"integer\":true,\"kind\":\"number\",\"max\":500,\"min\":60},\"woundedPct\":{\"default\":50,\"integer\":true,\"kind\":\"number\",\"max\":100,\"min\":0}},\"retune\":true}"

  # src/shell/cover_scorer.nim's half-sector slope thresholds (16 sectors).
  SlopeScale = 1_000_000'i64
  Tan1125 = 198_912'i64
  Tan3375 = 668_179'i64
  Tan5625 = 1_496_606'i64
  Tan7875 = 5_027_339'i64

  FreshGunTicks = 60'i32   ## a track older than this is not a live gun
  WoundedHpMax = 2'i32     ## known hp+shield at or below this = wounded

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
    engageDist: 600, pressRange: 220, woundedPct: 50)
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
    elif buf.keyIs(keyStart, keyLen, "pressRange"):
      result.pressRange = value
      if value < 60 or value > 500: result.valid = false
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

proc zoneTarget(decoded: SdkView): SdkPoint =
  ## Outside the current safe zone nothing else matters: the re-entry point
  ## is self clamped into the rect inset toward the center (server-version-
  ## independent zone discipline -- guards may not be evaluated for us).
  result.present = false
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
  result.present = true
  result.x = clampI(decoded.self.pos.x, lox + ix, hix - ix)
  result.y = clampI(decoded.self.pos.y, loy + iy, hiy - iy)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: SdkView
  if not readBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1
  if not decoded.self.pos.present or
      (decoded.self.alivePresent and not decoded.self.alive):
    return emitHoldIfChanged()

  # Zone discipline first: no press and no break is worth standing in the
  # storm for -- walk back inside, whatever the count says.
  let reentry = zoneTarget(decoded)
  if reentry.present:
    let goal = nearestReachable(reentry.x, reentry.y)
    if goal.ok:
      return emitGoal(dkZone, goal, "fire_superiority:zone")
    return emitHoldIfChanged()

  # Count the guns we can SEE (fog-honest; unknown hp is HEALTHY).
  var theirGuns = 0'i32
  var wounded = 0'i32
  var partnerFresh = false
  var targetFound = false
  var target: SdkPoint
  var targetHp = high(int32)          # known hp of the chosen press target
  var targetDistSq = high(int64)
  var nearestFound = false
  var nearest: SdkPoint
  var nearestDistSq = high(int64)
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
      if fresh and not (track.hpPresent and track.hp <= 0):
        partnerFresh = true
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
    let hpRank = if hpKnown: track.hp else: high(int32)
    if not targetFound or hpRank < targetHp or
        (hpRank == targetHp and d < targetDistSq):
      targetFound = true
      target = track.pos
      targetHp = hpRank
      targetDistSq = d

  if theirGuns == 0:
    # No live contact: the ladder guard normally keeps us from owning this.
    return emitHoldIfChanged()

  let ourGuns = 1'i32 + (if partnerFresh: 1'i32 else: 0'i32)
  let superior = ourGuns > theirGuns or
    (ourGuns >= theirGuns and wounded * 100 >= params.woundedPct * theirGuns)
  let inferior = theirGuns - ourGuns >= params.breakDeficit

  if superior:
    # PRESS to the range band; inside it the body finishes the work.
    if targetDistSq <= sq(params.pressRange):
      return emitHoldIfChanged()
    let stand = projectFrom(target, decoded.self.pos, params.pressRange)
    let goal = nearestReachable(stand.x, stand.y)
    if not goal.ok:
      return emitHoldIfChanged()
    return emitGoal(dkPress, goal, "fire_superiority:press")

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

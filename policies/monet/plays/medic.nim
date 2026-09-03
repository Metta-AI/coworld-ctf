## `medic` -- MONET custom controller #4: pick your teammate back up.
##
## Revive scout verification (re-verified at this tree, post-merge of
## origin/main 9511b240 "arm downedMode + lootStart, add downed to
## play_view"):
## - revive is PURE PROXIMITY: any upright teammate within DownedTagRange
##   (40 px, sim_types.nim:814) advances the channel one tick; at
##   downedReviveTicks the ghost stands at 1 hp; breaking range resets the
##   channel; bleed-out at downedBleedOutTicks, halving per successive down
##   (sim.nim:6627 updateDowned).
## - the duo partner is a DELIBERATE GRANT row in the play view -- exact
##   pos + downed bit, never fogged, hp deliberately withheld
##   (src/shell/view.nim:1013-1025); the row vanishes when the partner
##   dies, which is this play's abort signal.
## - self's own downed bit rides SdkSelf.downed (a downed self stays
##   alive==true and cannot move; play.nim SdkSelf doc).
##
## Behavior: navigate to the ghost via nearest_reachable, then HOLD inside
## the tag range (revive ticks by distance alone; hysteresis avoids
## range-edge jitter). Return fire stays allowed by design -- no hold_fire
## is forced; the reviver's vulnerability IS the adjacency. Two honest
## guards, both param-driven and mirrored client-side in gate_open:
## - abortHpFloor: at-or-below this hp with a fresh enemy camped near the
##   ghost, do not suicide into the camp (a dead reviver revives nobody
##   and hands the enemy a double).
## - zoneReach: if the ghost lies deeper than this outside the CURRENT
##   safe rect, do not walk into the storm. The exact bleed-out-vs-dps
##   ledger needs zone dps, travel time both ways and the revive channel;
##   a fixed shallow-dip budget is honest where false precision is not.

import ../../../play_sdk/play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"a downed partner is 48 ticks of walking: go stand with them until they stand back up\",\"modes\":[\"br\"],\"name\":\"medic\",\"params\":{\"abortHpFloor\":{\"default\":1,\"integer\":true,\"kind\":\"number\",\"max\":6,\"min\":0},\"zoneReach\":{\"default\":220,\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":0}},\"retune\":true}"

  ReviveRangePx = 40'i32   ## DownedTagRange (sim_types.nim:814)
  StandInPx = 26'i32       ## navigate until this close, then hold
  CampRadiusPx = 200'i32   ## an enemy this near the ghost = camped
  FreshEnemyTicks = 60'i32

type
  DecisionKind = enum
    dkNone
    dkHold
    dkGo

  MedicParams = object
    valid: bool
    abortHpFloor: int32
    zoneReach: int32

var
  params: MedicParams
  partnerSeat: int32
  lastKind: DecisionKind
  lastX, lastY: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc minI(a, b: int32): int32 {.inline.} =
  if a < b: a else: b

proc maxI(a, b: int32): int32 {.inline.} =
  if a > b: a else: b

proc sq(value: int32): int64 {.inline.} =
  int64(value) * int64(value)

proc distSq(a, b: SdkPoint): int64 {.inline.} =
  sq(a.x - b.x) + sq(a.y - b.y)

proc keyIs(buf: ptr UncheckedArray[byte]; start, length: int32;
           expected: static[string]): bool =
  if length != expected.len.int32:
    return false
  for index in 0 ..< expected.len:
    if char(buf[start + index.int32]) != expected[index]:
      return false
  true

proc readParams(dataPtr, dataLen: int32): MedicParams =
  result = MedicParams(valid: true, abortHpFloor: 1, zoneReach: 220)
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
    if buf.keyIs(keyStart, keyLen, "abortHpFloor"):
      result.abortHpFloor = value
      if value > 6: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "zoneReach"):
      result.zoneReach = value
      if value > 600: result.valid = false
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

proc emitHoldIfChanged(reason: static[string]): int32 =
  if sameDecision(dkHold):
    resetArena()
    return 0
  let code = emitHoldController(reason)
  if code < 0:
    return code
  remember(dkHold)
  resetArena()
  0

proc outsideDepth(rect: SdkRect; p: SdkPoint): int32 =
  ## How far outside `rect` the point lies (Chebyshev px; 0 = inside).
  let
    lox = minI(rect.x1, rect.x2)
    hix = maxI(rect.x1, rect.x2)
    loy = minI(rect.y1, rect.y2)
    hiy = maxI(rect.y1, rect.y2)
  var dx = 0'i32
  if p.x < lox: dx = lox - p.x elif p.x > hix: dx = p.x - hix
  var dy = 0'i32
  if p.y < loy: dy = loy - p.y elif p.y > hiy: dy = p.y - hiy
  maxI(dx, dy)

proc ghostCamped(decoded: SdkView; ghost: SdkPoint): bool =
  ## A fresh non-partner track within CampRadiusPx of the ghost.
  for index in 0 ..< decoded.trackCount:
    let track = decoded.tracks[index]
    if not track.pos.present or track.downed:
      continue
    if track.seatPresent and track.seat == partnerSeat:
      continue
    if track.freshTickPresent and decoded.tickPresent and
        decoded.tick - track.freshTick > FreshEnemyTicks:
      continue
    if distSq(ghost, track.pos) <= sq(CampRadiusPx):
      return true
  false

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
  partnerSeat = -1
  if readBinaryContextInto(context(ctxPtr, ctxLen), decoded) and
      decoded.duoPartnerPresent:
    partnerSeat = decoded.duoPartner

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  resetArena()
  loadContext(ctxPtr, ctxLen)
  loadParams(paramsPtr, paramsLen, true)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: SdkView
  if not readBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1
  if not decoded.self.pos.present or decoded.self.downed:
    # A downed self is frozen; nothing to drive.
    return emitHoldIfChanged("medic:idle")

  # The downed partner, off the never-fogged grant row. The row vanishing
  # (death/bleed-out) or the downed bit flipping false (revived) both land
  # here as "no ghost": hold, and the client-side gate takes medic off the
  # ladder on the same facts.
  var ghost: SdkPoint
  var ghostFound = false
  if partnerSeat >= 0:
    for index in 0 ..< decoded.trackCount:
      let track = decoded.tracks[index]
      if track.seatPresent and track.seat == partnerSeat and
          track.downed and track.pos.present:
        ghost = track.pos
        ghostFound = true
        break
  if not ghostFound:
    return emitHoldIfChanged("medic:idle")

  # Suicide guard: at-or-below the hp floor with an enemy camped on the
  # ghost, a dead reviver revives nobody and gifts a double.
  if decoded.self.hpPresent and decoded.self.hp <= params.abortHpFloor and
      decoded.ghostCamped(ghost):
    return emitHoldIfChanged("medic:camped")

  # Zone sanity: a shallow dip outside the current rect is worth a revive;
  # a deep walk into the storm is not (see header for why a fixed budget
  # beats false precision).
  if decoded.world.zone.current.present and
      outsideDepth(decoded.world.zone.current, ghost) > params.zoneReach:
    return emitHoldIfChanged("medic:storm")

  # Inside the tag range: STAND STILL -- revive ticks by distance alone.
  # Hysteresis: navigate until StandInPx, then hold anywhere inside the
  # full ReviveRangePx so a range-edge resolve never flickers the channel.
  let d = distSq(decoded.self.pos, ghost)
  if d <= sq(StandInPx) or (lastKind == dkHold and d <= sq(ReviveRangePx)):
    return emitHoldIfChanged("medic:reviving")

  let goal = nearestReachable(ghost.x, ghost.y)
  if not goal.ok:
    # No same-component path to the ghost (their pocket, not ours): honest
    # hold; the body's own movement cannot cross it either.
    return emitHoldIfChanged("medic:noPath")
  if sameDecision(dkGo, goal.x, goal.y):
    resetArena()
    return 0
  let code = emitNavigateController(goal, "16.0", "medic:pickup")
  if code < 0:
    return code
  remember(dkGo, goal.x, goal.y)
  resetArena()
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, true)

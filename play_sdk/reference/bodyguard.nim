## `bodyguard` reference controller.
##
## Degradations:
## - Ward facts come from ordinary fog tracks plus the context's configured duo
##   partner. The separate live duo-telemetry section is not landed.
## - Stale ward tracks are treated as the last known ward position. If no ward
##   track has ever been seen, the play emits a hold intent rather than roaming.
## - Peel threat detection uses visible enemy tracks near the ward. The
##   `aimedAtUs`/aimed-at-ward query is not landed, so aiming is not inferred.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"ward-relative movement: leash, interpose, and peel attackers from a ward\",\"modes\":[\"br\"],\"name\":\"bodyguard\",\"params\":{\"interpose\":{\"default\":true,\"kind\":\"bool\"},\"leash\":{\"default\":[80,220],\"items\":[{\"integer\":true,\"kind\":\"number\",\"max\":4096,\"min\":0},{\"integer\":true,\"kind\":\"number\",\"max\":4096,\"min\":0}],\"kind\":\"tuple\"},\"peelHp\":{\"default\":2,\"integer\":true,\"kind\":\"number\",\"max\":64,\"min\":0},\"ward\":{\"kind\":\"seat_or_duo_ref\"}},\"retune\":true}"
  WeaponishRangePx = 331'i32

type
  DecisionKind = enum
    dkNone
    dkHold
    dkClose
    dkBackoff
    dkInterpose
    dkPeel

  TrackChoice = object
    found: bool
    track: SdkTrack
    distSq: int64

  RawDecision = object
    kind: DecisionKind
    x, y: int32

var
  params: BodyguardParams
  wardSeat: int32
  wardKnown: bool
  lastWard: SdkPoint
  selfTeam: SdkTeam
  lastKind: DecisionKind
  lastX, lastY: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc sq(value: int32): int64 {.inline.} =
  int64(value) * int64(value)

proc distSq(a, b: SdkPoint): int64 {.inline.} =
  sq(a.x - b.x) + sq(a.y - b.y)

proc trackIsEnemy(track: SdkTrack): bool =
  if not track.teamPresent or selfTeam == stUnknown:
    return true
  track.team != selfTeam

proc findWard(view: BodyguardView): SdkTrack =
  for index in 0 ..< view.trackCount:
    let track = view.tracks[index]
    if track.seatPresent and track.seat == wardSeat and track.pos.present:
      return track

proc nearestThreat(view: BodyguardView; ward: SdkPoint): TrackChoice =
  for index in 0 ..< view.trackCount:
    let track = view.tracks[index]
    if not track.pos.present or not track.trackIsEnemy:
      continue
    let d = ward.distSq(track.pos)
    if not result.found or d < result.distSq:
      result = TrackChoice(found: true, track: track, distSq: d)

proc projectFrom(origin, toward: SdkPoint; distance: int32): SdkPoint =
  result = origin
  let
    dx = toward.x - origin.x
    dy = toward.y - origin.y
    ax = if dx < 0: -dx else: dx
    ay = if dy < 0: -dy else: dy
    scale = distance
  if ax + ay <= 0:
    return
  result.x = origin.x + int32((int64(dx) * int64(scale)) div int64(ax + ay))
  result.y = origin.y + int32((int64(dy) * int64(scale)) div int64(ax + ay))

proc choose(view: BodyguardView): RawDecision =
  if not view.self.pos.present or wardSeat < 0:
    return RawDecision(kind: dkHold)

  let wardTrack = view.findWard()
  var ward = lastWard
  var wardTrackPresent = false
  if wardTrack.pos.present:
    ward = wardTrack.pos
    lastWard = ward
    wardKnown = true
    wardTrackPresent = true
  elif not wardKnown:
    return RawDecision(kind: dkHold)

  let threat = view.nearestThreat(ward)
  if wardTrackPresent and wardTrack.hpPresent and wardTrack.hp < params.peelHp and
      threat.found and threat.distSq <= sq(WeaponishRangePx):
    return RawDecision(kind: dkPeel, x: threat.track.pos.x,
      y: threat.track.pos.y)

  if params.interpose and threat.found:
    let point = ward.projectFrom(threat.track.pos, params.leashMin)
    return RawDecision(kind: dkInterpose, x: point.x, y: point.y)

  let d = view.self.pos.distSq(ward)
  if d > sq(params.leashMax):
    let point = ward.projectFrom(view.self.pos, params.leashMax)
    return RawDecision(kind: dkClose, x: point.x, y: point.y)
  if d < sq(params.leashMin):
    let point = ward.projectFrom(view.self.pos, params.leashMin)
    return RawDecision(kind: dkBackoff, x: point.x, y: point.y)
  RawDecision(kind: dkHold)

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
  let code = emitHoldController("bodyguard:hold")
  if code < 0:
    return code
  remember(dkHold)
  resetArena()
  0

proc resetDecisionCache() =
  lastKind = dkNone
  lastX = 0
  lastY = 0

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readBodyguardParams(context(dataPtr, dataLen))
  if not decoded.valid:
    return 1
  params = decoded
  if decoded.wardPresent:
    wardSeat = decoded.wardSeat
  if clearCache:
    resetDecisionCache()
  0

proc loadContext(ctxPtr, ctxLen: int32) =
  var decoded: SdkContext
  wardSeat = -1
  selfTeam = stUnknown
  if readBinaryContextInto(context(ctxPtr, ctxLen), decoded):
    if decoded.selfTeamPresent:
      selfTeam = decoded.selfTeam
    if decoded.duoPartnerPresent:
      wardSeat = decoded.duoPartner

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  resetArena()
  wardKnown = false
  loadContext(ctxPtr, ctxLen)
  loadParams(paramsPtr, paramsLen, true)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: BodyguardView
  if not readBodyguardBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1

  let raw = choose(decoded)
  if raw.kind == dkHold:
    return emitHoldIfChanged()

  let goal = nearestReachable(raw.x, raw.y)
  if not goal.ok:
    return emitHoldIfChanged()
  if sameDecision(raw.kind, goal.x, goal.y):
    resetArena()
    return 0
  let code =
    case raw.kind
    of dkClose: emitNavigateController(goal, "24.0", "bodyguard:close")
    of dkBackoff: emitNavigateController(goal, "24.0", "bodyguard:backoff")
    of dkInterpose: emitNavigateController(goal, "24.0", "bodyguard:interpose")
    of dkPeel: emitNavigateController(goal, "24.0", "bodyguard:peel")
    else: emitHoldController("bodyguard:hold")
  if code < 0:
    return code
  remember(raw.kind, goal.x, goal.y)
  resetArena()
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, true)

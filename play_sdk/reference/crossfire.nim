## `crossfire` reference controller.
##
## Degradations:
## - Partner facts come from ordinary fog tracks plus the configured duo partner.
##   The separate live duo-telemetry section is not landed.
## - Stale partner tracks are treated as the last known partner position. If no
##   partner track has ever been seen, the play emits a hold intent.
## - Shared-target selection uses the nearest enemy track visible to this seat.
##   The play cannot observe the partner's selected target or order.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"duo spacing and angles so both guns bear without friendly-fire geometry\",\"modes\":[\"br\"],\"name\":\"crossfire\",\"params\":{\"minAngle\":{\"default\":32,\"integer\":true,\"kind\":\"number\",\"max\":128,\"min\":0},\"spacing\":{\"default\":[120,320],\"items\":[{\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":0},{\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":0}],\"kind\":\"tuple\"}},\"retune\":true}"

type
  DecisionKind = enum
    dkNone
    dkHold
    dkClose
    dkBackoff
    dkOpenAngle

  TrackChoice = object
    found: bool
    track: SdkTrack
    distSq: int64

  RawDecision = object
    kind: DecisionKind
    x, y: int32

var
  params: CrossfireParams
  partnerSeat: int32
  partnerKnown: bool
  lastPartner: SdkPoint
  selfTeam: SdkTeam
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

proc trackIsEnemy(track: SdkTrack): bool =
  if not track.teamPresent or selfTeam == stUnknown:
    return true
  track.team != selfTeam

proc findPartner(view: CrossfireView): SdkTrack =
  for index in 0 ..< view.trackCount:
    let track = view.tracks[index]
    if track.seatPresent and track.seat == partnerSeat and track.pos.present:
      return track

proc nearestTarget(view: CrossfireView): TrackChoice =
  for index in 0 ..< view.trackCount:
    let track = view.tracks[index]
    if not track.pos.present or not track.trackIsEnemy:
      continue
    let d = view.self.pos.distSq(track.pos)
    if not result.found or d < result.distSq or
        (d == result.distSq and track.seatPresent and
          track.seat < result.track.seat):
      result = TrackChoice(found: true, track: track, distSq: d)

proc projectFrom(origin, toward: SdkPoint; distance: int32): SdkPoint =
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

proc bearing8Brads(fromPoint, toPoint: SdkPoint): int32 =
  let
    dx = toPoint.x - fromPoint.x
    dy = toPoint.y - fromPoint.y
    ax = if dx < 0: -dx else: dx
    ay = if dy < 0: -dy else: dy
  if ax == 0 and ay == 0:
    return 0
  if ay * 2 <= ax:
    return if dx >= 0: 0'i32 else: 128'i32
  if ax * 2 <= ay:
    return if dy >= 0: 64'i32 else: 192'i32
  if dx >= 0 and dy >= 0:
    32'i32
  elif dx < 0 and dy >= 0:
    96'i32
  elif dx < 0 and dy < 0:
    160'i32
  else:
    224'i32

proc angleDiff(a, b: int32): int32 =
  let raw = if a > b: a - b else: b - a
  if raw > 128: 256 - raw else: raw

proc distanceToEdge(rect: SdkRect; point: SdkPoint): int32 =
  minI(minI(point.x - minI(rect.x1, rect.x2), maxI(rect.x1, rect.x2) - point.x),
    minI(point.y - minI(rect.y1, rect.y2), maxI(rect.y1, rect.y2) - point.y))

proc perpendicularCandidate(self, target: SdkPoint; positive: bool): SdkPoint =
  let
    dx = target.x - self.x
    dy = target.y - self.y
    ax = if dx < 0: -dx else: dx
    ay = if dy < 0: -dy else: dy
    denom = ax + ay
    distance = maxI(params.spacingMin, 24)
  result = self
  if denom <= 0:
    return
  let
    px = if positive: -dy else: dy
    py = if positive: dx else: -dx
  result.x = self.x + int32((int64(px) * int64(distance)) div int64(denom))
  result.y = self.y + int32((int64(py) * int64(distance)) div int64(denom))

proc openAngleTarget(view: CrossfireView; target: SdkTrack): SdkPoint =
  let
    a = perpendicularCandidate(view.self.pos, target.pos, true)
    b = perpendicularCandidate(view.self.pos, target.pos, false)
  if view.zone.current.present:
    let ad = view.zone.current.distanceToEdge(a)
    let bd = view.zone.current.distanceToEdge(b)
    if ad != bd:
      return if ad > bd: a else: b
  if a.y != b.y:
    return if a.y < b.y: a else: b
  if a.x <= b.x: a else: b

proc choose(view: CrossfireView): RawDecision =
  if not view.self.pos.present or partnerSeat < 0:
    return RawDecision(kind: dkHold)

  let partnerTrack = view.findPartner()
  var partner = lastPartner
  if partnerTrack.pos.present:
    partner = partnerTrack.pos
    lastPartner = partner
    partnerKnown = true
  elif not partnerKnown:
    return RawDecision(kind: dkHold)

  let d = view.self.pos.distSq(partner)
  if d > sq(params.spacingMax):
    let point = partner.projectFrom(view.self.pos, params.spacingMax)
    return RawDecision(kind: dkClose, x: point.x, y: point.y)
  if d < sq(params.spacingMin):
    let point = partner.projectFrom(view.self.pos, params.spacingMin)
    return RawDecision(kind: dkBackoff, x: point.x, y: point.y)

  let target = view.nearestTarget()
  if target.found:
    let selfBearing = bearing8Brads(view.self.pos, target.track.pos)
    let partnerBearing = bearing8Brads(partner, target.track.pos)
    if angleDiff(selfBearing, partnerBearing) < params.minAngle:
      let point = view.openAngleTarget(target.track)
      return RawDecision(kind: dkOpenAngle, x: point.x, y: point.y)

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
  let code = emitHoldController("crossfire:hold")
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
  let decoded = readCrossfireParams(context(dataPtr, dataLen))
  if not decoded.valid:
    return 1
  params = decoded
  if clearCache:
    resetDecisionCache()
  0

proc loadContext(ctxPtr, ctxLen: int32) =
  var decoded: SdkContext
  partnerSeat = -1
  selfTeam = stUnknown
  if readBinaryContextInto(context(ctxPtr, ctxLen), decoded):
    if decoded.selfTeamPresent:
      selfTeam = decoded.selfTeam
    if decoded.duoPartnerPresent:
      partnerSeat = decoded.duoPartner

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  resetArena()
  partnerKnown = false
  loadContext(ctxPtr, ctxLen)
  loadParams(paramsPtr, paramsLen, true)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: CrossfireView
  if not readCrossfireBinaryViewInto(view(viewPtr, viewLen), decoded):
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
    of dkClose: emitNavigateController(goal, "24.0", "crossfire:close")
    of dkBackoff: emitNavigateController(goal, "24.0", "crossfire:backoff")
    of dkOpenAngle: emitNavigateController(goal, "24.0", "crossfire:angle")
    else: emitHoldController("crossfire:hold")
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

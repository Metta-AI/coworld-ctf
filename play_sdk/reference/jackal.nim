## `jackal` reference controller.
##
## Degradations:
## - The active-fight clustering query is not landed. A fight is a public
##   kill-feed row inside the landed window plus this seat's own fog track for
##   a navigable enemy location.
## - Public kill-feed rows carry killer team and victim seat only, not killer
##   seat or location. `exitAfter: {kills:n}` therefore counts new rows where
##   our team is the killer while engaged.
## - `bothWeakened` uses only fog-visible tracks with known HP. Unknown HP rows
##   are excluded rather than guessed.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"loiter at earshot of a fight, join when cheap, leave with the profit\",\"modes\":[\"br\"],\"name\":\"jackal\",\"params\":{\"earshot\":{\"default\":500,\"integer\":true,\"kind\":\"number\",\"max\":1200,\"min\":100},\"exitAfter\":{\"arms\":{\"hpFloor\":{\"integer\":true,\"kind\":\"number\",\"max\":3,\"min\":0},\"kills\":{\"integer\":true,\"kind\":\"number\",\"max\":4,\"min\":1}},\"default\":{\"kills\":1},\"kind\":\"union\"},\"joinWhen\":{\"default\":\"afterKill\",\"kind\":\"enum\",\"of\":[\"afterKill\",\"bothWeakened\"]}},\"retune\":true}"
  KillFeedWindowTicks = 240'i32
  RingTolerancePx = 24'i32

type
  DecisionKind = enum
    dkNone
    dkHold
    dkJoin
    dkLoiter
    dkExit

  TrackChoice = object
    found: bool
    track: SdkTrack
    distSq: int64

  RawDecision = object
    kind: DecisionKind
    x, y: int32

var
  params: JackalParams
  selfTeam: SdkTeam
  engaged: bool
  ownKillRows: int32
  lastOwnKillTick: int32
  lastKind: DecisionKind
  lastX, lastY: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

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

proc clampToZone(view: JackalView; point: SdkPoint): SdkPoint =
  result = point
  if view.zone.current.present:
    result.x = clampI(result.x, minI(view.zone.current.x1, view.zone.current.x2),
      maxI(view.zone.current.x1, view.zone.current.x2))
    result.y = clampI(result.y, minI(view.zone.current.y1, view.zone.current.y2),
      maxI(view.zone.current.y1, view.zone.current.y2))

proc loiterTarget(view: JackalView; candidate: SdkTrack): SdkPoint =
  view.clampToZone(candidate.pos.projectFrom(view.self.pos, params.earshot))

proc exitTarget(view: JackalView; candidate: TrackChoice): SdkPoint =
  if candidate.found:
    let away = candidate.track.pos.projectFrom(view.self.pos, params.earshot)
    return view.clampToZone(away)
  if view.zone.current.present:
    return SdkPoint(present: true,
      x: (minI(view.zone.current.x1, view.zone.current.x2) +
        maxI(view.zone.current.x1, view.zone.current.x2)) div 2,
      y: (minI(view.zone.current.y1, view.zone.current.y2) +
        maxI(view.zone.current.y1, view.zone.current.y2)) div 2)
  view.self.pos

proc shouldExit(view: JackalView): bool =
  case params.exitKind
  of jeKills:
    ownKillRows >= params.exitKills
  of jeHpFloor:
    view.self.hpPresent and view.self.hp < params.exitHpFloor

proc choose(view: JackalView): RawDecision =
  if not view.self.pos.present:
    return RawDecision(kind: dkHold)

  if engaged:
    ownKillRows += view.newOwnKillRows
    lastOwnKillTick = maxI(lastOwnKillTick, view.newestOwnKillTick)
  let candidate = TrackChoice(found: view.candidateFound,
    track: view.candidate, distSq: view.candidateDistSq)
  if engaged and shouldExit(view):
    let point = view.exitTarget(candidate)
    return RawDecision(kind: dkExit, x: point.x, y: point.y)

  case params.joinWhen
  of jwAfterKill:
    if not engaged and view.freshKill:
      engaged = candidate.found
      lastOwnKillTick = maxI(lastOwnKillTick, view.newestOwnKillTick)
    if engaged and candidate.found:
      return RawDecision(kind: dkJoin, x: candidate.track.pos.x,
        y: candidate.track.pos.y)
  of jwBothWeakened:
    if candidate.found and view.knownHpCount >= 2 and
        view.knownHpCount == view.weakCount:
      engaged = true
      return RawDecision(kind: dkJoin, x: candidate.track.pos.x,
        y: candidate.track.pos.y)
    if candidate.found:
      let target = view.loiterTarget(candidate.track)
      let d = view.self.pos.distSq(candidate.track.pos)
      if d < sq(params.earshot - RingTolerancePx) or
          d > sq(params.earshot + RingTolerancePx):
        return RawDecision(kind: dkLoiter, x: target.x, y: target.y)

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
  let code = emitHoldController("jackal:hold")
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
  let decoded = readJackalParams(context(dataPtr, dataLen))
  if not decoded.valid:
    return 1
  params = decoded
  if clearCache:
    resetDecisionCache()
  0

proc loadContext(ctxPtr, ctxLen: int32) =
  var decoded: SdkContext
  selfTeam = stUnknown
  if readBinaryContextInto(context(ctxPtr, ctxLen), decoded) and
      decoded.selfTeamPresent:
    selfTeam = decoded.selfTeam

proc resetEngagement() =
  engaged = false
  ownKillRows = 0
  lastOwnKillTick = -1

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  resetArena()
  resetEngagement()
  loadContext(ctxPtr, ctxLen)
  loadParams(paramsPtr, paramsLen, true)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: JackalView
  if not readJackalBinaryViewInto(view(viewPtr, viewLen), decoded, selfTeam,
      params.earshot, lastOwnKillTick, engaged):
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
    of dkJoin: emitNavigateController(goal, "24.0", "jackal:join")
    of dkLoiter: emitNavigateController(goal, "24.0", "jackal:loiter")
    of dkExit: emitNavigateController(goal, "24.0", "jackal:exit")
    else: emitHoldController("jackal:hold")
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

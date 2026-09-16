## `scatter` reference controller: get off the spawn cluster, then yield.
##
## The league seats sixteen cogs in a tight ring, and the body's auto-aim
## makes the opening seconds a knife fight between neighbours: in the first
## competitive rounds a third of the aggressive starter's seats were dead
## inside 150 ticks, and the one entrant near the top of the table was the
## one whose ladder installed its own `spawn_scatter` navigate intents.
##
## For the first `ticks` ticks after this play first steps, it navigates
## `distance` px away from the nearest tracked enemy (the jackal view's
## candidate, within its 500 px earshot); with nobody tracked it heads toward
## the zone centre instead. After that it emits nothing and yields the seat
## to the rungs below. The harness makes it the spawn-phase base rung.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"navigate away from the nearest enemy for the opening ticks, then yield\",\"modes\":[\"br\"],\"name\":\"scatter\",\"params\":{\"distance\":{\"default\":320,\"integer\":true,\"kind\":\"number\",\"max\":1200,\"min\":60},\"ticks\":{\"default\":300,\"integer\":true,\"kind\":\"number\",\"max\":2400,\"min\":24}},\"retune\":true}"

var
  params: ScatterParams
  firstTick: int32 = -1
  lastX, lastY: int32
  lastValid = false

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc minI(a, b: int32): int32 {.inline.} = (if a < b: a else: b)
proc maxI(a, b: int32): int32 {.inline.} = (if a > b: a else: b)
proc clampI(v, lo, hi: int32): int32 {.inline.} = maxI(lo, minI(hi, v))

proc projectFrom(origin, toward: SdkPoint; distance: int32): SdkPoint =
  ## The point `distance` px from `origin` heading AWAY from `toward`.
  let dx = int64(origin.x - toward.x)
  let dy = int64(origin.y - toward.y)
  let lenSq = dx * dx + dy * dy
  if lenSq <= 0:
    return SdkPoint(present: true, x: origin.x + distance, y: origin.y)
  var length = int64(1)
  while length * length < lenSq: inc length
  SdkPoint(present: true,
    x: origin.x + int32(dx * int64(distance) div length),
    y: origin.y + int32(dy * int64(distance) div length))

proc clampToZone(view: JackalView; point: SdkPoint): SdkPoint =
  result = point
  if view.zone.current.present:
    result.x = clampI(result.x, minI(view.zone.current.x1, view.zone.current.x2),
      maxI(view.zone.current.x1, view.zone.current.x2))
    result.y = clampI(result.y, minI(view.zone.current.y1, view.zone.current.y2),
      maxI(view.zone.current.y1, view.zone.current.y2))

proc towardZoneCentre(view: JackalView): SdkPoint =
  if not view.zone.current.present:
    return view.self.pos
  let cx = (minI(view.zone.current.x1, view.zone.current.x2) +
    maxI(view.zone.current.x1, view.zone.current.x2)) div 2
  let cy = (minI(view.zone.current.y1, view.zone.current.y2) +
    maxI(view.zone.current.y1, view.zone.current.y2)) div 2
  # head `distance` px toward the centre (project away from the mirror point)
  let mirror = SdkPoint(present: true, x: 2 * view.self.pos.x - cx,
    y: 2 * view.self.pos.y - cy)
  view.self.pos.projectFrom(mirror, params.distance)

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readScatterParams(context(dataPtr, dataLen))
  if not decoded.valid:
    return 1
  params = decoded
  if clearCache:
    lastValid = false
  0

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard ctxPtr
  discard ctxLen
  resetArena()
  firstTick = -1
  loadParams(paramsPtr, paramsLen, true)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  let rawView = view(viewPtr, viewLen)
  var decoded: JackalView
  if not readJackalBinaryViewInto(rawView, decoded) or not decoded.valid:
    return 1
  if not decoded.tickPresent or not decoded.self.pos.present:
    resetArena()
    return 0
  if firstTick < 0:
    firstTick = decoded.tick
  if decoded.tick - firstTick >= params.ticks:
    # Opening over: emit nothing, yield to the rungs below.
    resetArena()
    return 0
  let target = if decoded.candidateFound:
      decoded.clampToZone(decoded.self.pos.projectFrom(decoded.candidate.pos,
        params.distance))
    else:
      decoded.clampToZone(decoded.towardZoneCentre())
  let goal = nearestReachable(target.x, target.y)
  if not goal.ok:
    resetArena()
    return 0
  if lastValid and goal.x == lastX and goal.y == lastY:
    resetArena()
    return 0
  let code = emitNavigateController(goal, "24.0", "scatter:away")
  if code < 0:
    return code
  lastX = goal.x
  lastY = goal.y
  lastValid = true
  resetArena()
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, true)

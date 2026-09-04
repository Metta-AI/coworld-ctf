## `edge_ride` reference controller.
##
## BR-only movement play: ride the safe-zone margin early, enter the announced
## next rectangle before the shrink, and optionally divert a selected margin
## goal to nearby cover. It uses at most one nearest_reachable and one
## nearest_cover host query per step.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"ride safe-zone edges early and bias toward nearby cover\",\"modes\":[\"br\"],\"name\":\"edge_ride\",\"params\":{\"coverBias\":{\"default\":0.8,\"kind\":\"number\",\"max\":1.0,\"min\":0.0},\"enterLead\":{\"default\":120,\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":0},\"margin\":{\"default\":220,\"integer\":true,\"kind\":\"number\",\"max\":600,\"min\":40}},\"retune\":true}"
  CoverRadiusMaxPx = 331'i32
  InitLog = "edge_ride initialized"

type
  DecisionKind = enum
    dkNone
    dkHold
    dkInside
    dkEnter
    dkMargin
    dkCover

  RawDecision = object
    kind: DecisionKind
    x, y: int32

var
  params: EdgeRideParams
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

proc rectMinX(rect: SdkRect): int32 {.inline.} = minI(rect.x1, rect.x2)
proc rectMaxX(rect: SdkRect): int32 {.inline.} = maxI(rect.x1, rect.x2)
proc rectMinY(rect: SdkRect): int32 {.inline.} = minI(rect.y1, rect.y2)
proc rectMaxY(rect: SdkRect): int32 {.inline.} = maxI(rect.y1, rect.y2)

proc inside(rect: SdkRect; x, y: int32): bool =
  rect.present and x >= rect.rectMinX and x <= rect.rectMaxX and
    y >= rect.rectMinY and y <= rect.rectMaxY

proc insetBounds(lo, hi, margin: int32): tuple[lo, hi: int32] =
  ## The standoff band for one axis: `margin` in from each edge, with the
  ## margin clamped to a quarter of the span so the band never collapses.
  ##
  ## `marginTarget` clamps each seat's own position INTO this band, so a
  ## zero-width band answers every seat with the same pixel: the squad piles
  ## onto the rectangle's midpoint, bumps, and jitters. A span shorter than
  ## `2 * margin` used to collapse outright, and a span just over it collapsed
  ## in all but name. Late BR rectangles cross both.
  ##
  ## Clamping to `span div 4` keeps the band at least half the span wide, so
  ## seats at distinct positions keep distinct answers and the play degrades
  ## from "ride the margin" to "hold the middle of the band". Spans with room
  ## to spare (`span >= margin * 4` — the whole early and mid game) are inset
  ## by exactly `margin`, as before.
  let effective = minI(margin, (hi - lo) div 4)
  (lo + effective, hi - effective)

proc marginTarget(rect: SdkRect; self: SdkPoint; margin: int32):
    tuple[x, y: int32] =
  let
    xs = insetBounds(rect.rectMinX, rect.rectMaxX, margin)
    ys = insetBounds(rect.rectMinY, rect.rectMaxY, margin)
  (clampI(self.x, xs.lo, xs.hi), clampI(self.y, ys.lo, ys.hi))

proc distanceToEdge(rect: SdkRect; x, y: int32): int32 =
  minI(minI(x - rect.rectMinX, rect.rectMaxX - x),
    minI(y - rect.rectMinY, rect.rectMaxY - y))

proc chooseRaw(view: EdgeRideView): RawDecision =
  if not view.selfPos.present or not view.current.present:
    return RawDecision(kind: dkHold)
  if not view.current.inside(view.selfPos.x, view.selfPos.y):
    let target = view.current.marginTarget(view.selfPos, params.margin)
    return RawDecision(kind: dkInside, x: target.x, y: target.y)
  if view.next.present and view.ticksToShrinkPresent and
      view.ticksToShrink <= params.enterLead:
    let target = view.next.marginTarget(view.selfPos, params.margin)
    return RawDecision(kind: dkEnter, x: target.x, y: target.y)
  if view.current.distanceToEdge(view.selfPos.x, view.selfPos.y) < params.margin:
    let target = view.current.marginTarget(view.selfPos, params.margin)
    return RawDecision(kind: dkMargin, x: target.x, y: target.y)
  RawDecision(kind: dkHold)

proc coverRadius(): int32 =
  if params.coverBiasScaled <= 0:
    return 0
  int32((int64(CoverRadiusMaxPx) * int64(params.coverBiasScaled) +
    999_999'i64) div 1_000_000'i64)

proc sameDecision(kind: DecisionKind; x = 0'i32; y = 0'i32): bool =
  lastKind == kind and (kind == dkHold or (lastX == x and lastY == y))

proc remember(kind: DecisionKind; x = 0'i32; y = 0'i32) =
  lastKind = kind
  lastX = x
  lastY = y

proc emitGoal(goal: ValidatedGoal; kind: DecisionKind): int32 =
  case kind
  of dkInside: emitNavigateController(goal, "24.0", "edge_ride:inside")
  of dkEnter: emitNavigateController(goal, "24.0", "edge_ride:enter")
  of dkMargin: emitNavigateController(goal, "24.0", "edge_ride:margin")
  of dkCover: emitNavigateController(goal, "24.0", "edge_ride:cover")
  else: emitHoldController("edge_ride:hold")

proc resetDecisionCache() =
  lastKind = dkNone
  lastX = 0
  lastY = 0

proc loadParams(dataPtr, dataLen: int32; clearCache: bool): int32 =
  let decoded = readEdgeRideParams(context(dataPtr, dataLen))
  if not decoded.valid:
    return 1
  params = decoded
  if clearCache:
    resetDecisionCache()
  0

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard ctxPtr
  discard ctxLen
  resetArena()
  result = loadParams(paramsPtr, paramsLen, true)
  if result == 0:
    log(1, InitLog.toOpenArrayByte(0, InitLog.high))

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: EdgeRideView
  if not readEdgeRideBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1

  let raw = chooseRaw(decoded)
  if raw.kind == dkHold:
    if sameDecision(dkHold):
      resetArena()
      return 0
    let code = emitHoldController("edge_ride:hold")
    if code < 0:
      return code
    remember(dkHold)
    resetArena()
    return 0

  let reachable = nearestReachable(raw.x, raw.y)
  var goal = reachable
  var kind = raw.kind
  let radius = coverRadius()
  if reachable.ok and radius > 0:
    let cover = nearestCover(reachable.x, reachable.y, radius)
    if cover.ok:
      goal = cover
      kind = dkCover
  if sameDecision(kind, goal.x, goal.y):
    resetArena()
    return 0
  let code = emitGoal(goal, kind)
  if code < 0:
    return code
  remember(kind, goal.x, goal.y)
  resetArena()
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, true)

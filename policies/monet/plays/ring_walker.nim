## `ring_walker` -- MONET custom controller #3: the anti-corner play.
##
## Owner field report (2026-09-02): we die to the ring early by cornering
## ourselves in unescapable building pockets when it closes. Two root causes:
## a raw clamped zone-return point is a straight-line intent (walls between
## us and the point corner us), and nothing anticipates the NEXT rect, so we
## sit deep in buildings until the current rect moves and then escape
## desperately. The ring is a schedule, not a surprise.
##
## Each step: if self is outside the CURRENT zone rect, or outside the NEXT
## rect with fewer than leadTicks ticks to the shrink, walk to a point
## inside the next rect (inset from its edge, biased toward its center) --
## and ALWAYS through the `nearest_reachable` host query, which resolves the
## request to the nearest point in SELF'S OWN connectivity component
## (src/shell/body_map.nim validateGoal: componentOf(selfPos) +
## resolveNearest within ValidatorRadiusPx=256). A clamped point inside a
## wall or across one becomes a reachable target instead of a beeline; if
## the center-biased request resolves to nothing, the raw clamped point is
## tried second (2 spatial calls = exactly MaxSpatialCallsPerStep).

import ../../../play_sdk/play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"the ring is a schedule, not a surprise: leave for the next rect before the walk turns into an escape, by reachable targets only\",\"modes\":[\"br\"],\"name\":\"ring_walker\",\"params\":{\"inset\":{\"default\":64,\"integer\":true,\"kind\":\"number\",\"max\":256,\"min\":16},\"leadTicks\":{\"default\":240,\"integer\":true,\"kind\":\"number\",\"max\":720,\"min\":24}},\"retune\":true}"

type
  DecisionKind = enum
    dkNone
    dkHold
    dkWalk

  RwParams = object
    valid: bool
    inset: int32
    leadTicks: int32

var
  params: RwParams
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

proc keyIs(buf: ptr UncheckedArray[byte]; start, length: int32;
           expected: static[string]): bool =
  if length != expected.len.int32:
    return false
  for index in 0 ..< expected.len:
    if char(buf[start + index.int32]) != expected[index]:
      return false
  true

proc readParams(dataPtr, dataLen: int32): RwParams =
  ## Strict reader over the canonical params bytes; missing keys keep the
  ## manifest defaults, anything undeclared or out of range is invalid.
  result = RwParams(valid: true, inset: 64, leadTicks: 240)
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
    if buf.keyIs(keyStart, keyLen, "inset"):
      result.inset = value
      if value < 16 or value > 256: result.valid = false
    elif buf.keyIs(keyStart, keyLen, "leadTicks"):
      result.leadTicks = value
      if value < 24 or value > 720: result.valid = false
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
  let code = emitHoldController("ring_walker:settled")
  if code < 0:
    return code
  remember(dkHold)
  resetArena()
  0

proc insideRect(rect: SdkRect; p: SdkPoint): bool =
  p.x >= minI(rect.x1, rect.x2) and p.x <= maxI(rect.x1, rect.x2) and
    p.y >= minI(rect.y1, rect.y2) and p.y <= maxI(rect.y1, rect.y2)

proc walkTargets(rect: SdkRect; self: SdkPoint;
                 clamped, biased: var SdkPoint) =
  ## Entry point into `rect`: self clamped into the inset rect, and the same
  ## point pulled halfway toward the rect center (the center bias keeps the
  ## request off pocket edges, where the reachable resolver has the least
  ## room to work with).
  let
    lox = minI(rect.x1, rect.x2)
    hix = maxI(rect.x1, rect.x2)
    loy = minI(rect.y1, rect.y2)
    hiy = maxI(rect.y1, rect.y2)
    ix = minI(params.inset, (hix - lox) div 2)
    iy = minI(params.inset, (hiy - loy) div 2)
  clamped.present = true
  clamped.x = clampI(self.x, lox + ix, hix - ix)
  clamped.y = clampI(self.y, loy + iy, hiy - iy)
  biased.present = true
  biased.x = (clamped.x + (lox + hix) div 2) div 2
  biased.y = (clamped.y + (loy + hiy) div 2) div 2

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

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard ctxPtr
  discard ctxLen
  resetArena()
  loadParams(paramsPtr, paramsLen, true)

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: SdkView
  if not readBinaryViewInto(view(viewPtr, viewLen), decoded):
    return 1
  if not decoded.self.pos.present:
    return emitHoldIfChanged()

  let
    zone = decoded.world.zone
    outsideCurrent = zone.current.present and
      not insideRect(zone.current, decoded.self.pos)
    nextPressure = zone.next.present and
      not insideRect(zone.next, decoded.self.pos) and
      zone.ticksToShrinkPresent and zone.ticksToShrink < params.leadTicks
  if not (outsideCurrent or nextPressure):
    # Inside the schedule: nothing to walk (the harness gate normally keeps
    # this play off the ladder here anyway).
    return emitHoldIfChanged()

  let rect = if zone.next.present: zone.next else: zone.current
  var clamped, biased: SdkPoint
  walkTargets(rect, decoded.self.pos, clamped, biased)
  # Reachable targets only: center-biased request first, the raw clamped
  # point second -- two spatial calls, exactly MaxSpatialCallsPerStep.
  var goal = nearestReachable(biased.x, biased.y)
  if not goal.ok:
    goal = nearestReachable(clamped.x, clamped.y)
  if not goal.ok:
    return emitHoldIfChanged()
  if sameDecision(dkWalk, goal.x, goal.y):
    resetArena()
    return 0
  let code = emitNavigateController(goal, "24.0", "ring_walker:walk")
  if code < 0:
    return code
  remember(dkWalk, goal.x, goal.y)
  resetArena()
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  resetArena()
  loadParams(newPtr, newLen, true)

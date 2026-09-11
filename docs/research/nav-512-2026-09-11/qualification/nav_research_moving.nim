## `nav_research_moving`: test-only controller for navigation qualification.
##
## Every 12 ticks it requests a new goal from the opposite interior quarter
## of the current safe-zone rectangle, alternating the carrier and hunter
## cost profiles, with moving_goal set. It emits exactly once per 12-tick
## interval and stays silent otherwise, so the engine sees a deterministic
## stream of replans. Not a league play; qualification support only.

import ../../../../play_sdk/play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"controller\",\"doc\":\"qualification: replan every 12 ticks between opposite zone quarters, alternating carrier and hunter\",\"modes\":[\"br\"],\"name\":\"nav_research_moving\",\"params\":{},\"retune\":true}"
  InitLog = "nav_research_moving initialized"
  IntervalTicks = 12'i32
  ## Fixed fallback goals, used only when the view carries no zone.
  FallbackEvenX = 256'i32
  FallbackEvenY = 256'i32
  FallbackOddX = 1024'i32
  FallbackOddY = 768'i32
  OutBytes = 192

var
  lastInterval: int32 = -1
  stepsSeen: int32
  outBuf: array[OutBytes, byte]
  outLen: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc putByte(value: byte) {.inline.} =
  if outLen < OutBytes.int32:
    outBuf[outLen] = value
    inc outLen

template putText(text: static[string]) =
  for ch in text:
    putByte(byte(ord(ch)))

proc putInt(value: int32) =
  ## Non-negative decimal; validated goals are map pixels, never negative.
  if value <= 0:
    putByte(byte(ord('0')))
    return
  var digits: array[10, byte]
  var count = 0
  var remaining = value
  while remaining > 0:
    digits[count] = byte(ord('0') + (remaining mod 10))
    remaining = remaining div 10
    inc count
  while count > 0:
    dec count
    putByte(digits[count])

proc emitMovingGoal(goal: ValidatedGoal; odd: bool): int32 =
  ## Canonical intent JSON: keys sorted, no whitespace, as the validator
  ## requires. Both profiles are accepted by emit_validator.parseProfile.
  outLen = 0
  putText("{\"arrive_radius\":24.0,\"kind\":\"navigate_to\",\"moving_goal\":true,\"point\":[")
  putInt(goal.x)
  putText(",")
  putInt(goal.y)
  if odd:
    putText("],\"profile\":\"hunter\",\"reason\":\"nav_research_moving:hunter\"")
  else:
    putText("],\"profile\":\"carrier\",\"reason\":\"nav_research_moving:carrier\"")
  putText(",\"schema\":\"intent\",\"v\":1}")
  emitRaw(outBuf.toOpenArray(0, outLen - 1))

proc minI(a, b: int32): int32 {.inline.} =
  if a < b: a else: b

proc maxI(a, b: int32): int32 {.inline.} =
  if a > b: a else: b

proc quarterPoint(rect: SdkRect; odd: bool): tuple[x, y: int32] =
  ## Interior quarter centres: (1/4, 1/4) of the rectangle on even
  ## intervals, (3/4, 3/4) on odd ones, so consecutive goals are far apart.
  let
    minX = minI(rect.x1, rect.x2)
    maxX = maxI(rect.x1, rect.x2)
    minY = minI(rect.y1, rect.y2)
    maxY = maxI(rect.y1, rect.y2)
    spanX = maxX - minX
    spanY = maxY - minY
  if odd:
    (minX + (spanX * 3) div 4, minY + (spanY * 3) div 4)
  else:
    (minX + spanX div 4, minY + spanY div 4)

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard paramsPtr
  discard paramsLen
  discard ctxPtr
  discard ctxLen
  resetArena()
  lastInterval = -1
  stepsSeen = 0
  log(1, InitLog.toOpenArrayByte(0, InitLog.high))
  0

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  var decoded: EdgeRideView
  let hasZone = readEdgeRideBinaryViewInto(view(viewPtr, viewLen), decoded)
  # The view tick is the shared clock when the zone frame decodes; without
  # a zone the play falls back to its own step count and fixed goals.
  let clock = if hasZone: decoded.tick else: stepsSeen
  inc stepsSeen
  let interval = clock div IntervalTicks
  if interval == lastInterval:
    resetArena()
    return 0
  lastInterval = interval
  let odd = (interval and 1) == 1
  var rawX, rawY: int32
  if hasZone:
    let target = quarterPoint(decoded.current, odd)
    rawX = target.x
    rawY = target.y
  elif odd:
    rawX = FallbackOddX
    rawY = FallbackOddY
  else:
    rawX = FallbackEvenX
    rawY = FallbackEvenY
  let goal = nearestReachable(rawX, rawY)
  if not goal.ok:
    resetArena()
    return 0
  let code = emitMovingGoal(goal, odd)
  resetArena()
  if code < 0:
    return code
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  discard newPtr
  discard newLen
  resetArena()
  0

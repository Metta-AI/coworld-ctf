## Minimal Nim play SDK for the Season 2 core-WASM ABI.
##
## This library is author convenience only. The server's real security
## boundary remains `src/shell`: binary validation, manifest parsing, ABI
## checks, host queries, and emit validation.

const
  ArenaBytes = 32 * 1024
  EmitBufferBytes = 1024
  NoGoal* = -1'i64
  QuotaExceeded* = -2'i64
  InvalidSpatialArgument* = -3'i64

type
  PlayContext* = object
    data*: int32
    len*: int32

  PlayView* = object
    data*: int32
    len*: int32

  ValidatedGoal* = object
    ok*: bool
    x*, y*: int32

  CoverThreat* = object
    x*, y*: int32

var
  arena: array[ArenaBytes, byte]
  nextOffset: int32
  emitBuffer: array[EmitBufferBytes, byte]
  emitLen: int32

proc playEmit(data: int32; length: int32): int32 {.importc: "play_emit",
  cdecl, header: "play_imports.h".}
proc playLog(level: int32; data: int32; length: int32) {.importc: "play_log",
  cdecl, header: "play_imports.h".}
proc playNearestReachable(x, y: int32): int64 {.
  importc: "play_nearest_reachable", cdecl, header: "play_imports.h".}
proc playNearestCover(x, y, radius, bearingBrads, threatsPtr,
                      threatsLen: int32): int64 {.
  importc: "play_nearest_cover", cdecl, header: "play_imports.h".}

proc play_alloc*(length: int32): int32 {.exportc, cdecl.} =
  if length <= 0 or length > ArenaBytes.int32 - nextOffset:
    return 0
  result = cast[int32](addr arena[nextOffset])
  nextOffset += length

proc resetArena*() =
  nextOffset = 0

proc context*(data, len: int32): PlayContext =
  PlayContext(data: data, len: len)

proc view*(data, len: int32): PlayView =
  PlayView(data: data, len: len)

proc unpackGoal(value: int64): ValidatedGoal =
  if value >= 0:
    result.ok = true
    result.x = int32((value shr 32) and 0xffffffff'i64)
    result.y = int32(value and 0xffffffff'i64)

proc nearestReachable*(x, y: int32): ValidatedGoal =
  ## The sole SDK constructor for an encodable navigation goal.
  unpackGoal(playNearestReachable(x, y))

proc nearestCover*(x, y, radius: int32; bearingBrads: int32 = -1): ValidatedGoal =
  ## Host cover query over the engine-side atlas. The scorer is now live;
  ## candidate density is still freeze-pending and is governed by the
  ## engine's `MaxCoverRadiusPx`/`MaxCoverPostsExamined` caps.
  unpackGoal(playNearestCover(x, y, radius, bearingBrads, 0, 0))

proc log*(level: int32; bytes: openArray[byte]) =
  if bytes.len > 0:
    playLog(level, cast[int32](unsafeAddr bytes[0]), bytes.len.int32)
  else:
    playLog(level, 0, 0)

proc emitRaw*(bytes: openArray[byte]): int32 =
  if bytes.len > 0:
    playEmit(cast[int32](unsafeAddr bytes[0]), bytes.len.int32)
  else:
    playEmit(0, 0)

proc clearEmitBuffer() =
  emitLen = 0

proc appendByte(value: byte) =
  if emitLen < EmitBufferBytes.int32:
    emitBuffer[emitLen] = value
    inc emitLen

template appendLiteral(text: static[string]) =
  for ch in text:
    appendByte(byte(ord(ch)))

proc emitRaw*(text: static[string]): int32 =
  clearEmitBuffer()
  appendLiteral(text)
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)

proc appendInt(value: int32) =
  if value == 0:
    appendByte(byte(ord('0')))
    return
  var digits: array[12, byte]
  var remaining = value
  var count = 0
  if remaining < 0:
    appendByte(byte(ord('-')))
    remaining = -remaining
  while remaining > 0:
    digits[count] = byte(ord('0') + remaining mod 10)
    remaining = remaining div 10
    inc count
  while count > 0:
    dec count
    appendByte(digits[count])

proc emitHoldController*(reason: static[string] = ""): int32 =
  clearEmitBuffer()
  appendLiteral("{\"arrive_radius\":0.0,\"kind\":\"hold\"")
  when reason.len > 0:
    appendLiteral(",\"reason\":\"")
    appendLiteral(reason)
    appendLiteral("\"")
  appendLiteral(",\"schema\":\"intent\",\"v\":1}")
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)

proc emitNavigateController*(goal: ValidatedGoal; arriveRadius: static[string];
                             reason: static[string] = ""): int32 =
  if not goal.ok:
    return -3
  clearEmitBuffer()
  appendLiteral("{\"arrive_radius\":")
  appendLiteral(arriveRadius)
  appendLiteral(",\"kind\":\"navigate_to\",\"point\":[")
  appendInt(goal.x)
  appendLiteral(",")
  appendInt(goal.y)
  appendLiteral("]")
  when reason.len > 0:
    appendLiteral(",\"reason\":\"")
    appendLiteral(reason)
    appendLiteral("\"")
  appendLiteral(",\"schema\":\"intent\",\"v\":1}")
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)

proc emitHoldFireOverlay*(): int32 =
  clearEmitBuffer()
  appendLiteral("{\"hold_fire\":true,\"schema\":\"combat_policy\",\"v\":1}")
  playEmit(cast[int32](addr emitBuffer[0]), emitLen)

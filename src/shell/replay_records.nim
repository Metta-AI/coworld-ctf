## Record-level codec and playback state for shell lifecycle records.
##
## File-level format-2 admission remains closed in ctf/replay_codec.nim until
## the complete format-2 reader/writer lands in P5'.

import ./[seats, types]

type
  LifecycleRecordKind* = enum
    lrDisconnect
    lrKick
    lrRebind

  LifecycleRecord* = object
    kind*: LifecycleRecordKind
    replayTimeMs*: uint32
    seat*: uint8

  LifecycleRecordErrorKind* = enum
    lreWrongSize
    lreWrongType
    lreSeatOutOfRange
    lreBackwardTime
    lreInvalidTransition
    lrePlaySeatDisconnect
    lrePlaySeatRebind

  LifecycleRecordError* = object of CatchableError
    kind*: LifecycleRecordErrorKind

  LifecyclePlayback* = object
    seats: seq[SeatPresence]
    playSeats: seq[bool]
    lastReplayTimeMs*: uint32
    hasReplayTime: bool

proc lifecycleError(kind: LifecycleRecordErrorKind) {.noReturn.} =
  var error = newException(LifecycleRecordError, $kind)
  error.kind = kind
  raise error

proc opcode(kind: LifecycleRecordKind): uint8 =
  case kind
  of lrDisconnect: RecDisconnect
  of lrKick: RecKick
  of lrRebind: RecRebind

proc encodeLifecycleRecord*(record: LifecycleRecord): string =
  result = newString(6)
  result[0] = char(record.kind.opcode())
  for byteIndex, shift in [0, 8, 16, 24]:
    result[byteIndex + 1] = char(uint8(
      (record.replayTimeMs shr shift) and 0xff'u32))
  result[5] = char(record.seat)

proc decodeLifecycleRecord*(bytes: string): LifecycleRecord =
  if bytes.len != 6:
    lifecycleError(lreWrongSize)
  case bytes[0].uint8
  of RecDisconnect: result.kind = lrDisconnect
  of RecKick: result.kind = lrKick
  of RecRebind: result.kind = lrRebind
  else: lifecycleError(lreWrongType)
  for byteIndex, shift in [0, 8, 16, 24]:
    result.replayTimeMs = result.replayTimeMs or
      (uint32(bytes[byteIndex + 1].uint8) shl shift)
  result.seat = bytes[5].uint8

proc initLifecyclePlayback*(playSeats: openArray[bool]): LifecyclePlayback =
  result.playSeats = @playSeats
  result.seats = newSeq[SeatPresence](playSeats.len)
  for presence in result.seats.mitems:
    presence = spConnected

proc presence*(playback: LifecyclePlayback, seat: int): SeatPresence =
  if seat < 0 or seat >= playback.seats.len:
    lifecycleError(lreSeatOutOfRange)
  playback.seats[seat]

proc applyLifecycleRecord*(
  playback: var LifecyclePlayback,
  record: LifecycleRecord,
) =
  # replayTimeMs stays uint32 through validation and comparison; wasm32 is a
  # first-class target, so no untrusted u32 narrows to int.
  if playback.hasReplayTime and record.replayTimeMs < playback.lastReplayTimeMs:
    lifecycleError(lreBackwardTime)
  let seat = int(record.seat) # uint8 is representable on every Nim target.
  if seat >= playback.seats.len:
    lifecycleError(lreSeatOutOfRange)
  case record.kind
  of lrDisconnect:
    if playback.playSeats[seat]:
      lifecycleError(lrePlaySeatDisconnect)
    if playback.seats[seat] != spConnected:
      lifecycleError(lreInvalidTransition)
    playback.seats[seat] = spReconnectable
  of lrKick:
    if playback.seats[seat] == spTerminal:
      lifecycleError(lreInvalidTransition)
    playback.seats[seat] = spTerminal
  of lrRebind:
    if playback.playSeats[seat]:
      lifecycleError(lrePlaySeatRebind)
    if playback.seats[seat] != spReconnectable:
      lifecycleError(lreInvalidTransition)
    playback.seats[seat] = spConnected
  playback.lastReplayTimeMs = record.replayTimeMs
  playback.hasReplayTime = true


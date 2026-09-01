## Pure binary codecs for the pre-match vote phase's wire pair (docs/
## designs/prematch-vote-wire-2026-08-31.md §2/§3): `0xA4` BallotCast
## (client -> server, 16 bytes fixed) and `0xB3` VoteState (server ->
## client, 18 bytes fixed, two kinds selected by a `kind` byte read right
## after the version byte).
##
## Mirrors ./packets.nim's framing conventions (own header/version check,
## explicit length bounds, no trailing bytes) on purpose, so lifting these
## into that module's `ClientPacketKind`/`ServerPacketKind`/
## `decodeClientPacket`/`decodeServerPacket`/`encodePacket` switch is a
## mechanical move once the real classifier arm lands. NOT edited into
## packets.nim directly: 0xA4/0xB3 are not yet in `decodeClientPacket`'s or
## `decodeServerPacket`'s admitted opcode sets there, and per the
## pre-match-vote-v1 ownership split, wiring that switch is sequenced,
## their-side work (see tests/test_vote_phase.nim's own ownership note,
## following huddle-v1/#321's precedent in tests/test_lobby_chat.nim).
##
## Uses the LANDED reservation constants from ./types
## (`OpBallotCastReserved`/`OpVoteStateReserved`, commit 2c2f905c)
## directly — nothing here redeclares them.

import ./types

type
  PacketErrorKind* = enum
    peWrongOpcode
    peWrongVersion
    peWrongKind
    peShortHeader
    peTrailingBytes
    peReservedNonzero
    peBadOption

  PacketError* = object of CatchableError
    kind*: PacketErrorKind
    offset*: int

  BallotCastPacket* = object
    castId*: uint64
    option*: uint8

  VoteStateCastPacket* = object
    ordinal*: uint64
    tick*: uint32
    seat*: uint8
    team*: uint8
    option*: uint8

  VoteStateResolvedPacket* = object
    ordinal*: uint64
    tick*: uint32
    category*: uint8
    tieBreakDrawn*: uint8
    finalOption*: uint8

  VoteStateKind* = enum
    vskCast
    vskResolved

  VoteStatePacket* = object
    case kind*: VoteStateKind
    of vskCast:
      castInfo*: VoteStateCastPacket
    of vskResolved:
      resolved*: VoteStateResolvedPacket

const
  # Unexported on purpose: ctf/sim_types.nim carries the test-visible
  # mirrored copies (BallotCastPacketBytes*/VoteStatePacketBytes*,
  # re-exported via ctf/sim) — exporting a second, same-named pair here
  # would be an ambiguous-identifier collision for any caller importing
  # both (e.g. tests/test_vote_phase.nim, exactly the shape
  # tests/test_lobby_chat.nim avoids by never re-exporting shell/types.nim
  # through shell/packets.nim either).
  BallotCastPacketBytes = 16
  VoteStatePacketBytes = 18

proc packetError(kind: PacketErrorKind, offset: int) {.noReturn.} =
  var error = newException(PacketError, $kind)
  error.kind = kind
  error.offset = offset
  raise error

proc requireBytes(bytes: string, cursor, count: int) =
  if cursor < 0 or cursor > bytes.len or count < 0 or
      count > bytes.len - cursor:
    packetError(peShortHeader, bytes.len)

proc readU8(bytes: string, cursor: var int): uint8 =
  bytes.requireBytes(cursor, 1)
  result = bytes[cursor].uint8
  inc cursor

proc readU32(bytes: string, cursor: var int): uint32 =
  bytes.requireBytes(cursor, 4)
  for shift in countup(0, 24, 8):
    result = result or (uint32(bytes[cursor].uint8) shl shift)
    inc cursor

proc readU64(bytes: string, cursor: var int): uint64 =
  bytes.requireBytes(cursor, 8)
  for shift in countup(0, 56, 8):
    result = result or (uint64(bytes[cursor].uint8) shl shift)
    inc cursor

proc requireEnd(bytes: string, cursor: int) =
  if cursor < bytes.len:
    packetError(peTrailingBytes, cursor)

proc requireHeader(bytes: string, expectedOpcode: uint8): int =
  ## Reads and checks `u8 op, u8 ver`; returns the cursor past them.
  if bytes.len < 2:
    packetError(peShortHeader, bytes.len)
  if bytes[0].uint8 != expectedOpcode:
    packetError(peWrongOpcode, 0)
  if bytes[1].uint8 != ShellProtocolVersion:
    packetError(peWrongVersion, 1)
  2

proc decodeBallotCast*(bytes: string): BallotCastPacket =
  ## `u8 op (0xA4), u8 ver (1), u64 castId, u8 option, u8[5] reserved
  ## (zero)`. Total = 16, fixed.
  if bytes.len != BallotCastPacketBytes:
    packetError(peShortHeader, bytes.len)
  var cursor = bytes.requireHeader(OpBallotCastReserved)
  let castId = bytes.readU64(cursor)
  let option = bytes.readU8(cursor)
  if option > 3'u8:
    packetError(peBadOption, cursor - 1)
  for _ in 0 ..< 5:
    let reservedOffset = cursor
    if bytes.readU8(cursor) != 0:
      packetError(peReservedNonzero, reservedOffset)
  bytes.requireEnd(cursor)
  BallotCastPacket(castId: castId, option: option)

proc encodePacket*(packet: BallotCastPacket): string =
  if packet.option > 3'u8:
    packetError(peBadOption, 10)
  result = newString(BallotCastPacketBytes)
  var cursor = 0
  result[cursor] = char(OpBallotCastReserved); inc cursor
  result[cursor] = char(ShellProtocolVersion); inc cursor
  for shift in countup(0, 56, 8):
    result[cursor] = char(uint8((packet.castId shr shift) and 0xff'u64))
    inc cursor
  result[cursor] = char(packet.option); inc cursor
  for _ in 0 ..< 5:
    result[cursor] = char(0'u8); inc cursor

proc decodeVoteState*(bytes: string): VoteStatePacket =
  ## `kind 0 (cast): u8 op, u8 ver, u8 kind (0), u64 ordinal, u32 tick,
  ## u8 seat, u8 team, u8 option`; `kind 1 (resolved): u8 op, u8 ver,
  ## u8 kind (1), u64 ordinal, u32 tick, u8 category, u8 tieBreakDrawn,
  ## u8 finalOption`. Both total 18, fixed.
  if bytes.len != VoteStatePacketBytes:
    packetError(peShortHeader, bytes.len)
  var cursor = bytes.requireHeader(OpVoteStateReserved)
  let kind = bytes.readU8(cursor)
  let ordinal = bytes.readU64(cursor)
  let tick = bytes.readU32(cursor)
  case kind
  of 0'u8:
    let seat = bytes.readU8(cursor)
    let team = bytes.readU8(cursor)
    let option = bytes.readU8(cursor)
    if option > 3'u8:
      packetError(peBadOption, cursor - 1)
    bytes.requireEnd(cursor)
    result = VoteStatePacket(kind: vskCast, castInfo: VoteStateCastPacket(
      ordinal: ordinal, tick: tick, seat: seat, team: team, option: option))
  of 1'u8:
    let category = bytes.readU8(cursor)
    let tieBreakDrawn = bytes.readU8(cursor)
    let finalOption = bytes.readU8(cursor)
    if category > 3'u8:
      packetError(peBadOption, cursor - 3)
    if finalOption > 2'u8:
      packetError(peBadOption, cursor - 1)
    bytes.requireEnd(cursor)
    result = VoteStatePacket(kind: vskResolved, resolved:
      VoteStateResolvedPacket(ordinal: ordinal, tick: tick,
        category: category, tieBreakDrawn: tieBreakDrawn,
        finalOption: finalOption))
  else:
    packetError(peWrongKind, 2)

proc encodePacket*(packet: VoteStatePacket): string =
  case packet.kind
  of vskResolved:
    if packet.resolved.category > 3'u8 or packet.resolved.finalOption > 2'u8:
      packetError(peBadOption, 15)
  of vskCast:
    if packet.castInfo.option > 3'u8:
      packetError(peBadOption, 17)
  result = newString(VoteStatePacketBytes)
  var cursor = 0
  result[cursor] = char(OpVoteStateReserved); inc cursor
  result[cursor] = char(ShellProtocolVersion); inc cursor
  case packet.kind
  of vskCast:
    result[cursor] = char(0'u8); inc cursor
    for shift in countup(0, 56, 8):
      result[cursor] = char(uint8((packet.castInfo.ordinal shr shift) and 0xff'u64))
      inc cursor
    for shift in countup(0, 24, 8):
      result[cursor] = char(uint8((packet.castInfo.tick shr shift) and 0xff'u32))
      inc cursor
    result[cursor] = char(packet.castInfo.seat); inc cursor
    result[cursor] = char(packet.castInfo.team); inc cursor
    result[cursor] = char(packet.castInfo.option); inc cursor
  of vskResolved:
    result[cursor] = char(1'u8); inc cursor
    for shift in countup(0, 56, 8):
      result[cursor] =
        char(uint8((packet.resolved.ordinal shr shift) and 0xff'u64))
      inc cursor
    for shift in countup(0, 24, 8):
      result[cursor] = char(uint8((packet.resolved.tick shr shift) and 0xff'u32))
      inc cursor
    result[cursor] = char(packet.resolved.category); inc cursor
    result[cursor] = char(packet.resolved.tieBreakDrawn); inc cursor
    result[cursor] = char(packet.resolved.finalOption); inc cursor

## Pure binary codecs for the Season 2 play-seat packets (§4.3).
##
## This module owns framing only. Payloads remain opaque bytes: canonical JSON,
## UTF-8, admission, and socket state are validated by their later layers.
## Every decoder checks lengths before slicing and rejects trailing bytes.

import ./types

type
  PacketErrorKind* = enum
    peWrongOpcode
    peWrongVersion
    peReservedNonzero
    peShortHeader
    peLengthMismatch
    peTrailingBytes
    peLimitExceeded
    peWrongKind
      ## A union packet's kind byte names no admitted kind (first user:
      ## 0xB3 VoteState, a two-kind union selected by the byte after the
      ## version byte).
    peBadOption
      ## A fixed-range field value lies outside its documented range
      ## (first users: 0xA4's option 0-3, 0xB3's category 0-3 and
      ## finalOption 0-2).

  PacketError* = object of CatchableError
    kind*: PacketErrorKind
    offset*: int

  ModuleUploadPacket* = object
    uploadId*: uint64
    wasm*: string

  PlayCallPacket* = object
    proposalId*: uint64
    callBytes*: string

  StatusAckPacket* = object
    mark*: uint64

  LobbyChatSendPacket* = object
    text*: string

  PlayContextPacket* = object
    control*: string
    context*: string

  PlayViewPacket* = object
    tick*: uint32
    control*: string
    view*: string

  LobbyChatBroadcastPacket* = object
    ordinal*: uint64
    tick*: uint32
    seat*: uint8
    team*: uint8
    text*: string

  ClientPacketKind* = enum
    cpkModuleUpload
    cpkPlayCall
    cpkStatusAck
    cpkLobbyChatSend

  ClientPacket* = object
    case kind*: ClientPacketKind
    of cpkModuleUpload:
      moduleUpload*: ModuleUploadPacket
    of cpkPlayCall:
      playCall*: PlayCallPacket
    of cpkStatusAck:
      statusAck*: StatusAckPacket
    of cpkLobbyChatSend:
      lobbyChatSend*: LobbyChatSendPacket

  ServerPacketKind* = enum
    spkPlayContext
    spkPlayView
    spkLobbyChatBroadcast

  ServerPacket* = object
    case kind*: ServerPacketKind
    of spkPlayContext:
      playContext*: PlayContextPacket
    of spkPlayView:
      playView*: PlayViewPacket
    of spkLobbyChatBroadcast:
      lobbyChatBroadcast*: LobbyChatBroadcastPacket

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

proc readPayload(
  bytes: string,
  cursor: var int,
  length: uint32,
  cap: int,
  lengthOffset: int
): string =
  if length > uint32(cap):
    packetError(peLimitExceeded, lengthOffset)
  let count = int(length)
  if count > bytes.len - cursor:
    packetError(peLengthMismatch, lengthOffset)
  result = bytes[cursor ..< cursor + count]
  cursor += count

proc requireEnd(bytes: string, cursor: int) =
  if cursor < bytes.len:
    packetError(peTrailingBytes, cursor)

proc readClientHeader(bytes: string): uint8 =
  if bytes.len == 0:
    packetError(peShortHeader, 0)
  result = bytes[0].uint8
  if result notin {OpModuleUpload, OpPlayCall, OpStatusAck, OpLobbyChatSend}:
    packetError(peWrongOpcode, 0)
  if bytes.len < 2:
    packetError(peShortHeader, 1)
  if bytes[1].uint8 != ShellProtocolVersion:
    packetError(peWrongVersion, 1)

proc readServerHeader(bytes: string): uint8 =
  if bytes.len == 0:
    packetError(peShortHeader, 0)
  result = bytes[0].uint8
  if result notin {OpPlayContext, OpPlayView, OpLobbyChatBroadcast}:
    packetError(peWrongOpcode, 0)
  if bytes.len < 2:
    packetError(peShortHeader, 1)
  if bytes[1].uint8 != ShellProtocolVersion:
    packetError(peWrongVersion, 1)

proc decodeClientPacket*(bytes: string): ClientPacket =
  let opcode = bytes.readClientHeader()
  var cursor = 2
  case opcode
  of OpModuleUpload:
    let
      uploadId = bytes.readU64(cursor)
      lengthOffset = cursor
      length = bytes.readU32(cursor)
      wasm = bytes.readPayload(cursor, length, MaxModuleBytes, lengthOffset)
    bytes.requireEnd(cursor)
    result = ClientPacket(
      kind: cpkModuleUpload,
      moduleUpload: ModuleUploadPacket(uploadId: uploadId, wasm: wasm)
    )
  of OpPlayCall:
    let
      proposalId = bytes.readU64(cursor)
      lengthOffset = cursor
      length = bytes.readU32(cursor)
      callBytes = bytes.readPayload(cursor, length, MaxCallBytes, lengthOffset)
    bytes.requireEnd(cursor)
    result = ClientPacket(
      kind: cpkPlayCall,
      playCall: PlayCallPacket(proposalId: proposalId, callBytes: callBytes)
    )
  of OpStatusAck:
    for _ in 0 ..< 6:
      let reservedOffset = cursor
      if bytes.readU8(cursor) != 0:
        packetError(peReservedNonzero, reservedOffset)
    let mark = bytes.readU64(cursor)
    bytes.requireEnd(cursor)
    result = ClientPacket(
      kind: cpkStatusAck,
      statusAck: StatusAckPacket(mark: mark)
    )
  of OpLobbyChatSend:
    let
      lengthOffset = cursor
      length = bytes.readU32(cursor)
      text = bytes.readPayload(cursor, length, LobbyChatMaxBytes, lengthOffset)
    bytes.requireEnd(cursor)
    result = ClientPacket(
      kind: cpkLobbyChatSend,
      lobbyChatSend: LobbyChatSendPacket(text: text)
    )
  else:
    discard # readClientHeader has already restricted the opcode.

proc decodeServerPacket*(bytes: string): ServerPacket =
  let opcode = bytes.readServerHeader()
  var cursor = 2
  case opcode
  of OpPlayContext:
    let
      controlLengthOffset = cursor
      controlLength = bytes.readU32(cursor)
      control = bytes.readPayload(
        cursor, controlLength, MaxControlEnvelopeBytes, controlLengthOffset)
      contextLengthOffset = cursor
      contextLength = bytes.readU32(cursor)
      context = bytes.readPayload(
        cursor, contextLength, MaxContextBytes, contextLengthOffset)
    bytes.requireEnd(cursor)
    result = ServerPacket(
      kind: spkPlayContext,
      playContext: PlayContextPacket(control: control, context: context)
    )
  of OpPlayView:
    let
      tick = bytes.readU32(cursor)
      controlLengthOffset = cursor
      controlLength = bytes.readU32(cursor)
      control = bytes.readPayload(
        cursor, controlLength, MaxControlEnvelopeBytes, controlLengthOffset)
      viewLengthOffset = cursor
      viewLength = bytes.readU32(cursor)
      view = bytes.readPayload(
        cursor, viewLength, MaxViewFrameBytes, viewLengthOffset)
    bytes.requireEnd(cursor)
    result = ServerPacket(
      kind: spkPlayView,
      playView: PlayViewPacket(tick: tick, control: control, view: view)
    )
  of OpLobbyChatBroadcast:
    let
      ordinal = bytes.readU64(cursor)
      tick = bytes.readU32(cursor)
      seat = bytes.readU8(cursor)
      team = bytes.readU8(cursor)
      lengthOffset = cursor
      length = bytes.readU32(cursor)
      text = bytes.readPayload(cursor, length, LobbyChatMaxBytes, lengthOffset)
    bytes.requireEnd(cursor)
    result = ServerPacket(
      kind: spkLobbyChatBroadcast,
      lobbyChatBroadcast: LobbyChatBroadcastPacket(
        ordinal: ordinal, tick: tick, seat: seat, team: team, text: text)
    )
  else:
    discard # readServerHeader has already restricted the opcode.

proc ensureCap(length, cap, offset: int) =
  if length > cap:
    packetError(peLimitExceeded, offset)

proc putU8(bytes: var string, cursor: var int, value: uint8) =
  bytes[cursor] = char(value)
  inc cursor

proc putU32(bytes: var string, cursor: var int, value: uint32) =
  for shift in countup(0, 24, 8):
    bytes.putU8(cursor, uint8((value shr shift) and 0xff'u32))

proc putU64(bytes: var string, cursor: var int, value: uint64) =
  for shift in countup(0, 56, 8):
    bytes.putU8(cursor, uint8((value shr shift) and 0xff'u64))

proc putPayload(bytes: var string, cursor: var int, payload: string) =
  for value in payload:
    bytes[cursor] = value
    inc cursor

proc putHeader(bytes: var string, cursor: var int, opcode: uint8) =
  bytes.putU8(cursor, opcode)
  bytes.putU8(cursor, ShellProtocolVersion)

proc encodePacket*(packet: ModuleUploadPacket): string =
  packet.wasm.len.ensureCap(MaxModuleBytes, 10)
  result = newString(14 + packet.wasm.len)
  var cursor = 0
  result.putHeader(cursor, OpModuleUpload)
  result.putU64(cursor, packet.uploadId)
  result.putU32(cursor, uint32(packet.wasm.len))
  result.putPayload(cursor, packet.wasm)

proc encodePacket*(packet: PlayCallPacket): string =
  packet.callBytes.len.ensureCap(MaxCallBytes, 10)
  result = newString(14 + packet.callBytes.len)
  var cursor = 0
  result.putHeader(cursor, OpPlayCall)
  result.putU64(cursor, packet.proposalId)
  result.putU32(cursor, uint32(packet.callBytes.len))
  result.putPayload(cursor, packet.callBytes)

proc encodePacket*(packet: StatusAckPacket): string =
  result = newString(StatusAckPacketBytes)
  var cursor = 0
  result.putHeader(cursor, OpStatusAck)
  for _ in 0 ..< 6:
    result.putU8(cursor, 0)
  result.putU64(cursor, packet.mark)

proc encodePacket*(packet: LobbyChatSendPacket): string =
  packet.text.len.ensureCap(LobbyChatMaxBytes, 2)
  result = newString(6 + packet.text.len)
  var cursor = 0
  result.putHeader(cursor, OpLobbyChatSend)
  result.putU32(cursor, uint32(packet.text.len))
  result.putPayload(cursor, packet.text)

proc encodePacket*(packet: PlayContextPacket): string =
  packet.control.len.ensureCap(MaxControlEnvelopeBytes, 2)
  packet.context.len.ensureCap(MaxContextBytes, 6 + packet.control.len)
  result = newString(10 + packet.control.len + packet.context.len)
  var cursor = 0
  result.putHeader(cursor, OpPlayContext)
  result.putU32(cursor, uint32(packet.control.len))
  result.putPayload(cursor, packet.control)
  result.putU32(cursor, uint32(packet.context.len))
  result.putPayload(cursor, packet.context)

proc encodePacket*(packet: PlayViewPacket): string =
  packet.control.len.ensureCap(MaxControlEnvelopeBytes, 6)
  packet.view.len.ensureCap(MaxViewFrameBytes, 10 + packet.control.len)
  result = newString(14 + packet.control.len + packet.view.len)
  var cursor = 0
  result.putHeader(cursor, OpPlayView)
  result.putU32(cursor, packet.tick)
  result.putU32(cursor, uint32(packet.control.len))
  result.putPayload(cursor, packet.control)
  result.putU32(cursor, uint32(packet.view.len))
  result.putPayload(cursor, packet.view)

proc encodePacket*(packet: LobbyChatBroadcastPacket): string =
  packet.text.len.ensureCap(LobbyChatMaxBytes, 16)
  result = newString(20 + packet.text.len)
  var cursor = 0
  result.putHeader(cursor, OpLobbyChatBroadcast)
  result.putU64(cursor, packet.ordinal)
  result.putU32(cursor, packet.tick)
  result.putU8(cursor, packet.seat)
  result.putU8(cursor, packet.team)
  result.putU32(cursor, uint32(packet.text.len))
  result.putPayload(cursor, packet.text)

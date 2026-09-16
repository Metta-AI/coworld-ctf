## Byte-level tests for the Season 2 play-seat packet codec.
##
## The checked-in binary fixtures are the protocol oracle. They are produced
## only by the independent, hand-written layout builders below when compiling
## with -d:writePacketGoldens; ordinary tests never rewrite them.

import std/[os, unittest]
import ../src/shell/[packets, types]

const FixtureDir = "tests" / "fixtures" / "shell" / "packets"

proc addU8(bytes: var string, value: uint8) =
  bytes.add(char(value))

proc addU32(bytes: var string, value: uint32) =
  for shift in countup(0, 24, 8):
    bytes.add(char(uint8((value shr shift) and 0xff'u32)))

proc addU64(bytes: var string, value: uint64) =
  for shift in countup(0, 56, 8):
    bytes.add(char(uint8((value shr shift) and 0xff'u64)))

proc patternedBytes(length: int): string =
  ## Deterministic full-range-ish binary payload for the max-upload golden.
  ## The 251-byte cycle is intentionally non-text and includes NUL bytes.
  result = newString(length)
  for i in 0 ..< length:
    result[i] = char((i * 31 + 7) mod 251)

proc moduleUploadGolden(uploadId: uint64, wasm: string): string =
  result.addU8(OpModuleUpload)
  result.addU8(ShellProtocolVersion)
  result.addU64(uploadId)
  result.addU32(uint32(wasm.len))
  result.add(wasm)

proc playCallGolden(proposalId: uint64, callBytes: string): string =
  result.addU8(OpPlayCall)
  result.addU8(ShellProtocolVersion)
  result.addU64(proposalId)
  result.addU32(uint32(callBytes.len))
  result.add(callBytes)

proc statusAckGolden(mark: uint64): string =
  result.addU8(OpStatusAck)
  result.addU8(ShellProtocolVersion)
  for _ in 0 ..< 6:
    result.addU8(0)
  result.addU64(mark)

proc lobbyChatSendGolden(text: string): string =
  result.addU8(OpLobbyChatSend)
  result.addU8(ShellProtocolVersion)
  result.addU32(uint32(text.len))
  result.add(text)

proc playContextGolden(control, context: string): string =
  result.addU8(OpPlayContext)
  result.addU8(ShellProtocolVersion)
  result.addU32(uint32(control.len))
  result.add(control)
  result.addU32(uint32(context.len))
  result.add(context)

proc playViewGolden(tick: uint32, control, view: string): string =
  result.addU8(OpPlayView)
  result.addU8(ShellProtocolVersion)
  result.addU32(tick)
  result.addU32(uint32(control.len))
  result.add(control)
  result.addU32(uint32(view.len))
  result.add(view)

proc lobbyChatBroadcastGolden(
  ordinal: uint64,
  tick: uint32,
  seat, team: uint8,
  text: string
): string =
  result.addU8(OpLobbyChatBroadcast)
  result.addU8(ShellProtocolVersion)
  result.addU64(ordinal)
  result.addU32(tick)
  result.addU8(seat)
  result.addU8(team)
  result.addU32(uint32(text.len))
  result.add(text)

proc writeU32At(bytes: var string, offset: int, value: uint32) =
  for shift in countup(0, 24, 8):
    bytes[offset + shift div 8] = char(uint8((value shr shift) and 0xff'u32))

proc fixtureBytes(name: string): string =
  case name
  of "module_upload.bin":
    moduleUploadGolden(0x0102030405060708'u64, "\0asm\1\0\0\0")
  of "module_upload_max.bin":
    moduleUploadGolden(high(uint64), patternedBytes(MaxModuleBytes))
  of "play_call.bin":
    playCallGolden(0x8877665544332211'u64, "{\"plays\":[]}")
  of "status_ack.bin":
    statusAckGolden(0x0102030405060708'u64)
  of "lobby_chat_send.bin":
    lobbyChatSendGolden("meet at center")
  of "play_context.bin":
    playContextGolden("{\"gen\":\"1\"}", "{\"mode\":\"br\"}")
  of "play_view.bin":
    playViewGolden(0x01020304'u32, "{\"gen\":\"2\"}", "{\"self\":{}}")
  of "play_view_control_only.bin":
    playViewGolden(37, "{\"gen\":\"3\"}", "")
  of "lobby_chat_broadcast.bin":
    lobbyChatBroadcastGolden(0x0102030405060708'u64, 99, 3, 12, "pact?")
  else:
    raise newException(ValueError, "unknown packet fixture " & name)

const FixtureNames = [
  "module_upload.bin",
  "module_upload_max.bin",
  "play_call.bin",
  "status_ack.bin",
  "lobby_chat_send.bin",
  "play_context.bin",
  "play_view.bin",
  "play_view_control_only.bin",
  "lobby_chat_broadcast.bin"
]

when defined(writePacketGoldens):
  createDir(FixtureDir)
  for name in FixtureNames:
    writeFile(FixtureDir / name, fixtureBytes(name))

template checkClientError(
  packetBytes: string,
  expectedKind: PacketErrorKind,
  expectedOffset: int
) =
  block:
    var caught = false
    try:
      discard decodeClientPacket(packetBytes)
    except PacketError as error:
      caught = true
      check error.kind == expectedKind
      check error.offset == expectedOffset
    check caught

template checkServerError(
  packetBytes: string,
  expectedKind: PacketErrorKind,
  expectedOffset: int
) =
  block:
    var caught = false
    try:
      discard decodeServerPacket(packetBytes)
    except PacketError as error:
      caught = true
      check error.kind == expectedKind
      check error.offset == expectedOffset
    check caught

template checkEncodeError(
  packet: untyped,
  expectedOffset: int
) =
  block:
    var caught = false
    try:
      discard encodePacket(packet)
    except PacketError as error:
      caught = true
      check error.kind == peLimitExceeded
      check error.offset == expectedOffset
    check caught

suite "shell packet byte goldens":
  test "every checked-in fixture is the independent exact layout":
    for name in FixtureNames:
      check readFile(FixtureDir / name) == fixtureBytes(name)

  test "every encoder matches its full checked-in binary golden":
    check encodePacket(ModuleUploadPacket(
      uploadId: 0x0102030405060708'u64,
      wasm: "\0asm\1\0\0\0"
    )) == readFile(FixtureDir / "module_upload.bin")
    check encodePacket(ModuleUploadPacket(
      uploadId: high(uint64),
      wasm: patternedBytes(MaxModuleBytes)
    )) == readFile(FixtureDir / "module_upload_max.bin")
    check encodePacket(PlayCallPacket(
      proposalId: 0x8877665544332211'u64,
      callBytes: "{\"plays\":[]}"
    )) == readFile(FixtureDir / "play_call.bin")
    check encodePacket(StatusAckPacket(mark: 0x0102030405060708'u64)) ==
      readFile(FixtureDir / "status_ack.bin")
    check encodePacket(LobbyChatSendPacket(text: "meet at center")) ==
      readFile(FixtureDir / "lobby_chat_send.bin")
    check encodePacket(PlayContextPacket(
      control: "{\"gen\":\"1\"}", context: "{\"mode\":\"br\"}"
    )) == readFile(FixtureDir / "play_context.bin")
    check encodePacket(PlayViewPacket(
      tick: 0x01020304'u32,
      control: "{\"gen\":\"2\"}",
      view: "{\"self\":{}}"
    )) == readFile(FixtureDir / "play_view.bin")
    check encodePacket(PlayViewPacket(
      tick: 37, control: "{\"gen\":\"3\"}", view: ""
    )) == readFile(FixtureDir / "play_view_control_only.bin")
    check encodePacket(LobbyChatBroadcastPacket(
      ordinal: 0x0102030405060708'u64,
      tick: 99,
      seat: 3,
      team: 12,
      text: "pact?"
    )) == readFile(FixtureDir / "lobby_chat_broadcast.bin")

  test "client goldens decode without changing payload bytes":
    let upload = decodeClientPacket(readFile(FixtureDir / "module_upload.bin"))
    check upload.kind == cpkModuleUpload
    check upload.moduleUpload.uploadId == 0x0102030405060708'u64
    check upload.moduleUpload.wasm == "\0asm\1\0\0\0"
    let maxUpload = decodeClientPacket(
      readFile(FixtureDir / "module_upload_max.bin"))
    check maxUpload.moduleUpload.uploadId == high(uint64)
    check maxUpload.moduleUpload.wasm == patternedBytes(MaxModuleBytes)
    let call = decodeClientPacket(readFile(FixtureDir / "play_call.bin"))
    check call.kind == cpkPlayCall
    check call.playCall.proposalId == 0x8877665544332211'u64
    check call.playCall.callBytes == "{\"plays\":[]}"
    let ack = decodeClientPacket(readFile(FixtureDir / "status_ack.bin"))
    check ack.kind == cpkStatusAck
    check ack.statusAck.mark == 0x0102030405060708'u64
    let chat = decodeClientPacket(readFile(FixtureDir / "lobby_chat_send.bin"))
    check chat.kind == cpkLobbyChatSend
    check chat.lobbyChatSend.text == "meet at center"

  test "server goldens decode without changing either slice":
    let context = decodeServerPacket(readFile(FixtureDir / "play_context.bin"))
    check context.kind == spkPlayContext
    check context.playContext.control == "{\"gen\":\"1\"}"
    check context.playContext.context == "{\"mode\":\"br\"}"
    let view = decodeServerPacket(readFile(FixtureDir / "play_view.bin"))
    check view.kind == spkPlayView
    check view.playView.tick == 0x01020304'u32
    check view.playView.control == "{\"gen\":\"2\"}"
    check view.playView.view == "{\"self\":{}}"
    let controlOnly = decodeServerPacket(
      readFile(FixtureDir / "play_view_control_only.bin"))
    check controlOnly.playView.tick == 37
    check controlOnly.playView.view == ""
    let chat = decodeServerPacket(
      readFile(FixtureDir / "lobby_chat_broadcast.bin"))
    check chat.kind == spkLobbyChatBroadcast
    check chat.lobbyChatBroadcast.ordinal == 0x0102030405060708'u64
    check chat.lobbyChatBroadcast.tick == 99
    check chat.lobbyChatBroadcast.seat == 3
    check chat.lobbyChatBroadcast.team == 12
    check chat.lobbyChatBroadcast.text == "pact?"

suite "shell packet rejection matrix":
  test "empty and one-byte messages are short headers":
    checkClientError("", peShortHeader, 0)
    checkClientError($char(OpModuleUpload), peShortHeader, 1)
    checkServerError("", peShortHeader, 0)
    checkServerError($char(OpPlayContext), peShortHeader, 1)

  test "wrong-direction opcodes and unknown opcodes fail at byte zero":
    checkClientError(readFile(FixtureDir / "play_context.bin"), peWrongOpcode, 0)
    checkServerError(readFile(FixtureDir / "module_upload.bin"), peWrongOpcode, 0)
    checkClientError("\xff\1", peWrongOpcode, 0)
    checkServerError("\xff\1", peWrongOpcode, 0)

  test "every opcode rejects a wrong version at the edited byte":
    for name in FixtureNames:
      var bytes = readFile(FixtureDir / name)
      bytes[1] = char(ShellProtocolVersion + 1)
      if bytes[0].uint8 in {OpModuleUpload, OpPlayCall, OpStatusAck,
                            OpLobbyChatSend}:
        checkClientError(bytes, peWrongVersion, 1)
      else:
        checkServerError(bytes, peWrongVersion, 1)

  test "StatusAck rejects each nonzero reserved byte and trailing data":
    for offset in 2 .. 7:
      var bytes = readFile(FixtureDir / "status_ack.bin")
      bytes[offset] = char(1)
      checkClientError(bytes, peReservedNonzero, offset)
    checkClientError(
      readFile(FixtureDir / "status_ack.bin") & "\0", peTrailingBytes, 16)

  test "every fixed header truncation is rejected at the missing byte":
    for (name, headerBytes, fromClient) in [
      ("module_upload.bin", 14, true),
      ("play_call.bin", 14, true),
      ("status_ack.bin", 16, true),
      ("lobby_chat_send.bin", 6, true),
      ("lobby_chat_broadcast.bin", 20, false)
    ]:
      let bytes = readFile(FixtureDir / name)
      for length in 2 ..< headerBytes:
        if fromClient:
          checkClientError(bytes[0 ..< length], peShortHeader, length)
        else:
          checkServerError(bytes[0 ..< length], peShortHeader, length)
    let context = readFile(FixtureDir / "play_context.bin")
    for length in 2 ..< 6:
      checkServerError(context[0 ..< length], peShortHeader, length)
    for length in 17 ..< 21: # after the complete 11-byte control slice
      checkServerError(context[0 ..< length], peShortHeader, length)
    let view = readFile(FixtureDir / "play_view.bin")
    for length in 2 ..< 10:
      checkServerError(view[0 ..< length], peShortHeader, length)
    for length in 21 ..< 25: # after the complete 11-byte control slice
      checkServerError(view[0 ..< length], peShortHeader, length)

  test "single lengths reject explicit too-small and too-large edits":
    for (name, lengthOffset, payloadLength) in [
      ("module_upload.bin", 10, 8),
      ("play_call.bin", 10, 12),
      ("lobby_chat_send.bin", 2, 14)
    ]:
      var tooSmall = readFile(FixtureDir / name)
      tooSmall.writeU32At(lengthOffset, uint32(payloadLength - 1))
      checkClientError(
        tooSmall, peTrailingBytes, tooSmall.len - 1)
      var tooLarge = readFile(FixtureDir / name)
      tooLarge.writeU32At(lengthOffset, uint32(payloadLength + 1))
      checkClientError(tooLarge, peLengthMismatch, lengthOffset)

  test "both PlayContext lengths are checked independently":
    let good = readFile(FixtureDir / "play_context.bin")
    let controlLength = 11
    let secondLengthOffset = 6 + controlLength
    var firstSmall = good
    firstSmall.writeU32At(2, uint32(controlLength - 1))
    checkServerError(firstSmall, peLengthMismatch, secondLengthOffset - 1)
    var firstLarge = good
    firstLarge.writeU32At(2, uint32(controlLength + 1))
    checkServerError(firstLarge, peLimitExceeded, secondLengthOffset + 1)
    var secondSmall = good
    secondSmall.writeU32At(secondLengthOffset, 12)
    checkServerError(secondSmall, peTrailingBytes, good.len - 1)
    var secondLarge = good
    secondLarge.writeU32At(secondLengthOffset, 14)
    checkServerError(secondLarge, peLengthMismatch, secondLengthOffset)

  test "both PlayView lengths are checked independently":
    let good = readFile(FixtureDir / "play_view.bin")
    let controlLength = 11
    let secondLengthOffset = 10 + controlLength
    var firstSmall = good
    firstSmall.writeU32At(6, uint32(controlLength - 1))
    checkServerError(firstSmall, peLengthMismatch, secondLengthOffset - 1)
    var firstLarge = good
    firstLarge.writeU32At(6, uint32(controlLength + 1))
    checkServerError(firstLarge, peLimitExceeded, secondLengthOffset + 1)
    var secondSmall = good
    secondSmall.writeU32At(secondLengthOffset, 10)
    checkServerError(secondSmall, peTrailingBytes, good.len - 1)
    var secondLarge = good
    secondLarge.writeU32At(secondLengthOffset, 12)
    checkServerError(secondLarge, peLengthMismatch, secondLengthOffset)

  test "LobbyChat broadcast length and every variable packet reject trailing bytes":
    let good = readFile(FixtureDir / "lobby_chat_broadcast.bin")
    var tooLarge = good
    tooLarge.writeU32At(16, 6)
    checkServerError(tooLarge, peLengthMismatch, 16)
    var tooSmall = good
    tooSmall.writeU32At(16, 4)
    checkServerError(tooSmall, peTrailingBytes, good.len - 1)
    for name in ["module_upload.bin", "play_call.bin", "lobby_chat_send.bin"]:
      let bytes = readFile(FixtureDir / name)
      checkClientError(bytes & "\0", peTrailingBytes, bytes.len)
    for name in ["play_context.bin", "play_view.bin", "lobby_chat_broadcast.bin"]:
      let bytes = readFile(FixtureDir / name)
      checkServerError(bytes & "\0", peTrailingBytes, bytes.len)

  test "huge claimed lengths reject before slicing or allocating":
    var upload = readFile(FixtureDir / "module_upload.bin")[0 ..< 14]
    upload.writeU32At(10, high(uint32))
    checkClientError(upload, peLimitExceeded, 10)
    var context = readFile(FixtureDir / "play_context.bin")[0 ..< 10]
    context.writeU32At(2, high(uint32))
    checkServerError(context, peLimitExceeded, 2)

suite "shell packet cap boundaries":
  test "module, call, and lobby send caps accept limit-1/limit and reject limit+1":
    for length in [MaxModuleBytes - 1, MaxModuleBytes]:
      let packet = ModuleUploadPacket(uploadId: high(uint64), wasm: patternedBytes(length))
      check decodeClientPacket(encodePacket(packet)).moduleUpload == packet
    checkClientError(
      moduleUploadGolden(1, patternedBytes(MaxModuleBytes + 1)),
      peLimitExceeded,
      10
    )
    checkEncodeError(ModuleUploadPacket(
      uploadId: 1, wasm: patternedBytes(MaxModuleBytes + 1)), 10)
    for length in [MaxCallBytes - 1, MaxCallBytes]:
      let packet = PlayCallPacket(proposalId: high(uint64), callBytes: patternedBytes(length))
      check decodeClientPacket(encodePacket(packet)).playCall == packet
    checkClientError(
      playCallGolden(1, patternedBytes(MaxCallBytes + 1)),
      peLimitExceeded,
      10
    )
    checkEncodeError(PlayCallPacket(
      proposalId: 1, callBytes: patternedBytes(MaxCallBytes + 1)), 10)
    for length in [LobbyChatMaxBytes - 1, LobbyChatMaxBytes]:
      let packet = LobbyChatSendPacket(text: patternedBytes(length))
      check decodeClientPacket(encodePacket(packet)).lobbyChatSend == packet
    checkClientError(
      lobbyChatSendGolden(patternedBytes(LobbyChatMaxBytes + 1)),
      peLimitExceeded,
      2
    )
    checkEncodeError(LobbyChatSendPacket(
      text: patternedBytes(LobbyChatMaxBytes + 1)), 2)

  test "control, context, and view caps accept limit-1/limit and reject limit+1":
    for length in [MaxControlEnvelopeBytes - 1, MaxControlEnvelopeBytes]:
      let context = PlayContextPacket(
        control: patternedBytes(length), context: "x")
      check decodeServerPacket(encodePacket(context)).playContext == context
      let view = PlayViewPacket(tick: high(uint32), control: patternedBytes(length), view: "x")
      check decodeServerPacket(encodePacket(view)).playView == view
    checkServerError(
      playContextGolden(patternedBytes(MaxControlEnvelopeBytes + 1), "x"),
      peLimitExceeded,
      2
    )
    checkEncodeError(PlayContextPacket(
      control: patternedBytes(MaxControlEnvelopeBytes + 1), context: "x"), 2)
    checkServerError(
      playViewGolden(1, patternedBytes(MaxControlEnvelopeBytes + 1), "x"),
      peLimitExceeded,
      6
    )
    checkEncodeError(PlayViewPacket(
      tick: 1, control: patternedBytes(MaxControlEnvelopeBytes + 1), view: "x"), 6)
    for length in [MaxContextBytes - 1, MaxContextBytes]:
      let packet = PlayContextPacket(control: "x", context: patternedBytes(length))
      check decodeServerPacket(encodePacket(packet)).playContext == packet
    checkServerError(
      playContextGolden("x", patternedBytes(MaxContextBytes + 1)),
      peLimitExceeded,
      7
    )
    checkEncodeError(PlayContextPacket(
      control: "x", context: patternedBytes(MaxContextBytes + 1)), 7)
    for length in [MaxViewFrameBytes - 1, MaxViewFrameBytes]:
      let packet = PlayViewPacket(tick: high(uint32), control: "x", view: patternedBytes(length))
      check decodeServerPacket(encodePacket(packet)).playView == packet
    checkServerError(
      playViewGolden(1, "x", patternedBytes(MaxViewFrameBytes + 1)),
      peLimitExceeded,
      11
    )
    checkEncodeError(PlayViewPacket(
      tick: 1, control: "x", view: patternedBytes(MaxViewFrameBytes + 1)), 11)

  test "broadcast lobby text cap and uint64 identities round-trip":
    for length in [LobbyChatMaxBytes - 1, LobbyChatMaxBytes]:
      let packet = LobbyChatBroadcastPacket(
        ordinal: high(uint64), tick: high(uint32), seat: high(uint8),
        team: high(uint8), text: patternedBytes(length))
      check decodeServerPacket(encodePacket(packet)).lobbyChatBroadcast == packet
    checkServerError(
      lobbyChatBroadcastGolden(1, 2, 3, 4,
        patternedBytes(LobbyChatMaxBytes + 1)),
      peLimitExceeded,
      16
    )
    checkEncodeError(LobbyChatBroadcastPacket(
      ordinal: 1, tick: 2, seat: 3, team: 4,
      text: patternedBytes(LobbyChatMaxBytes + 1)), 16)

## Server-level proof that the play leading-byte switch precedes Sprite parsing.

import std/[atomics, unittest]
import ../src/ctf/labels

include ../src/ctf/server

var
  seenUpload, seenCall, seenAck, seenLobby: Atomic[uint64]

proc consumeUpload(
  websocket: WebSocket,
  seat: int,
  packet: ModuleUploadPacket,
) {.gcsafe.} =
  doAssert seat == 0
  doAssert packet.wasm == "wasm"
  seenUpload.store(packet.uploadId)

proc consumeCall(
  websocket: WebSocket,
  seat: int,
  packet: PlayCallPacket,
) {.gcsafe.} =
  doAssert seat == 0
  doAssert packet.callBytes == "{}"
  seenCall.store(packet.proposalId)

proc consumeAck(
  websocket: WebSocket,
  seat: int,
  packet: StatusAckPacket,
) {.gcsafe.} =
  doAssert seat == 0
  seenAck.store(packet.mark)

proc consumeLobby(
  websocket: WebSocket,
  seat: int,
  packet: LobbyChatSendPacket,
) {.gcsafe.} =
  doAssert seat == 0
  doAssert packet.text == "hello"
  seenLobby.store(1)

proc binaryMessage(data: string): Message =
  Message(kind: BinaryMessage, data: data)

proc playConfig(control: SlotControl): GameConfig =
  result = defaultGameConfig()
  result.season2Shell = true
  result.slots = @[PlayerSlotConfig(control: control)]

proc bytes(value: string): seq[uint8] =
  for byte in value:
    result.add(uint8(byte))

suite "server play receive arm":
  setup:
    initAppState()
    registerPlayModuleUploadConsumer(consumeUpload)
    registerPlayCallConsumer(consumeCall)
    registerPlayStatusAckConsumer(consumeAck)
    registerPlayLobbyChatConsumer(consumeLobby)
    seenUpload.store(0)
    seenCall.store(0)
    seenAck.store(0)
    seenLobby.store(0)

  test "play packets reach registered seams and malformed bytes reject":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](1)
    check ws.registerPlayerWebSocket("play", 0, "")

    websocketHandler(ws, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 7, wasm: "wasm").encodePacket()))
    websocketHandler(ws, MessageEvent, binaryMessage(
      PlayCallPacket(proposalId: 8, callBytes: "{}").encodePacket()))
    websocketHandler(ws, MessageEvent, binaryMessage(
      StatusAckPacket(mark: 9).encodePacket()))
    websocketHandler(ws, MessageEvent, binaryMessage(
      LobbyChatSendPacket(text: "hello").encodePacket()))
    check seenUpload.load == 7
    check seenCall.load == 8
    check seenAck.load == 9
    check seenLobby.load == 1

    let rejectedBefore = appState.playProtocolRejected
    websocketHandler(ws, MessageEvent, binaryMessage("\xA0\x02"))
    websocketHandler(ws, MessageEvent, binaryMessage("\x80"))
    check appState.playProtocolRejected == rejectedBefore + 2

  test "play input and ready are ignored with telemetry but Sprite chat passes":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](2)
    check ws.registerPlayerWebSocket("play", 0, "")
    websocketHandler(ws, MessageEvent,
      binaryMessage(blobFromSpriteMask(0xff)))
    websocketHandler(ws, MessageEvent,
      binaryMessage(blobFromSpriteReady()))
    check appState.inputMasks[ws] == 0
    check not appState.playerReady[ws]
    check appState.playSpriteInputIgnored == 1
    check appState.playSpriteReadyIgnored == 1

    websocketHandler(ws, MessageEvent,
      binaryMessage(blobFromSpriteChat("x")))
    check appState.chatMessages[ws] == "x"

  test "play debug sprites are ignored whether leading or embedded":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](7)
    check ws.registerPlayerWebSocket("play", 0, "")

    let leading = blobFromSpriteDebugSprites(@[1'u8, 2, 3])
    check leading.classifyPlaySeatMessage().kind == prIgnoredSpriteDebug
    websocketHandler(ws, MessageEvent, binaryMessage(leading))
    check appState.playSpriteDebugIgnored == 1
    check appState.playerViewers[ws].pendingDebugSprites.len == 0

    let embedded =
      blobFromSpriteChat("debug-free") &
      blobFromSpriteDebugSprites(@[4'u8, 5, 6]) &
      blobFromSpriteDebugSprites(bytes(PolicyPageMagic & "page"))
    websocketHandler(ws, MessageEvent, binaryMessage(embedded))

    check appState.chatMessages[ws] == "debug-free"
    check appState.playSpriteDebugIgnored == 2
    check appState.playerViewers[ws].pendingDebugSprites.len == 0
    check ws notin appState.policyPageFlashes

  test "input seats retain embedded debug sprite and reflash behavior":
    appState.config = playConfig(scInput)
    let ws = cast[WebSocket](8)
    check ws.registerPlayerWebSocket("input", 0, "")
    let embedded =
      blobFromSpriteChat("legacy-debug") &
      blobFromSpriteDebugSprites(@[4'u8, 5, 6]) &
      blobFromSpriteDebugSprites(bytes(PolicyPageMagic & "page"))

    websocketHandler(ws, MessageEvent, binaryMessage(embedded))

    check appState.chatMessages[ws] == "legacy-debug"
    check appState.playerViewers[ws].pendingDebugSprites == @[@[4'u8, 5, 6]]
    check appState.policyPageFlashes[ws] == "page"
    check appState.playSpriteDebugIgnored == 0

  test "embedded Sprite input is ignored on a play seat while chat lands":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](4)
    check ws.registerPlayerWebSocket("play", 0, "")
    let chatThenMask =
      blobFromSpriteChat("embedded") & blobFromSpriteMask(0x5a)

    websocketHandler(ws, MessageEvent, binaryMessage(chatThenMask))

    check appState.chatMessages[ws] == "embedded"
    check appState.inputMasks[ws] == 0
    check appState.inputPressedMasks[ws] == 0
    check appState.playSpriteInputIgnored == 1

  test "embedded Sprite input stays active on a gate-on all-input seat":
    appState.config = playConfig(scInput)
    let ws = cast[WebSocket](5)
    check ws.registerPlayerWebSocket("input", 0, "")
    let chatThenMask =
      blobFromSpriteChat("legacy") & blobFromSpriteMask(0x5a)

    websocketHandler(ws, MessageEvent, binaryMessage(chatThenMask))

    check appState.chatMessages[ws] == "legacy"
    check appState.inputMasks[ws] == 0x5a
    check appState.inputPressedMasks[ws] == 0x5a
    check appState.playSpriteInputIgnored == 0

  test "sprites-off remains a strict play-seat rejection":
    # Design section 4.3's exact accepted Sprite-opcode list deliberately
    # excludes the 0x87 sprites-off extension.
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](6)
    check ws.registerPlayerWebSocket("play", 0, "")
    let classified = "\x87".classifyPlaySeatMessage()
    check classified.kind == prRejected
    check classified.rejection == prrUnknownOpcode

    websocketHandler(ws, MessageEvent, binaryMessage("\x87"))

    check appState.playProtocolRejected == 1

  test "gate-on all-input stays on the legacy Sprite path":
    appState.config = playConfig(scInput)
    let ws = cast[WebSocket](3)
    check ws.registerPlayerWebSocket("input", 0, "")
    websocketHandler(ws, MessageEvent,
      binaryMessage(blobFromSpriteMask(0x5a)))
    websocketHandler(ws, MessageEvent,
      binaryMessage(blobFromSpriteReady()))
    check appState.inputMasks[ws] == 0x5a
    check appState.playerReady[ws]
    check appState.playSpriteInputIgnored == 0
    check appState.playSpriteReadyIgnored == 0

  test "player upgrade selects play limits only for a configured play seat":
    var config = playConfig(scPlay)
    check config.playerUpgradeUsesPlaySeatTransport(0)
    check not config.playerUpgradeUsesPlaySeatTransport(-1)
    check not config.playerUpgradeUsesPlaySeatTransport(1)

    config.slots[0].control = scInput
    check not config.playerUpgradeUsesPlaySeatTransport(0)
    config.slots[0].control = scPlay
    config.season2Shell = false
    check not config.playerUpgradeUsesPlaySeatTransport(0)

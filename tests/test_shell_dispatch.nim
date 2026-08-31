## Server-level proof that the play leading-byte switch precedes Sprite parsing.

import std/[atomics, unittest]
import ../src/ctf/labels
import ../src/shell/types
import ./raw_websocket_client

include ../src/ctf/server

var
  seenUpload, seenCall, seenAck, seenLobby: Atomic[uint64]
  uploadDeliveries, callDeliveries, seenUploadBytes: Atomic[int]

proc consumeUpload(
  websocket: WebSocket,
  seat: int,
  packet: ModuleUploadPacket,
) {.gcsafe.} =
  doAssert seat == 0
  seenUpload.store(packet.uploadId)
  seenUploadBytes.store(packet.wasm.len)
  discard uploadDeliveries.fetchAdd(1)

proc consumeCall(
  websocket: WebSocket,
  seat: int,
  packet: PlayCallPacket,
) {.gcsafe.} =
  doAssert seat == 0
  seenCall.store(packet.proposalId)
  discard callDeliveries.fetchAdd(1)

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
    uploadDeliveries.store(0)
    callDeliveries.store(0)
    seenUploadBytes.store(0)

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
    check seenUpload.load == 0
    check seenCall.load == 0
    check seenAck.load == 9
    check seenLobby.load == 1
    drainPlayIngressAtTickBoundary()
    check seenUpload.load == 7
    check seenCall.load == 8

    let rejectedBefore = appState.playProtocolRejected
    websocketHandler(ws, MessageEvent, binaryMessage("\xA0\x02"))
    websocketHandler(ws, MessageEvent, binaryMessage("\x80"))
    check appState.playProtocolRejected == rejectedBefore + 2

  test "newest authenticated socket invalidates queued work from its predecessor":
    appState.config = playConfig(scPlay)
    let
      oldSocket = cast[WebSocket](11)
      newSocket = cast[WebSocket](12)
    check oldSocket.registerPlayerWebSocket("play", 0, "token")
    appState.playerIndices[oldSocket] = 4
    websocketHandler(oldSocket, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 1, wasm: "old").encodePacket()))

    var
      replaced = false
      replacedSocket: WebSocket
    check newSocket.registerPlayerWebSocket(
      "play", 0, "token", replaced, replacedSocket)
    check replaced
    check replacedSocket == oldSocket
    check appState.playerIndices[newSocket] == 4
    check appState.playIngress[0].binding.generation == 2
    websocketHandler(newSocket, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 2, wasm: "new").encodePacket()))

    drainPlayIngressAtTickBoundary()
    check uploadDeliveries.load == 1
    check seenUpload.load == 2
    check appState.playIngress[0].binding.state == pssBound

    websocketHandler(oldSocket, CloseEvent, Message())
    check appState.playIngress[0].binding.state == pssBound
    websocketHandler(newSocket, CloseEvent, Message())
    check appState.playIngress[0].binding.state == pssLost
    check appState.playerIndices[newSocket] == 4

  test "per-tick upload and call caps drop deterministically":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](13)
    check ws.registerPlayerWebSocket("play", 0, "")
    for uploadId in 1'u64 .. 2'u64:
      websocketHandler(ws, MessageEvent, binaryMessage(
        ModuleUploadPacket(uploadId: uploadId, wasm: "x").encodePacket()))
    for proposalId in 1'u64 .. 3'u64:
      websocketHandler(ws, MessageEvent, binaryMessage(
        PlayCallPacket(proposalId: proposalId, callBytes: "{}").encodePacket()))

    check appState.playIngress[0].pendingCount == 3
    check appState.playIngress[0].counters.droppedUploads == 1
    check appState.playIngress[0].counters.droppedCalls == 1
    drainPlayIngressAtTickBoundary()
    check uploadDeliveries.load == 1
    check callDeliveries.load == 2

  test "upload module budget enforces limit minus one, limit, and limit plus one":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](14)
    check ws.registerPlayerWebSocket("play", 0, "")
    for uploadId in 1'u64 .. uint64(MaxModulesPerSeatPerEpisode - 1):
      websocketHandler(ws, MessageEvent, binaryMessage(
        ModuleUploadPacket(uploadId: uploadId, wasm: "").encodePacket()))
      drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].admittedModules ==
      MaxModulesPerSeatPerEpisode - 1

    websocketHandler(ws, MessageEvent, binaryMessage(
      ModuleUploadPacket(
        uploadId: uint64(MaxModulesPerSeatPerEpisode),
        wasm: "").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].admittedModules == MaxModulesPerSeatPerEpisode
    check uploadDeliveries.load == MaxModulesPerSeatPerEpisode

    let rejectedBefore = appState.playProtocolRejected
    websocketHandler(ws, MessageEvent, binaryMessage(
      ModuleUploadPacket(
        uploadId: uint64(MaxModulesPerSeatPerEpisode + 1),
        wasm: "x").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check uploadDeliveries.load == MaxModulesPerSeatPerEpisode
    check appState.playProtocolRejected == rejectedBefore + 1

  test "upload byte budget enforces limit minus one, limit, and limit plus one":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](18)
    check ws.registerPlayerWebSocket("play", 0, "")
    for uploadId in 1'u64 .. 7'u64:
      websocketHandler(ws, MessageEvent, binaryMessage(
        ModuleUploadPacket(
          uploadId: uploadId,
          wasm: newString(MaxModuleBytes)).encodePacket()))
      drainPlayIngressAtTickBoundary()
    websocketHandler(ws, MessageEvent, binaryMessage(
      ModuleUploadPacket(
        uploadId: 8,
        wasm: newString(MaxModuleBytes - 1)).encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].admittedUploadBytes ==
      uint64(MaxUploadBytesPerSeatPerEpisode - 1)

    websocketHandler(ws, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 9, wasm: "x").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].admittedUploadBytes ==
      uint64(MaxUploadBytesPerSeatPerEpisode)
    let rejectedBefore = appState.playProtocolRejected
    websocketHandler(ws, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 10, wasm: "x").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].admittedUploadBytes ==
      uint64(MaxUploadBytesPerSeatPerEpisode)
    check appState.playProtocolRejected == rejectedBefore + 1

  test "id floors reject stale and conflicting retries without a second handoff":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](15)
    check ws.registerPlayerWebSocket("play", 0, "")
    template sendAndDrain(packet: ModuleUploadPacket) =
      websocketHandler(ws, MessageEvent, binaryMessage(packet.encodePacket()))
      drainPlayIngressAtTickBoundary()

    sendAndDrain(ModuleUploadPacket(uploadId: 2, wasm: "same"))
    sendAndDrain(ModuleUploadPacket(uploadId: 2, wasm: "same"))
    sendAndDrain(ModuleUploadPacket(uploadId: 2, wasm: "different"))
    sendAndDrain(ModuleUploadPacket(uploadId: 1, wasm: "stale"))
    sendAndDrain(ModuleUploadPacket(uploadId: 3, wasm: "new"))

    check uploadDeliveries.load == 2
    check seenUpload.load == 3
    check appState.playProtocolRejected == 2

  test "status reservations backpressure before consuming a call id":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](16)
    check ws.registerPlayerWebSocket("play", 0, "")
    for proposalId in 1'u64 .. 2'u64:
      websocketHandler(ws, MessageEvent, binaryMessage(
        PlayCallPacket(proposalId: proposalId, callBytes: "{}").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].reservedStatusSlots ==
      2 * (1 + MaxLadderEntries)
    websocketHandler(ws, MessageEvent, binaryMessage(
      PlayCallPacket(proposalId: 3, callBytes: "{}").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check callDeliveries.load == 2
    check appState.playIngress[0].counters.backpressure == 1
    check appState.playIngress[0].proposalIdFloor == 2

  test "an absent lane-C consumer rejects only after tick admission":
    appState.config = playConfig(scPlay)
    playReceiveConsumers.moduleUpload = nil
    let ws = cast[WebSocket](17)
    check ws.registerPlayerWebSocket("play", 0, "")
    websocketHandler(ws, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 1, wasm: "x").encodePacket()))
    check appState.playProtocolRejected == 0
    drainPlayIngressAtTickBoundary()
    check appState.playProtocolRejected == 1

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

  test "maximum-size A0 crosses the real play socket and tick seam":
    appState.config = playConfig(scPlay)
    appState.config.closedRoster = true
    appState.config.slots[0].name = "play"
    appState.config.slots[0].token = "secret"
    configurePlayIngress(appState.config)

    var httpServer = newServer(httpHandler, websocketHandler, workerThreads = 1)
    var
      serverThread: Thread[ServerThreadArgs]
      serverPtr = cast[ptr Server](unsafeAddr httpServer)
    createThread(
      serverThread,
      serverThreadProc,
      ServerThreadArgs(
        server: serverPtr,
        address: "127.0.0.1",
        port: 8396))
    httpServer.waitUntilReady()

    let client = connectRawWebSocket(
      8396, "/player?slot=0&token=secret")
    client.sendBinary(ModuleUploadPacket(
      uploadId: 99,
      wasm: newString(MaxModuleBytes)).encodePacket())
    let deadline = epochTime() + 10.0
    while seenUpload.load != 99 and epochTime() < deadline:
      drainPlayIngressAtTickBoundary()
      sleep(5)

    check seenUpload.load == 99
    check seenUploadBytes.load == MaxModuleBytes
    check uploadDeliveries.load == 1
    client.close()
    httpServer.close()
    joinThread(serverThread)

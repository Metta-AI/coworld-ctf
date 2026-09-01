## Server-level proof that the play leading-byte switch precedes Sprite parsing.

import std/[atomics, os, unittest]
import ../src/ctf/labels
import ../src/ctf/sim_types as ctfTypes
import ../src/shell/episode
import ../src/shell/types
import ../src/shell/types as shellTypes
const DispatchRuntimeAvailable =
  compileOption("threads") and static(getEnv("WASMTIME_C_API")).len > 0
when DispatchRuntimeAvailable:
  type TestWasmByteVec {.bycopy.} = object
    size: csize_t
    data: ptr byte

  proc testWat2Wasm(wat: cstring; watLen: csize_t;
                    output: ptr TestWasmByteVec): pointer
      {.importc: "wasmtime_wat2wasm".}
  proc testWasmBytesDelete(output: ptr TestWasmByteVec)
      {.importc: "wasm_byte_vec_delete".}
import ./raw_websocket_client

include ../src/ctf/server

var
  seenUpload, seenCall, seenAck, seenLobby: Atomic[uint64]
  uploadDeliveries, callDeliveries, seenUploadBytes: Atomic[int]
  ackDeliveries, ackRetiredSlots: Atomic[int]
  ackRetiredProposal: Atomic[uint64]

proc consumeUpload(
  websocket: WebSocket,
  seat: int,
  generation: uint64,
  packet: ModuleUploadPacket,
) {.gcsafe.} =
  doAssert seat == 0
  doAssert generation > 0
  seenUpload.store(packet.uploadId)
  seenUploadBytes.store(packet.wasm.len)
  discard uploadDeliveries.fetchAdd(1)

proc consumeCall(
  websocket: WebSocket,
  seat: int,
  generation: uint64,
  packet: PlayCallPacket,
) {.gcsafe.} =
  doAssert seat == 0
  doAssert generation > 0
  seenCall.store(packet.proposalId)
  discard callDeliveries.fetchAdd(1)

proc consumeAck(
  websocket: WebSocket,
  seat: int,
  packet: StatusAckPacket,
): PlayIngressFeedback {.gcsafe.} =
  doAssert seat == 0
  seenAck.store(packet.mark)
  discard ackDeliveries.fetchAdd(1)
  result.statusSlotsRetired = ackRetiredSlots.load
  let proposalId = ackRetiredProposal.load
  if proposalId != 0:
    result.retiredProposalIds = @[proposalId]

proc consumeLobby(
  websocket: WebSocket,
  seat: int,
  packet: LobbyChatSendPacket,
) {.gcsafe.} =
  doAssert seat == 0
  doAssert packet.text == "hello"
  seenLobby.store(1)

proc consumeKick(seat: int): seq[ShellAnnotation] {.gcsafe.} =
  @[ShellAnnotation(
    tick: 12, seat: uint8(seat), kind: akInstallSafeIntent,
    installGeneration: 0, installReason: "kicked",
    safeBytes: "{\"kind\":\"hold\"}")]

proc binaryMessage(data: string): Message =
  Message(kind: BinaryMessage, data: data)

proc playConfig(control: SlotControl): GameConfig =
  result = defaultGameConfig()
  result.season2Shell = true
  result.slots = @[PlayerSlotConfig(control: control)]

proc bytes(value: string): seq[uint8] =
  for byte in value:
    result.add(uint8(byte))

when DispatchRuntimeAvailable:
  proc validPlayModuleBytes(): string =
    let wat = readFile("tests/fixtures/shell/wasm/valid.wat")
      .replace("[\\22br\\22]", "[\\22ctf\\22]")
      .replace("i32.const 87 call", "i32.const 88 call")
    var output: TestWasmByteVec
    let error = testWat2Wasm(wat.cstring, wat.len.csize_t, addr output)
    doAssert error == nil
    defer: testWasmBytesDelete(addr output)
    result = newString(output.size.int)
    if output.size > 0:
      copyMem(addr result[0], output.data, output.size)

suite "server play receive arm":
  setup:
    initAppState()
    registerPlayModuleUploadConsumer(consumeUpload)
    registerPlayCallConsumer(consumeCall)
    registerPlayStatusAckConsumer(consumeAck)
    registerPlayLobbyChatConsumer(consumeLobby)
    registerPlaySeatKickConsumer(consumeKick)
    seenUpload.store(0)
    seenCall.store(0)
    seenAck.store(0)
    seenLobby.store(0)
    uploadDeliveries.store(0)
    callDeliveries.store(0)
    seenUploadBytes.store(0)
    ackDeliveries.store(0)
    ackRetiredSlots.store(0)
    ackRetiredProposal.store(0)

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
    check seenAck.load == 0
    check seenLobby.load == 1
    drainPlayIngressAtTickBoundary()
    check seenUpload.load == 7
    check seenCall.load == 8
    check seenAck.load == 9

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
    # The rebind consumes the old socket's tick allowance. The next real
    # tick drain resets it; only then does the replacement get fresh service.
    drainPlayIngressAtTickBoundary()
    check uploadDeliveries.load == 0
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

  test "rebind does not refresh the per-tick classification byte budget":
    appState.config = playConfig(scPlay)
    let
      oldSocket = cast[WebSocket](25)
      newSocket = cast[WebSocket](26)
      maximumUpload = ModuleUploadPacket(
        uploadId: 1, wasm: newString(MaxModuleBytes)).encodePacket()
    check oldSocket.registerPlayerWebSocket("play", 0, "token")
    websocketHandler(oldSocket, MessageEvent, binaryMessage(maximumUpload))

    var
      replaced = false
      replacedSocket: WebSocket
    check newSocket.registerPlayerWebSocket(
      "play", 0, "token", replaced, replacedSocket)
    check replaced
    websocketHandler(newSocket, MessageEvent, binaryMessage(maximumUpload))

    # Two maximum uploads exceed the one-tick classification byte cap even
    # though the authenticated socket changed between them.
    check appState.playIngress[0].binding.state == pssLost
    check appState.playIngress[0].pendingCount == 0

  test "rebind does not refresh the per-tick upload queue slot":
    appState.config = playConfig(scPlay)
    let
      oldSocket = cast[WebSocket](27)
      newSocket = cast[WebSocket](28)
    check oldSocket.registerPlayerWebSocket("play", 0, "token")
    websocketHandler(oldSocket, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 1, wasm: "old").encodePacket()))

    var
      replaced = false
      replacedSocket: WebSocket
    check newSocket.registerPlayerWebSocket(
      "play", 0, "token", replaced, replacedSocket)
    check replaced
    check appState.playIngress[0].pendingCount == 0
    websocketHandler(newSocket, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 2, wasm: "same-tick").encodePacket()))
    check appState.playIngress[0].pendingCount == 0
    check appState.playIngress[0].counters.droppedUploads == 1

    # The tick drain resets the spent allowance even though stale eviction
    # left no pending payload to admit.
    drainPlayIngressAtTickBoundary()
    websocketHandler(newSocket, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 2, wasm: "next-tick").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check uploadDeliveries.load == 1
    check seenUpload.load == 2

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

  test "ack feedback releases upload capacity before same-tick call admission":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](19)
    check ws.registerPlayerWebSocket("play", 0, "")
    websocketHandler(ws, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 1, wasm: "x").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].reservedStatusSlots == 2

    ackRetiredSlots.store(2)
    websocketHandler(ws, MessageEvent, binaryMessage(
      PlayCallPacket(proposalId: 1, callBytes: "{}").encodePacket()))
    websocketHandler(ws, MessageEvent, binaryMessage(
      StatusAckPacket(mark: 1).encodePacket()))
    drainPlayIngressAtTickBoundary()

    check ackDeliveries.load == 1
    check callDeliveries.load == 1
    check appState.playIngress[0].reservedStatusSlots ==
      1 + MaxLadderEntries

  test "a full upload budget can call after its reservations retire":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](20)
    check ws.registerPlayerWebSocket("play", 0, "")
    for uploadId in 1'u64 .. uint64(MaxModulesPerSeatPerEpisode):
      websocketHandler(ws, MessageEvent, binaryMessage(
        ModuleUploadPacket(uploadId: uploadId, wasm: "").encodePacket()))
      drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].reservedStatusSlots == 32

    ackRetiredSlots.store(32)
    websocketHandler(ws, MessageEvent, binaryMessage(
      StatusAckPacket(mark: 32).encodePacket()))
    websocketHandler(ws, MessageEvent, binaryMessage(
      PlayCallPacket(proposalId: 1, callBytes: "{}").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check callDeliveries.load == 1
    check appState.playIngress[0].reservedStatusSlots ==
      1 + MaxLadderEntries

  test "call payload eviction waits for explicit complete retirement feedback":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](21)
    check ws.registerPlayerWebSocket("play", 0, "")
    websocketHandler(ws, MessageEvent, binaryMessage(
      PlayCallPacket(proposalId: 7, callBytes: "{}").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].hasCallPayload(7)

    ackRetiredSlots.store(1)
    websocketHandler(ws, MessageEvent, binaryMessage(
      StatusAckPacket(mark: 1).encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].hasCallPayload(7)

    ackRetiredSlots.store(MaxLadderEntries)
    ackRetiredProposal.store(7)
    websocketHandler(ws, MessageEvent, binaryMessage(
      StatusAckPacket(mark: 2).encodePacket()))
    drainPlayIngressAtTickBoundary()
    check not appState.playIngress[0].hasCallPayload(7)
    check appState.playIngress[0].reservedStatusSlots == 0

  test "over-retirement clamps and counts instead of raising in production":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](23)
    check ws.registerPlayerWebSocket("play", 0, "")
    websocketHandler(ws, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 1, wasm: "x").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].reservedStatusSlots == 2

    applyPlayIngressFeedback(0, PlayIngressFeedback(statusSlotsRetired: 99))
    check appState.playIngress[0].reservedStatusSlots == 0
    check appState.playIngress[0].counters.feedbackErrors == 1
    check appState.playIngressFeedbackErrors == 1

    applyPlayIngressFeedback(99, PlayIngressFeedback(statusSlotsRetired: 1))
    check appState.playIngressFeedbackErrors == 2

    expect ValueError:
      appState.playIngress[0].applyPlayIngressFeedbackStrict(
        PlayIngressFeedback(statusSlotsRetired: 1))

  test "unknown retired proposal is ignored and counted":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](24)
    check ws.registerPlayerWebSocket("play", 0, "")
    websocketHandler(ws, MessageEvent, binaryMessage(
      PlayCallPacket(proposalId: 7, callBytes: "{}").encodePacket()))
    drainPlayIngressAtTickBoundary()
    check appState.playIngress[0].hasCallPayload(7)

    applyPlayIngressFeedback(0, PlayIngressFeedback(
      retiredProposalIds: @[999'u64]))
    check appState.playIngress[0].hasCallPayload(7)
    check appState.playIngress[0].counters.feedbackErrors == 1
    check appState.playIngressFeedbackErrors == 1

    expect ValueError:
      appState.playIngress[0].applyPlayIngressFeedbackStrict(
        PlayIngressFeedback(retiredProposalIds: @[999'u64]))

  test "StatusAck coalesces to the greatest mark and runs once on the tick":
    appState.config = playConfig(scPlay)
    let ws = cast[WebSocket](22)
    check ws.registerPlayerWebSocket("play", 0, "")
    for mark in [5'u64, 3'u64, 8'u64]:
      websocketHandler(ws, MessageEvent, binaryMessage(
        StatusAckPacket(mark: mark).encodePacket()))
    check seenAck.load == 0
    drainPlayIngressAtTickBoundary()
    check seenAck.load == 8
    check ackDeliveries.load == 1

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

  test "game-thread replay batch emits lifecycle transcript call and annotation":
    let path = getTempDir() / ("shell-server-replay-batch-" &
      $getCurrentProcessId() & ".bitreplay")
    var config = defaultGameConfig()
    config.season2Shell = true
    config.slots = @[
      PlayerSlotConfig(name: "play", control: scPlay),
      PlayerSlotConfig(name: "input", control: scInput)]
    appState.config = config
    configurePlayIngress(config)
    appState.pendingLifecycleRecords = @[
      PendingLifecycleRecord(kind: lrDisconnect, seat: 1, playerIndex: 1),
      PendingLifecycleRecord(kind: lrRebind, seat: 1, playerIndex: 1),
      PendingLifecycleRecord(kind: lrKick, seat: 1, playerIndex: 1)]
    queueLobbyChatRecord(LobbyChatRecord(
      replayTimeMs: 7, ordinal: 1, seat: 0, team: 0, text: "ready"))
    queuePlayCallRecord(PlayCallRecord(
      replayTimeMs: 7, seat: 0, epoch: 1,
      ladderBytes: "{\"plays\":[]}", entries: @[]))
    queueShellAnnotation(ShellAnnotation(
      tick: 1, seat: 0, kind: akInstallSafeIntent,
      installGeneration: 0, installReason: "activation",
      safeBytes: "{\"kind\":\"hold\"}"))
    try:
      var
        writer = ctfReplayCodec.openReplayWriter(
          path, config.configJson(), CtfReplaySpec,
          shellEpisode = true, shellSeatCount = config.slots.len,
          openedAtMs = 1_735_689_600_000'u64)
        simServer = initSimServer(config)
      writer.drainShellReplayRecords(simServer, 7)
      writer.closeReplayWriter()
      let detailed = loadCtfReplay(path)
      check detailed.shell.lifecycle.len == 3
      check detailed.shell.lifecycle[0].kind == lrDisconnect
      check detailed.shell.lifecycle[1].kind == lrRebind
      check detailed.shell.lifecycle[2].kind == lrKick
      check detailed.shell.lobbyTranscript.len == 1
      check detailed.shell.calls.len == 1
      check detailed.shell.annotations.len == 1
      check detailed.shell.manifestVerified
    finally:
      if fileExists(path):
        removeFile(path)

  test "input disconnect and lobby rebind retain one stable sim row":
    var config = defaultGameConfig()
    config.season2Shell = true
    config.minPlayers = 3
    config.slots = @[
      PlayerSlotConfig(name: "play", control: scPlay),
      PlayerSlotConfig(name: "input", control: scInput),
      PlayerSlotConfig(name: "waiting", control: scInput)]
    appState.config = config
    configurePlayIngress(config)
    var simServer = initSimServer(config)
    discard simServer.addPlayer("play", 0, "", trusted = true)
    discard simServer.addPlayer("input", 1, "", trusted = true)
    let oldSocket = cast[WebSocket](701)
    appState.playerIndices[oldSocket] = 1
    appState.playerSlots[oldSocket] = 1
    appState.playerAddresses[oldSocket] = "input"
    appState.seatPlayerIndices[1] = 1
    var prevInputs = newSeq[InputState](2)

    check simServer.retainShellSocketLoss(oldSocket, prevInputs)
    check simServer.players.len == 2
    check appState.seatTombstones[1].presence == spReconnectable
    check appState.pendingLifecycleRecords.len == 1

    appState.shellEpisodeInLobby = true
    let replacement = cast[WebSocket](702)
    check replacement.registerPlayerWebSocket("input", 1, "")
    check appState.playerIndices[replacement] == 1
    check simServer.players.len == 2
    check appState.seatTombstones[1].presence == spConnected
    check appState.pendingLifecycleRecords.len == 2

    check simServer.terminallyTombstoneShellSeat(replacement, prevInputs)
    check simServer.players.len == 2
    check appState.seatTombstones[1].presence == spTerminal
    check appState.pendingLifecycleRecords.len == 3

suite "server play outbound arm":
  setup:
    initAppState()

  test "control envelopes and durable status retirement are byte-exact":
    var seat: PlayOutboundSeat[int]
    seat.bindOutbound(7, generation = 5, transcriptMark = 9)
    check seat.retainStatus(StatusEntry(
      kind: skModuleAccepted, originGeneration: 5, acceptedUploadId: 7),
      reservationSlots = 1)
    check seat.retainCallRefusal(5, 8, "nope", spontaneous = false,
      reservationSlots = 1)
    let expectedView =
      "{\"counters\":{\"backpressure\":0,\"dropped_calls\":0," &
      "\"dropped_chat\":0,\"dropped_uploads\":0,\"faults_dropped\":0}," &
      "\"gen\":\"5\",\"schema\":\"control_view\",\"statuses\":[" &
      "{\"gen\":\"5\",\"kind\":\"module_accepted\",\"ordinal\":\"1\"," &
      "\"upload_id\":\"7\"}," &
      "{\"gen\":\"5\",\"kind\":\"call_rejected\",\"ordinal\":\"2\"," &
      "\"proposal_id\":\"8\",\"reason\":\"nope\"}],\"v\":1}"
    check seat.controlViewEnvelope() == expectedView
    check controlContextEnvelope(PlayContextRecovery(
      generation: 5, epoch: 0, uploadIdFloor: 7, proposalIdFloor: 8,
      modulesLeft: 15, uploadBytesLeft: 123, ackMark: 0,
      lobbyTranscriptMark: 9)) ==
      "{\"ack_mark\":\"0\",\"budgets\":{\"modules_left\":15," &
      "\"upload_bytes_left\":123},\"epoch\":\"0\",\"floors\":{" &
      "\"proposal_id\":\"8\",\"upload_id\":\"7\"},\"gen\":\"5\"," &
      "\"lobby_transcript_mark\":\"9\",\"schema\":\"control_context\"," &
      "\"v\":1}"

    check not seat.acknowledge(3).valid
    check seat.retainedStatusCount == 2
    let retired = seat.acknowledge(2)
    check retired.valid
    check retired.statusSlotsRetired == 2
    check retired.retiredProposalIds == @[8'u64]
    check seat.retainedStatusCount == 0

  test "spontaneous refusals are bounded by the 16 fault-reserve slots":
    var seat: PlayOutboundSeat[int]
    seat.bindOutbound(7, generation = 1, transcriptMark = 0)
    for id in 1'u64 .. uint64(StatusFaultReserve):
      check seat.retainModuleRefusal(1, id, "per_tick_upload_cap")
    check not seat.retainModuleRefusal(1, 99, "per_tick_upload_cap")
    check seat.retainedStatusCount == StatusFaultReserve
    check seat.counters.faultsDropped == 1

  test "production registration is conjunctively gate-conditioned":
    var config = playConfig(scInput)
    appState.config = config
    configurePlayIngress(config)
    installProductionPlayConsumers(config)
    check playReceiveConsumers.moduleUpload == nil
    check playReceiveConsumers.playCall == nil
    check playReceiveConsumers.statusAck == nil
    check playReceiveConsumers.lobbyChat == nil

    config.slots[0].control = scPlay
    appState.config = config
    configurePlayIngress(config)
    installProductionPlayConsumers(config)
    check playReceiveConsumers.moduleUpload != nil
    check playReceiveConsumers.playCall != nil
    check playReceiveConsumers.statusAck != nil
    check playReceiveConsumers.lobbyChat != nil

  test "live episode consumers retain admission, completion, and call outcomes":
    when DispatchRuntimeAvailable:
      let config = playConfig(scPlay)
      appState.config = config
      configurePlayIngress(config)
      installProductionPlayConsumers(config)
      let websocket = cast[WebSocket](801)
      check websocket.registerPlayerWebSocket("play", 0, "")
      var simServer = initSimServer(config)
      var episode: FirstLightEpisode
      episode.resetFirstLightForSim(false, config, simServer, "test")
      defer:
        episode.closeFirstLightEpisode()

      websocketHandler(websocket, MessageEvent, binaryMessage(
        ModuleUploadPacket(
          uploadId: 7, wasm: validPlayModuleBytes()).encodePacket()))
      drainPlayIngressAtTickBoundary(episode, 1)
      check appState.playOutbound[0].retainedStatusCount == 1
      check "module_accepted" in appState.playOutbound[0].statusBytes[0]
      check "\"gen\":\"1\"" in appState.playOutbound[0].statusBytes[0]

      var tick = 1'u32
      while appState.playOutbound[0].retainedStatusCount < 2 and tick < 5000:
        let output = episode.step([], tick)
        retainProductionModuleStatuses(output.moduleStatuses)
        if output.moduleStatuses.len == 0:
          sleep(1)
        inc tick
      check appState.playOutbound[0].retainedStatusCount == 2
      let moduleStatuses = appState.playOutbound[0].statusBytes.join("\n")
      check "module_ready" in moduleStatuses
      check "\"name\":\"alpha\"" in moduleStatuses
      check "\"sha256\":" in moduleStatuses

      websocketHandler(websocket, MessageEvent, binaryMessage(
        PlayCallPacket(
          proposalId: 8,
          callBytes: "{\"plays\":[{\"entry_id\":\"alpha\"," &
            "\"params\":{},\"play\":\"alpha\"}]}"
        ).encodePacket()))
      drainPlayIngressAtTickBoundary(episode, tick)
      let statuses = appState.playOutbound[0].statusBytes.join("\n")
      check appState.playOutbound[0].retainedStatusCount == 3
      check "call_accepted" in statuses
      check "\"proposal_id\":\"8\"" in statuses
      check appState.playIngress[0].snapshot.reservedStatusSlots ==
        2 + 1 + MaxLadderEntries
      check appState.playIngress[0].hasCallPayload(8)

      websocketHandler(websocket, MessageEvent, binaryMessage(
        StatusAckPacket(mark: 3).encodePacket()))
      drainPlayIngressAtTickBoundary(episode, tick + 1)
      check appState.playOutbound[0].retainedStatusCount == 0
      check appState.playIngress[0].snapshot.reservedStatusSlots ==
        MaxLadderEntries
      check appState.playIngress[0].hasCallPayload(8)

      # INTERIM boundary awaiting lane A's retune-completion channel. Even
      # after the immediate call statuses are acked, two retained 16-slot
      # retune sets leave 32 slots occupied; a third 17-slot admission would
      # require 49 of the 48 regular slots and must visibly backpressure.
      websocketHandler(websocket, MessageEvent, binaryMessage(
        PlayCallPacket(
          proposalId: 9,
          callBytes: "{\"plays\":[{\"entry_id\":\"alpha\"," &
            "\"params\":{},\"play\":\"alpha\"}]}"
        ).encodePacket()))
      drainPlayIngressAtTickBoundary(episode, tick + 2)
      check "call_accepted" in appState.playOutbound[0].statusBytes.join("\n")
      websocketHandler(websocket, MessageEvent, binaryMessage(
        StatusAckPacket(mark: 4).encodePacket()))
      drainPlayIngressAtTickBoundary(episode, tick + 3)
      check appState.playIngress[0].snapshot.reservedStatusSlots ==
        2 * MaxLadderEntries
      check appState.playIngress[0].hasCallPayload(8)
      check appState.playIngress[0].hasCallPayload(9)

      websocketHandler(websocket, MessageEvent, binaryMessage(
        PlayCallPacket(
          proposalId: 10,
          callBytes: "{\"plays\":[{\"entry_id\":\"alpha\"," &
            "\"params\":{},\"play\":\"alpha\"}]}"
        ).encodePacket()))
      drainPlayIngressAtTickBoundary(episode, tick + 4)
      check "status_backpressure" in
        appState.playOutbound[0].statusBytes.join("\n")
      check not appState.playIngress[0].hasCallPayload(10)

  test "ten thousand cross-tick uploads stay bounded after episode quota":
    when DispatchRuntimeAvailable:
      let config = playConfig(scPlay)
      appState.config = config
      configurePlayIngress(config)
      installProductionPlayConsumers(config)
      let websocket = cast[WebSocket](804)
      check websocket.registerPlayerWebSocket("play", 0, "")
      var simServer = initSimServer(config)
      var episode: FirstLightEpisode
      episode.resetFirstLightForSim(false, config, simServer, "load-test")
      defer:
        episode.closeFirstLightEpisode()

      let started = epochTime()
      for uploadId in 1'u64 .. 10_000'u64:
        websocketHandler(websocket, MessageEvent, binaryMessage(
          ModuleUploadPacket(uploadId: uploadId, wasm: "bad").encodePacket()))
        drainPlayIngressAtTickBoundary(episode, uint32(uploadId))
        let output = episode.step([], uint32(uploadId))
        retainProductionModuleStatuses(output.moduleStatuses)
      let elapsedMs = (epochTime() - started) * 1000.0
      echo "PLAY_UPLOAD_LOAD iterations=10000 elapsed_ms=", elapsedMs

      let snapshot = appState.playIngress[0].snapshot
      let statuses = appState.playOutbound[0].statusBytes.join("\n")
      check snapshot.admittedModules == MaxModulesPerSeatPerEpisode
      check snapshot.admittedUploadBytes ==
        uint64(MaxModulesPerSeatPerEpisode * 3)
      check statuses.count("module_accepted") == MaxModulesPerSeatPerEpisode
      check appState.playOutbound[0].retainedStatusCount <=
        2 * MaxModulesPerSeatPerEpisode + StatusFaultReserve
      check appState.playOutbound[0].counters.faultsDropped ==
        uint32(10_000 - 2 * MaxModulesPerSeatPerEpisode)

  test "non-runtime episode verdicts remain visible terminal refusals":
    when not DispatchRuntimeAvailable:
      let config = playConfig(scPlay)
      appState.config = config
      configurePlayIngress(config)
      installProductionPlayConsumers(config)
      let websocket = cast[WebSocket](805)
      check websocket.registerPlayerWebSocket("play", 0, "")
      var episode = FirstLightEpisode(enabled: true, rosterSize: 1)
      websocketHandler(websocket, MessageEvent, binaryMessage(
        ModuleUploadPacket(uploadId: 7, wasm: "wasm").encodePacket()))
      websocketHandler(websocket, MessageEvent, binaryMessage(
        PlayCallPacket(proposalId: 8, callBytes: "{}").encodePacket()))
      drainPlayIngressAtTickBoundary(episode, 1)
      let statuses = appState.playOutbound[0].statusBytes.join("\n")
      check statuses.count("runtimeUnavailable") == 2

  test "every deterministic ingress refusal mints a visible status":
    let config = playConfig(scPlay)
    appState.config = config
    configurePlayIngress(config)
    installProductionPlayConsumers(config)
    let websocket = cast[WebSocket](802)
    check websocket.registerPlayerWebSocket("play", 0, "")
    websocketHandler(websocket, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 1, wasm: "a").encodePacket()))
    websocketHandler(websocket, MessageEvent, binaryMessage(
      ModuleUploadPacket(uploadId: 2, wasm: "b").encodePacket()))
    websocketHandler(websocket, MessageEvent, binaryMessage("\xA1\x01"))
    drainPlayIngressAtTickBoundary()
    let statuses = appState.playOutbound[0].statusBytes.join("\n")
    check "per_tick_upload_cap" in statuses
    check "malformed_packet" in statuses

  test "episode upload budget refusal is durable and visible to the policy":
    let config = playConfig(scPlay)
    appState.config = config
    configurePlayIngress(config)
    installProductionPlayConsumers(config)
    let websocket = cast[WebSocket](803)
    check websocket.registerPlayerWebSocket("play", 0, "")
    for uploadId in 1'u64 .. uint64(MaxModulesPerSeatPerEpisode + 1):
      websocketHandler(websocket, MessageEvent, binaryMessage(
        ModuleUploadPacket(uploadId: uploadId, wasm: "w").encodePacket()))
      drainPlayIngressAtTickBoundary()
    let statuses = appState.playOutbound[0].statusBytes.join("\n")
    check "module_budget_exhausted" in statuses

  test "live socket sends B0 then B1 and rebind replays B2 from ordinal one":
    var config = defaultGameConfig()
    config.season2Shell = true
    config.closedRoster = true
    config.minPlayers = 2
    config.startWaitTicks = 0
    config.lobbyChatTicks = 100
    config.slots = @[
      PlayerSlotConfig(name: "play", token: "secret", team: Red,
        control: scPlay),
      PlayerSlotConfig(name: "input", token: "input", team: Blue,
        control: scInput)]
    appState.config = config
    configurePlayIngress(config)
    installProductionPlayConsumers(config)

    var httpServer = newServer(httpHandler, websocketHandler, workerThreads = 1)
    var
      serverThread: Thread[ServerThreadArgs]
      serverPtr = cast[ptr Server](unsafeAddr httpServer)
    createThread(serverThread, serverThreadProc, ServerThreadArgs(
      server: serverPtr, address: "127.0.0.1", port: 8397))
    httpServer.waitUntilReady()
    let first = connectRawWebSocket(8397, "/player?slot=0&token=secret")
    let firstBindDeadline = epochTime() + 5.0
    while epochTime() < firstBindDeadline:
      var bound = false
      withLock appState.lock:
        bound = appState.playOutbound.len > 0 and
          appState.playOutbound[0].currentSocket.isSome
      if bound:
        break
      sleep(5)
    var simServer = initSimServer(config)
    discard simServer.addPlayer("play", 0, "secret", trusted = true)
    discard simServer.addPlayer("input", 1, "input", trusted = true)
    let noInputs: seq[InputState] = @[]
    simServer.step(noInputs, noInputs)
    var firstSocket: WebSocket
    withLock appState.lock:
      for socket, slot in appState.playerSlots.pairs:
        if slot == 0:
          firstSocket = socket
      appState.playerIndices[firstSocket] = 0
      appState.seatPlayerIndices[0] = 0
      appState.playIngress[0].playerIndex = 0
    simServer.pumpPlayOutbound(config, FirstLightEpisode())
    check decodeServerPacket(first.recvBinary()).kind == spkPlayContext
    let firstView = decodeServerPacket(first.recvBinary())
    check firstView.kind == spkPlayView
    check firstView.playView.view.len == 0

    first.sendBinary(LobbyChatSendPacket(text: "e\u0301 pact").encodePacket())
    let chatDeadline = epochTime() + 5.0
    while epochTime() < chatDeadline:
      var chatPending = false
      withLock appState.lock:
        chatPending = appState.pendingLobbyChats.len > 0
      if chatPending:
        break
      sleep(5)
    simServer.drainProductionLobbyChats()
    check appState.lobbyTranscript.len == 1
    check appState.lobbyTranscript[0].text == "e\u0301 pact"
    simServer.pumpPlayOutbound(config, FirstLightEpisode())
    let liveChat = decodeServerPacket(first.recvBinary())
    check liveChat.kind == spkLobbyChatBroadcast
    check liveChat.lobbyChatBroadcast.ordinal == 1
    check liveChat.lobbyChatBroadcast.text == "e\u0301 pact"

    let replacement = connectRawWebSocket(
      8397, "/player?slot=0&token=secret")
    let replacementBindDeadline = epochTime() + 5.0
    while epochTime() < replacementBindDeadline:
      var rebound = false
      withLock appState.lock:
        rebound = appState.playOutbound.len > 0 and
          appState.playOutbound[0].generation >= 2
      if rebound:
        break
      sleep(5)
    simServer.pumpPlayOutbound(config, FirstLightEpisode())
    check decodeServerPacket(replacement.recvBinary()).kind == spkPlayContext
    let replayed = decodeServerPacket(replacement.recvBinary())
    check replayed.kind == spkLobbyChatBroadcast
    check replayed.lobbyChatBroadcast.ordinal == 1
    check replayed.lobbyChatBroadcast.text == "e\u0301 pact"
    check decodeServerPacket(replacement.recvBinary()).kind == spkPlayView

    first.close()
    replacement.close()
    httpServer.close()
    joinThread(serverThread)

  test "lobby constants agree across the deliberately duplicated owners":
    check ctfTypes.LobbyChatMaxBytes == shellTypes.LobbyChatMaxBytes
    check ctfTypes.LobbyChatMaxMessagesPerSeat ==
      shellTypes.LobbyChatMaxPerSeatPerPhase
    check ctfTypes.LobbyChatMinSpacingTicks ==
      shellTypes.LobbyChatMinSpacingTicks

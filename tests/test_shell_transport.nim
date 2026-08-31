## Real-socket coverage for the play-seat Mummy transport adapter.

import mummy {.all.}
import std/[atomics, importutils, locks, net, options, os, strutils, tables, times]
import whisky

import ../src/shell/[transport, types]

privateAccess(ServerObj)

proc waitFor(startedAt: float64, timeoutSeconds = 10.0) =
  doAssert epochTime() - startedAt < timeoutSeconds, "timed out waiting"
  sleep(5)

template waitUntil(condition: untyped, timeoutSeconds = 10.0) =
  block:
    let startedAt = epochTime()
    while not (condition):
      waitFor(startedAt, timeoutSeconds)

proc serveProc(args: tuple[server: Server, port: int]) {.thread.} =
  try:
    args.server.serve(Port(args.port))
  except CatchableError:
    echo "serve failed: ", getCurrentExceptionMsg()

proc rawWebSocketConnect(port: int, path: string): net.Socket =
  result = newSocket()
  result.connect("127.0.0.1", Port(port))
  result.send(
    "GET " & path & " HTTP/1.1\r\n" &
    "Host: 127.0.0.1\r\n" &
    "Connection: Upgrade\r\n" &
    "Upgrade: websocket\r\n" &
    "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n" &
    "Sec-WebSocket-Version: 13\r\n\r\n"
  )
  var response: string
  while not response.endsWith("\r\n\r\n"):
    let c = result.recv(1, timeout = 5000)
    doAssert c.len == 1, "unexpected EOF during WebSocket upgrade"
    response &= c
  doAssert response.startsWith("HTTP/1.1 101")

proc frameHeaderOnly(payloadLen: uint64): string =
  result.add 0x82.char # final binary frame
  result.add 0xFF.char # masked, 64-bit extended length
  for i in countdown(7, 0):
    result.add char((payloadLen shr (8 * i)) and 0xFF)

proc isDisconnected(ws: whisky.WebSocket, timeout = 10000): bool =
  try:
    discard ws.receiveMessage(timeout)
  except CatchableError:
    return true

proc socketStateCount(server: Server): int =
  withLock server.websocketQueuesLock:
    result += server.websocketQueues.len
    result += server.websocketClaimed.len
  withLock server.outboundLock:
    result += server.outboundStates.len

var receiveCloses: Atomic[int]

block: # Per-route receive limits on one server.
  proc handler(request: Request) =
    case request.path:
    of "/play":
      discard request.upgradePlaySeatWebSocket()
    of "/default":
      discard request.upgradeToWebSocket()
    else:
      request.respond(404)

  proc websocketHandler(
    websocket: mummy.WebSocket,
    event: WebSocketEvent,
    message: mummy.Message,
  ) =
    case event:
    of MessageEvent:
      if message.kind in {mummy.TextMessage, mummy.BinaryMessage}:
        websocket.send($message.data.len)
    of CloseEvent:
      discard receiveCloses.fetchAdd(1)
    else:
      discard

  doAssert PlaySeatTransportLimits.maxMessageLen == PlaySeatReceiveLimitBytes
  doAssert PlaySeatTransportLimits.maxPendingEvents == MaxPendingSocketEvents
  doAssert PlaySeatTransportLimits.maxPendingBytes == MaxPendingSocketBytes
  doAssert PlaySeatTransportLimits.maxOutboundEvents == MaxOutboundEvents
  doAssert PlaySeatTransportLimits.maxOutboundBytes == MaxOutboundBytes

  let server = newServer(handler, websocketHandler)
  var serverThread: Thread[tuple[server: Server, port: int]]
  createThread(serverThread, serveProc, (server, 8391))
  server.waitUntilReady()

  block: # The exact play protocol maximum is accepted.
    let ws = newWebSocket("ws://127.0.0.1:8391/play")
    ws.send(newString(PlaySeatReceiveLimitBytes), whisky.BinaryMessage)
    let reply = ws.receiveMessage(10000)
    doAssert reply.isSome
    doAssert reply.get.data == $PlaySeatReceiveLimitBytes
    ws.close()

  block: # One byte over is rejected from the header, before allocation.
    let raw = rawWebSocketConnect(8391, "/play")
    raw.send(frameHeaderOnly(uint64(PlaySeatReceiveLimitBytes + 1)))
    var closed = false
    try:
      closed = raw.recv(1, timeout = 10000).len == 0
    except CatchableError:
      closed = true
    doAssert closed, "play socket did not reject the oversized frame header"
    raw.close()

  block: # The same server leaves an ordinary 32 KiB route unchanged.
    let ws = newWebSocket("ws://127.0.0.1:8391/default")
    ws.send(newString(32 * 1024), whisky.BinaryMessage)
    let reply = ws.receiveMessage(10000)
    doAssert reply.isSome
    doAssert reply.get.data == $(32 * 1024)
    ws.close()

  waitUntil receiveCloses.load == 3
  waitUntil server.socketStateCount == 0
  server.close()
  joinThread(serverThread)

var
  pendingGate: Atomic[bool]
  pendingMessages, pendingErrors, pendingCloses: Atomic[int]
  pendingCleanups: Atomic[int]

block: # Pending-event and pending-byte breaches.
  proc handler(request: Request) =
    if request.path == "/play":
      discard request.upgradePlaySeatWebSocket()
    else:
      request.respond(404)

  proc websocketHandler(
    websocket: mummy.WebSocket,
    event: WebSocketEvent,
    message: mummy.Message,
  ) =
    case event:
    of OpenEvent:
      while not pendingGate.load:
        sleep(1)
    of MessageEvent:
      discard pendingMessages.fetchAdd(1)
    of ErrorEvent:
      doAssert not event.isPlaySocketCleanupEvent()
      discard pendingErrors.fetchAdd(1)
    of CloseEvent:
      doAssert event.isPlaySocketCleanupEvent()
      discard pendingCleanups.fetchAdd(1)
      discard pendingCloses.fetchAdd(1)

  let server = newServer(handler, websocketHandler)
  var serverThread: Thread[tuple[server: Server, port: int]]
  createThread(serverThread, serveProc, (server, 8392))
  server.waitUntilReady()

  template breachEventCap(kindExpression: untyped) =
    block:
      pendingGate.store(false)
      let
        messagesBefore = pendingMessages.load
        errorsBefore = pendingErrors.load
        closesBefore = pendingCloses.load
        cleanupsBefore = pendingCleanups.load
      let ws = newWebSocket("ws://127.0.0.1:8392/play")
      for i in 0 ..< MaxPendingSocketEvents:
        ws.send("", kindExpression)
      # The first event past the cap atomically purges the accepted events.
      ws.send("", kindExpression)
      doAssert ws.isDisconnected()
      ws.close()
      pendingGate.store(true)
      waitUntil pendingCloses.load == closesBefore + 1
      doAssert pendingErrors.load == errorsBefore + 1
      doAssert pendingCleanups.load == cleanupsBefore + 1
      doAssert pendingMessages.load == messagesBefore
      # Poll a short deadline to prove the purged queue cannot dispatch later.
      let stableUntil = epochTime() + 0.1
      while epochTime() < stableUntil:
        doAssert pendingMessages.load == messagesBefore
        doAssert pendingErrors.load == errorsBefore + 1
        doAssert pendingCloses.load == closesBefore + 1
        waitFor(stableUntil - 0.1, 0.2)

  breachEventCap(whisky.Ping)
  breachEventCap(whisky.Pong)

  block: # Mixed control and data breach at the same exact event cap.
    pendingGate.store(false)
    let
      messagesBefore = pendingMessages.load
      errorsBefore = pendingErrors.load
      closesBefore = pendingCloses.load
      cleanupsBefore = pendingCleanups.load
    let ws = newWebSocket("ws://127.0.0.1:8392/play")
    for i in 0 ..< MaxPendingSocketEvents:
      case i mod 3
      of 0: ws.send("", whisky.Ping)
      of 1: ws.send("", whisky.Pong)
      else: ws.send("x", whisky.BinaryMessage)
    ws.send("x", whisky.BinaryMessage)
    doAssert ws.isDisconnected()
    ws.close()
    pendingGate.store(true)
    waitUntil pendingCloses.load == closesBefore + 1
    doAssert pendingErrors.load == errorsBefore + 1
    doAssert pendingCleanups.load == cleanupsBefore + 1
    doAssert pendingMessages.load == messagesBefore

  block: # Exactly one MiB is admitted; the next byte breaches the byte cap.
    pendingGate.store(false)
    let
      messagesBefore = pendingMessages.load
      errorsBefore = pendingErrors.load
      closesBefore = pendingCloses.load
      cleanupsBefore = pendingCleanups.load
    let ws = newWebSocket("ws://127.0.0.1:8392/play")
    for i in 0 ..< 4:
      ws.send(newString(MaxPendingSocketBytes div 4), whisky.BinaryMessage)
    ws.send("x", whisky.BinaryMessage)
    doAssert ws.isDisconnected()
    ws.close()
    pendingGate.store(true)
    waitUntil pendingCloses.load == closesBefore + 1
    doAssert pendingErrors.load == errorsBefore + 1
    doAssert pendingCleanups.load == cleanupsBefore + 1
    doAssert pendingMessages.load == messagesBefore

  waitUntil server.socketStateCount == 0
  server.close()
  joinThread(serverThread)

const
  FloodMessageLen = 256 * 1024
  EventFloodMessageLen = 4096

var
  outboundScenario: Atomic[int]
  outboundSent, outboundDropped: Atomic[int]
  outboundAdmitted, outboundRefused: Atomic[int]
  outboundDone, refillAttempted, refillAdmitted: Atomic[bool]
  outboundEventCapSeen: Atomic[bool]
  outboundCloses, outboundCleanups: Atomic[int]

proc outboundCompletion(
  websocket: mummy.WebSocket,
  completion: SendCompletion,
) {.gcsafe.} =
  case completion:
  of SendSent:
    discard outboundSent.fetchAdd(1)
    if outboundScenario.load == 1 and
        not refillAttempted.exchange(true):
      # Mummy releases capacity before invoking the callback, so admission
      # from this non-capturing completion proc must succeed.
      refillAdmitted.store websocket.trySendPlaySocket(
        newString(FloodMessageLen),
        onCompletion = outboundCompletion,
      )
  of SendDropped:
    discard outboundDropped.fetchAdd(1)

block: # Outbound refusal and completion-driven capacity.
  proc handler(request: Request) =
    if request.path == "/play":
      discard request.upgradePlaySeatWebSocket()
    else:
      request.respond(404)

  proc websocketHandler(
    websocket: mummy.WebSocket,
    event: WebSocketEvent,
    message: mummy.Message,
  ) =
    case event:
    of OpenEvent:
      case outboundScenario.load
      of 1:
        # Seven encoded 256 KiB frames fit below 2 MiB; the eighth is refused.
        for i in 0 ..< 7:
          doAssert websocket.trySendPlaySocket(
            newString(FloodMessageLen),
            onCompletion = outboundCompletion,
          )
        doAssert not websocket.trySendPlaySocket(
          newString(FloodMessageLen),
          onCompletion = outboundCompletion,
        )
      of 2:
        var consecutiveRefusals = 0
        while consecutiveRefusals < 50:
          if websocket.trySendPlaySocket(
            newString(FloodMessageLen),
            onCompletion = outboundCompletion,
          ):
            discard outboundAdmitted.fetchAdd(1)
            consecutiveRefusals = 0
            let outstanding = outboundAdmitted.load -
              outboundSent.load - outboundDropped.load
            doAssert outstanding <= MaxOutboundEvents
            doAssert outstanding * (FloodMessageLen + 10) <=
              MaxOutboundBytes
            doAssert outboundAdmitted.load <= 64
          else:
            discard outboundRefused.fetchAdd(1)
            inc consecutiveRefusals
            sleep(5)
        outboundDone.store(true)
      of 3:
        var consecutiveRefusals = 0
        while consecutiveRefusals < 50:
          if websocket.trySendPlaySocket(
            newString(EventFloodMessageLen),
            onCompletion = outboundCompletion,
          ):
            discard outboundAdmitted.fetchAdd(1)
            consecutiveRefusals = 0
            let outstanding = outboundAdmitted.load -
              outboundSent.load - outboundDropped.load
            doAssert outstanding <= MaxOutboundEvents + 1
            doAssert outstanding * (EventFloodMessageLen + 4) <=
              MaxOutboundBytes
            doAssert outboundAdmitted.load <= 4096
          else:
            discard outboundRefused.fetchAdd(1)
            let outstanding = outboundAdmitted.load -
              outboundSent.load - outboundDropped.load
            # Completion accounting can lag Mummy's reservation release by
            # one callback while these two threads cross.
            if outstanding == MaxOutboundEvents or
                outstanding == MaxOutboundEvents + 1:
              outboundEventCapSeen.store(true)
            inc consecutiveRefusals
            sleep(5)
        websocket.close() # Application policy disconnects on persistent refusal.
        outboundDone.store(true)
      else:
        discard
    of ErrorEvent:
      doAssert not event.isPlaySocketCleanupEvent()
    of CloseEvent:
      doAssert event.isPlaySocketCleanupEvent()
      discard outboundCleanups.fetchAdd(1)
      discard outboundCloses.fetchAdd(1)
    of MessageEvent:
      discard

  let server = newServer(handler, websocketHandler)
  var serverThread: Thread[tuple[server: Server, port: int]]
  createThread(serverThread, serveProc, (server, 8393))
  server.waitUntilReady()

  block: # A SendSent completion is the point at which capacity returns.
    outboundScenario.store(1)
    let ws = newWebSocket("ws://127.0.0.1:8393/play")
    for i in 0 ..< 8:
      let message = ws.receiveMessage(10000)
      doAssert message.isSome
      doAssert message.get.data.len == FloodMessageLen
    waitUntil refillAttempted.load
    doAssert refillAdmitted.load
    waitUntil outboundSent.load == 8
    doAssert outboundDropped.load == 0
    ws.close()
    waitUntil outboundCloses.load == 1

  block: # A stalled peer reaches refusal and queued buffers drop once.
    outboundScenario.store(2)
    let sentBefore = outboundSent.load
    let raw = rawWebSocketConnect(8393, "/play")
    waitUntil outboundDone.load, 30.0
    doAssert outboundRefused.load >= 50
    let admitted = outboundAdmitted.load
    doAssert admitted >= 1
    raw.close()
    waitUntil outboundSent.load + outboundDropped.load == 8 + admitted
    doAssert outboundSent.load + outboundDropped.load == 8 + admitted
    doAssert outboundDropped.load >= 1
    doAssert outboundSent.load >= sentBefore
    waitUntil outboundCloses.load == 2
    doAssert outboundCleanups.load == 2

  block: # Small frames independently fill the 256-event cap.
    outboundAdmitted.store(0)
    outboundRefused.store(0)
    outboundSent.store(0)
    outboundDropped.store(0)
    outboundDone.store(false)
    outboundEventCapSeen.store(false)
    outboundScenario.store(3)
    let raw = rawWebSocketConnect(8393, "/play")
    waitUntil outboundDone.load, 30.0
    doAssert outboundRefused.load >= 50
    doAssert outboundEventCapSeen.load
    let admitted = outboundAdmitted.load
    doAssert admitted >= MaxOutboundEvents
    raw.close()
    waitUntil outboundSent.load + outboundDropped.load == admitted
    doAssert outboundSent.load + outboundDropped.load == admitted
    doAssert outboundDropped.load >= 1
    waitUntil outboundCloses.load == 3
    doAssert outboundCleanups.load == 3

  waitUntil server.socketStateCount == 0
  # Server teardown has no adapter-owned completion state to drain. Mummy may
  # intentionally omit callbacks for buffers still queued at destroy().
  server.close()
  joinThread(serverThread)

echo "Shell transport tests passed"

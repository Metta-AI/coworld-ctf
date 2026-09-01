## Real-socket coverage for the play-seat Mummy transport adapter.

import mummy {.all.}
import std/[atomics, importutils, locks, net, options, os, strutils, tables, times]
import whisky

import ../src/shell/[transport, types]

privateAccess(ServerObj)

var heartbeat: Atomic[int]
  ## Bumped by markProgress() from every server-thread callback below
  ## (websocketHandler's open/message/error/close branches,
  ## outboundCompletion, and the per-iteration admit/refuse steps inside
  ## the outbound flood loops) -- every place the callbacks actually
  ## mutate the atomics a waitUntil call site polls. This is the generic
  ## "is the adapter alive and doing real work" signal, independent of
  ## which specific condition a given wait cares about.

template markProgress() = discard heartbeat.fetchAdd(1)

proc waitFor(startedAt: var float64, lastSeen: var int,
             noProgressSeconds = 45.0) =
  ## HEARTBEAT-RESET, not a flat wall-clock ceiling: startedAt only
  ## advances (via lastSeen catching up to heartbeat) when real progress
  ## has happened since the last check, so this only ever times out on
  ## noProgressSeconds of genuine STALL, never on cumulative slowness.
  ##
  ## Was a flat 120.0s ceiling (raised from 10.0s after a wall-clock audit
  ## caught this file failing 2/3 runs at ~10.6-10.9s under heavy
  ## synthetic CPU load) -- a bigger flat constant just moves the same
  ## race further out. It stopped being enough once James's CI pipelining
  ## (16f031e8) made shards compile while other shards run: a 2-core
  ## runner now has permanent co-tenant contention for the life of the
  ## job, the same load profile that made this file flake on a dev box.
  ## The internal refusal/flood loops this guards already self-terminate
  ## on an event count (consecutiveRefusals < 50), not wall time, so
  ## progress-based waiting matches what's actually being proven: the
  ## adapter keeps making progress, at whatever pace the runner allows,
  ## rather than "the adapter finishes inside N flat seconds."
  let current = heartbeat.load
  if current != lastSeen:
    lastSeen = current
    startedAt = epochTime()
  doAssert epochTime() - startedAt < noProgressSeconds,
    "timed out waiting: no progress for " & $noProgressSeconds & "s"
  sleep(5)

template waitUntil(condition: untyped, noProgressSeconds = 45.0) =
  block:
    var startedAt = epochTime()
    var lastSeen = heartbeat.load
    while not (condition):
      waitFor(startedAt, lastSeen, noProgressSeconds)

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
    markProgress()
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
    markProgress()
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
      # Poll a short deadline to prove the purged queue cannot dispatch
      # later. This proves STASIS over a fixed short window, the opposite
      # of what the heartbeat-reset waitFor is for -- a plain sleep is all
      # this ever needed from it.
      let stableUntil = epochTime() + 0.1
      while epochTime() < stableUntil:
        doAssert pendingMessages.load == messagesBefore
        doAssert pendingErrors.load == errorsBefore + 1
        doAssert pendingCloses.load == closesBefore + 1
        sleep(5)

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
  scenario1BurstDone: Atomic[bool]
  scenario1Admitted: Atomic[int]
    ## scenario1BurstDone flips once OpenEvent's burst below has resolved a
    ## real refusal (proving the cap) AND the completion-triggered refill in
    ## outboundCompletion has been attempted -- whichever of the two settles
    ## last. scenario1Admitted is the true total number of 256 KiB frames
    ## sent to the client: the burst's own admits, plus the refill's if it
    ## won its slot, computed only once both have resolved.
    ##
    ## Neither a fixed attempt count nor a fixed ordering between the two is
    ## safe to assume here. Mummy's IO thread completes a send (freeing
    ## outbound capacity, under the same outboundLock trySend itself checks)
    ## as soon as a frame is fully handed to the OS, and a fresh socket's OWN
    ## kernel send/receive buffers can absorb at least one 256 KiB frame with
    ## the peer never having read a byte. So a completion -- and the refill
    ## it triggers -- can land WHILE the burst is still mid-loop, not only
    ## after it. Under normal load the burst's tight loop finishes in
    ## microseconds, far under a completion's round trip, so this is latent;
    ## under real CPU contention (this suite's own parallel shards, or a
    ## loaded CI runner) the burst can be descheduled mid-loop for long
    ## enough that it fires. Polling for the real refusal boundary (like
    ## scenarios 2 and 3 below already do), and waiting for the refill to
    ## resolve before computing the true sent total, is what makes the
    ## reading client's expected count exact regardless of which order the
    ## two settled in.

proc outboundCompletion(
  websocket: mummy.WebSocket,
  completion: SendCompletion,
) {.gcsafe.} =
  markProgress()
  case completion:
  of SendSent:
    discard outboundSent.fetchAdd(1)
    if outboundScenario.load == 1 and
        not refillAttempted.exchange(true):
      # Mummy releases capacity before invoking the callback, so admission
      # from this non-capturing completion proc succeeds UNLESS the burst
      # loop below is concurrently competing for the same just-freed slot
      # (see scenario1Admitted's doc comment) -- in that case the burst's
      # own count already reflects the reclaim, just attributed to it.
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
    markProgress()
    case event:
    of OpenEvent:
      case outboundScenario.load
      of 1:
        # Seven encoded 256 KiB frames fit below 2 MiB, so admission must
        # refuse well before attempt 16; poll for the boundary instead of
        # assuming it lands exactly on attempt 8 (see scenario1Admitted).
        # The bound is deliberately tight (not e.g. 64): every extra attempt
        # here widens the window in which this loop can race the completion-
        # triggered refill in outboundCompletion for the same freed slot.
        var admitted = 0
        while admitted < 16 and websocket.trySendPlaySocket(
          newString(FloodMessageLen),
          onCompletion = outboundCompletion,
        ):
          inc admitted
          markProgress()
        doAssert admitted >= 7, "fewer than the 7 frames guaranteed to fit " &
          "under the 2 MiB cap were admitted"
        doAssert admitted < 16, "outbound cap never refused within a bounded burst"
        # The refill can already have fired (and resolved) mid-burst, or it
        # can still be pending on a completion for one of the frames just
        # admitted above -- it settles within one completion round trip of
        # the last admit, well inside this bound. Computing the true total
        # only after it resolves is what lets the reading client below know
        # exactly how many frames to expect, with no stray unread frame left
        # to stall the close handshake at the end of this block.
        let waitStart = epochTime()
        while not refillAttempted.load and epochTime() - waitStart < 10.0:
          sleep(1)
        doAssert refillAttempted.load,
          "no SendSent completion arrived to trigger the refill"
        scenario1Admitted.store(admitted + (if refillAdmitted.load: 1 else: 0))
        scenario1BurstDone.store(true)
      of 2:
        var consecutiveRefusals = 0
        while consecutiveRefusals < 50:
          markProgress()
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
          markProgress()
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
    scenario1BurstDone.store(false)
    let ws = newWebSocket("ws://127.0.0.1:8393/play")
    # scenario1Admitted is the true total (burst admits, plus the refill's
    # if it won its slot -- see its doc comment): the refill has already
    # been attempted and resolved by the time scenario1BurstDone flips, so
    # reading exactly this many drains the connection with no stray unread
    # frame left to stall the close handshake below.
    waitUntil scenario1BurstDone.load
    let admitted = scenario1Admitted.load
    for i in 0 ..< admitted:
      let message = ws.receiveMessage(10000)
      doAssert message.isSome
      doAssert message.get.data.len == FloodMessageLen
    # The dedicated refill (outboundCompletion's reentrant trySend) wins its
    # slot whenever nothing else is contending for it. It can lose that race
    # only to the burst loop above claiming the same just-freed slot first --
    # a benign outcome of this test's own greedy burst, not a capacity leak --
    # in which case the burst's own count (folded into scenario1Admitted
    # above) already exceeds the guaranteed minimum of 7, proving the same
    # reclaim-and-reuse happened either way.
    doAssert refillAdmitted.load or admitted > 7,
      "capacity was never reclaimed for reuse by either the refill or the burst"
    waitUntil outboundSent.load == admitted
    doAssert outboundDropped.load == 0
    ws.close()
    waitUntil outboundCloses.load == 1

  block: # A stalled peer reaches refusal and queued buffers drop once.
    outboundScenario.store(2)
    let sentBefore = outboundSent.load
    let raw = rawWebSocketConnect(8393, "/play")
    waitUntil outboundDone.load
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
    waitUntil outboundDone.load
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

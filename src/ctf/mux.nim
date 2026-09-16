## Single-channel seat transport for RL training: every policy-driven seat of
## one env multiplexed over ONE Unix domain socket instead of one websocket
## per seat. Enabled by COGAME_MUX_SOCKET=<path>; the default (unset) leaves
## the server byte-identical to the websocket-only build — prod containers and
## the live player never see this path.
##
## The FRAME payload bytes are exactly the Sprite v1 wire packets the
## websocket path sends (same buildSpriteProtocolPlayerUpdates + dedup +
## chunking), so client-side parsing and featurization are untouched — only
## the transport framing differs.
##
## Wire format (little-endian), client -> server:
##   0x01 JOIN:  u8 slot, u16 nameLen, name, u16 tokenLen, token
##   0x02 INPUT: u8 slot, u8 mask            (websocket 0x84 equivalent)
##   0x03 READY: u8 slot                     (websocket 0x85 equivalent)
## server -> client:
##   0x01 FRAME: u8 slot, u32 len, len bytes (one websocket binary message;
##                                            len 0 is the empty keep-the-
##                                            frame-count message)
##
## Threading: one listener/reader thread owns the accepting socket and applies
## client records into `muxState` under its lock; the serve loop is the only
## writer to the connected socket. muxState.lock is always the INNERMOST lock
## (never take appState.lock while holding it).

import std/[locks, net, os]

const
  MuxJoin* = 0x01'u8
  MuxInput* = 0x02'u8
  MuxReady* = 0x03'u8
  MuxFrame* = 0x01'u8
  MaxMuxSeats* = 32
  MuxPendingIndex* = 0x7fffffff
    ## playerIndex of a joined-but-not-yet-admitted seat, mirroring the
    ## websocket path's pending sentinel.

type
  MuxJoinRequest* = object
    slot*: int
    address*: string
    token*: string

  MuxSeat* = object
    joined*: bool
    address*: string
    token*: string
    playerIndex*: int
    inputMask*: uint8
    pressedMask*: uint8
    ready*: bool

  MuxState* = object
    lock*: Lock
    enabled*: bool
    connected*: bool
    closed*: bool
    socketPath*: string
    client: Socket
    listener: Socket
    pendingJoins*: seq[MuxJoinRequest]
    seats*: array[MaxMuxSeats, MuxSeat]

var
  muxState*: MuxState
  muxThread: Thread[string]

proc recvExact(socket: Socket, size: int): string =
  ## Reads exactly `size` bytes or returns "" on a closed/broken connection.
  result = newString(size)
  var got = 0
  while got < size:
    let n = socket.recv(addr result[got], size - got)
    if n <= 0:
      return ""
    got += n

proc readU16(data: string): int =
  int(data[0].uint8) or (int(data[1].uint8) shl 8)

proc applyMuxRecord(socket: Socket): bool =
  ## Reads and applies one client record; false ends the reader loop.
  let kindByte = recvExact(socket, 1)
  if kindByte.len == 0:
    return false
  case kindByte[0].uint8
  of MuxJoin:
    let slotByte = recvExact(socket, 1)
    if slotByte.len == 0: return false
    let slot = int(slotByte[0].uint8)
    let nameLenBytes = recvExact(socket, 2)
    if nameLenBytes.len == 0: return false
    let name = recvExact(socket, nameLenBytes.readU16())
    let tokenLenBytes = recvExact(socket, 2)
    if tokenLenBytes.len == 0: return false
    let token = recvExact(socket, tokenLenBytes.readU16())
    if slot >= MaxMuxSeats:
      echo "mux: join slot ", slot, " out of range"
      return false
    withLock muxState.lock:
      muxState.seats[slot] = MuxSeat(
        joined: true,
        address: name,
        token: token,
        playerIndex: MuxPendingIndex
      )
      muxState.pendingJoins.add(
        MuxJoinRequest(slot: slot, address: name, token: token)
      )
    true
  of MuxInput:
    let body = recvExact(socket, 2)
    if body.len == 0: return false
    let slot = int(body[0].uint8)
    let mask = body[1].uint8
    if slot >= MaxMuxSeats:
      return false
    withLock muxState.lock:
      # Same edge semantics as applyPlayerViewerMessage: pressed accumulates
      # newly-down bits until the serve loop samples them.
      muxState.seats[slot].pressedMask =
        muxState.seats[slot].pressedMask or
          (mask and not muxState.seats[slot].inputMask)
      muxState.seats[slot].inputMask = mask
    true
  of MuxReady:
    let body = recvExact(socket, 1)
    if body.len == 0: return false
    let slot = int(body[0].uint8)
    if slot >= MaxMuxSeats:
      return false
    withLock muxState.lock:
      muxState.seats[slot].ready = true
    true
  else:
    echo "mux: unknown record kind ", kindByte[0].uint8
    false

proc muxReaderThread(path: string) {.thread.} =
  ## Accepts ONE client on the mux socket and applies its records until EOF.
  {.gcsafe.}:
    let listener = newSocket(AF_UNIX, SOCK_STREAM, IPPROTO_IP)
    removeFile(path)
    listener.bindUnix(path)
    listener.listen()
    withLock muxState.lock:
      muxState.listener = listener
    var client: Socket
    try:
      listener.accept(client)
    except CatchableError:
      # closeMux() closed the listener before any client connected.
      withLock muxState.lock:
        muxState.closed = true
      return
    withLock muxState.lock:
      muxState.client = client
      muxState.connected = true
    echo "mux: client connected on ", path
    while true:
      var alive: bool
      try:
        alive = applyMuxRecord(client)
      except CatchableError:
        alive = false
      if not alive:
        break
    withLock muxState.lock:
      muxState.connected = false
      muxState.closed = true
    echo "mux: client disconnected"

proc startMux*(path: string) =
  ## Enables the mux transport and starts its listener/reader thread.
  initLock(muxState.lock)
  muxState.enabled = true
  muxState.socketPath = path
  createThread(muxThread, muxReaderThread, path)
  echo "mux: listening on ", path

proc closeMux*() =
  ## Tears the channel down so the client sees EOF at server exit.
  if not muxState.enabled:
    return
  withLock muxState.lock:
    if muxState.connected:
      try:
        muxState.client.close()
      except CatchableError:
        discard
      muxState.connected = false
    try:
      muxState.listener.close()
    except CatchableError:
      discard
  removeFile(muxState.socketPath)

proc muxConnected*(): bool =
  if not muxState.enabled:
    return false
  withLock muxState.lock:
    result = muxState.connected

proc muxAppendFrame*(
  buffer: var string,
  slot: int,
  packet: openArray[uint8]
) =
  ## Appends one seat-tagged FRAME record to an outgoing batch.
  buffer.add(char(MuxFrame))
  buffer.add(char(slot.uint8))
  let size = packet.len.uint32
  buffer.add(char(size and 0xff))
  buffer.add(char((size shr 8) and 0xff))
  buffer.add(char((size shr 16) and 0xff))
  buffer.add(char((size shr 24) and 0xff))
  if packet.len > 0:
    let start = buffer.len
    buffer.setLen(start + packet.len)
    copyMem(addr buffer[start], unsafeAddr packet[0], packet.len)

proc muxSend*(buffer: string) =
  ## Writes one batch of FRAME records (single syscall for the whole tick).
  if buffer.len == 0:
    return
  var client: Socket = nil
  withLock muxState.lock:
    if muxState.connected:
      client = muxState.client
  if client == nil:
    return
  try:
    client.send(buffer)
  except CatchableError:
    withLock muxState.lock:
      muxState.connected = false
      muxState.closed = true

proc muxRequeueJoins*() =
  ## Re-queues every joined seat for admission after a between-games roster
  ## reset (needsReregister), mirroring the websocket path's pending reset.
  if not muxState.enabled:
    return
  withLock muxState.lock:
    muxState.pendingJoins = @[]
    for slot in 0 ..< MaxMuxSeats:
      if muxState.seats[slot].joined:
        muxState.seats[slot].playerIndex = MuxPendingIndex
        muxState.seats[slot].ready = false
        muxState.pendingJoins.add(MuxJoinRequest(
          slot: slot,
          address: muxState.seats[slot].address,
          token: muxState.seats[slot].token
        ))

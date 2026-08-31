## Persistent seat state independent of the CTF server's socket tables.

import ../ctf/sim_types
import ./types

type
  SeatStateError* = object of CatchableError

  PlaySeatBinding*[Socket] = object
    state*: PlaySeatSocketState
    generation*: uint64
    socket: Socket
    hasSocket: bool

  BindResult*[Socket] = object
    generation*: uint64
    replaced*: bool
    oldSocket*: Socket

  SeatPresence* = enum
    spConnected
    spReconnectable
    spTerminal

  SeatTombstoneTiming* = enum
    stNone
    stPreStart
    stInGame

  SeatTombstone* = object
    presence*: SeatPresence
    timing*: SeatTombstoneTiming

proc initPlaySeatBinding*[Socket](): PlaySeatBinding[Socket] =
  result.state = pssUnbound

proc bindSocket*[Socket](
  binding: var PlaySeatBinding[Socket],
  socket: Socket,
): BindResult[Socket] =
  ## Authentication happens outside this generic transaction. Once called,
  ## the generation changes before the new socket can be admitted, making a
  ## queued message from the replaced socket stale in the same drain.
  if binding.state == pssClosed:
    raise newException(SeatStateError, "cannot bind a closed play seat")
  if binding.generation == high(uint64):
    raise newException(SeatStateError, "play-seat generation exhausted")
  result.replaced = binding.state == pssBound and binding.hasSocket
  if result.replaced:
    result.oldSocket = binding.socket
  inc binding.generation
  binding.socket = socket
  binding.hasSocket = true
  binding.state = pssBound
  result.generation = binding.generation

proc lose*[Socket](binding: var PlaySeatBinding[Socket], socket: Socket): bool =
  ## A stale socket cannot demote the replacement that superseded it.
  if binding.state != pssBound or not binding.hasSocket or
      binding.socket != socket:
    return false
  binding.state = pssLost
  binding.hasSocket = false
  true

proc close*[Socket](binding: var PlaySeatBinding[Socket]) =
  ## Episode teardown is the only destructive binding transition.
  binding.state = pssClosed
  binding.hasSocket = false

proc admits*[Socket](
  binding: PlaySeatBinding[Socket],
  socket: Socket,
  generation: uint64,
): bool =
  binding.state == pssBound and binding.hasSocket and
    binding.socket == socket and binding.generation == generation

proc isPlaySeatEpisode*(config: GameConfig): bool =
  if not config.season2Shell:
    return false
  for slot in config.slots:
    if slot.control == scPlay:
      return true

proc isPlaySeat*(config: GameConfig, seat: int): bool =
  config.isPlaySeatEpisode() and seat >= 0 and seat < config.slots.len and
    config.slots[seat].control == scPlay

proc initSeatTombstone*(): SeatTombstone =
  result.presence = spConnected

proc disconnect*(seat: var SeatTombstone, inGame: bool): bool =
  if seat.presence != spConnected:
    return false
  seat.presence = spReconnectable
  seat.timing = if inGame: stInGame else: stPreStart
  true

proc kick*(seat: var SeatTombstone, inGame: bool): bool =
  if seat.presence == spTerminal:
    return false
  seat.presence = spTerminal
  seat.timing = if inGame: stInGame else: stPreStart
  true

proc rebind*(seat: var SeatTombstone, inLobby: bool): bool =
  if not inLobby or seat.presence != spReconnectable:
    return false
  seat.presence = spConnected
  seat.timing = stNone
  true

proc preserveAcrossReset*(seat: var SeatTombstone) =
  ## Deliberate no-op: only a successful rebind clears a tombstone.
  discard

proc isNeverParticipant*(seat: SeatTombstone): bool =
  seat.presence != spConnected and seat.timing == stPreStart

proc isInGameAbandonment*(seat: SeatTombstone): bool =
  seat.presence != spConnected and seat.timing == stInGame

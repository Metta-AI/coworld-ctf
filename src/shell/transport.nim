## Generic Mummy transport policy for Season 2 play sockets.
##
## Mummy owns every admitted outbound buffer until its completion callback.
## This adapter deliberately adds no second queue or socket table: `false` from
## `trySendPlaySocket` is the application's backpressure signal, and capacity
## is released by Mummy only when it reports SendSent or SendDropped. Mummy does
## not invoke callbacks for buffers still queued when the whole server is
## destroyed, so teardown must never wait for completion accounting.

import mummy

import ./types

const PlaySeatTransportLimits* = WebSocketLimits(
  maxMessageLen: PlaySeatReceiveLimitBytes,
  maxPendingEvents: MaxPendingSocketEvents,
  maxPendingBytes: MaxPendingSocketBytes,
  maxOutboundEvents: MaxOutboundEvents,
  maxOutboundBytes: MaxOutboundBytes,
)

proc upgradePlaySeatWebSocket*(request: Request): WebSocket =
  ## Upgrades one play-seat route with the protocol's per-socket limits.
  request.upgradeToWebSocket(PlaySeatTransportLimits)

proc trySendPlaySocket*(
  websocket: WebSocket,
  data: sink string,
  kind = BinaryMessage,
  onCompletion: SendCallback = nil,
): bool {.raises: [], gcsafe.} =
  ## Transfers `data` to Mummy only when its bounded outbound pipeline admits
  ## it. A false result leaves ownership with the caller. Completion callbacks
  ## run on Mummy's event-loop thread and therefore must be non-capturing and
  ## non-blocking.
  websocket.trySend(move data, kind, onCompletion)

proc isPlaySocketCleanupEvent*(event: WebSocketEvent): bool {.inline.} =
  ## Mummy represents an abnormal close as exactly one ErrorEvent followed by
  ## one CloseEvent. This maps the design's single terminal event onto Mummy's
  ## two-event idiom: socket-owned application state is cleaned up only for the
  ## CloseEvent, never for the preceding ErrorEvent.
  event == CloseEvent

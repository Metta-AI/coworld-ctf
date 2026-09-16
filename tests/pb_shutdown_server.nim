## Thin access shim for the `closePlayerSocketsPromptly` scoping test
## (test_squad_shutdown_scoping.nim), isolated in its own module.
##
## This module `include`s server.nim, which uses mummy's (server-side)
## `WebSocket` unqualified throughout server.nim's own ~4700 lines. Keeping
## that `include` confined to a small file with no other conflicting
## imports means the test file itself never has to worry about the
## mummy-vs-anything-else name collisions that combining `include` with a
## second websocket-shaped library (e.g. whisky) would create -- Nim
## resolves an `include`d file's names in the includer's full scope, so
## every unqualified `WebSocket` inside the pasted-in server.nim source
## would become ambiguous the moment a second same-named type entered this
## file's scope.
include ../src/ctf/server

proc callClosePlayerSocketsPromptly*(
  sockets, takeoverSockets: seq[WebSocket],
  closeSocket: proc(websocket: WebSocket) {.gcsafe.}
) =
  ## Exposes the real (non-exported) shutdown helper to the test, with the
  ## real `closeSocket` action swapped for a spy -- so the test can assert
  ## exactly which sockets this call site reaches without needing a live
  ## mummy connection behind each one (calling the real `.close()` on a
  ## fabricated `cast[WebSocket](n)` identity would dereference a fake
  ## pointer and crash).
  closePlayerSocketsPromptly(sockets, takeoverSockets, closeSocket)

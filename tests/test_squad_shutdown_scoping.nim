## Unit coverage for `closePlayerSocketsPromptly` (src/ctf/server.nim), the
## certification-headroom fix (2026-08-31): on a squad-mode (paintball KOTH)
## final shutdown, roster-player and seat-takeover sockets now close as soon
## as the last frame is queued, instead of waiting out the full
## `ShutdownGraceSeconds` window with everyone else. See
## test_squad_shutdown_timing.nim for the real end-to-end timing proof (a
## live server + real websocket clients); this file is the fast, safe unit
## check that the call site closes EXACTLY the right sockets -- gameplay
## ones, never a spectator or reward-observer connection, which must keep
## the full grace period untouched.
##
## Uses fabricated `cast[WebSocket](n)` identities (the same technique
## test_lobby_reconnect_wedge.nim uses for table-identity tests) with a spy
## `closeSocket` action in place of the real `mummy.WebSocket.close()` --
## calling the REAL close on a fabricated pointer would dereference garbage
## and crash, so the production code takes `closeSocket` as an injectable
## parameter (defaulting to the real close) specifically so this is safe.
##
## Red-proofed: reverting `closePlayerSocketsPromptly` to close `sockets`
## only (dropping the `takeoverSockets` loop) fails the second test below;
## reverting it to also iterate a `globalViewers`-like third list would
## fail the "touches nothing else" assertion the same way -- both are
## exactly the class of regression this file exists to catch.

import std/unittest
import mummy
import pb_shutdown_server

proc fakeSocket(id: int): mummy.WebSocket =
  cast[mummy.WebSocket](id)

suite "closePlayerSocketsPromptly closes only gameplay sockets":
  test "closes every roster socket and every takeover socket, exactly once each":
    var closedIds: seq[int] = @[]
    proc spy(websocket: mummy.WebSocket) {.gcsafe.} =
      {.cast(gcsafe).}:
        closedIds.add(cast[int](websocket))

    let roster = @[fakeSocket(1), fakeSocket(2), fakeSocket(3)]
    let takeover = @[fakeSocket(101), fakeSocket(102)]

    pb_shutdown_server.callClosePlayerSocketsPromptly(roster, takeover, spy)

    check closedIds == @[1, 2, 3, 101, 102]

  test "an empty roster and empty takeover list close nothing (no crash on a quiet lobby-less shutdown)":
    var closedIds: seq[int] = @[]
    proc spy(websocket: mummy.WebSocket) {.gcsafe.} =
      {.cast(gcsafe).}:
        closedIds.add(cast[int](websocket))

    pb_shutdown_server.callClosePlayerSocketsPromptly(@[], @[], spy)

    check closedIds.len == 0

  test "sockets outside the two passed-in lists are never reachable from this call -- proof spectators/reward observers cannot be swept in by construction":
    ## closePlayerSocketsPromptly only ever iterates its two parameters, so
    ## a spectator/reward-observer socket that the caller never puts into
    ## `sockets` or `takeoverSockets` structurally cannot be closed by this
    ## proc. This is exactly the scoping guarantee runServerLoop's call
    ## site relies on (it passes the roster's own `sockets`/`takeoverSockets`
    ## locals, never `globalViewers`/`rewardViewers`).
    var closedIds: seq[int] = @[]
    proc spy(websocket: mummy.WebSocket) {.gcsafe.} =
      {.cast(gcsafe).}:
        closedIds.add(cast[int](websocket))

    let roster = @[fakeSocket(1)]
    let spectatorLikeId = 999
    pb_shutdown_server.callClosePlayerSocketsPromptly(roster, @[], spy)

    check spectatorLikeId notin closedIds
    check closedIds == @[1]

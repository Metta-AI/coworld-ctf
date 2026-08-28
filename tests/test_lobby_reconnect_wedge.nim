## The lobby-fill reconnect wedge (2026-08-27 BR incident, later found live on
## the CTF field too -- see removePlayer in server.nim).
##
## Join admission is strictly slot-sequential: a socket is tagged
## UnresolvedPlayerIndex ("registered, not yet resolved into a live roster
## slot") until join.slotIndex == sim.nextPlayerSlot(). removePlayer, called
## on every disconnect, re-indexes every OTHER socket's tracked array
## position by decrementing values greater than the removed index -- but
## UnresolvedPlayerIndex is always greater than any real index, so an
## unguarded decrement corrupts it into a value that can never match the
## pending-join scan (`== UnresolvedPlayerIndex`) again. The socket stays
## connected forever; the roster can never see it. Mode-independent: nothing
## here reads config.brMode, so it hits plain CTF fields exactly as it hit
## BR -- CTF just hides it, because CTF's minPlayers is usually well under
## its seat count, so an orphaned pending bot reads as "one fewer bot showed
## up" instead of a hard stall.
##
## This module is invisible to every other test because it exercises
## server.nim's live-socket bookkeeping directly (registerPlayerWebSocket /
## removePlayer / admitPendingJoins), which nothing else in the suite drives
## outside test_seat_takeover.nim's narrower takeover-only slice.

import std/unittest

include ../src/ctf/server

const GameDir = currentSourcePath.parentDir.parentDir

proc lobbyConfig(minPlayers: int): GameConfig =
  ## A plain (non-BR) lobby-phase config -- the bug needs no BR feature.
  ## startWaitTicks pinned low so a started round is quick to observe.
  result = defaultGameConfig()
  result.update(
    """{"minPlayers": """ & $minPlayers & """, "startWaitTicks": 1}"""
  )

proc lobbySim(minPlayers: int): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(lobbyConfig(minPlayers))
  finally:
    setCurrentDir(previousDir)

suite "lobby-fill reconnect wedge":
  test "sentinel boundary: an unrelated disconnect must not touch a pending join":
    ## The minimal, direct proof: one admitted socket, one pending socket.
    ## Removing the admitted one must leave the pending one's sentinel
    ## untouched -- it is not a real index and must never be decremented.
    initAppState()
    var sim = lobbySim(2)
    let admitted = cast[WebSocket](1)
    let pending = cast[WebSocket](2)

    check registerPlayerWebSocket(admitted, "seat0", 0, "tok0")
    var socketsToClose: seq[WebSocket] = @[]
    var overlays: seq[DebugOverlay] = @[]
    var join0 = @[sim.pendingPlayerJoin(admitted)]
    discard sim.admitPendingJoins(join0, socketsToClose, overlays)
    check appState.playerIndices[admitted] == 0
    check sim.players.len == 1

    check registerPlayerWebSocket(pending, "seat1", 1, "tok1")
    check appState.playerIndices[pending] == UnresolvedPlayerIndex

    sim.removePlayer(admitted)

    check sim.players.len == 0
    check appState.playerIndices[pending] == UnresolvedPlayerIndex

  test "multiple simultaneous pending joins all survive one unrelated disconnect":
    ## The same boundary, but with several pending joins at once -- a
    ## refactor that special-cased "exactly one pending socket" would still
    ## pass the test above and still be wrong.
    initAppState()
    var sim = lobbySim(6)
    let admitted = cast[WebSocket](1)
    var pendingSockets: seq[WebSocket] = @[]
    for i in 1 .. 4:
      pendingSockets.add cast[WebSocket](100 + i)

    check registerPlayerWebSocket(admitted, "seat0", 0, "tok0")
    var socketsToClose: seq[WebSocket] = @[]
    var overlays: seq[DebugOverlay] = @[]
    var join0 = @[sim.pendingPlayerJoin(admitted)]
    discard sim.admitPendingJoins(join0, socketsToClose, overlays)
    check sim.players.len == 1

    for i, ws in pendingSockets:
      check registerPlayerWebSocket(ws, "seat" & $(i + 2), i + 2, "tok" & $(i + 2))
      check appState.playerIndices[ws] == UnresolvedPlayerIndex

    sim.removePlayer(admitted)

    check sim.players.len == 0
    for ws in pendingSockets:
      check appState.playerIndices[ws] == UnresolvedPlayerIndex

  test "a full 16-seat reconnect blip still reaches a live round":
    ## The end-to-end shape of the incident: 16 seats, one already-admitted
    ## socket blips mid-fill while a later socket is still pending, and the
    ## roster must recover to a full, startable lobby. Uses the exact same
    ## admission primitives runServerLoop calls -- not a reimplementation of
    ## the loop's structure, just the loop's own building blocks driven by
    ## hand.
    initAppState()
    var sim = lobbySim(16)
    var socketsToClose: seq[WebSocket] = @[]
    var overlays: seq[DebugOverlay] = @[]

    # Slot 15 registers first and can never be admitted until slots 0..14
    # exist -- it sits pending for the whole test, exactly like the socket
    # that loses the TCP race in a real 16-way burst join.
    let wsLast = cast[WebSocket](15)
    check registerPlayerWebSocket(wsLast, "seat15", 15, "tok15")

    # Slot 0 connects and admits immediately.
    let ws0a = cast[WebSocket](100)
    check registerPlayerWebSocket(ws0a, "seat0", 0, "tok0")
    var join0 = @[sim.pendingPlayerJoin(ws0a)]
    discard sim.admitPendingJoins(join0, socketsToClose, overlays)
    check sim.players.len == 1

    # THE BLIP: slot 0 drops and reconnects immediately, exactly as the
    # incident's crew socket did.
    sim.removePlayer(ws0a)
    check sim.players.len == 0
    let ws0b = cast[WebSocket](101)
    check registerPlayerWebSocket(ws0b, "seat0", 0, "tok0")

    # The rest of the crew connects, untouched by the blip.
    for i in 1 .. 14:
      let ws = cast[WebSocket](200 + i)
      check registerPlayerWebSocket(ws, "seat" & $i, i, "tok" & $i)

    # Run the same reconciliation runServerLoop runs each tick: gather every
    # still-pending socket and admit in slot order, repeating until a pass
    # makes no progress.
    var progressed = true
    while progressed:
      progressed = false
      var pendingPlayers: seq[PendingPlayerJoin] = @[]
      for ws, idx in appState.playerIndices.pairs:
        if ws.isPlayerWebSocket() and idx == UnresolvedPlayerIndex:
          pendingPlayers.add(sim.pendingPlayerJoin(ws))
      for join in sim.admitPendingJoins(pendingPlayers, socketsToClose, overlays):
        progressed = true

    # The roster is FULL for this lobby's own minPlayers (16) even though
    # MaxPlayers on this lineage is 32 (the 32-seat BR-duos shape) -- so
    # canAddPlayer() staying true here is correct engine behavior, not part
    # of what this test is checking. What matters is that all 16 pending
    # joins -- including the one the blip could have orphaned -- actually
    # got seated, and that the lobby can now start a round with them.
    check sim.players.len == 16
    check sim.phase == Lobby
    for _ in 0 ..< 5:
      sim.step(newSeq[InputState](16), newSeq[InputState](16))
    check sim.phase != Lobby  # the round actually starts

  test "the same wedge in the serve-forever reset dance (the filed 8-of-16 stall)":
    ## runServerLoop's `shouldReset` branch (server.nim, `if shouldReset:`)
    ## is a SEPARATE call site from ordinary lobby fill, used for the
    ## standing serve-forever field: it builds a fresh SimServer and re-runs
    ## every already-connected socket back through admission by resetting
    ## them ALL to UnresolvedPlayerIndex and looping admitPendingJoins --
    ## byte for byte the same shape reproduced here. A previously-filed,
    ## separate defect describes exactly this: a 16-seat freeplay field
    ## reseats only 8 after a reset, all 16 bot processes staying alive and
    ## connected, the field then silent forever. This test reproduces that
    ## shape directly (not inferred) with the real admission primitives:
    ## partway through re-admitting 16 already-connected sockets, one that
    ## already re-landed disconnects, and the still-pending remainder are
    ## orphaned exactly like the incident.
    initAppState()
    var sim = lobbySim(16)
    var socketsToClose: seq[WebSocket] = @[]
    var overlays: seq[DebugOverlay] = @[]
    var allSockets: seq[WebSocket] = @[]

    # A prior, fully-seated match: all 16 admitted once already.
    for i in 0 .. 15:
      let ws = cast[WebSocket](300 + i)
      allSockets.add ws
      check registerPlayerWebSocket(ws, "seat" & $i, i, "tok" & $i)
    block:
      var progressed = true
      while progressed:
        progressed = false
        var pendingPlayers: seq[PendingPlayerJoin] = @[]
        for ws, idx in appState.playerIndices.pairs:
          if ws.isPlayerWebSocket() and idx == UnresolvedPlayerIndex:
            pendingPlayers.add(sim.pendingPlayerJoin(ws))
        for join in sim.admitPendingJoins(pendingPlayers, socketsToClose, overlays):
          progressed = true
    check sim.players.len == 16

    # THE RESET: a fresh sim (matching `sim = initSimServer(config)`), every
    # already-connected socket dropped back to pending, matching
    # server.nim's shouldReset block exactly.
    sim = lobbySim(16)
    for ws in allSockets:
      appState.playerIndices[ws] = UnresolvedPlayerIndex

    # The dance gets partway through -- slots 0..7 re-land -- before a
    # disconnect lands on one of THOSE (this is the timing the incident
    # needs: the corrupting disconnect must hit an already-admitted socket
    # while others are still mid-dance, not before or after).
    block:
      var pendingPlayers: seq[PendingPlayerJoin] = @[]
      for i in 0 .. 7:
        pendingPlayers.add(sim.pendingPlayerJoin(allSockets[i]))
      discard sim.admitPendingJoins(pendingPlayers, socketsToClose, overlays)
    check sim.players.len == 8

    sim.removePlayer(allSockets[0])  # the mid-dance disconnect
    check sim.players.len == 7

    # A fresh reconnect for the dropped seat, matching the incident's
    # observed "player disconnected" immediately followed by "player
    # connected" for the same identity.
    let reconnected = cast[WebSocket](999)
    check registerPlayerWebSocket(reconnected, "seat0", 0, "tok0")

    # Finish the dance: everyone else (slots 1..7 already seated, 8..15
    # still nominally "reconnecting") gets a full run of the same loop.
    block:
      var progressed = true
      while progressed:
        progressed = false
        var pendingPlayers: seq[PendingPlayerJoin] = @[]
        for ws, idx in appState.playerIndices.pairs:
          if ws.isPlayerWebSocket() and idx == UnresolvedPlayerIndex:
            pendingPlayers.add(sim.pendingPlayerJoin(ws))
        for join in sim.admitPendingJoins(pendingPlayers, socketsToClose, overlays):
          progressed = true

    # THIS IS A SEPARATE, NOT-YET-FIXED DEFECT, characterized here rather
    # than fixed -- the sentinel guard above (removePlayer) is not enough
    # to save this scenario, and shipping a false "check sim.players.len ==
    # 16" would be a lie about tonight's fix. What actually happens even
    # WITH the sentinel fix: removing joinOrder 0 while joinOrder 1..7
    # remain leaves sim.players.len == 7, but nextPlayerSlot() (== 7) is
    # not the identity of the vacated slot (0) -- it is just a count. Slot
    # 0's reconnect resolves cleanly (slotOccupied(0) is false) but can
    # never be ADMITTED, because admission requires
    # `join.slotIndex == sim.nextPlayerSlot()`, i.e. 0 == 7, which is never
    # true. Slots 8..15 are then permanently stuck behind slot 0's hole for
    # the same reason. nextPlayerSlot() conflates "how many are seated"
    # with "which slot is next," and those two only agree when removals
    # always happen from the TOP of the join order -- exactly the
    # assumption a mid-stack disconnect breaks. This reproduces the filed
    # 8-of-16 stall's SHAPE (stuck below full, sockets presumably still
    # connected, no self-recovery) via a mechanism distinct from the
    # sentinel-corruption bug this commit fixes. Tracking as a follow-up;
    # NOT fixed here.
    check sim.players.len == 7
    # Still pending forever: resolvePlayerSlot happily resolves it to 0
    # every pass (slot 0 is unoccupied), but admitPendingJoins never
    # reaches it because 0 == sim.nextPlayerSlot() (7) is never true.
    check appState.playerIndices[reconnected] == UnresolvedPlayerIndex
    for i in 8 .. 15:
      check appState.playerIndices[allSockets[i]] == UnresolvedPlayerIndex

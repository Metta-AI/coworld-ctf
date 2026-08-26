import std/unittest

include ../src/ctf/server

proc seat(index: int): SeatTakeover =
  SeatTakeover(seat: index, name: "Green Rookie", active: false, cog: -1,
    observed: false, prevAlive: false)

suite "freeplay seat takeover":
  test "a human who arrives mid-life waits out that life":
    # The whole point of the respawn boundary: nobody is body-snatched.
    var t = seat(3)
    check not t.advanceSeatTakeover(3, true)   # first sample is never an edge
    for _ in 0 ..< 200:
      check not t.advanceSeatTakeover(3, true)
    check not t.active
    check t.cog == 3
    check t.cogAlive

  test "the swap lands on the cog's next respawn, not on its death":
    var t = seat(3)
    discard t.advanceSeatTakeover(3, true)
    check not t.advanceSeatTakeover(3, false)  # the cog is tagged out...
    check not t.active
    for _ in 0 ..< 47:                          # ...and stays down its timer
      check not t.advanceSeatTakeover(3, false)
    check not t.active
    check t.advanceSeatTakeover(3, true)        # THE respawn: the swap lands
    check t.active

  test "a human who arrives while the cog is already down takes the next spawn":
    var t = seat(5)
    check not t.advanceSeatTakeover(5, false)
    check t.advanceSeatTakeover(5, true)
    check t.active

  test "once driving, later deaths never hand the seat back":
    var t = seat(0)
    discard t.advanceSeatTakeover(0, false)
    check t.advanceSeatTakeover(0, true)
    check t.active
    check not t.advanceSeatTakeover(0, false)  # no second "landing"
    check t.active
    check not t.advanceSeatTakeover(0, true)
    check t.active

  test "a seat with no cog yet is not an edge":
    # Between matches the roster is empty; the seat resolves to -1 and the
    # human keeps suiting up rather than driving nothing.
    var t = seat(7)
    check not t.advanceSeatTakeover(-1, false)
    check not t.advanceSeatTakeover(-1, false)
    check not t.active
    check t.cog == -1
    check t.advanceSeatTakeover(7, true)       # the seat's first spawn
    check t.active

  test "a new match lands every pending takeover at the opening spawn":
    # A reset re-seats the whole roster inside one locked block, so no frame
    # samples the gap and the alive edge alone would miss it.
    initAppState()
    var pending = seat(1)
    discard pending.advanceSeatTakeover(1, true)
    appState.takeovers[cast[WebSocket](1)] = pending
    check not appState.takeovers[cast[WebSocket](1)].active
    landSeatTakeoversOnNewMatch()
    check appState.takeovers[cast[WebSocket](1)].active
    # ...and it re-arms the sampler, so the seat is re-read from scratch.
    check not appState.takeovers[cast[WebSocket](1)].observed

  test "one seat takes exactly one human":
    initAppState()
    check not 4.takeoverSeatTaken()
    appState.takeovers[cast[WebSocket](2)] = seat(4)
    check 4.takeoverSeatTaken()
    check not 5.takeoverSeatTaken()

  test "dropping the socket IS the reverse handoff":
    # Nothing hands the seat back explicitly: the takeover entry goes with the
    # socket, so the next frame finds no driver and reads the policy again.
    initAppState()
    let human = cast[WebSocket](3)
    appState.takeovers[human] = seat(6)
    appState.playerViewers[human] = initPlayerViewerState()
    check human in appState.takeovers
    discard removePlayerWebSocketState(human)
    check human notin appState.takeovers
    check human notin appState.playerViewers

  test "a takeover socket is never a roster player":
    # It must not enter playerIndices: it never joins, never occupies a slot,
    # and never writes a join/leave record.
    initAppState()
    let human = cast[WebSocket](4)
    human.registerTakeoverWebSocket(6, "Green Rookie")
    check human in appState.takeovers
    check human in appState.playerViewers
    check human notin appState.playerIndices
    check not human.isPlayerWebSocket()

  test "guest names keep their space and stay display-safe":
    check "Green Rookie".cleanGuestName() == "Green Rookie"
    check "  Blue Sprout  ".cleanGuestName() == "Blue Sprout"
    check "<script>x".cleanGuestName() == "scriptx"
    check "Green\tRookie".cleanGuestName() == "GreenRookie"
    check cleanGuestName(repeat("A", 60)).len == 24

  test "takeover is off unless the config turns it on":
    initAppState()
    check not appState.config.allowSeatTakeover
    check not defaultGameConfig().allowSeatTakeover

  test "a league config's replay JSON is byte-identical to a pre-takeover build":
    # The key is echoed ONLY when the mode is on — the same rule the puddle,
    # barrier and paintball knobs follow — so a league game's recorded config
    # does not gain a byte because this feature exists.
    var config = defaultGameConfig()
    check "allowSeatTakeover" notin config.configJson()
    config.allowSeatTakeover = true
    check "allowSeatTakeover" in config.configJson()

  test "the mode survives a config round trip":
    var config = defaultGameConfig()
    config.allowSeatTakeover = true
    var reread = defaultGameConfig()
    reread.update(config.configJson())
    check reread.allowSeatTakeover

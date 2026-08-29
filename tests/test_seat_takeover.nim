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
    human.registerTakeoverWebSocket(6, "Green Rookie", false)
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

proc snap(seat, cog: int, alive: bool, timer = 0): SeatSnapshot =
  SeatSnapshot(seat: seat, cog: cog, alive: alive, respawnTimer: timer)

suite "freeplay seat picker: click play, then play":
  test "a cog already DOWN is preferred over a healthy one":
    # The whole speed rule. The swap lands at the next respawn, so a healthy
    # cog costs the arrival a whole life for nothing.
    let board = @[
      snap(0, 0, true), snap(1, 1, false, 30), snap(2, 2, true)
    ]
    let pick = pickFreeplaySeat(board, @[], 3)
    check pick.seat == 1
    check pick.waitTicks == 30

  test "the SOONEST respawn wins among the downed":
    let board = @[
      snap(0, 0, false, 44), snap(1, 1, false, 6), snap(2, 2, false, 21)
    ]
    check pickFreeplaySeat(board, @[], 3).seat == 1
    check pickFreeplaySeat(board, @[], 3).waitTicks == 6

  test "a seat someone already holds is never handed out twice":
    let board = @[snap(0, 0, false, 5), snap(1, 1, false, 9)]
    check pickFreeplaySeat(board, @[0], 2).seat == 1
    check pickFreeplaySeat(board, @[0, 1], 2).seat == -1

  test "an all-healthy field still seats you, and does not guess the wait":
    let board = @[snap(0, 0, true), snap(1, 1, true)]
    let pick = pickFreeplaySeat(board, @[0], 2)
    check pick.seat == 1
    check pick.waitTicks == -1

  test "an empty roster seats the arrival for the opening whistle":
    # Between matches every pending takeover lands at the opening spawn, so
    # the honest wait is zero, not unknown.
    let pick = pickFreeplaySeat(@[], @[], 8)
    check pick.seat == 0
    check pick.waitTicks == 0
    check pickFreeplaySeat(@[], @[0, 1], 8).seat == 2

  test "a seat outside the configured roster is never picked":
    let board = @[snap(9, 0, false, 1), snap(1, 1, false, 40)]
    check pickFreeplaySeat(board, @[], 4).seat == 1

proc pendingOn(seat: int): SeatTakeover =
  SeatTakeover(seat: seat, requestedSeat: seat, name: "Green Rookie",
    active: false, cog: -1, observed: false, prevAlive: false)

proc registerPending(ws: WebSocket, seat: int) =
  appState.takeovers[ws] = pendingOn(seat)

suite "freeplay: a pending takeover parks on a cog that is already down":
  setup:
    initAppState()

  test "a human on a HEALTHY cog is moved to one that is down":
    # The unbounded wait is the bug. Nobody arriving at Free Play asked for a
    # particular policy seat -- they asked to play.
    let human = cast[WebSocket](1)
    human.registerPending(0)
    migratePendingTakeovers(@[
      snap(0, 0, true), snap(1, 1, false, 9), snap(2, 2, true)
    ])
    check appState.takeovers[human].seat == 1
    check appState.takeovers[human].requestedSeat == 0
    check not appState.takeovers[human].observed

  test "already parked on a downed cog, it never hops again":
    # That cog is about to stand up. Hopping off it would be pure thrash.
    let human = cast[WebSocket](1)
    human.registerPending(3)
    migratePendingTakeovers(@[snap(3, 3, false, 40), snap(1, 1, false, 2)])
    check appState.takeovers[human].seat == 3

  test "a human who is already DRIVING is never moved":
    let human = cast[WebSocket](1)
    appState.takeovers[human] = SeatTakeover(
      seat: 0, requestedSeat: 0, name: "Green Rookie", active: true, cog: 0)
    migratePendingTakeovers(@[snap(0, 0, true), snap(1, 1, false, 1)])
    check appState.takeovers[human].seat == 0

  test "two arrivals never park on the same cog":
    let
      first = cast[WebSocket](1)
      second = cast[WebSocket](2)
    first.registerPending(0)
    second.registerPending(4)
    migratePendingTakeovers(@[
      snap(0, 0, true), snap(4, 4, true), snap(1, 1, false, 5),
      snap(2, 2, false, 11)
    ])
    check appState.takeovers[first].seat != appState.takeovers[second].seat
    check appState.takeovers[first].seat in [1, 2]
    check appState.takeovers[second].seat in [1, 2]

  test "an all-healthy field leaves the seat exactly where it was":
    let human = cast[WebSocket](1)
    human.registerPending(6)
    migratePendingTakeovers(@[snap(6, 6, true), snap(1, 1, true)])
    check appState.takeovers[human].seat == 6

  test "a seat another human holds is never taken from them":
    let
      driver = cast[WebSocket](1)
      arrival = cast[WebSocket](2)
    appState.takeovers[driver] = SeatTakeover(
      seat: 1, requestedSeat: 1, name: "Driver", active: true, cog: 1)
    arrival.registerPending(0)
    migratePendingTakeovers(@[snap(0, 0, true), snap(1, 1, false, 3)])
    check appState.takeovers[arrival].seat == 0

suite "freeplay seat picker in brMode: alive is the fast seat, not the slow one":
  # sim.nim's killPlayer forces lives=0/respawnTimer=0 on a brMode death,
  # permanently -- a "down" brMode cog never comes back this round. The
  # classic-mode rule (prefer down, soonest respawn) would confidently hand
  # every BR arrival the ONE cog guaranteed to never land. preferAlive=true
  # is the whole fix: root-caused against the seat-resolution delay family.
  test "an ALIVE cog is preferred over one that is permanently down":
    let board = @[
      snap(0, 0, false, 0), snap(1, 1, true), snap(2, 2, false, 0)
    ]
    let pick = pickFreeplaySeat(board, @[], 3, preferAlive = true)
    check pick.seat == 1
    check pick.waitTicks == 0

  test "classic mode on the SAME board still prefers the down cog":
    # Same board, opposite ranking -- proves the two modes are not
    # accidentally sharing an answer.
    let board = @[
      snap(0, 0, false, 0), snap(1, 1, true), snap(2, 2, false, 0)
    ]
    check pickFreeplaySeat(board, @[], 3).seat in [0, 2]

  test "an all-eliminated board still seats you, and does not guess the wait":
    let board = @[snap(0, 0, false, 0), snap(1, 1, false, 0)]
    let pick = pickFreeplaySeat(board, @[0], 2, preferAlive = true)
    check pick.seat == 1
    check pick.waitTicks == -1

  test "a seat someone already holds is never handed out twice, brMode too":
    let board = @[snap(0, 0, true), snap(1, 1, true)]
    check pickFreeplaySeat(board, @[0], 2, preferAlive = true).seat == 1
    check pickFreeplaySeat(board, @[0, 1], 2, preferAlive = true).seat == -1

suite "freeplay: a pending brMode takeover parks on a cog that is ALIVE":
  setup:
    initAppState()

  test "a human on a permanently-down cog is moved to one that is alive":
    let human = cast[WebSocket](1)
    human.registerPending(0)
    migratePendingTakeovers(
      @[snap(0, 0, false, 0), snap(1, 1, true), snap(2, 2, false, 0)],
      preferAlive = true
    )
    check appState.takeovers[human].seat == 1
    check appState.takeovers[human].requestedSeat == 0
    check not appState.takeovers[human].observed

  test "already parked on an alive cog, it never hops to an eliminated one":
    let human = cast[WebSocket](1)
    human.registerPending(3)
    migratePendingTakeovers(
      @[snap(3, 3, true), snap(1, 1, true)], preferAlive = true)
    check appState.takeovers[human].seat == 3

  test "an all-eliminated field leaves the seat exactly where it was":
    # Nothing to migrate to -- every candidate is permanently down. Stay put
    # rather than hop between two dead cogs.
    let human = cast[WebSocket](1)
    human.registerPending(6)
    migratePendingTakeovers(
      @[snap(6, 6, false, 0), snap(1, 1, false, 0)], preferAlive = true)
    check appState.takeovers[human].seat == 6

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

suite "a takeover socket's chat resolves to the cog it drives, not -1":
  # Board task 38dc16d7: a takeover socket never enters playerIndices, so its
  # own chat always resolved to player index -1 and applyShout silently
  # refused it (docs/SEAT_TAKEOVER.md "Known gaps": a takeover seat cannot
  # shout). takeoverShoutCog is the fix's whole resolution rule — mirrors it
  # to the DRIVEN cog while ACTIVE, keeps dropping otherwise.
  test "an ACTIVE takeover resolves to the cog it drives":
    let t = SeatTakeover(seat: 2, requestedSeat: 2, name: "Green Rookie",
      active: true, cog: 5, observed: true, prevAlive: true)
    check t.takeoverShoutCog() == 5

  test "still suiting up (pending) drops, same as before the fix":
    let t = SeatTakeover(seat: 2, requestedSeat: 2, name: "Green Rookie",
      active: false, cog: 5, observed: true, prevAlive: true)
    check t.takeoverShoutCog() == -1

  test "active with no cog resolved yet still drops (defense in depth)":
    # Should not arise in practice -- advanceSeatTakeover never sets active
    # true without a valid cog -- but the resolver must not hand applyShout a
    # negative-plus-garbage index if it ever does.
    let t = SeatTakeover(seat: 2, requestedSeat: 2, name: "Green Rookie",
      active: true, cog: -1, observed: true, prevAlive: true)
    check t.takeoverShoutCog() == -1

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

suite "freeplay tickets: a guest never holds the policy's credential":
  setup:
    initAppState()
    appState.config = defaultGameConfig()
    appState.config.allowSeatTakeover = true
    appState.config.slots = @[
      PlayerSlotConfig(token: "policy-secret-0"),
      PlayerSlotConfig(token: "policy-secret-1")
    ]

  test "a minted ticket admits its seat without the seat's token":
    let ticket = mintTakeoverTicket(1)
    check ticket.len > 0
    check ticket != "policy-secret-1"
    check ticket.consumeTakeoverTicket(1)
    check appState.config.takeoverRejection(
      1, "", false, false, ticketAccepted = true) == ""

  test "without a ticket, the seat's token is still required":
    check appState.config.takeoverRejection(1, "", false, false).len > 0
    check appState.config.takeoverRejection(
      1, "policy-secret-1", false, false) == ""

  test "a ticket is spent, so replaying a captured one buys nothing":
    let ticket = mintTakeoverTicket(0)
    check ticket.consumeTakeoverTicket(0)
    check not ticket.consumeTakeoverTicket(0)

  test "a ticket for one seat does not open another":
    let ticket = mintTakeoverTicket(0)
    check not ticket.consumeTakeoverTicket(1)
    # ...and the failed attempt spent it too, so it cannot be retried.
    check not ticket.consumeTakeoverTicket(0)

  test "an unminted or empty ticket is refused":
    check not "".consumeTakeoverTicket(0)
    check not "deadbeef".consumeTakeoverTicket(0)

  test "an expired ticket is refused":
    let ticket = mintTakeoverTicket(0)
    appState.takeoverTickets[ticket].expires =
      getMonoTime() - initDuration(seconds = 1)
    check not ticket.consumeTakeoverTicket(0)

  test "two tickets are never the same string":
    var seen: seq[string] = @[]
    for _ in 0 ..< 64:
      let t = mintTakeoverTicket(0)
      check t notin seen
      seen.add(t)

  test "a league config mints nothing and admits nothing":
    initAppState()
    check not appState.config.allowSeatTakeover
    check appState.takeoverTickets.len == 0
    check defaultGameConfig().takeoverRejection(
      0, "", false, false, ticketAccepted = true).len > 0

suite "config round trip: the serializer must not emit what its reader refuses":
  test "a partially named roster survives its own configJson":
    # configJson turns the players array on when ANY slot is named, then emits
    # an entry for EVERY slot -- so one named slot beside an unnamed one wrote
    # {"name":""}, which readConfigPlayers used to reject outright. A replay
    # recorded from such a roster could not be loaded AT ALL.
    var config = defaultGameConfig()
    config.slots = @[
      PlayerSlotConfig(name: "player1", token: "t0"),
      PlayerSlotConfig(name: "", token: "t1")
    ]
    let recorded = config.configJson()
    check "\"players\"" in recorded
    var reread = defaultGameConfig()
    reread.update(recorded)                 # used to raise
    check reread.slots[0].name == "player1"
    check reread.slots[1].name == ""

  test "a fully named roster is unchanged":
    var config = defaultGameConfig()
    config.slots = @[
      PlayerSlotConfig(name: "player1", token: "t0"),
      PlayerSlotConfig(name: "player2", token: "t1")
    ]
    var reread = defaultGameConfig()
    reread.update(config.configJson())
    check reread.slots[0].name == "player1"
    check reread.slots[1].name == "player2"

  test "an unnamed roster still emits no players key at all":
    # The zero-diff case: nothing named, nothing echoed.
    var config = defaultGameConfig()
    config.slots = @[PlayerSlotConfig(token: "t0"), PlayerSlotConfig(token: "t1")]
    check "\"players\"" notin config.configJson()

  test "a players entry with no name key is still an error":
    # Relaxing EMPTY must not relax MISSING -- an authored config that forgot
    # the key is still a typo, not a deliberate blank.
    var config = defaultGameConfig()
    expect CtfError:
      config.update("""{"players":[{"team":"red"}]}""")

proc recordTakeoverShoutReplay(path: string): tuple[shoutCog: int] =
  ## Records a short, direct-player (non-squad, freeplay-shaped) episode and
  ## writes ONE chat mid-match: a takeover's shout, resolved through
  ## `takeoverShoutCog` exactly as the fixed frame-loop chat resolution does,
  ## and applied/recorded under the DRIVEN COG's own player index -- the
  ## same path a policy's own shout takes (sim.applyShout + writer.writeChat
  ## by player index). Closes the writer (via defer) before returning, so the
  ## caller can safely read the file back.
  var config = defaultGameConfig()
  config.minPlayers = 2
  config.startWaitTicks = 0          # the whistle lands on the first step
  config.maxGames = 1
  config.maxTicks = 200
  config.allowSeatTakeover = true    # the mode this fix exists for

  var sim = initSimServer(config)
  sim.gameEventLoggingEnabled = false
  var writer = openReplayWriter(path, config.configJson())
  defer: writer.closeReplayWriter()

  discard sim.addPlayer("red-rookie", 0, "")
  discard sim.addPlayer("blue-veteran", 1, "")
  for order in 0 ..< sim.players.len:
    writer.writeJoin(tickTime(sim.tickCount), order,
      sim.players[order].address, order, "")
    writer.lastMasks.add(0)

  var prev = newSeq[InputState](sim.players.len)

  proc tickOnce() =
    var inputs = newSeq[InputState](sim.players.len)
    for i in 0 ..< sim.players.len:
      writer.writeInputMaskChange(tickTime(sim.tickCount), i, 0)
    sim.step(inputs, prev)
    prev = inputs
    writer.writeHash(uint32(sim.tickCount), sim.gameHash())

  tickOnce()                          # Lobby -> Playing (startWaitTicks=0)
  doAssert sim.phase == Playing
  doAssert sim.players[0].alive

  # THE takeover: a human has already landed on seat 0's cog (the
  # respawn-edge dance lives in advanceSeatTakeover and is covered above) and
  # is now ACTIVE, driving cog 0.
  let takeover = SeatTakeover(seat: 0, requestedSeat: 0, name: "Green Rookie",
    active: true, cog: 0, observed: true, prevAlive: true)
  result.shoutCog = takeover.takeoverShoutCog()
  doAssert result.shoutCog == 0
  doAssert sim.applyShout(result.shoutCog, "gg from the seat")
  writer.writeChat(tickTime(sim.tickCount), result.shoutCog,
    "gg from the seat")

  for _ in 0 ..< 100:
    tickOnce()

suite "a takeover shout round-trips the replay hash chain":
  let dir = getTempDir() / "paintball-test-takeover-shout"
  createDir(dir)
  let path = dir / "takeover-shout.bitreplay"
  let written = recordTakeoverShoutReplay(path)

  test "the recorded chat is attributed to the driven cog, not -1":
    let data = parseReplayBytes(readFile(path))
    check data.chats.len == 1
    check int(data.chats[0].player) == written.shoutCog
    check data.chats[0].message == "gg from the seat"

  test "playback re-simulates the identical hash chain (the determinism gate)":
    # mismatchQuit = true: a single divergent bit RAISES here rather than
    # being tolerated -- the same gate test_pb_replay.nim uses for a policy's
    # own shout. A takeover shout recorded under the wrong player index (the
    # pre-fix -1, or any index but the driven cog's) either fails to apply on
    # replay or applies to the wrong cog, and either way the hash chain
    # diverges from the one this same episode produced live.
    let data = parseReplayBytes(readFile(path))
    check data.chats.len == 1
    var runtime = initReplayRuntime(data, mismatchQuit = true,
      gameEventLoggingEnabled = false)
    var player = runtime.player
    var sim = runtime.sim
    var steps = 0
    while player.playing and sim.tickCount < player.replayMaxTick():
      player.stepReplay(sim)
      inc steps
    check steps > 50
    check not player.hashValidationFailed
    check player.hashMismatchTick == -1

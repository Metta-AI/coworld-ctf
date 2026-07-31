import
  std/[algorithm, os, sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  ## Initializes the CTF sim from the game directory (so data/ resolves).
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc twoTeamGame(): SimServer =
  ## A started game with one Red player (0) and one Blue player (1).
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc openGround(sim: var SimServer) =
  ## All-open floor with both players apart and at rest, so held movement
  ## input produces real, deterministic displacement.
  for i in 0 ..< sim.walkMask.len:
    sim.walkMask[i] = true
  for (index, x, y) in [(0, 100, 100), (1, 400, 300)]:
    sim.players[index].x = x
    sim.players[index].y = y
    sim.players[index].velX = 0
    sim.players[index].velY = 0
    sim.players[index].carryX = 0
    sim.players[index].carryY = 0

proc shoutLabels(sim: var SimServer, viewerIndex: int): seq[string] =
  ## Every shout-bubble label one viewer receives: a seat index for the player
  ## stream a bot reads, -1 for the board/broadcast stream. Built from the game
  ## directory so data/ art resolves, like initCtfForTest.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  var packet: seq[uint8]
  try:
    if viewerIndex >= 0:
      var
        state: PlayerViewerState
        nextState: PlayerViewerState
      packet = sim.buildSpriteProtocolPlayerUpdates(
        viewerIndex, state, nextState)
    else:
      var
        state = initGlobalViewerState()
        nextState: GlobalViewerState
      packet = sim.buildSpriteProtocolUpdates(state, nextState)
  finally:
    setCurrentDir(previousDir)
  for message in packet.parseSpritePacket():
    if message.kind == spkSprite and " shout " in message.sprite.label:
      result.add message.sprite.label

proc sansShoutTick(player: Player, matching: Player): Player =
  ## The player with lastShoutTick copied over, so everything else can be
  ## compared for exact equality.
  result = player
  result.lastShoutTick = matching.lastShoutTick

suite "shouts":
  test "a shout is stored with player, team, and shout-time coordinates":
    var sim = twoTeamGame()
    check sim.applyShout(0, "push mid")
    check sim.recentShouts.len == 1
    let shout = sim.recentShouts[0]
    check shout.address == "red0"
    check shout.team == Red
    check shout.text == "push mid"
    check shout.tick == sim.tickCount
    check shout.x == sim.players[0].x + CollisionW div 2
    check shout.y == sim.players[0].y + CollisionH div 2

  test "shouts are truncated to the limit and sanitized":
    var sim = twoTeamGame()
    check sim.applyShout(0, "0123456789ABCDEF")
    check sim.recentShouts[0].text == "0123456789"
    check sim.recentShouts[0].text.len == ShoutMaxChars
    # Control characters are dropped; whitespace-only shouts are ignored.
    sim.players[1].lastShoutTick = -1
    check not sim.applyShout(1, "\x01\x02   \n")

  test "dead players cannot shout":
    var sim = twoTeamGame()
    sim.players[0].alive = false
    check not sim.applyShout(0, "ghost")
    check sim.recentShouts.len == 0

  test "shouting is rate limited and replaces the previous bubble":
    var sim = twoTeamGame()
    check sim.applyShout(0, "first")
    check not sim.applyShout(0, "too soon")
    check sim.recentShouts.len == 1
    check sim.recentShouts[0].text == "first"
    # After the cooldown a new shout replaces the old bubble.
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ShoutCooldownTicks:
      sim.step(none, none)
    check sim.applyShout(0, "second")
    check sim.recentShouts.len == 1
    check sim.recentShouts[0].text == "second"

  test "shouts expire after their display window":
    var sim = twoTeamGame()
    check sim.applyShout(0, "brief")
    let none = newSeq[InputState](sim.players.len)
    for _ in 0 ..< ShoutTicks:
      sim.step(none, none)
    check sim.recentShouts.len == 0

  test "shouts are audible within range, through walls, but not to the dead":
    var sim = twoTeamGame()
    check sim.applyShout(0, "here")
    let shout = sim.recentShouts[0]
    # The shouter hears its own shout.
    check sim.shoutAudibleTo(0, shout)
    # A viewer just inside the radius hears it; just outside does not.
    sim.players[1].x = shout.x + ShoutRange - 1 - CollisionW div 2
    sim.players[1].y = shout.y - CollisionH div 2
    check sim.shoutAudibleTo(1, shout)
    sim.players[1].x = shout.x + ShoutRange + 1 - CollisionW div 2
    check not sim.shoutAudibleTo(1, shout)
    # Dead viewers observe nothing.
    sim.players[1].x = shout.x - CollisionW div 2
    sim.players[1].alive = false
    check not sim.shoutAudibleTo(1, shout)

  test "shouting is parallel: it never blocks or alters same-tick movement and fire":
    # Two identical worlds, identical held inputs (move right + trigger
    # pull); one of them also shouts. Talking is free: it must never
    # consume, delay, or modify any other same-tick action.
    var
      talker = twoTeamGame()
      silent = twoTeamGame()
    talker.openGround()
    silent.openGround()

    # applyShout on its own changes nothing in the player state except
    # lastShoutTick.
    let before = talker.players[0]
    check talker.applyShout(0, "on my mark")
    check talker.recentShouts.len == 1
    check talker.recentShouts[0].text == "on my mark"
    check talker.players[0].lastShoutTick == talker.tickCount
    check talker.players[0].sansShoutTick(before) == before

    # With the shout in flight, movement and fire advance in lockstep with
    # the silent world: every tick, the full player state matches exactly
    # (lastShoutTick aside).
    var inputs = newSeq[InputState](talker.players.len)
    inputs[0] = InputState(right: true, attack: true)
    var prev = newSeq[InputState](talker.players.len)
    let startX = talker.players[0].x
    for _ in 0 ..< 10:
      talker.step(inputs, prev)
      silent.step(inputs, prev)
      prev = inputs
      check talker.players[0].sansShoutTick(silent.players[0]) ==
        silent.players[0]
    check talker.players[0].x > startX      # the shouter really moved

    # A second shout inside the cooldown is rejected — and the rejection,
    # too, leaves movement and fire untouched.
    check not talker.applyShout(0, "too soon")
    check talker.recentShouts.len == 1
    check talker.recentShouts[0].text == "on my mark"
    for _ in 0 ..< 5:
      talker.step(inputs, prev)
      silent.step(inputs, prev)
      check talker.players[0].sansShoutTick(silent.players[0]) ==
        silent.players[0]

  test "shouts are part of the game hash":
    var sim1 = twoTeamGame()
    var sim2 = twoTeamGame()
    check sim1.gameHash == sim2.gameHash
    sim1.applyShout(0, "flank left")
    check sim1.gameHash != sim2.gameHash
    sim2.applyShout(0, "flank left")
    check sim1.gameHash == sim2.gameHash

suite "shout labels name a slot letter, never the shouter's address":
  # A bubble's label is read off the wire by EVERY listener in earshot, so
  # whatever it names the shouter is public to the other side. It used to name
  # the connection address — for a league bot, the policy's own name — so a team
  # talking to itself ("red shout daveey: H2") handed rivals a free roster and
  # told them exactly whose build they were playing. These tests pin the
  # anonymous per-team slot letter in BOTH streams.

  proc namedGame(seats: int): SimServer =
    ## `seats` players whose addresses are unmistakable inside a label and share
    ## no substring with the team colors or the slot letters. Seats alternate
    ## Red, Blue, Red, Blue... by slot order, as teamForSlot assigns them.
    result = initCtfForTest(defaultGameConfig())
    for i in 0 ..< seats:
      discard result.addPlayer("policy" & $i)
    result.startGame()

  proc standOn(sim: var SimServer, viewer, target: int) =
    ## Puts `viewer` on top of `target`, well inside ShoutRange.
    sim.players[viewer].x = sim.players[target].x
    sim.players[viewer].y = sim.players[target].y

  test "a player view labels a heard shout with the shouter's slot letter":
    var sim = namedGame(2)
    check sim.applyShout(0, "H2")
    sim.standOn(viewer = 1, target = 0)
    let heard = sim.shoutLabels(viewerIndex = 1)
    check heard == @[labelShout("red", "alpha", "H2")]
    check not heard.anyIt("policy" in it)

  test "the board view labels shouts the same way":
    # The broadcast stream is anonymized too: one label shape everywhere, and a
    # human watching still reads the address off the `name` label over the
    # shouter's head.
    var sim = namedGame(2)
    check sim.applyShout(0, "H2")
    let shown = sim.shoutLabels(viewerIndex = -1)
    check shown == @[labelShout("red", "alpha", "H2")]
    check not shown.anyIt("policy" in it)

  test "slot letters rank within the team, not across the roster":
    # Seat 2 is Red's SECOND seat, so it is beta even though it is the third
    # player to join. Getting this from the roster index instead would make two
    # teammates share a letter and the enemy's letters mirror our own.
    var sim = namedGame(4)
    # A shout is heard at the coordinates it was MADE at, so gather the seats
    # before either of them talks.
    sim.standOn(viewer = 3, target = 2)
    sim.standOn(viewer = 0, target = 2)
    check sim.applyShout(2, "H2")        # red beta
    check sim.applyShout(3, "H3")        # blue beta
    check sim.shoutLabels(viewerIndex = 0).sorted == @[
      labelShout("blue", "beta", "H3"),
      labelShout("red", "beta", "H2"),
    ]

  test "a departed shouter's bubble falls back to the unknown slot name":
    # A bubble outlives its author: it displays for ShoutTicks and the shouter
    # can disconnect inside that window, which drops its player row and with it
    # the only route from address to slot. The bubble is observable state, so it
    # stays — under a name that still leaks nothing.
    var sim = namedGame(2)
    check sim.applyShout(0, "H2")
    sim.standOn(viewer = 1, target = 0)
    sim.removePlayerAt(0)
    check sim.players.len == 1
    check sim.recentShouts.len == 1
    let heard = sim.shoutLabels(viewerIndex = 0)
    check heard == @[labelShout("red", IdentityNameUnknown, "H2")]
    check not heard.anyIt("policy" in it)

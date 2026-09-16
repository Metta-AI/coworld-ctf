import
  std/[os, strutils, tables, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

# FX pool capacity at the 32-player limit.
#
# The spectator render draws every combat-FX family from a fixed object pool
# and clamps with `min(list.len, cap)` — an over-cap effect is not an error,
# it just silently never reaches the wire. The pools were sized for the old
# 16-player maximum, so a full 32-seat episode (archived paintbot 4ffa8 seats 32)
# dropped half its tracers/flashes/shouts in the worst tick. These tests
# drive every family the roster can saturate to exactly MaxPlayers live
# effects at once and count the objects that actually land in the packet:
# each family must emit all MaxPlayers, none clamped. Object ids are private
# pool constants, so families are counted by their sprite-label contract,
# like the shout tests do.

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc fullRosterGame(): SimServer =
  ## A started game with the maximum roster seated.
  var config = defaultGameConfig()
  result = initCtfForTest(config)
  for i in 0 ..< MaxPlayers:
    discard result.addPlayer("p" & $i)
  result.startGame()

proc labelCounts(
  sim: var SimServer,
  packets: openArray[seq[uint8]]
): CountTable[string] =
  ## Counts drawn OBJECTS per sprite-label family prefix (first two words),
  ## applying packets in order with client semantics (defs before objects).
  var labels: Table[int, string]
  for packet in packets:
    for message in packet.parseSpritePacket():
      case message.kind
      of spkSprite:
        labels[message.sprite.id] = message.sprite.label
      of spkObject:
        let label = labels.getOrDefault(message.objectDef.spriteId, "")
        let words = label.split(' ')
        if words.len >= 2:
          result.inc(words[0] & " " & words[1])
      else:
        discard

proc boardPacket(sim: var SimServer, state: var GlobalViewerState): seq[uint8] =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var nextState: GlobalViewerState
    result = sim.buildSpriteProtocolUpdates(state, nextState)
    state = nextState
  finally:
    setCurrentDir(previousDir)

suite "combat FX pools hold a full 32-player roster":
  test "every shooter-scaled family draws all MaxPlayers effects at once":
    var game = fullRosterGame()
    check game.players.len == MaxPlayers
    let tick = game.tickCount
    for i in 0 ..< MaxPlayers:
      # One live tracer + struck-victim flash + damage pop per seat, spread
      # mid-arena so nothing clips a map edge.
      let
        x0 = 100 + (i div 8) * 200
        y0 = 100 + (i mod 8) * 60
      game.recentShots.add ShotFx(
        x0: x0, y0: y0, x1: x0 + 250, y1: y0,
        firedTick: tick, color: teamColor(game.players[i].team), hit: true)
      game.hitFlashes.add HitFlashFx(playerIndex: i, tick: tick)
      game.damagePops.add DamageFx(
        x: x0, y: y0, tick: tick, amount: 1,
        color: teamColor(game.players[i].team))
      # One live speech bubble per seat (applyShout enforces one per player).
      check game.applyShout(i, "go " & $i)
    var state = initGlobalViewerState()
    var counts = game.labelCounts([game.boardPacket(state)])
    # Every family must land one object per seat — the old 16-wide pools
    # clamped each of these to half the roster.
    check counts["muzzle bloom"] == MaxPlayers
    check counts["shot head"] == MaxPlayers
    check counts["hit flash"] == MaxPlayers
    check counts["damage pop"] == MaxPlayers
    var shoutObjects = 0
    for label, n in counts:
      if label.endsWith(" shout"):        # "<slot> shout: <text>" families
        shoutObjects += n
    check shoutObjects == MaxPlayers

  test "a player view receives every shot's impact ring":
    var game = fullRosterGame()
    let tick = game.tickCount
    for i in 0 ..< MaxPlayers:
      let
        x0 = 100 + (i div 8) * 200
        y0 = 100 + (i mod 8) * 60
      game.recentShots.add ShotFx(
        x0: x0, y0: y0, x1: x0 + 250, y1: y0,
        firedTick: tick, color: teamColor(game.players[i].team), hit: false)
    var
      state: PlayerViewerState
      nextState: PlayerViewerState
    let previousDir = getCurrentDir()
    setCurrentDir(GameDir)
    var packet: seq[uint8]
    try:
      packet = game.buildSpriteProtocolPlayerUpdates(0, state, nextState)
    finally:
      setCurrentDir(previousDir)
    let counts = game.labelCounts([packet])
    check counts["shot impact"] == MaxPlayers

suite "neutral item pools survive BR-scale authored counts (finding 1)":
  ## The four NEUTRAL pickup pools (grenades/shields/med kits/spray cans)
  ## declared width 4 — a <=4-team holdover — while BR authors runtime-sized
  ## pools (the showmatch: 33 med kits, 36 sprays, 14 grenades, 7 shields).
  ## `Base + i` past the declared width wrote straight into the NEXT pool's
  ## id range (medkit i=10 into RotDiamondObjectBase, spray i=20 into
  ## SprayPaintCarryObjectBase): two families claiming the same wire object
  ## id in one packet, so the client's per-id object table can only keep
  ## one — the other silently vanishes or shows the wrong sprite. The fix
  ## widens all four to NeutralItemPoolWidth (64) and relocates them to
  ## fresh, non-colliding headroom (global.nim, PaintBombPickupObjectBase's
  ## comment); these tests exercise the two guards that keep it that way:
  ## the runtime clamp+assert in the render loop itself, and an end-to-end
  ## check that a realistic BR-scale load never collides on the wire.

  test "med kits / shields / spray pickups / grenade pickups assert rather than silently overflow their pool":
    ## Bypasses the map entirely — sets the SIM's runtime spawn arrays
    ## directly past NeutralItemPoolWidth, so this exercises the render
    ## loop's own defense (finding 1), independent of validateMap's
    ## separate map-authoring gate (finding 4).
    for family in ["medKitSpawns", "shieldSpawns", "sprayPaintSpawns", "grenadeSpawns"]:
      var game = fullRosterGame()
      let overflowLen = NeutralItemPoolWidth + 1
      template fill(spawnsField: untyped) =
        game.spawnsField.setLen(overflowLen)
        for i in 0 ..< overflowLen:
          game.spawnsField[i] =
            PickupSpawn(x: 60, y: 60, present: true, respawnAt: 0)
      case family
      of "medKitSpawns": fill(medKitSpawns)
      of "shieldSpawns": fill(shieldSpawns)
      of "sprayPaintSpawns": fill(sprayPaintSpawns)
      of "grenadeSpawns": fill(grenadeSpawns)
      else: discard
      var state = initGlobalViewerState()
      var raised = false
      try:
        discard game.boardPacket(state)
      except AssertionDefect:
        raised = true
      check raised

  test "BR-scale item pools (33 med kits, 36 spray cans, 14 grenades, 7 shields) never collide with each other or any other object pool":
    var game = fullRosterGame()
    template seat(spawnsField: untyped, n: int, row: int) =
      game.spawnsField.setLen(n)
      for i in 0 ..< n:
        game.spawnsField[i] =
          PickupSpawn(x: 60 + i * 4, y: 60 + row * 40, present: true, respawnAt: 0)
    seat(medKitSpawns, 33, 0)
    seat(shieldSpawns, 7, 1)
    seat(sprayPaintSpawns, 36, 2)
    seat(grenadeSpawns, 14, 3)
    # Every player also carries every carriable item, so the (already
    # MaxPlayers-wide) carry-marker pools are maximally live in the SAME
    # packet as the pickups above — the exact conditions the historical
    # medkit-vs-rotdiamond and spray-vs-spraycarry collisions needed.
    for i in 0 ..< game.players.len:
      game.players[i].hasSprayPaint = true
      game.players[i].hasShield = true
      game.players[i].shieldHp = 1
      game.players[i].hasGrenade = true
    var state = initGlobalViewerState()
    let packet = game.boardPacket(state)
    var seenIds: seq[int]
    for message in packet.parseSpritePacket():
      if message.kind == spkObject:
        check message.objectDef.id notin seenIds
        seenIds.add message.objectDef.id
    # Sanity: the packet really is item-dense, not vacuously passing on an
    # empty frame.
    check seenIds.len > 200

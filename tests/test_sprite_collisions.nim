import
  std/[os, sets, tables, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

# Sprite-id collision + bot label-contract audit.
#
# The client keeps ONE sprite definition per id per connection, and a later
# definition REPLACES an earlier one — so two render sites claiming the same
# id is a silent, game-wide failure: whichever label loses, every exact-match
# label scan for it goes blind (the 2026-07-22 incident: UnitTagSpriteBase =
# 5000 clobbered SpritePlayerFireSpriteId = 5000 "fire icon", and every
# scripted bot stopped firing — zero shots per game — while nothing crashed
# and no unit test failed).
#
# Two guards, both over a FULL-FEATURE frame (carriers of every pickup, a
# visible enemy, live pickups on the floor):
#   1. within one packet, no sprite id may be defined twice with different
#      labels (two call sites claiming the same id);
#   2. after applying several ticks of packets in arrival order (client
#      semantics, later-def-wins), every label the baseline bot exact-match
#      scans for must still exist in the table (the label CONTRACT — also
#      catches cross-packet clobbering and silent renames).

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc buildPlayerMessages(
  sim: var SimServer,
  playerIndex: int,
  state: var PlayerViewerState
): seq[SpritePacketMessage] =
  var nextState: PlayerViewerState
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = sim.buildSpriteProtocolPlayerUpdates(
      playerIndex, state, nextState).parseSpritePacket()
  finally:
    setCurrentDir(previousDir)
  state = nextState

proc buildGlobalMessages(
  sim: var SimServer,
  state: var GlobalViewerState
): seq[SpritePacketMessage] =
  var nextState: GlobalViewerState
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = sim.buildSpriteProtocolUpdates(state, nextState).parseSpritePacket()
  finally:
    setCurrentDir(previousDir)
  state = nextState

proc fullFeatureGame(): SimServer =
  ## A game exercising every sprite family at once: a viewer, a visible
  ## enemy, teammates carrying shield / grenade / plasma arc, floor pickups
  ## untouched, and combat FX.
  result = initCtfForTest(defaultGameConfig())
  for i in 0 ..< 6:
    discard result.addPlayer("p" & $i)
  result.startGame()
  for i in 0 ..< result.players.len:
    result.players[i].team = (if i mod 2 == 0: Red else: Blue)
  let
    cx = result.gameMap.center.x
    cy = result.gameMap.center.y
  # Viewer (0, Red) mid-map aiming east at a visible enemy (1, Blue).
  result.players[0].x = cx - 60
  result.players[0].y = cy
  result.players[0].aimBrads = 0
  # The enemy carries a shield so the carry marker + bubble render.
  result.players[1].x = cx + 60
  result.players[1].y = cy
  result.players[1].hasShield = true
  # Red teammates just behind the viewer, in its vision bubble, carrying
  # the grenade and the plasma arc so those markers render too.
  result.players[2].x = cx - 90
  result.players[2].y = cy - 20
  result.players[2].hasGrenade = true
  result.players[4].x = cx - 90
  result.players[4].y = cy + 20
  result.players[4].hasPlasmaArc = true

proc conflicts(messages: openArray[SpritePacketMessage]): seq[string] =
  ## Ids defined twice with different labels WITHIN one packet.
  var seen: Table[int, string]
  for message in messages:
    if message.kind != spkSprite:
      continue
    let id = message.sprite.id
    let label = message.sprite.label
    if id in seen and seen[id] != label:
      result.add("sprite id " & $id & ": \"" & seen[id] &
        "\" vs \"" & label & "\"")
    seen[id] = label

proc applyDefs(
  table: var Table[int, string],
  messages: openArray[SpritePacketMessage]
) =
  ## Client semantics: a later definition for an id replaces the earlier one.
  for message in messages:
    if message.kind == spkSprite:
      table[message.sprite.id] = message.sprite.label

suite "sprite id collisions":
  test "no two render sites claim one sprite id in a packet":
    var game = fullFeatureGame()
    # Exercise the collision-prone extras: a spectator-selected Blue player
    # (the outlined-soldier pool) and a landed shot (sound/impact rings).
    game.players[0].fireCooldown = 0
    game.tryFire(0)
    var pstate: PlayerViewerState
    var gstate = initGlobalViewerState()
    gstate.selectedJoinOrder = game.players[1].joinOrder
    check game.buildPlayerMessages(0, pstate).conflicts() == newSeq[string]()
    check game.buildPlayerMessages(1, pstate).conflicts() == newSeq[string]()
    check game.buildGlobalMessages(gstate).conflicts() == newSeq[string]()

  test "bot-critical labels survive a full-feature frame":
    # Every label the baseline bot exact-match scans for. A missing entry
    # means either a silent rename or a sprite-id clobber — both blind every
    # scripted bot in the league while nothing else fails.
    var game = fullFeatureGame()
    var pstate: PlayerViewerState
    var defs: Table[int, string]
    let none = newSeq[InputState](game.players.len)
    # Floor-pickup sprites define lazily on first sight (fog-gated), so walk
    # the viewer past each spawn family; the def table accumulates.
    let stops = [
      (game.players[0].x, game.players[0].y),
      (game.grenadeSpawns[0].x, game.grenadeSpawns[0].y),
      (game.shieldSpawns[0].x, game.shieldSpawns[0].y),
      (game.plasmaArcSpawns[0].x, game.plasmaArcSpawns[0].y),
      (game.medKitSpawns[0].x, game.medKitSpawns[0].y),
    ]
    for stop in stops:
      # Hover NEXT TO the spawn (not on it) so nothing is picked up.
      game.players[0].x = stop[0] + 40
      game.players[0].y = stop[1]
      game.players[0].aimBrads = 128    # aim west, spawn in the cone
      defs.applyDefs(game.buildPlayerMessages(0, pstate))
      game.step(none, none)
      defs.applyDefs(game.buildPlayerMessages(0, pstate))
    var labels = initHashSet[string]()
    var prefixes = initHashSet[string]()
    for label in defs.values:
      labels.incl(label)
      let space = label.find(' ')
      if space > 0:
        prefixes.incl(label[0 .. space])
    for needed in [
      "fire icon",            # the bot's trigger gate (shotReady)
      "walkability map",      # the bot's navigation grid
      "med kit",              # pickup routing
      "shield",               # endzone pickup
      "shield carried",       # own/enemy carry state
      "grenade",              # corner pickup
      "grenade carried",      # own carry state (nade state machine)
      "plasma arc carried",   # own carry state (arc discipline)
    ]:
      check needed in labels
    # Actor and HUD families the bot parses by prefix.
    check "player " in prefixes    # "player red right" etc (actorsFor)
    check "hp " in prefixes        # overhead pips "hp N/3"
    check "lives " in prefixes     # own-HUD hp/lives text

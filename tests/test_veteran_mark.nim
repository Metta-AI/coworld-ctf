import
  helpers,
  std/[sequtils, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, labels, sim]

# LabelVeteranMark: the overhead rank plume over a cog at or above AceLevel
# (glory.nim) — the perception half of the `dAceTag` bounty rule. Before this
# label existed a policy could see a level-3+ enemy's inflated hp bar but had
# no way to tell WHY it was inflated or which enemy was the bounty.
#
# Two contracts, mirroring the hp bar's own (test_player_fog.nim):
#   1. fog-gated exactly like every other overhead marker — visible only to a
#      viewer who can see the cog at all, same `playerVisibleTo` rule as the
#      shield/barrier carry markers;
#   2. absent below AceLevel, on purpose — absence is the "not a bounty yet"
#      signal, so a below-threshold cog must never emit the prefix even in
#      plain sight.

proc spriteLabels(messages: openArray[SpritePacketMessage]): seq[string] =
  for message in messages:
    if message.kind == spkSprite:
      result.add(message.sprite.label)

proc facedGame(foeLevel: int): (SimServer, int, int) =
  ## Viewer at map center, foe straight up the open corridor (the same
  ## fixture test_player_fog.nim uses for its cone fog/reveal toggle) —
  ## aimBrads 64 faces away from the foe (fogged), 192 faces it (visible).
  var game = initCtfForTest(defaultGameConfig())
  let viewer = game.addPlayer("red0")
  let foe = game.addPlayer("blue0")
  game.startGame()
  game.players[viewer].team = Red
  game.players[foe].team = Blue
  game.players[foe].level = foeLevel
  let
    cx = game.gameMap.center.x
    cy = game.gameMap.center.y
  game.players[viewer].x = cx
  game.players[viewer].y = cy
  game.players[viewer].aimBrads = 64
  game.players[foe].x = cx
  game.players[foe].y = 550
  (game, viewer, foe)

suite "veteran mark label":
  test "a level-3+ cog's rank plume appears only once the cog is visible":
    var (game, viewer, foe) = facedGame(AceLevel)
    var state: PlayerViewerState

    # buildPlayerMessages refreshes the viewer's fov cache as a side effect
    # (playerVisibleTo defaults to visible while that cache is still unset,
    # like every viewer before its first frame), so the fog assertion below
    # reads the cache a frame builds, not a not-yet-computed default.
    let fogged = game.buildPlayerMessages(viewer, state).spriteLabels()
    check not game.playerVisibleTo(viewer, foe)
    check not fogged.anyIt(it.startsWith(LabelPrefixVeteranMark))

    # Turn the viewer around: the foe enters the cone and its plume appears,
    # carrying its exact level.
    game.players[viewer].aimBrads = 192
    let visible = game.buildPlayerMessages(viewer, state).spriteLabels()
    check game.playerVisibleTo(viewer, foe)
    check labelVeteranMark(AceLevel) in visible

  test "a sub-AceLevel cog carries no rank plume even in plain sight":
    var (game, viewer, foe) = facedGame(AceLevel - 1)
    game.players[viewer].aimBrads = 192
    var state: PlayerViewerState
    let labels = game.buildPlayerMessages(viewer, state).spriteLabels()
    check game.playerVisibleTo(viewer, foe)
    check not labels.anyIt(it.startsWith(LabelPrefixVeteranMark))

  test "the board/spectator stream also fog-gates by level, not by team":
    # The map view has no viewer to fog against, so it shows every plume —
    # the same "map view shows everything" rule addHpPips documents.
    var game = initCtfForTest(defaultGameConfig())
    discard game.addPlayer("red0")
    let foe = game.addPlayer("blue0")
    game.startGame()
    game.players[0].team = Red
    game.players[foe].team = Blue
    game.players[foe].level = AceLevel
    var gstate = initGlobalViewerState()
    let labels = game.buildGlobalMessages(gstate).spriteLabels()
    check labelVeteranMark(AceLevel) in labels

import
  std/[os, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc unitLabels(sim: var SimServer, playerIndex: int): seq[string] =
  var state, nextState: PlayerViewerState
  for m in sim.buildSpriteProtocolPlayerUpdates(playerIndex, state, nextState)
      .parseSpritePacket():
    if m.kind == spkSprite and m.sprite.label.startsWith("unit "):
      result.add m.sprite.label

suite "unit identity tags":
  test "own tag visible; loadout suffixes track pickups":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    let seat = game.players[viewer].joinOrder
    var labels = game.unitLabels(viewer)
    check labels.len >= 1
    check ("unit " & $seat) in labels
    game.players[viewer].hasGrenade = true
    game.players[viewer].hasShield = true
    labels = game.unitLabels(viewer)
    check ("unit " & $seat & " shield nade") in labels

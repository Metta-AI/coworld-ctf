import
  std/[os, sequtils, strutils, unittest],
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

proc labels(sim: var SimServer, playerIndex: int): seq[string] =
  var state, nextState: PlayerViewerState
  for m in sim.buildSpriteProtocolPlayerUpdates(playerIndex, state, nextState)
      .parseSpritePacket():
    if m.kind == spkSprite:
      result.add m.sprite.label

suite "weapon observability":
  test "own HUD names the weapon; badges carry an explicit weapon token":
    var game = initCtfForTest(defaultGameConfig())
    let viewer = game.addPlayer("red0")
    discard game.addPlayer("blue0")
    game.startGame()
    var ls = game.labels(viewer)
    check "weapon gun" in ls
    check ls.anyIt(it.startsWith("identity ") and it.endsWith(" gun"))
    game.players[viewer].hasPlasmaArc = true
    ls = game.labels(viewer)
    check "weapon arc" in ls
    check ls.anyIt(it.startsWith("identity ") and it.endsWith(" arc"))

import
  std/[os, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[global, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  ## Initializes the CTF sim from the game directory (so data/ resolves).
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc startedGame(configJson: string): SimServer =
  ## A started two-player game over the map the config JSON selects.
  var config = defaultGameConfig()
  if configJson.len > 0:
    config.update(configJson)
  result = initCtfForTest(config)
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()

proc initBandPixels(sim: var SimServer): seq[seq[uint8]] =
  ## The compressed map-band sprite payloads a brand-new global viewer's
  ## init packet carries, in band order.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var
      state = initGlobalViewerState()
      nextState: GlobalViewerState
    let packet = sim.buildSpriteProtocolUpdates(state, nextState)
    for message in packet.parseSpritePacket():
      if message.kind == spkSprite and
          message.sprite.label.startsWith("map band"):
        result.add message.sprite.compressedPixels
  finally:
    setCurrentDir(previousDir)

suite "replay switch render caches":
  test "invalidateBoardMapCaches stops serving the previous sim's map":
    # The serve loop's replay hot-switch swaps in a sim over a NEW map while
    # the board render caches (map bands, arena bakes, endzone strips) are
    # process-wide. This pins the switch contract: after
    # invalidateBoardMapCaches(), a fresh viewer of the new sim must receive
    # that sim's map bands, not the previous arena's cached bytes.
    var simA = startedGame("")
    let bandsA = simA.initBandPixels()
    check bandsA.len > 0
    var simB = startedGame("""{"mapPath": "pool", "mapPoolIndex": 3}""")
    invalidateBoardMapCaches()
    let bandsB = simB.initBandPixels()
    check bandsB.len > 0
    check bandsB != bandsA
    # The repopulated cache serves the NEW map to the next viewer too, and
    # re-invalidating rebuilds the identical bytes (the cache is a pure
    # function of the current map).
    check simB.initBandPixels() == bandsB
    invalidateBoardMapCaches()
    check simB.initBandPixels() == bandsB

## Checks that the map VALIDATORS see the same walls the GAME plays on.
##
## Two definitions of the same rule exist: isProtectedFloor (used when a map is
## installed as the process map, i.e. in play) and mapProtectedFloorAt (used by
## generators, validators and the invariant tests on a map that is not
## installed). They must agree, because everything the tests promise about a
## map -- no sealed pockets, no open cross-field firing row, fair halves -- is
## promised about whichever mask they compute.
##
## Usage: nim r tools/mw2_maskcheck.nim [map ...]
## Audit tooling; not part of the server.
import
  std/[os, strformat],
  ../src/ctf/sim

when isMainModule:
  let gameDir = currentSourcePath().parentDir().parentDir()
  setCurrentDir(gameDir)
  var maps = commandLineParams()
  if maps.len == 0:
    maps = @["rust", "terminal", "highrise", "favela", "afghan", "scrapyard"]

  var anyBad = false
  for name in maps:
    var config = defaultGameConfig()
    config.mapPath = name
    var game = initSimServer(config)
    let
      gameMap = game.gameMap
      obstacles = (if gameMap.fullObstacles.len > 0: gameMap.fullObstacles
                   else: gameMap.leftObstacles)
    var
      diffs = 0
      firstX, firstY = -1
      validatorSaysFloor = 0   ## validator floor, game wall
      validatorSaysWall = 0    ## validator wall, game floor
    for y in 0 ..< MapHeight:
      for x in 0 ..< MapWidth:
        let
          vWall = mapWallAt(gameMap, obstacles, x, y)
          gWall = game.wallMask[y * MapWidth + x]
        if vWall != gWall:
          inc diffs
          if firstX < 0:
            firstX = x
            firstY = y
          if vWall: inc validatorSaysWall else: inc validatorSaysFloor
    let
      redHome = gameMap.teamHome(Red)
      blueHome = gameMap.teamHome(Blue)
      offCenter = abs(redHome.y - gameMap.center.y) +
                  abs(blueHome.y - gameMap.center.y)
    if diffs == 0:
      echo &"{name:<11} OK      (homes off centre by {offCenter}px)"
    else:
      anyBad = true
      echo &"{name:<11} MISMATCH {diffs} px  " &
        &"(validator wall/game floor {validatorSaysWall}, " &
        &"validator floor/game wall {validatorSaysFloor}); " &
        &"first at ({firstX},{firstY}); homes off centre by {offCenter}px"
  if anyBad:
    echo "\nThe invariant tests validate a mask the game does not play on."
    quit(1)

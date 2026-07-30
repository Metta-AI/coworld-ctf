## Dumps each pack map's full-resolution wall mask, so the layouts can be
## judged on ARCHITECTURE rather than on how they look at a glance.
##
## The recurring review failure on this pack is geometry that reads as objects
## scattered on a field instead of buildings with interiors, doorways and lanes
## between them. That difference is measurable — connected structures, their
## sizes, and how much enclosed interior floor exists — but only against the
## real mask, so this writes it out for tools/mw2_structure.py to analyse.
##
## Usage: nim r tools/mw2_structure.nim [map ...]
## Audit tooling; not part of the server.
import
  std/[os],
  ../src/ctf/sim

when isMainModule:
  let gameDir = currentSourcePath().parentDir().parentDir()
  setCurrentDir(gameDir)
  var maps = commandLineParams()
  if maps.len == 0:
    maps = @["arena", "rust", "terminal", "highrise", "favela", "afghan",
             "scrapyard"]

  for name in maps:
    var config = defaultGameConfig()
    if name != "arena":
      config.mapPath = name
    var game = initSimServer(config)
    # PBM: one byte per pixel is wasteful but trivially parseable, and this
    # runs once per audit.
    var buf = newStringOfCap(MapWidth * MapHeight + 64)
    buf.add "P1\n" & $MapWidth & " " & $MapHeight & "\n"
    for y in 0 ..< MapHeight:
      for x in 0 ..< MapWidth:
        buf.add(if game.wallMask[y * MapWidth + x]: "1" else: "0")
      buf.add "\n"
    let path = "/tmp/mw2mask-" & name & ".pbm"
    writeFile(path, buf)
    echo "wrote ", path, "  props=", game.gameMap.props.len,
      " shapes=", (if game.gameMap.fullObstacles.len > 0:
                     game.gameMap.fullObstacles.len
                   else: game.gameMap.leftObstacles.len),
      " trenches=", game.gameMap.trenches.len

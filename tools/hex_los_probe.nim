## Scratch probe: how many rows carry a full horizontal crossing, for a few
## candidate scan columns on the landscape hull.
import std/[os, strformat], ../src/ctf/sim, "../tests/helpers"

setCurrentDir(getAppDir() / "..")
let game = initSimServer(defaultGameConfig())

proc walkableAt(game: SimServer, x, y: int): bool {.used.} =
  x >= 0 and y >= 0 and x < MapWidth and y < MapHeight and
    game.walkMask[mapIndex(x, y)]

echo &"board {MapWidth}x{MapHeight} homeX red={game.gameMap.teamHomeX(Red)} " &
  &"blue={game.gameMap.teamHomeX(Blue)}"
for (lo, hi) in [(215, 1020), (284, 834), (195, 924), (265, 853), (255, 863)]:
  var worst = 0
  var worstRows: seq[int]
  var spun = game
  for frame in 0 ..< DiamondSpinFrames:
    spun.applyDiamondGeometry(frame * DiamondSpinTicksPerFrame)
    var rows: seq[int]
    for y in 10 ..< MapHeight - 10:
      if (spun.walkableAt(lo, y) or spun.walkableAt(hi, y)) and
          not spun.segmentBlocked(lo, y, hi, y):
        rows.add y
    if rows.len > worst:
      worst = rows.len
      worstRows = rows
  echo &"cols {lo}..{hi}: worst open rows = {worst}"
  echo &"    rows: {worstRows}"
  break

echo "--- wall runs across the open rows ---"
for y in [360, 425, 545, 149, 727, 950]:
  var runs: seq[(int, int)]
  var x = 0
  while x < MapWidth:
    if not game.isWall(x, y): inc x; continue
    let x0 = x
    while x < MapWidth and game.isWall(x, y): inc x
    runs.add((x0, x - 1))
  echo &"y={y}: {runs}"

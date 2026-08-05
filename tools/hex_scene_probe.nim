## Scratch probe: prints the landscape-hull arena coordinates the frozen scene
## tests pin, so they can be RE-MEASURED off the installed map instead of
## re-derived by hand. Run from the repo root:
##   nim c -d:release -r tools/hex_scene_probe.nim
import std/[os, strformat], ctf/sim

let previousDir = getCurrentDir()
setCurrentDir(getAppDir() / "..")
let game = initSimServer(defaultGameConfig())
setCurrentDir(previousDir)

let
  gameMap = game.gameMap
  cx = gameMap.center.x
  cy = gameMap.center.y
echo &"board {MapWidth}x{MapHeight} center {cx},{cy}"
echo &"homeX red={gameMap.teamHomeX(Red)} blue={gameMap.teamHomeX(Blue)}"
echo &"anchor red={gameMap.teamAnchor(Red)} radius={gameMap.endzoneRadius}"
echo &"border={ArenaBorder} grenadeInset={GrenadeSpawnInset}"
echo &"R={gameMap.mapBoard().circumradius()} A={gameMap.mapBoard().apothem()}"

proc rowScan(y: int, xLo = 0, xHi = MapWidth - 1) =
  ## The wall runs on one row, as (x0, x1, kind).
  var runs: seq[(int, int, string)]
  var x = xLo
  while x <= xHi:
    if not game.isWall(x, y): inc x; continue
    let glass = isArenaWindowPixel(x, y, cx, cy)
    let x0 = x
    while x <= xHi and game.isWall(x, y) and
        isArenaWindowPixel(x, y, cx, cy) == glass:
      inc x
    runs.add((x0, x - 1, if glass: "GLASS" else: "stone"))
  echo &"row y={y}: {runs}"

echo "--- glass bracket rows (left half) ---"
for y in [449, 454, 460, 470, 475, 480, 490]:
  rowScan(y, 0, MapWidth div 2)

echo "--- med kit rows ---"
for p in game.medKitSpawns:
  rowScan(p.y, max(0, p.x - 140), min(MapWidth - 1, p.x + 140))

echo "--- med kit spawns ---"
for p in game.medKitSpawns:
  echo &"  {p.x},{p.y} wall={game.isWall(p.x, p.y)}"
echo "--- grenade spawns + neighbourhood ---"
for p in game.grenadeSpawns:
  let n = game.nearestWalkable(p.x, p.y)
  echo &"  {p.x},{p.y} wall={game.isWall(p.x, p.y)} walk={game.isWalkable(p.x, p.y)}" &
    &" hexEdge={gameMap.mapBoard().hexEdgeDist(p.x, p.y):.1f} nearest={n}"
echo "--- rows at each grenade y ---"
for p in game.grenadeSpawns:
  rowScan(p.y, max(0, p.x - 140), min(MapWidth - 1, p.x + 140))
echo "--- shield spawns ---"
for p in game.shieldSpawns:
  echo &"  {p.x},{p.y} wall={game.isWall(p.x, p.y)} walk={game.isWalkable(p.x, p.y)}"
echo "--- spray spawns ---"
for p in game.plasmaArcSpawns:
  echo &"  {p.x},{p.y} wall={game.isWall(p.x, p.y)} walk={game.isWalkable(p.x, p.y)}"

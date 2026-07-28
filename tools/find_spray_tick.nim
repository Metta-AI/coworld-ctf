## Scans a replay for the ticks where a spray burst is live, so a viewer check can
## jump to a frame that exercises the animation.
import std/os, ../src/ctf/replays, ../src/ctf/sim
let path = commandLineParams()[0].absolutePath()
setCurrentDir(currentSourcePath().parentDir().parentDir())
let data = loadReplay(path)
var config = defaultGameConfig()
config.update(data.configJson)
var game = initSimServer(config)
game.gameEventLoggingEnabled = false
var replay = initReplayPlayer(data)
replay.looping = false
replay.mismatchQuit = true
var fires: seq[int]
var holdFrom = -1
while replay.playing:
  replay.stepReplay(game)
  for i in 0 ..< game.players.len:
    if game.players[i].hasPlasmaArc and holdFrom < 0:
      holdFrom = game.tickCount
    if game.players[i].arcTicksLeft > 0:
      if fires.len == 0 or fires[^1] != game.tickCount:
        fires.add game.tickCount
echo "holdFrom=", holdFrom, " lastTick=", game.tickCount
echo "fire ticks: ", fires

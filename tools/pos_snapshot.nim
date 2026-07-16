import std/[os, strformat], ../src/ctf/replays, ../src/ctf/sim

let params = commandLineParams()
if params.len < 1:
  echo "usage: pos_snapshot <replay> [start_tick] [end_tick]"
  quit(1)

let
  path = params[0]
  startTick = if params.len >= 2: parseInt(params[1]) else: 0
  endTick = if params.len >= 3: parseInt(params[2]) else: 99999
  gameDir = currentSourcePath().parentDir().parentDir()

setCurrentDir(gameDir)
let data = loadReplay(path)
var config = defaultGameConfig()
config.update(data.configJson)
var
  game = initSimServer(config)
  replay = initReplayPlayer(data)
game.gameEventLoggingEnabled = false
replay.looping = false
replay.mismatchQuit = true

while replay.playing and game.tick <= endTick:
  replay.stepReplay(game)
  if game.tick >= startTick and game.tick <= endTick and game.tick mod 100 == 0:
    echo &"tick {game.tick}"
    for i in 0 ..< game.players.len:
      let p = game.players[i]
      if p.slot >= 0 and p.alive:
        let team = if p.team == Red: "R" else: "B"
        let carry = if game.flags[Red].carrier == i: " CARRY-R"
                    elif game.flags[Blue].carrier == i: " CARRY-B"
                    else: ""
        echo &"  {team}{p.slot} {p.name:18s} x={p.x:4d} y={p.y:3d}{carry}"

import std/[os, strformat], ../src/ctf/replays, ../src/ctf/sim

# Re-simulates a replay and prints, every SampleEvery ticks, the carrier of
# each flag (if any) with its position — plus that carrier's position stream
# so a stalled run home is visible at a glance.

const SampleEvery = 60

let path = commandLineParams()[0]
let gameDir = currentSourcePath().parentDir().parentDir()
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

var tick = 0
while replay.playing:
  replay.stepReplay(game)
  inc tick
  if tick mod SampleEvery == 0:
    for team in [Red, Blue]:
      let c = game.flags[team].carrier
      if c >= 0:
        let p = game.players[c]
        echo &"tick {tick}: {team} flag carried by slot {c} ({p.team}) at ({p.x},{p.y}) alive={p.alive}"

import std/[os, strformat], ../src/ctf/replays, ../src/ctf/sim

# Re-simulates a replay WITH sim event logging (med kit pickups, kills) and
# prints each flag's carrier position every 150 ticks.

let path = commandLineParams()[0]
let gameDir = currentSourcePath().parentDir().parentDir()
setCurrentDir(gameDir)
let data = loadReplay(path)
var config = defaultGameConfig()
config.update(data.configJson)
var
  game = initSimServer(config)
  replay = initReplayPlayer(data)
game.gameEventLoggingEnabled = true
replay.looping = false
replay.mismatchQuit = true
var tick = 0
while replay.playing:
  replay.stepReplay(game)
  inc tick
  if tick mod 150 == 0:
    for team in [Red, Blue]:
      let c = game.flags[team].carrier
      if c >= 0:
        let p = game.players[c]
        echo &"T{tick} {team} flag carried by slot {c} ({p.team}) at ({p.x},{p.y}) hp={p.hp}"

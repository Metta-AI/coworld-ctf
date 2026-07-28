import std/[os, strformat, strutils, json], ../src/ctf/replays, ../src/ctf/sim

# Flag/steal/outcome probe for the pre-positioning heatmap job.
# Re-sims a replay (mismatchQuit) and reports, per team:
#   - steals of that team's flag (transitions carrier -1 -> >=0 on flags[team])
#   - each steal's tick (elapsed from Playing start), stealer index/address/team
#   - per-player final kills/deaths/captures/lives/address/team
#   - winner / isDraw / durations
# Usage: flag_probe <replay>   -> JSON on stdout

proc main() =
  let args = commandLineParams()
  let path = args[0]
  let gameDir = currentSourcePath().parentDir().parentDir()
  setCurrentDir(gameDir)
  let data = loadReplay(path)
  var config = defaultGameConfig()
  config.update(data.configJson)
  var game = initSimServer(config)
  var replay = initReplayPlayer(data)
  game.gameEventLoggingEnabled = false
  replay.looping = false
  replay.mismatchQuit = true

  var playStart = -1
  var tick = 0
  var prevCarrier: array[Team, int] = [-1, -1]
  var steals = newJArray()
  var lastGt = 0
  while replay.playing:
    replay.stepReplay(game)
    inc tick
    if game.phase == Playing and playStart < 0: playStart = tick
    if playStart >= 0 and game.phase == Playing:
      let gt = tick - playStart
      lastGt = gt
      for t in [Red, Blue]:
        let c = game.flags[t].carrier
        if c >= 0 and prevCarrier[t] < 0 and c < game.players.len:
          steals.add(%*{
            "gt": gt, "flagTeam": $t, "stealer": c,
            "stealerAddress": game.players[c].address,
            "stealerTeam": $game.players[c].team,
            "x": game.players[c].x, "y": game.players[c].y})
        prevCarrier[t] = c

  var players = newJArray()
  for i, p in game.players:
    players.add(%*{"i": i, "address": p.address, "team": $p.team,
                   "kills": p.kills, "deaths": p.deaths, "captures": p.captures,
                   "lives": p.lives, "alive": p.alive, "joinOrder": p.joinOrder})
  echo $(%*{"ticks": tick, "playStart": playStart, "lastGt": lastGt,
            "winner": $game.winner, "isDraw": game.isDraw,
            "steals": steals, "players": players})

main()

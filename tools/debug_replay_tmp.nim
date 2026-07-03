import std/[os, strutils], ../src/ctf/replays, ../src/ctf/sim

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
var
  deaths: array[16, int]
  carriers: array[Team, int] = [-1, -1]
while replay.playing:
  replay.stepReplay(game)
  for i in 0 ..< game.players.len:
    if game.players[i].deaths > deaths[i]:
      deaths[i] = game.players[i].deaths
      echo game.tickCount, " KILL victim=", teamText(game.players[i].team),
        game.players[i].joinOrder, " at ", game.players[i].x, ",", game.players[i].y,
        " lives=", game.players[i].lives
  for team in Team:
    if game.flags[team].carrier != carriers[team]:
      carriers[team] = game.flags[team].carrier
      echo game.tickCount, " FLAG ", teamText(team), " carrier=", carriers[team],
        " at ", game.flags[team].x, ",", game.flags[team].y
    if carriers[team] >= 0 and game.tickCount mod 25 == 0:
      echo game.tickCount, " CARRY ", teamText(team), " flag at ",
        game.flags[team].x, ",", game.flags[team].y
  if game.tickCount mod 400 == 0 and game.phase == Playing:
    var line = $game.tickCount & " POS"
    for i in 0 ..< game.players.len:
      line.add " " & teamText(game.players[i].team)[0..0] & $game.players[i].joinOrder &
        (if game.players[i].alive: "@" else: "x") & $game.players[i].x & "," & $game.players[i].y
    echo line
echo "END phase=", game.phase, " winner=", teamText(game.winner), " draw=", game.isDraw

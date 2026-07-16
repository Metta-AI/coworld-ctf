import std/[os, strformat], ../src/ctf/replays, ../src/ctf/sim

let path = commandLineParams()[0]
setCurrentDir("/Users/daveey/code/coworld-ctf-hd")
let data = loadReplay(path)
var config = defaultGameConfig()
config.update(data.configJson)
var
  game = initSimServer(config)
  replay = initReplayPlayer(data)
game.gameEventLoggingEnabled = false
replay.looping = false
replay.mismatchQuit = false
var hashIndex = 0
while replay.playing and game.tickCount < 2000:
  replay.stepReplay(game)
  while hashIndex < data.hashes.len and data.hashes[hashIndex].tick < uint32(game.tickCount):
    inc hashIndex
  if hashIndex < data.hashes.len and data.hashes[hashIndex].tick == uint32(game.tickCount):
    let expected = data.hashes[hashIndex].hash
    if expected != game.gameHash:
      echo &"DIVERGE tick={game.tickCount} resim: players={game.players.len} phase={game.phase} winner={game.winner} isDraw={game.isDraw} gameOverTimer={game.gameOverTimer}"
      # Search: what live state matches the expected hash?
      var probe = game
      for phase in [Lobby, Playing, GameOver]:
        for winner in [Red, Blue]:
          for isDraw in [false, true]:
            for tlr in [false, true]:
              for timer in 0 .. game.config.gameOverTicks + 2:
                probe.phase = phase
                probe.winner = winner
                probe.isDraw = isDraw
                probe.timeLimitReached = tlr
                probe.gameOverTimer = timer
                if probe.gameHash == expected:
                  echo &"LIVE WAS: phase={phase} winner={winner} isDraw={isDraw} timeLimitReached={tlr} gameOverTimer={timer}"
                  quit(0)
      echo "no scalar mutation matched — divergence is in players/flags/grenades"
      quit(0)
echo "no divergence"

import std/[os, strformat], ../src/ctf/replays, ../src/ctf/sim

# Re-simulates a replay to its end and reports the win TYPE (capture / wipe /
# draw) and, for a capture, WHICH slot carried the heart home. Used to attribute
# captures to v3 seats (0/4/8/12) vs v2 seats (2/6/10/14) on the shared Red team,
# the one per-policy discriminator the team win/loss score can't give.

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

# Tally captures per slot (recordCapture increments players[i].captures).
var capSlots: seq[int]
for i in 0 ..< game.players.len:
  if game.players[i].captures > 0:
    capSlots.add(i)

let outcome =
  if game.phase != GameOver: "unfinished"
  elif game.isDraw: "draw"
  else: "win:" & (if game.winner == Red: "RED" else: "BLUE")

var capStr = ""
for s in capSlots:
  let p = game.players[s]
  capStr &= &" join{p.joinOrder}/{p.team}/\"{p.address}\""
echo &"{outcome} ticks={tick} captureBy=[{capStr} ]"

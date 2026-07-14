import std/[os, algorithm, strformat], ../src/ctf/replays, ../src/ctf/sim

# Re-simulates a replay and reports, per player, how much of their alive time
# is spent "stuck" (net displacement under StuckRadius map px over a
# StuckWindow-tick window).

const
  StuckWindow = 60
  StuckRadius = 6

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
  history: array[16, seq[(int, int, bool)]] # x, y, alive per tick
  stuckTicks: array[16, int]
  aliveTicks: array[16, int]
  worstSpots: array[16, (int, int, int)] # start tick, x, y of longest stall
  stallLen: array[16, int]
  curStall: array[16, int]

while replay.playing:
  replay.stepReplay(game)
  for i in 0 ..< min(game.players.len, 16):
    let p = game.players[i]
    history[i].add((p.x, p.y, p.alive))
    if not p.alive:
      curStall[i] = 0
      continue
    inc aliveTicks[i]
    let n = history[i].len
    if n > StuckWindow:
      let (ox, oy, oalive) = history[i][n - 1 - StuckWindow]
      let
        dx = p.x - ox
        dy = p.y - oy
      if oalive and dx * dx + dy * dy < StuckRadius * StuckRadius:
        inc stuckTicks[i]
        inc curStall[i]
        if curStall[i] > stallLen[i]:
          stallLen[i] = curStall[i]
          worstSpots[i] = (game.tickCount, p.x, p.y)
      else:
        curStall[i] = 0

echo "ticks=", game.tickCount
var rows: seq[(float, int)]
for i in 0 ..< 16:
  if aliveTicks[i] == 0:
    continue
  rows.add((stuckTicks[i].float / aliveTicks[i].float, i))
rows.sort()
rows.reverse()
for (frac, i) in rows:
  let (st, sx, sy) = worstSpots[i]
  echo &"player{i + 1} stuck {frac * 100:.1f}% of alive time, " &
    &"longest stall {stallLen[i]} ticks at tick {st} pos ({sx},{sy})"

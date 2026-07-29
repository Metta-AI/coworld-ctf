## NADE DIST — where are unarmed bots relative to an armed corner, per team?
## Buckets bot-frames (alive, no grenade) by distance to the nearest ARMED
## corner, split into the early / mid / late tick windows, so the pickup detour
## can be sized off the real position distribution instead of a guess. Also
## splits OWN-SIDE corners (the two on our half) from the enemy pair, since the
## own-side pair is the safe resupply the policy's flanker route intends.
##
## Usage: nade_dist <replay> --us=red|blue

import std/[algorithm, json, math, os, strutils]
import ../src/ctf/replays
import ../src/ctf/sim

let params = commandLineParams()
var
  replayPath = ""
  usTeamText = "red"
for p in params:
  if p.startsWith("--us="): usTeamText = p[5 .. ^1]
  elif not p.startsWith("--"): replayPath = p.absolutePath()

setCurrentDir(currentSourcePath().parentDir().parentDir())
let data = loadReplay(replayPath)
var config = defaultGameConfig()
config.update(data.configJson)
var
  game = initSimServer(config)
  replay = initReplayPlayer(data)
game.gameEventLoggingEnabled = false
replay.looping = false
replay.mismatchQuit = true

let corners = grenadeSpawnPoints()
const Buckets = [90, 150, 240, 320, 450, 650, 10000]

var
  # [team][window][bucket] — window 0 = <1000, 1 = 1000..3000, 2 = >3000
  hist: array[2, array[3, array[Buckets.len, int]]]
  histOwn: array[2, array[3, array[Buckets.len, int]]]
  frames: array[2, array[3, int]]
  nPlayers = 0

proc ti(t: Team): int = (if t == Red: 0 else: 1)
let usIdx = (if usTeamText == "red": 0 else: 1)

while replay.playing:
  replay.stepReplay(game)
  if game.players.len > nPlayers: nPlayers = min(game.players.len, 16)
  let w = (if game.tickCount < 1000: 0 elif game.tickCount <= 3000: 1 else: 2)
  for i in 0 ..< nPlayers:
    let p = game.players[i]
    if not p.alive or p.hasGrenade: continue
    let team = ti(p.team)
    inc frames[team][w]
    let
      px = float(p.x + CollisionW div 2)
      py = float(p.y + CollisionH div 2)
      # our half: Red spawns at low x, Blue at high x.
      ownLowX = (p.team == Red)
    var best = 1e18
    var bestOwn = 1e18
    for ci in 0 ..< corners.len:
      if not game.grenadeSpawns[ci].present: continue
      let c = corners[ci]
      let
        dx = px - float(c.x)
        dy = py - float(c.y)
        d = sqrt(dx * dx + dy * dy)
      if d < best: best = d
      let isOwn = (ownLowX and c.x < MapWidth div 2) or
                  (not ownLowX and c.x > MapWidth div 2)
      if isOwn and d < bestOwn: bestOwn = d
    for b in 0 ..< Buckets.len:
      if best <= float(Buckets[b]):
        inc hist[team][w][b]
        break
    for b in 0 ..< Buckets.len:
      if bestOwn <= float(Buckets[b]):
        inc histOwn[team][w][b]
        break

proc j(t: int): JsonNode =
  var w = newJArray()
  for win in 0 .. 2:
    var any = newJArray()
    var own = newJArray()
    for b in 0 ..< Buckets.len:
      any.add %hist[t][win][b]
      own.add %histOwn[t][win][b]
    w.add(%*{"frames": frames[t][win], "any": any, "own": own})
  %*{"windows": w}

echo $(%*{"replay": replayPath.extractFilename,
  "buckets": @Buckets, "us": j(usIdx), "them": j(1 - usIdx)})

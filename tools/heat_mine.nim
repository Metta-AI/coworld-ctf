import std/[os, strformat, strutils], ../src/ctf/replays, ../src/ctf/sim

# Enemy-gathering heatmap miner (comms-018). Re-sims a live replay and bins the
# positions of ONE team's ALIVE bodies into a 32px grid x phase bucket, weighted
# by DWELL (one sample per alive body per sampled tick). Positions are folded to
# a CANONICAL frame (enemy defends the RIGHT half = Blue) so red-enemy and
# blue-enemy episodes pool: if the enemy is actually Red, mirror x -> MapW-1-x.
#
# Phase buckets on the GV21/GV22 5000-tick clock (elapsed from Playing start):
#   opening <1400, mid 1400-3400, late >=3400.
#
# Usage: nim r tools/heat_mine.nim <replay> <red|blue enemyTeam> [sampleEvery=3]
# Output (stdout):
#   MAP <mapW> <mapH> <gridW> <gridH> <cellSize>
#   DENOM <openSamples> <midSamples> <lateSamples>
#   C <phase> <cx> <cy> <count>   (one line per nonzero cell)

const
  CellSize = 32
  OpenEnd = 1400
  MidEnd = 3400

proc phaseOf(t: int): int =
  if t < OpenEnd: 0
  elif t < MidEnd: 1
  else: 2

proc main() =
  let args = commandLineParams()
  let path = args[0]
  let mineTeamStr = args[1].toLowerAscii()   # which team's bodies to bin
  let doMirror = args[2] == "1"              # 1 = mirror x (flip board) for canonical frame
  let sampleEvery = if args.len > 3: parseInt(args[3]) else: 3
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
  let mineTeam = if mineTeamStr == "red": Red else: Blue

  let gw = (MapWidth + CellSize - 1) div CellSize
  let gh = (MapHeight + CellSize - 1) div CellSize
  var dwell: array[3, seq[int]]
  for i in 0 .. 2: dwell[i] = newSeq[int](gw * gh)
  var denom: array[3, int]

  var playStart = -1
  var tick = 0
  while replay.playing:
    replay.stepReplay(game)
    inc tick
    if game.phase == Playing and playStart < 0: playStart = tick
    if playStart >= 0 and game.phase == Playing:
      let gt = tick - playStart
      if gt mod sampleEvery == 0:
        let ph = phaseOf(gt)
        for p in game.players:
          if p.team == mineTeam and p.alive:
            var x = p.x
            let y = p.y
            if doMirror: x = MapWidth - 1 - x
            if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight: continue
            let cx = x div CellSize
            let cy = y div CellSize
            dwell[ph][cy * gw + cx] += 1
            inc denom[ph]

  echo &"MAP {MapWidth} {MapHeight} {gw} {gh} {CellSize}"
  echo &"DENOM {denom[0]} {denom[1]} {denom[2]}"
  for ph in 0 .. 2:
    for cy in 0 ..< gh:
      for cx in 0 ..< gw:
        let c = dwell[ph][cy * gw + cx]
        if c > 0:
          echo &"C {ph} {cx} {cy} {c}"

main()

## wall_probe — prints the sim's wall/walk mask around one map point at one
## tick of a replay, so a "the seat pressed LEFT for 80 s and never moved"
## stall can be attributed to real geometry rather than guessed at.
##
## Usage: nim r tools/wall_probe.nim <replay> <tick> <x> <y> [halfW] [halfH]

import
  std/[os, strformat, strutils],
  ../src/ctf/[sim, sim_types, sim_state],
  toolutil

proc main() =
  let p = commandLineParams()
  chdirGameDir()
  let
    tick = parseInt(p[1])
    cx = parseInt(p[2])
    cy = parseInt(p[3])
    hw = if p.len > 4: parseInt(p[4]) else: 40
    hh = if p.len > 5: parseInt(p[5]) else: 20
  var (game, replay) = openReplay(p[0].absolutePath(), mismatchQuit = false)
  while replay.playing and game.tickCount < tick:
    replay.stepReplay(game)
  echo &"tick {game.tickCount}  centre ({cx},{cy})  '#'=wall '.'=open  cols x={cx-hw}..{cx+hw} step 2"
  var y = cy - hh
  while y <= cy + hh:
    var row = &"y{y:4d} "
    var x = cx - hw
    while x <= cx + hw:
      if x < 0 or y < 0 or x >= MapWidth or y >= MapHeight:
        row.add "?"
      elif game.wallMask[mapIndex(x, y)]:
        row.add "#"
      else:
        row.add "."
      x += 2
    echo row
    y += 2
  for i in 0 ..< game.players.len:
    let q = game.players[i]
    if abs(q.x - cx) <= 120 and abs(q.y - cy) <= 120:
      echo &"  seat {i} team {ord(q.team)} at ({q.x},{q.y}) alive={q.alive}"

main()

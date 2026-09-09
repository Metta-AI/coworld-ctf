## stall_trace — per-tick trace of ONE team's seats over a tick window, for
## root-causing a single stall found by tools/stuck_census.nim.
##
## Prints tick, and for every seat of the chosen team: position, velocity, the
## applied input mask, and whether the pixel 24 px along the pressed heading is
## wall — plus the identity and distance of the NEAREST other body. A seat that
## presses into a wall and a seat that presses into a team-mate look identical
## in the census and need opposite fixes; this is what tells them apart.
##
## Usage: nim r tools/stall_trace.nim <replay> <team> <fromTick> <toTick> [stride]

import
  std/[math, os, strformat, strutils],
  ../src/ctf/[sim, sim_types, sim_state],
  toolutil

proc main() =
  let p = commandLineParams()
  if p.len < 4:
    echo "Usage: stall_trace <replay> <team> <from> <to> [stride]"
    quit(1)
  chdirGameDir()
  let
    team = parseInt(p[1])
    a = parseInt(p[2])
    b = parseInt(p[3])
    stride = if p.len > 4: parseInt(p[4]) else: 1
  var (game, replay) = openReplay(p[0].absolutePath(), mismatchQuit = false)
  while replay.playing:
    replay.stepReplay(game)
    let t = game.tickCount
    if t < a or t > b or ((t - a) mod stride) != 0: continue
    var line = &"t{t:5d}"
    for i in 0 ..< game.players.len:
      let q = game.players[i]
      if ord(q.team) != team: continue
      let m = replay.lastAppliedMasks[i]
      var dx = 0
      var dy = 0
      if (m and 0x08'u8) != 0: inc dx
      if (m and 0x04'u8) != 0: dec dx
      if (m and 0x02'u8) != 0: inc dy
      if (m and 0x01'u8) != 0: dec dy
      var wall = "-"
      if dx != 0 or dy != 0:
        let n = sqrt(float(dx * dx + dy * dy))
        let px = clamp(q.x + int(float(dx) / n * 24.0), 0, MapWidth - 1)
        let py = clamp(q.y + int(float(dy) / n * 24.0), 0, MapHeight - 1)
        wall = if game.wallMask[mapIndex(px, py)]: "WALL" else: "open"
      var nearI = -1
      var nearD = 1e9
      for j in 0 ..< game.players.len:
        if j == i or not game.players[j].alive: continue
        let d = sqrt(float((q.x - game.players[j].x) ^ 2 +
                           (q.y - game.players[j].y) ^ 2))
        if d < nearD:
          nearD = d
          nearI = j
      let mate = if nearI >= 0 and ord(game.players[nearI].team) == team: "mate" else: "foe "
      line.add &" | s{i:2d} {(if q.alive: \"A\" else: \"d\")} ({q.x:4d},{q.y:3d})" &
        &" v({q.velX:5d},{q.velY:5d}) dp({dx:2d},{dy:2d}) {wall} near {mate}{nearI:2d}@{nearD:5.0f}"
    echo line

main()

import std/[strformat, strutils, os]
import ../src/ctf/[replays, sim]

proc main() =
  if paramCount() < 1:
    echo "usage: trace_positions <replay> <start_tick> <end_tick>"
    quit(1)

  let
    path = paramStr(1)
    startTick = if paramCount() >= 2: parseInt(paramStr(2)) else: 0
    endTick = if paramCount() >= 3: parseInt(paramStr(3)) else: 99999
    data = loadReplay(path)

  var
    player = initReplayPlayer(data)
    sim = deserializeReplaySim(data.keyframes[0].simBytes)

  while sim.tick < startTick:
    if not sim.stepReplay(data, player.joinIndex, player.leaveIndex,
                   player.chatIndex, player.inputIndex, player.hashIndex,
                   player.masks, player.lastAppliedMasks):
      break

  while sim.tick <= endTick:
    if sim.tick >= startTick and sim.tick mod 100 == 0:
      echo &"tick {sim.tick}"
      for i in 0 ..< sim.players.len:
        let p = sim.players[i]
        if p.slot >= 0 and p.alive:
          let team = if p.team == Red: "R" else: "B"
          let carry = if p.carriedFlag == Red: " CARRY-R"
                      elif p.carriedFlag == Blue: " CARRY-B"
                      else: ""
          echo &"  {team}{p.slot} {p.name:18s} x={p.pos.x div 256:4d} y={p.pos.y div 256:3d}{carry}"

    if not sim.stepReplay(data, player.joinIndex, player.leaveIndex,
                          player.chatIndex, player.inputIndex, player.hashIndex,
                          player.masks, player.lastAppliedMasks):
      break

when isMainModule:
  main()

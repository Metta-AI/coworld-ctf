## SCRATCH (endcard lane, NOT for landing): what does the WIN actually mint?
## Re-simulates one replay and prints the achievement feed WITH per-claim
## ticks plus the final team ledger, so the endcard's displayed totals can be
## checked against the terminal-tick mints specifically (the known trap
## class: terminal-tick achievements minting landing after the displayed
## total was computed). dump_glory_from_replay prints the whole-episode
## ledger; this adds the WHEN.

import
  std/[os, strformat],
  ../src/ctf/sim,
  toolutil

when isMainModule:
  if paramCount() < 1:
    quit("Usage: endcard_mint_scratch <replay.bitreplay>", 1)
  let
    path = paramStr(1).absolutePath()
    data = parseReplayBytes(readFile(path))
    previousDir = getCurrentDir()
  chdirGameDir()
  # mismatchQuit=false: tolerate recorded-hash drift (the server's own
  # playback posture) and REPORT it, so a drifted re-simulation is loudly
  # labeled rather than silently trusted or refused outright.
  var (srv, replay) = openReplay(data, mismatchQuit = false)
  var lastTick = 0
  var gameOverTick = -1
  while replay.playing:
    let tick = srv.tickCount + 1
    try:
      replay.stepReplay(srv)
    except ReplayError:
      echo &"DIVERGED at tick {tick} -- everything below is UNTRUSTWORTHY"
      quit(1)
    lastTick = tick
    if gameOverTick < 0 and srv.phase == GameOver:
      gameOverTick = tick
  setCurrentDir(previousDir)
  if replay.hashMismatchTick >= 0:
    echo &"WARNING: recorded-hash mismatch first seen at tick {replay.hashMismatchTick}"
    echo "  (re-simulated outcome below must be cross-checked against the"
    echo "   platform's own episode scores before it is trusted)"

  echo &"replay: {path}"
  echo &"  ticks: {lastTick}  gameOver at tick: {gameOverTick}"
  echo &"  phase: {srv.phase}  winner: {srv.winner}  draw: {srv.isDraw}"
  echo ""
  echo "ACHIEVEMENT FEED (claim order): tick / team / tree tier / glory / slot"
  for c in srv.achievementFeed:
    let mark = if gameOverTick >= 0 and c.tick >= gameOverTick: "  <-- TERMINAL-TICK MINT" else: ""
    echo &"  t={c.tick:<6} {$c.team:<8} {$c.tree:<10} T{c.tier} +{c.glory:<4}" &
      (if c.first: " FIRST" else: "      ") & &" slot={c.slot}{mark}"
  echo ""
  echo "TEAM GLORY (srv.teamGlory after full re-simulation)"
  for team in srv.teams():
    echo &"  {$team:<8} {srv.teamGlory[team]:>6}"
  echo ""
  echo "DEED AUDIT (nonzero)"
  for deed in Deed:
    if srv.deedCounts[deed] > 0:
      echo &"  {$deed:<20} x{srv.deedCounts[deed]:<4} glory-mass={srv.deedGloryMass[deed]}"

## The replay-path answer to "did Glory mint in THIS episode?" —
## expand_replay's event map does not cover glory, and increment 2's
## minting proof read the LIVE broadcast JSON, which a recorded episode
## no longer has. This re-simulates the replay through the same loop the
## divergence instrument uses, keeps the sim, and dumps the ledger it
## accrued: per-team glory, the deed audit counters, and the winner.

import
  std/[os, strformat, strutils],
  ../src/ctf/sim,
  toolutil

when isMainModule:
  if paramCount() < 1:
    quit("Usage: dump_glory_from_replay <replay.bitreplay>", 1)
  let
    path = paramStr(1).absolutePath()
    data = parseReplayBytes(readFile(path))
    previousDir = getCurrentDir()
  chdirGameDir()
  var (srv, replay) = openReplay(data)
  var lastTick = 0
  while replay.playing:
    let tick = srv.tickCount + 1
    try:
      replay.stepReplay(srv)
    except ReplayError:
      echo &"DIVERGED at tick {tick} — ledger below is UNTRUSTWORTHY"
      quit(1)
    lastTick = tick
  setCurrentDir(previousDir)

  echo &"replay: {path}"
  echo &"  ticks re-simulated : {lastTick}"
  echo &"  final phase        : {srv.phase}  winner: {srv.winner}  draw: {srv.isDraw}"
  echo ""
  echo "TEAM GLORY LEDGER (srv.teamGlory after full re-simulation)"
  var teamsNonzero = 0
  var total = 0
  for team in Team:
    let g = srv.teamGlory[team]
    if g != 0:
      inc teamsNonzero
    total += g
    echo &"  {team:<10} {g:>8}"
  echo &"  TOTAL      {total:>8}   ({teamsNonzero} teams nonzero)"
  echo ""
  echo "DEED AUDIT (srv.deedCounts, nonzero only)"
  var deedsFired = 0
  for deed in Deed:
    if srv.deedCounts[deed] > 0:
      inc deedsFired
      echo &"  {deed:<20} x{srv.deedCounts[deed]}"
  echo &"  {deedsFired} distinct deed kinds fired"
  if total == 0:
    quit("FAIL: zero glory minted anywhere — the hooks did not fire in this episode.", 1)

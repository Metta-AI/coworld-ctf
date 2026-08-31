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
  # GLORY v11 (BR increment 3, level-pacing measurement): trace every LEVEL
  # CROSSING (never a dip -- levelForXp is monotonic in xp within a life) so
  # a level-threshold tune can be read off a real episode instead of guessed
  # blind. `lastLevel` starts at -1 so tick-0's level (usually 0) still logs
  # a crossing row and every player gets at least one line even if they
  # never level up.
  var lastLevel: seq[int] = @[]
  var crossings: seq[tuple[tick, playerIndex: int, team: Team, level: int]] = @[]
  while replay.playing:
    let tick = srv.tickCount + 1
    try:
      replay.stepReplay(srv)
    except ReplayError:
      echo &"DIVERGED at tick {tick} — ledger below is UNTRUSTWORTHY"
      quit(1)
    lastTick = tick
    # Seats join progressively during a replay (join events, not day-0
    # roster), so `srv.players` grows over the course of playback -- pad
    # `lastLevel` to match each tick rather than sizing it once up front.
    while lastLevel.len < srv.players.len: lastLevel.add -1
    for i, p in srv.players:
      if p.level != lastLevel[i]:
        crossings.add (tick, i, p.team, p.level)
        lastLevel[i] = p.level
  setCurrentDir(previousDir)

  echo &"replay: {path}"
  echo &"  ticks re-simulated : {lastTick}"
  echo &"  zone center        : ({srv.zoneCenter.x}, {srv.zoneCenter.y})  board: {srv.gameMap.width}x{srv.gameMap.height}"
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
  echo ""
  echo &"LEVEL TRACE (winner: {srv.winner}), tick / player / level"
  var finalLevel = newSeq[int](srv.players.len)
  var peakLevel = newSeq[int](srv.players.len)
  for c in crossings:
    if c.team == srv.winner:
      echo &"  t={c.tick:<6} p{c.playerIndex:<3} ({c.team:<8}) -> L{c.level}"
    finalLevel[c.playerIndex] = c.level
    if c.level > peakLevel[c.playerIndex]: peakLevel[c.playerIndex] = c.level
  echo ""
  echo "FINAL / PEAK LEVEL by player on the WINNING team"
  var winnerFinalSum, winnerFinalCount = 0
  for i, p in srv.players:
    if p.team == srv.winner:
      echo &"  p{i:<3} final=L{finalLevel[i]} peak=L{peakLevel[i]}"
      winnerFinalSum += finalLevel[i]
      inc winnerFinalCount
  if winnerFinalCount > 0:
    echo &"  winning-team median-ish final level (mean): " &
      &"{winnerFinalSum / winnerFinalCount:.2f}"
  echo ""
  echo "FINAL XP / LEVEL, every player that ever left L0 (all 16 teams)"
  for i, p in srv.players:
    if peakLevel[i] > 0 or p.xp > 0:
      echo &"  p{i:<3} ({$p.team:<8}) finalXp={p.xp:<5} final=L{finalLevel[i]} peak=L{peakLevel[i]}"
  echo ""
  echo "MULTIPLIER SWEEP -- what level each player's FINAL xp buys at " &
    "candidate BrLevelThresholdMultPct values (pure re-derivation off the " &
    "recorded final xp, no re-simulation; a player who died mid-match " &
    "shows xp=0/L0, resetLadder's own per-life-reset semantics)"
  for pct in [100, 200, 300, 350, 400, 500]:
    var levelSum, levelCount, l5count = 0
    var maxLevel = 0
    for i, p in srv.players:
      # `levelForXp` bakes in the compiled `BrLevelThresholdMultPct` --
      # sweeping several candidate percentages means re-deriving the same
      # threshold check inline rather than calling it.
      var lvlAtPct = 0
      for threshold in LevelThresholds:
        if p.xp >= threshold * pct div 100: inc lvlAtPct
        else: break
      levelSum += lvlAtPct
      inc levelCount
      if lvlAtPct > maxLevel: maxLevel = lvlAtPct
      if lvlAtPct >= 5: inc l5count
    echo &"  {pct:>4}%  mean-final-level={levelSum / levelCount:.2f}  " &
      &"max={maxLevel}  L5-count={l5count}/32"
  if total == 0:
    quit("FAIL: zero glory minted anywhere — the hooks did not fire in this episode.", 1)

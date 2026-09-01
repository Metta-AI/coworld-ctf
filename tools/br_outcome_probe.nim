## br_outcome_probe — extracts PLAYED per-spawn-group outcomes from finished
## BR replays, for the probe suite's earn-the-switch gates (win-share floor,
## contested-finish rate, ring bias). Statics cannot answer any of these: the
## zone center is DRAWN per episode from the sim RNG, and the team -> spawn
## group binding rotates per episode (spawnGroupOffset), so only real episode
## data can say whether the closing zone favors certain spawns.
##
## One JSON row per replay on stdout (or --out FILE, appended), consumed by
## tools/mapgen_play_gate.py.
##
## INSTRUMENTATION RULE (the carrier-sampler branch's lesson, inherited):
## event-drained state reads zero — the sim consumes its own event queue
## before any post-hoc reader arrives. This probe therefore reads ONLY
## persistent state: per-tick SNAPSHOTS of monotone counters (players[].kills,
## alive flags) taken while it drives the replay loop itself, plus end-state
## fields that survive GameOver (winner, isDraw, lastDeathTick, zoneCenter,
## brPlacements' total order). sim.events is never touched.
##
## EPISODE-BUDGET REALISM (why every consumer of these rows is
## budget-parameterized): 16 spawn groups need roughly 8x the episode budget
## a 2-team CTF question needs, because each episode yields ONE winner among
## 16 groups instead of one among two.
##   * Detecting a group that NEVER wins (share 0 vs uniform 1/16): the
##     one-sided exact test P(0 wins in N | 1/16) = (15/16)^N needs N >= 47
##     episodes for p < 0.05.
##   * Detecting a 2x-favored group (share 1/8 vs 1/16) needs N in the low
##     hundreds; a full 16-group certification sweep at 95% power needs
##     N >= ~400.
##   * Placement-rank measures (the ring-bias gate) converge much faster than
##     win share because every episode yields a FULL 1..16 ranking, not one
##     bit — which is why the ring-bias gate is defined on placements.
## Small-N runs DEMONSTRATE the instrument; they do not certify a map. The
## play gate prints the same warning when N is below the exact-test floor.
##
## Usage:
##   nim r -d:release tools/br_outcome_probe.nim ep1.bitreplay [ep2 ...] \
##       [--out rows.jsonl]

import
  std/[json, os, strutils],
  ../src/ctf/[replays, sim],
  toolutil

proc groupOfTeam(sim: SimServer, team: Team): int =
  ## Which spawn GROUP (block of gameMap.spawnPoints) this team was dealt
  ## this episode: sim_state.nim's own binding, `(ord(team) + offset) mod
  ## teamCount` with offset = spawnGroupOffset(), a pure function of the
  ## config seed. NOT read back via spawnPosition(): that proc nudges through
  ## nearestWalkable against CURRENT occupancy, so a post-game call can land
  ## off the authored point (measured: 3 of 8 real episodes failed an exact
  ## match). The formula is pinned against sim_state.nim's source in
  ## tests/test_defect_probe.nim, so drift there fails the suite.
  if sim.gameMap.spawnPoints.len == 0: return int(team)
  (ord(team) + sim.spawnGroupOffset()) mod sim.gameMap.teamCount()

proc probeReplay*(path: string): JsonNode =
  let data = loadReplay(path)
  var (sim, replay) = openReplay(data)
  let teamCount = sim.config.teams
  ## Per-team elimination records, built from per-tick snapshots of
  ## PERSISTENT counters while this loop drives the replay.
  var
    elimTick = newSeq[int](teamCount)      # -1 = survived
    elimByCombat = newSeq[bool](teamCount)
    prevAlive = newSeq[bool](teamCount)
    prevKills = 0
  for t in 0 ..< teamCount: elimTick[t] = -1
  for t in 0 ..< teamCount: prevAlive[t] = true

  proc aliveOf(sim: SimServer): seq[bool] =
    result = newSeq[bool](teamCount)
    for p in sim.players:
      if p.alive and int(p.team) < teamCount:
        result[int(p.team)] = true

  proc totalKills(sim: SimServer): int =
    for p in sim.players: result += p.kills

  var started = false
  while replay.playing:
    replay.stepReplay(sim)
    if not started:
      ## Snapshot baselines once the roster is seated (startGame respawns
      ## everyone); before that every team reads dead-by-default.
      var seated = 0
      for p in sim.players:
        if p.alive: inc seated
      if seated > 0:
        started = true
        prevAlive = sim.aliveOf()
        prevKills = sim.totalKills()
      continue
    let nowAlive = sim.aliveOf()
    let nowKills = sim.totalKills()
    for t in 0 ..< teamCount:
      if prevAlive[t] and not nowAlive[t]:
        elimTick[t] = sim.tickCount
        ## Combat-caused iff SOMEONE's persistent kill counter moved on the
        ## exact tick the team died; a zone (environment) death credits no
        ## killer, so the counter stays flat.
        elimByCombat[t] = nowKills > prevKills
    prevAlive = nowAlive
    prevKills = nowKills

  let placements = sim.brPlacements()
  let finished = sim.phase == GameOver
  var aliveTeams = 0
  for t in 0 ..< teamCount:
    if prevAlive[t]: inc aliveTeams
  let byTimeout = aliveTeams > 1
    ## >1 teams still standing at GameOver = the clock (or maxGames), not an
    ## elimination, ended it: nobody contested the finish.

  ## Runner-up = placement rank 2; the finish is CONTESTED when the game
  ## ended by elimination and the FINAL elimination (the runner-up's) was a
  ## combat kill rather than zone attrition.
  var runnerUp = -1
  for t in 0 ..< teamCount:
    if placements[Team(t)] == 2: runnerUp = t
  let contested =
    finished and not byTimeout and runnerUp >= 0 and
    elimTick[runnerUp] >= 0 and elimByCombat[runnerUp]

  var groups = newJArray()
  for t in 0 ..< teamCount:
    let team = Team(t)
    let g = sim.groupOfTeam(team)
    let pts = sim.gameMap.spawnPoints
    var sx, sy = -1
    if g >= 0 and pts.len > 0:
      let perTeam = max(1, pts.len div teamCount)
      sx = pts[g * perTeam].x
      sy = pts[g * perTeam].y
    var kills, damage = 0
    for p in sim.players:
      if int(p.team) == t:
        kills += p.kills
        damage += p.damageDealt
    groups.add %*{
      "team": t,
      "group": g,
      "spawnX": sx,
      "spawnY": sy,
      "placement": placements[team],
      "kills": kills,
      "damage": damage,
      "elimTick": elimTick[t],
      "elimByCombat": elimByCombat[t],
    }

  %*{
    "replay": path.extractFilename,
    "map": sim.gameMap.name,
    "seed": sim.config.seed,
    "ticks": sim.tickCount,
    "maxTicks": sim.config.maxTicks,
    "finished": finished,
    "isDraw": sim.isDraw,
    "byTimeout": byTimeout,
    "contested": contested,
    "winnerTeam": (if finished and not sim.isDraw: int(sim.winner) else: -1),
    "winnerGroup": (
      if finished and not sim.isDraw: sim.groupOfTeam(sim.winner) else: -1),
    "zoneCenterX": sim.zoneCenter.x,
    "zoneCenterY": sim.zoneCenter.y,
    "mapCenterX": sim.gameMap.center.x,
    "mapCenterY": sim.gameMap.center.y,
    "groups": groups,
  }

when isMainModule:
  var paths: seq[string]
  var outPath = ""
  var params = commandLineParams()
  var i = 0
  while i < params.len:
    if params[i] == "--out" and i + 1 < params.len:
      outPath = params[i + 1]
      inc i
    else:
      paths.add params[i]
    inc i
  if paths.len == 0:
    quit("usage: br_outcome_probe <replay.bitreplay>... [--out rows.jsonl]")
  var outFile: File
  if outPath.len > 0:
    outFile = open(outPath, fmAppend)
  for path in paths:
    let row = probeReplay(path)
    if outPath.len > 0:
      outFile.writeLine($row)
      stderr.writeLine("  " & path.extractFilename & " -> " & outPath)
    else:
      echo $row
  if outPath.len > 0:
    outFile.close()

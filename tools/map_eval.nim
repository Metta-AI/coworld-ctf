## The map fitness harness: load or generate maps -> hard gates -> static
## score -> (top-k only) simulate N episodes -> rank.
##
## This is the measuring stick, built before anything changes what it
## measures. It wires together pieces that already existed and were never
## joined into a loop: `map_metrics` (pure static geometry), the
## `benchmark_game` self-play orchestration (which never set
## COGAME_SAVE_REPLAY_URI, so it produced no replay — that is added here),
## and `extract_events --frames`, whose per-tick per-seat state is the
## travel-heatmap substrate nothing else in the repo carries.
##
## Usage:
##   nim c -d:release -o:/tmp/mapeval tools/map_eval.nim
##   /tmp/mapeval --map pool:0 --map pool:3 --map gen:4242 --episodes 3
##
## Map sources (`--map`, repeatable):
##   arena | arena-large   the hand-authored maps
##   gen:<seed>            the generator, mapPath "gen" + mapSeed
##   pool:<index>          the curated pool, mapPath "pool" + mapPoolIndex
##   spec:<path.json>      an arbitrary inline mapSpec. resolveCtfMapMetadata
##                         checks mapSpec FIRST, before any named map or
##                         generator call, so this is the hook for scoring a
##                         hand-authored candidate that no seed produces.
##
## THE FIVE META-RULES, enforced here rather than by discipline. Each was
## learned by producing a confidently wrong number:
##
##   1. The default `arena` runs as CONTROL in every batch — it is injected
##      whether you asked for it or not, and ranking is REFUSED without it.
##      A metric that flags your control is wrong; a metric that SKIPS your
##      control is worse. Both happened. Every scored band is therefore
##      checked against the control first, and a band the control fails is
##      reported as a METRIC BUG, not as a bad map.
##   2. Never a count without its fraction. Every count printed below is
##      followed by the fraction that disambiguates it: one narrow doorway
##      and one enormous gap both score "1".
##   3. Merge >= 3 seeds before judging (`--episodes 3` is the minimum the
##      report will not warn about).
##   4. A capture ENDS the episode, so episode length is itself an outcome.
##      Every episode's tick count and result is printed, and dead space is
##      never compared across samples of different length.
##   5. Thresholds are picked against the control, and a value sitting
##      within a quarter of a band's taper of a real bound prints "tight",
##      so slack stays visible instead of being silently spent by the next
##      change. Bounds that do not exist ("at least 3 routes" has no ceiling)
##      are marked open and never produce a phantom warning.
##
## Static scoring is free (tens of ms); SIMULATION is the budget, which is
## why only the top-k are played. Always build -d:release: debug is 10-50x
## slower through the per-pixel map code.
import
  std/[algorithm, json, math, monotimes, net, os, osproc, sequtils, streams,
    strformat, strutils, times],
  ../src/ctf/sim,
  extract_events,
  toolutil

## `map_metrics` (the measurements) and `map_score` (the bands, the gates and
## the best-of-K ranker) moved into `src/ctf/` when the GENERATOR started
## ranking with them — this harness and `generateCtfMap` must judge maps by
## the same rubric or the pool is curated against a score nothing ships. They
## arrive re-exported through `ctf/sim`.

const
  UsageText = """
Usage: map_eval [options]
  --map <src>        arena | arena-large | gen:<seed> | pool:<idx> |
                     spec:<path.json>   (repeatable)
  --pool <n>         shorthand for pool:0 .. pool:<n-1>
  --episodes <n>     self-play episodes per simulated map (default 0)
  --topk <k>         simulate only the k best static scorers (default all)
  --out <dir>        artifact directory (default /tmp/map-eval)
  --max-ticks <n>    playing-tick cap (default 3000; the reported tick count
                     also carries the lobby and any banked overtime, so it
                     legitimately exceeds this)
  --lives <n>        lives per player (default: config.json's). Raise it to
                     keep the episode alive long enough to observe the
                     objective — at the shipped 3, a 16-seat game is decided
                     by attrition before anyone converts a steal.
  --seats <n>        seats (default: 8 per team)
  --teams <n>        team count for `gen:` sources (default 2). `arena`,
                     `pool:` and `spec:` seat whatever they seat.
  --port <n>         base TCP port for the self-play server (default 21500)
  --seed <n>         base episode seed (default 7)
  --quick            skip the chokepoint pass (the one expensive stage)
  --rebuild          force a rebuild of bin/ctf-server and the baseline bot
"""
  ControlSource = "arena"
    ## The league default and the layout the engine was tuned on. It is the
    ## floor, not the target — and it is never optional.
  MinEpisodesForJudgement = 3
  HeatCell = AnalysisCell

type
  MapSource* = object
    label: string      ## how the user named it, e.g. "pool:3".
    kind: string       ## "arena" | "arena-large" | "gen" | "pool" | "spec"
    number: int
    specJson: string

  Episode = object
    index: int
    seed: int
    ticks: int
    captures: int
    steals: int
    deaths: int
    replayPath: string
    jsonPath: string
    ok: bool
    reason: string
    warning: string

  Candidate = object
    source: MapSource
    gameMap: CtfMap
    metrics: MapMetrics
    card: ScoreCard
    gateReason: string       ## "" when the hard gates pass.
    episodes: seq[Episode]

# ------------------------------------------------------------------ args ----

proc parseSource*(text: string): MapSource =
  result.label = text
  if text == "arena" or text == "arena-large":
    result.kind = text
    return
  let parts = text.split(':', 1)
  if parts.len != 2:
    quit("Unknown map source: " & text & "\n" & UsageText)
  result.kind = parts[0]
  case parts[0]
  of "gen", "pool":
    try:
      result.number = parseInt(parts[1])
    except ValueError:
      quit("Map source " & text & " needs an integer suffix.")
  of "spec":
    if not fileExists(parts[1]):
      quit("mapSpec file does not exist: " & parts[1])
    result.specJson = readFile(parts[1]).strip()
  else:
    quit("Unknown map source: " & text & "\n" & UsageText)

proc resolveSource*(source: MapSource, teams = 2): CtfMap =
  ## Resolves one source through the SERVER's own resolver, so the harness
  ## measures the map a game would get rather than a private reconstruction
  ## of it. mapSpec is checked first by resolveCtfMapMetadata, which is what
  ## makes `spec:` a first-class source.
  var config = defaultGameConfig()
  config.teams = teams
  case source.kind
  of "arena", "arena-large":
    ## The hand-authored maps seat two; asking for four would make
    ## resolveCtfMapMetadata reject them for a reason the caller did not
    ## mean by `--teams`.
    config.teams = 2
    config.mapPath = source.kind
  of "gen":
    config.mapPath = "gen"
    config.mapSeed = source.number
  of "pool":
    config.teams = 2
    config.mapPath = "pool"
    config.mapPoolIndex = source.number
    config.mapSeed = source.number
  of "spec":
    config.mapSpec = source.specJson
  else:
    raise newException(CtfError, "Unknown map source kind: " & source.kind)
  ## A spec or a 4-team generated map seats whatever it seats; ask for the
  ## count the map itself declares rather than guessing.
  if source.kind == "spec":
    config.teams = mapFromSpecJson(source.specJson).teamCount()
  resolveCtfMapMetadata(config)

# ------------------------------------------------------- self-play loop ----

proc buildBinary(outPath, source: string) =
  echo "  building ", outPath, " (release)..."
  let process = startProcess("nim",
    args = ["c", "-d:release", "--out:" & outPath, source],
    options = {poUsePath, poParentStreams})
  let code = process.waitForExit()
  process.close()
  if code != 0:
    quit("build failed: " & source)

proc drainToFile(arg: tuple[handle: FileHandle, path: string]) {.thread.} =
  ## The server echoes every game event, more than a pipe buffer holds —
  ## left undrained it fills up and deadlocks the game mid-match.
  var input: File
  if not input.open(arg.handle, fmRead):
    return
  let output = open(arg.path, fmWrite)
  var line = ""
  while input.readLine(line):
    output.writeLine(line)
    output.flushFile()
  output.close()
  input.close()

proc portListening(port: int): bool =
  let socket = newSocket()
  defer: socket.close()
  try:
    socket.connect("127.0.0.1", Port(port), timeout = 250)
    true
  except CatchableError:
    false

proc tailFile(path: string, lines: int): string =
  if not fileExists(path):
    return ""
  let all = readFile(path).strip().splitLines()
  all[max(0, all.len - lines) .. ^1].join("\n")

proc writeEpisodeConfig(
  source: MapSource, gameMap: CtfMap, seed, maxTicks, seats, lives: int
): string =
  ## The episode config, derived from the repo config so the rules are the
  ## shipped ones. The map is selected by the SOURCE's own knobs, not by
  ## pinning the resolved spec — that keeps the gen / pool / spec resolution
  ## paths under test, and the recorded replay's pinned mapSpec is compared
  ## against the scored map afterwards, so a divergence is loud.
  let teams = gameMap.teamCount()
  var config = parseJson(readFile("config.json"))
  config["seed"] = %seed
  config["maxTicks"] = %maxTicks
  config["maxGames"] = %1
  config["teams"] = %teams
  config["fastMode"] = %true
  config["minPlayers"] = %seats
  if lives > 0:
    config["lives"] = %lives
  case source.kind
  of "arena", "arena-large":
    config["mapPath"] = %source.kind
  of "gen":
    config["mapPath"] = %"gen"
    config["mapSeed"] = %source.number
  of "pool":
    config["mapPath"] = %"pool"
    config["mapPoolIndex"] = %source.number
  of "spec":
    config["mapSpec"] = %source.specJson
  else: discard
  var tokens = newJArray()
  var players = newJArray()
  var slots = newJArray()
  const TeamNames = ["red", "blue", "green", "yellow"]
  for slot in 0 ..< seats:
    tokens.add(%("0xBADA55_" & $slot))
    players.add(%*{"name": &"eval_{slot}"})
    slots.add(%*{"team": TeamNames[slot mod teams],
                 "color": TeamNames[slot mod teams]})
  config["tokens"] = tokens
  config["players"] = players
  config["slots"] = slots
  result = getTempDir() / &"ctf-mapeval-cfg-{getCurrentProcessId()}-{seed}.json"
  writeFile(result, $config)

proc recordEpisode(
  source: MapSource, gameMap: CtfMap, seed, maxTicks, seats, lives,
  port: int, replayPath: string
): string =
  ## Runs one headless self-play episode and writes a .bitreplay.
  ##
  ## This is `benchmark_game`'s orchestration with the one piece it never
  ## had: COGAME_SAVE_REPLAY_URI. Without it the benchmark produced timings
  ## and no evidence; `record_fixture.sh` had the missing line and no loop.
  let configPath =
    writeEpisodeConfig(source, gameMap, seed, maxTicks, seats, lives)
  ## Logs land NEXT TO the evidence, not in the system temp directory: the
  ## first episode that failed left its explanation somewhere unreachable.
  let
    serverLog = replayPath.changeFileExt("server.log")
    eventsPath = replayPath.changeFileExt("events.jsonl")
  removeFile(replayPath)
  var
    serverProcess: Process = nil
    botProcesses: seq[Process]
  proc shutdown() =
    if serverProcess != nil and serverProcess.running:
      serverProcess.kill()
    for bot in botProcesses:
      if bot.running:
        bot.kill()
  try:
    let started = getMonoTime()
    putEnv("COGAME_HOST", "127.0.0.1")
    putEnv("COGAME_PORT", $port)
    putEnv("COGAME_CONFIG_URI", "file://" & configPath)
    putEnv("COGAME_EVENTS_URI", "file://" & eventsPath)
    putEnv("COGAME_SAVE_REPLAY_URI", "file://" & replayPath.absolutePath())
    serverProcess = startProcess(GameDir / "bin/ctf-server",
      workingDir = GameDir, options = {poStdErrToStdOut})
    var logThread: Thread[tuple[handle: FileHandle, path: string]]
    createThread(logThread, drainToFile,
      (serverProcess.outputHandle, serverLog))
    while not portListening(port):
      if not serverProcess.running:
        joinThread(logThread)
        return "server died during startup:\n" & tailFile(serverLog, 12)
      if (getMonoTime() - started).inSeconds > 480:
        return "server never listened:\n" & tailFile(serverLog, 12)
      sleep(200)
    putEnv("CTF_BOT_FAST_READY", "1")
    for slot in 0 ..< seats:
      putEnv("COWORLD_PLAYER_WS_URL",
        &"ws://127.0.0.1:{port}/player?slot={slot}&token=0xBADA55_{slot}")
      botProcesses.add(startProcess(GameDir / "players/baseline/baseline.out",
        workingDir = GameDir, options = {poStdErrToStdOut}))
    let botsUp = getMonoTime()
    while serverProcess.running:
      if (getMonoTime() - botsUp).inSeconds > 900:
        return "episode hung past 15 minutes:\n" & tailFile(serverLog, 12)
      sleep(100)
    joinThread(logThread)
    for bot in botProcesses:
      if bot.running:
        bot.kill()
      discard bot.outputStream.readAll()
    if not fileExists(replayPath) or getFileSize(replayPath) < 10_000:
      ## A replay under ~10KB is a truncated episode, not evidence.
      let size = if fileExists(replayPath): getFileSize(replayPath) else: 0
      return &"replay missing or truncated ({size} bytes; log at " &
        &"{serverLog}):\n" & tailFile(serverLog, 12)
    ""
  finally:
    shutdown()
    removeFile(configPath)

# ---------------------------------------------------- dynamic extraction ----

proc balanceEntropy*(kills: seq[int]): float =
  ## B = -sum (k_i/K) * log_N(k_i/K), log base N = TEAM COUNT, so the value
  ## stays in [0, 1] for 2, 3, 4 and 6 teams and is directly comparable
  ## across modes. 1.0 = every team took an equal share of the kills.
  let teams = kills.len
  if teams < 2:
    return 0.0
  var total = 0
  for k in kills:
    total += k
  if total <= 0:
    return 0.0
  for k in kills:
    if k <= 0:
      continue
    let p = k.float / total.float
    result -= p * (ln(p) / ln(teams.float))

proc extractEpisode(
  source: MapSource, gameMap: CtfMap, replayPath, outPath: string,
  episode: var Episode
): string =
  ## Re-simulates one recorded episode and writes the evidence set the
  ## Python report and heatmap consume.
  ##
  ## Two channels, from ONE hash-validated walk: the tier-2 event stream
  ## (deaths, steals, captures, damage ticks) and `--frames` per-tick
  ## per-seat state (occupancy, carry routes). The re-simulation also proves
  ## the recording is deterministic.
  let data = loadReplay(replayPath)

  ## The replay pins the resolved geometry. If it is not the map that was
  ## scored, every dynamic number below belongs to a different map.
  let recorded = parseJson(data.configJson){"mapSpec"}.getStr("")
  if recorded.len > 0 and recorded != mapSpecJson(gameMap):
    return "recorded mapSpec differs from the scored map — the episode " &
      "played different terrain than the static score measured"

  let extraction = extractEvents(data, captureFrames = true)
  let results = parseJson(extraction.resultsJson)
  let teams = gameMap.teamCount()
  var seatTeam: seq[int]
  const TeamNames = ["red", "blue", "green", "yellow"]
  for entry in results["team"]:
    var index = -1
    for t in 0 ..< TeamNames.len:
      if entry.getStr() == TeamNames[t]:
        index = t
    seatTeam.add index
  var teamKills = newSeq[int](teams)
  for i, entry in results["kills"].getElems():
    if i < seatTeam.len and seatTeam[i] >= 0 and seatTeam[i] < teams:
      teamKills[seatTeam[i]] += entry.getInt()

  let masks = buildMapMasks(gameMap, HeatCell)
  let
    gw = masks.gw
    gh = masks.gh
  var
    occupancy = newSeq[int](gw * gh)
    occTeam = newSeq[seq[int]](teams)
  for t in 0 ..< teams:
    occTeam[t] = newSeq[int](gw * gh)

  var carries: seq[JsonNode]
  var captureAt: seq[JsonNode]
  var capturesByPredicate = 0
  var zones: seq[CaptureZone]
  for team in gameMap.teams():
    zones.add gameMap.captureZone(team)
  var lastCarrier = newSeq[int](teams)
  for team in 0 ..< teams:
    lastCarrier[team] = -1

  for frame in 0 ..< extraction.frameCount:
    for seat in 0 ..< extraction.frameSlots:
      let state = extraction.frameSeat(frame, seat)
      if (state.flags and 1) == 0:
        continue
      let
        cx = clamp(state.x div HeatCell, 0, gw - 1)
        cy = clamp(state.y div HeatCell, 0, gh - 1)
        index = cy * gw + cx
      inc occupancy[index]
      if seat < seatTeam.len and seatTeam[seat] >= 0 and
          seatTeam[seat] < teams:
        inc occTeam[seatTeam[seat]][index]
    for team in 0 ..< teams:
      let flag = extraction.frameFlag(frame, team)
      if flag.carrier >= 0:
        if frame mod 4 == 0:
          ## Sampled: a carry lasts hundreds of ticks and the ROUTE is what
          ## matters, not the pixel-by-pixel walk.
          carries.add(%*{"x": flag.x, "y": flag.y, "flag": TeamNames[team]})
        lastCarrier[team] = flag.carrier
        continue
      if lastCarrier[team] < 0:
        continue
      ## The carry ended on this tick — capture, carrier death, or return.
      ##
      ## A capture cannot be read off the carrier -> -1 edge ALONE: scoring
      ## resets the carrier inside the same tick and ends the game, which is
      ## how an earlier pass reported 0 captures on every map including the
      ## arena. It cannot be read off "carrier is standing in the zone"
      ## either, for the same reason — the frame written after the tick
      ## already shows carrier -1, and a first attempt at this check duly
      ## reported 0 crossings against 1 real Capture event.
      ##
      ## What works is the edge AND the engine's own predicate, evaluated on
      ## the state the tick left behind: the carrier is still standing where
      ## they scored. A carrier who merely died fails the predicate, which
      ## is exactly the discrimination the edge alone lacks.
      let
        seat = lastCarrier[team]
        carrier = extraction.frameSeat(frame, seat)
        scoring = if seat < seatTeam.len: seatTeam[seat] else: -1
      lastCarrier[team] = -1
      if scoring < 0 or scoring >= teams or (carrier.flags and 1) == 0:
        continue
      if zones[scoring].inCaptureZone(carrier.x, carrier.y):
        inc capturesByPredicate

  var
    deaths: seq[JsonNode]
    steals = 0
    captures = 0
    damageTicks: seq[int]
    lastDamageTick = -1
  for event in extraction.events:
    case event.kind
    of Death:
      let team =
        if event.source >= 0 and event.source < seatTeam.len:
          seatTeam[event.source]
        else:
          -1
      deaths.add(%*{"x": int(event.x), "y": int(event.y),
        "tick": event.tick,
        "team": (if team >= 0: TeamNames[team] else: "unknown")})
    of FlagSteal:
      inc steals
    of Capture:
      inc captures
      captureAt.add(%*{"x": int(event.x), "y": int(event.y),
        "tick": event.tick})
    of Damage:
      if event.tick != lastDamageTick:
        damageTicks.add event.tick
        lastDamageTick = event.tick
    else:
      discard

  ## Two masks, because they answer two questions and swapping them is a
  ## real error. `wall` is "a player cannot stand here" — the one occupancy,
  ## dead space and midfield crossings are read against. `wallLos` is "a
  ## shot is stopped here", which is what a sightline is; reading sightlines
  ## off the footprint mask gave the control an 80px median against the
  ## 112px the static side reported for the same map.
  var wall = newJArray()
  var wallLos = newJArray()
  for i in 0 ..< gw * gh:
    wall.add(%(not masks.freeCell[i]))
    wallLos.add(%masks.wallCell[i])

  proc pointNode(p: MapPoint): JsonNode = %*{"x": p.x, "y": p.y}

  var homes = newJArray()
  var spawns = newJArray()
  for team in gameMap.teams():
    let
      anchor = gameMap.teamAnchor(team)
      half = gameMap.spawnPocketHalf(team)
    homes.add(%*{"team": TeamNames[ord(team)],
      "x": anchor.x, "y": anchor.y})
    spawns.add(%*{"team": TeamNames[ord(team)],
      "x": anchor.x - half.w, "y": anchor.y - half.h,
      "w": 2 * half.w, "h": 2 * half.h})

  var trenches = newJArray()
  for t in gameMap.trenches:
    ## GV37 made a trench an `ArenaShape` (it can be a disc or a hex, not just
    ## a box), so the artifact carries its BOUNDING BOX — the renderer only
    ## ever wanted an extent to draw. `shapeAsRect` is exact only for an
    ## axis-aligned bar and would mis-size anything else.
    let b = shapeBounds(t)
    trenches.add(%*{"x": b.x0, "y": b.y0,
      "w": b.x1 - b.x0 + 1, "h": b.y1 - b.y0 + 1})

  var occTeamNode = newJArray()
  for t in 0 ..< teams:
    occTeamNode.add(%occTeam[t])

  let ticks = extraction.ticks
  ## `occRed` / `occBlue` are the two-team names the ported heatmap tints
  ## warm and cool. On a 4-team board they are teams 0 and 1; every team's
  ## grid is in `occTeam`.
  var payload = %*{
    "map": gameMap.name,
    "source": source.label,
    "episode": episode.index,
    "seed": episode.seed,
    "ticks": ticks,
    "cell": HeatCell,
    "gw": gw, "gh": gh,
    "teams": teams,
    "occupancy": occupancy,
    "occTeam": occTeamNode,
    "occRed": occTeam[0],
    "occBlue": occTeam[min(1, teams - 1)],
    "wall": wall,
    "wallLos": wallLos,
    "deaths": deaths,
    "carries": carries,
    "captureAt": captureAt,
    "steals": steals,
    "captures": captures,
    "capturesByPredicate": capturesByPredicate,
    "homes": homes,
    "spawns": spawns,
    "redHome": pointNode(gameMap.flagHome(Red)),
    "blueHome": pointNode(gameMap.flagHome(Blue)),
    # Every hex endzone is a disc, so the radius is always the real one; the
    # heatmap's 0 meant "no circle to draw" on the deleted column shape.
    "captureRadius": gameMap.endzoneRadius,
    "trenches": trenches,
    "teamKills": teamKills,
    "balanceEntropy": balanceEntropy(teamKills),
    "fightTimeFrac": damageTicks.len.float / max(ticks, 1).float,
    "paceDeathsPer1000": deaths.len.float * 1000.0 / max(ticks, 1).float,
  }
  var redSpawn = spawns[0]
  payload["redSpawn"] = %*{"x": redSpawn["x"].getInt(),
    "y": redSpawn["y"].getInt(), "w": redSpawn["w"].getInt(),
    "h": redSpawn["h"].getInt()}
  if spawns.len > 1:
    payload["blueSpawn"] = %*{"x": spawns[1]["x"].getInt(),
      "y": spawns[1]["y"].getInt(), "w": spawns[1]["w"].getInt(),
      "h": spawns[1]["h"].getInt()}
  writeFile(outPath, $payload)
  episode.ticks = ticks
  episode.captures = captures
  episode.steals = steals
  episode.deaths = deaths.len
  episode.jsonPath = outPath
  if captures != capturesByPredicate:
    ## Not fatal — the evidence is still good — but the two channels are
    ## supposed to be two readings of one fact, so a gap means one of them
    ## is lying and the harness has to say which numbers to distrust.
    episode.warning = &"capture channels disagree: {captures} Capture " &
      &"events vs {capturesByPredicate} inCaptureZone crossings"
  ""

# --------------------------------------------------------------- report ----

proc stem(source: MapSource): string =
  ## A filesystem-safe artifact name. `spec:/tmp/x.json` carries a path
  ## separator, and a label pasted straight into a filename silently wrote
  ## into a directory that does not exist.
  for c in source.label:
    result.add(if c.isAlphaNumeric() or c == '-' or c == '_': c else: '-')

proc unitText(check: Check): string =
  case check.unit
  of "pct": &"{check.value * 100:6.1f}%"
  of "px": &"{check.value:6.0f}px"
  of "x": &"{check.value:6.2f}x"
  else: &"{check.value:6.1f} "

proc boundValue(check: Check, value: float): string =
  case check.unit
  of "pct": &"{value * 100:.0f}%"
  of "px": &"{value:.0f}px"
  of "x": &"{value:.2f}x"
  else: &"{value:.0f}"

proc boundText(check: Check): string =
  if check.loOpen and check.hiOpen: "[any]"
  elif check.loOpen: "<= " & check.boundValue(check.hi)
  elif check.hiOpen: ">= " & check.boundValue(check.lo)
  else: "[" & check.boundValue(check.lo) & ".." &
    check.boundValue(check.hi) & "]"

proc printStatic(candidate: Candidate, isControl: bool) =
  let metrics = candidate.metrics
  let tag = if isControl: "  <-- CONTROL" else: ""
  echo ""
  echo &"=== {candidate.source.label}  ({metrics.name}, " &
    &"{metrics.width}x{metrics.height}, {metrics.teamCount} teams, " &
    &"seed {metrics.genSeed}){tag}"
  if candidate.gateReason.len > 0:
    echo &"    HARD GATE FAILED: {candidate.gateReason}"
  echo &"    static score {candidate.card.score * 100:.1f}/100"
  for check in candidate.card.checks:
    let
      verdict =
        if not check.scored: "n/s"
        elif not check.passes(): "FAIL"
        elif check.isTight(): "tight"
        else: "ok"
      anchor =
        if not check.scored: " not scored: " & check.skipReason
        elif check.controlRelative: " (control-anchored)"
        else: ""
    echo &"    {check.name:<24}{check.unitText} {check.boundText:<14}" &
      &"{verdict:<6}{anchor}"
  ## Counts always with their fractions (meta-rule 2).
  for crossing in metrics.crossings:
    echo &"    midfield {crossing.axis:<10} {crossing.count} crossing(s) at " &
      &"the most divided line (x/y {crossing.linePx}px), median " &
      &"{crossing.medianCount} across the band; " &
      &"{crossing.openFrac * 100:.0f}% of that line open, widest " &
      &"{crossing.widestPx}px, narrowest {crossing.narrowestPx}px"
  for route in metrics.routes:
    let cut =
      if route.capped: &">= {route.minCutPx}px"
      else: &"{route.minCutPx}px"
    echo &"    routes {route.a}->{route.b}: " &
      &"{route.routes}{(if route.capped: \"+\" else: \"\")} disjoint, " &
      &"min cut {cut}, detour {route.detour:.2f}x " &
      &"({route.pathPx:.0f}px walked / {route.straightPx:.0f}px straight)"
  for stand in metrics.stands:
    echo &"    stand team {stand.team} at ({stand.x},{stand.y}): " &
      &"cover {stand.coverFrac * 100:.1f}% within {StandRadius}px " &
      &"({stand.protectedFrac * 100:.0f}% of that annulus is protected " &
      "floor the generator may not build in), ring " &
      &"r{stand.ringRadius} {stand.ringOpen * 100:.0f}% open in " &
      &"{stand.ringArcs} arc(s) " &
      &"({stand.ringProtectedFrac * 100:.0f}% of the ring is protected)"
  echo &"    chokepoints {metrics.chokepoints} genuine cut vertices of " &
    &"{metrics.chokeCandidates} medial-axis minima; one isovist covers " &
    &"all: {metrics.chokeCoveredByOnePoint}"
  echo &"    collision point ({metrics.collision.x},{metrics.collision.y}) " &
    &"over {metrics.collision.cells} cells " &
    &"({metrics.collision.frac * 100:.1f}% of floor), cover " &
    &"{metrics.collision.coverFrac * 100:.1f}% vs map " &
    &"{metrics.collision.mapCoverFrac * 100:.1f}%, clearance " &
    &"{metrics.collision.clearancePx:.0f}px vs map " &
    &"{metrics.collision.mapClearancePx:.0f}px"
  echo &"    enclosure: interior {metrics.interiorFrac * 100:.0f}%, " &
    &"covered {metrics.coveredFrac * 100:.0f}%, wide open " &
    &"{metrics.exposedFrac * 100:.0f}%"
  echo &"    sightlines: median {metrics.medianSightPx:.0f}px, P95 " &
    &"{metrics.p95SightPx:.0f}px, {metrics.longSightFrac * 100:.1f}% over " &
    &"{LongSightPx}px"
  echo &"    reported, not scored: {metrics.trenchCount} trenches " &
    "(the control has none, so a 3-8 band would flag it), " &
    &"{metrics.shapeCount} seed shapes"

proc metricsJson(metrics: MapMetrics, card: ScoreCard,
                 source: MapSource, gate: string): JsonNode =
  result = %*{
    "source": source.label,
    "name": metrics.name,
    "width": metrics.width, "height": metrics.height,
    "teams": metrics.teamCount, "genSeed": metrics.genSeed,
    "cell": metrics.cell,
    "compactEndzone": metrics.compactEndzone,
    "gateReason": gate,
    "validationReason": metrics.validationReason,
    "score": card.score,
    "wallFrac": metrics.wallFrac,
    "interiorFrac": metrics.interiorFrac,
    "coveredFrac": metrics.coveredFrac,
    "exposedFrac": metrics.exposedFrac,
    "p95OpenRunPx": metrics.p95OpenRunPx,
    "p95ClearancePx": metrics.p95ClearancePx,
    "medianSightPx": metrics.medianSightPx,
    "p95SightPx": metrics.p95SightPx,
    "longSightFrac": metrics.longSightFrac,
    "minRoutes": metrics.minRoutes,
    "minCutPx": metrics.minCutPx,
    "detourMean": metrics.detourMean,
    "chokeCandidates": metrics.chokeCandidates,
    "chokepoints": metrics.chokepoints,
    "chokeCoveredByOnePoint": metrics.chokeCoveredByOnePoint,
    "rectShapeFrac": metrics.rectShapeFrac,
    "shapeCount": metrics.shapeCount,
    "trenchCount": metrics.trenchCount,
    "standCoverMin": metrics.standCoverMin,
    "standCoverMax": metrics.standCoverMax,
    "standRingMin": metrics.standRingMin,
    "standRingMax": metrics.standRingMax,
    "standRingDelta": metrics.standRingDelta,
    "collision": {
      "x": metrics.collision.x, "y": metrics.collision.y,
      "cells": metrics.collision.cells, "frac": metrics.collision.frac,
      "coverFrac": metrics.collision.coverFrac,
      "mapCoverFrac": metrics.collision.mapCoverFrac,
      "clearancePx": metrics.collision.clearancePx,
      "mapClearancePx": metrics.collision.mapClearancePx,
    },
  }
  var stands = newJArray()
  for stand in metrics.stands:
    stands.add(%*{"team": stand.team, "x": stand.x, "y": stand.y,
      "coverFrac": stand.coverFrac, "protectedFrac": stand.protectedFrac,
      "ringRadius": stand.ringRadius,
      "ringOpen": stand.ringOpen, "ringArcs": stand.ringArcs,
      "ringProtectedFrac": stand.ringProtectedFrac})
  result["stands"] = stands
  var routes = newJArray()
  for route in metrics.routes:
    routes.add(%*{"a": route.a, "b": route.b, "routes": route.routes,
      "capped": route.capped, "minCutPx": route.minCutPx,
      "pathPx": route.pathPx, "straightPx": route.straightPx,
      "detour": route.detour})
  result["routes"] = routes
  var crossings = newJArray()
  for crossing in metrics.crossings:
    crossings.add(%*{"axis": crossing.axis, "count": crossing.count,
      "medianCount": crossing.medianCount, "linePx": crossing.linePx,
      "openFrac": crossing.openFrac, "widestPx": crossing.widestPx,
      "narrowestPx": crossing.narrowestPx})
  result["crossings"] = crossings
  var checks = newJArray()
  for check in card.checks:
    checks.add(%*{"name": check.name, "value": check.value,
      "lo": check.lo, "hi": check.hi, "unit": check.unit,
      "loOpen": check.loOpen, "hiOpen": check.hiOpen,
      "weight": check.weight, "controlRelative": check.controlRelative,
      "scored": check.scored, "skipReason": check.skipReason,
      "ok": check.passes(), "tight": check.isTight(), "note": check.note})
  result["checks"] = checks

# ----------------------------------------------------------------- main ----

proc main() =
  chdirGameDir()
  var
    sources: seq[MapSource]
    episodes = 0
    topK = 0
    outDir = "/tmp/map-eval"
    maxTicks = 3000
    basePort = 21500
    baseSeed = 7
    lives = 0
    seats = 0
    teams = 2
    quick = false
    rebuild = false
    params = commandLineParams()
    i = 0
  while i < params.len:
    let arg = params[i]
    proc next(): string =
      inc i
      if i >= params.len: quit(arg & " needs a value.\n" & UsageText)
      params[i]
    case arg
    of "--help", "-h": echo UsageText; quit(0)
    of "--map": sources.add parseSource(next())
    of "--pool":
      let count = parseInt(next())
      for index in 0 ..< count:
        sources.add parseSource("pool:" & $index)
    of "--episodes": episodes = parseInt(next())
    of "--topk": topK = parseInt(next())
    of "--out": outDir = next()
    of "--max-ticks": maxTicks = parseInt(next())
    of "--port": basePort = parseInt(next())
    of "--seed": baseSeed = parseInt(next())
    of "--lives": lives = parseInt(next())
    of "--seats": seats = parseInt(next())
    of "--teams": teams = parseInt(next())
    of "--quick": quick = true
    of "--rebuild": rebuild = true
    else: quit("Unknown option: " & arg & "\n" & UsageText)
    inc i

  ## META-RULE 1. The control is not optional and is not the caller's
  ## choice: a batch without it cannot be ranked, because every
  ## control-anchored band would have no anchor and every absolute band
  ## would have nothing proving it is calibrated.
  var hasControl = false
  for source in sources:
    if source.label == ControlSource:
      hasControl = true
  if not hasControl:
    sources.insert(parseSource(ControlSource), 0)
    echo "note: the default arena was added as CONTROL — every batch runs it."
  if sources.len == 1:
    sources.add parseSource("pool:0")
    echo "note: nothing to compare the control against; added pool:0."

  createDir(outDir)
  var candidates: seq[Candidate]
  echo &"resolving {sources.len} map(s)..."
  for source in sources:
    var candidate = Candidate(source: source)
    let started = getMonoTime()
    candidate.gameMap = resolveSource(source, teams)
    candidate.metrics = computeMapMetrics(
      candidate.gameMap, AnalysisCell, withChokepoints = not quick)
    candidate.gateReason = hardGates(candidate.metrics)
    echo &"  {source.label:<16} {candidate.gameMap.name:<10} " &
      &"{(getMonoTime() - started).inMilliseconds} ms"
    candidates.add candidate

  var controlIndex = -1
  for index, candidate in candidates:
    if candidate.source.label == ControlSource:
      controlIndex = index
  doAssert controlIndex >= 0, "the control vanished from the batch"
  let control = candidates[controlIndex].metrics

  for index in 0 ..< candidates.len:
    candidates[index].card = scoreMap(candidates[index].metrics, control)

  ## META-RULE 1, the enforcement half: score the control against its own
  ## bands and shout if any of them reject it. A band the control fails is a
  ## broken band, and the harness says so rather than quietly ranking the
  ## league's own map last.
  var controlFailures: seq[string]
  for check in candidates[controlIndex].card.checks:
    if check.scored and not check.passes():
      controlFailures.add &"{check.name} = {check.unitText.strip()} " &
        &"outside {check.boundText}"
  if candidates[controlIndex].gateReason.len > 0:
    controlFailures.add "hard gate: " & candidates[controlIndex].gateReason

  for index, candidate in candidates:
    printStatic(candidate, index == controlIndex)
    writeFile(outDir / &"static-{candidate.source.stem()}.json",
      metricsJson(candidate.metrics, candidate.card, candidate.source,
        candidate.gateReason).pretty())
    let masks = buildMapMasks(candidate.gameMap, AnalysisCell)
    writeFile(outDir / &"mask-{candidate.source.stem()}.bin",
      rawWallMaskBytes(masks))

  echo ""
  echo "=== static ranking (control marked) ==="
  echo "    the control scores ~100 BY CONSTRUCTION — half these bands are "
  echo "    anchored on it and the rest were chosen so it passes. Read a "
  echo "    score as distance from the arena, not as absolute quality."
  var order = toSeq(0 ..< candidates.len)
  order.sort(proc (a, b: int): int =
    cmp(candidates[b].card.score, candidates[a].card.score))
  for rank, index in order:
    let
      candidate = candidates[index]
      gate = if candidate.gateReason.len > 0: "  GATED" else: ""
      tag = if index == controlIndex: "  <-- CONTROL" else: ""
    echo &"  {rank + 1:>2}. {candidate.source.label:<16} " &
      &"{candidate.card.score * 100:5.1f}{gate}{tag}"

  if controlFailures.len > 0:
    echo ""
    echo "!! METRIC BUG: the CONTROL fails its own bands:"
    for failure in controlFailures:
      echo "     - " & failure
    echo "   A metric that flags your control is wrong. Fix the metric (or "
    echo "   the band), not the map — the arena is the layout the engine "
    echo "   was tuned on and the league default."

  if episodes <= 0:
    echo ""
    echo "static only (pass --episodes 3 to play them). Artifacts in " & outDir
    return

  if episodes < MinEpisodesForJudgement:
    echo ""
    echo &"!! WARNING: {episodes} episode(s) is below the {MinEpisodesForJudgement}-" &
      "seed minimum. One short episode read a real map as 53% dead floor; " &
      "across three it was 22%. Do not judge a map off this."

  ## The control is simulated in every batch too, even when its static score
  ## does not place it in the top k: dynamic numbers are only readable
  ## against it.
  var selected: seq[int]
  let limit = if topK > 0: topK else: candidates.len
  for index in order:
    if selected.len < limit and candidates[index].gateReason.len == 0:
      selected.add index
  if controlIndex notin selected:
    selected.add controlIndex

  if not fileExists("bin/ctf-server") or rebuild:
    buildBinary("bin/ctf-server", "src/ctf.nim")
  if not fileExists("players/baseline/baseline.out") or rebuild:
    buildBinary("players/baseline/baseline.out", "players/baseline/baseline.nim")

  var port = basePort
  for index in selected:
    let seats =
      if seats > 0: seats else: candidates[index].gameMap.teamCount() * 8
    echo ""
    echo &"=== simulating {candidates[index].source.label} " &
      &"({episodes} episodes, {seats} seats) ==="
    for episodeIndex in 0 ..< episodes:
      var episode = Episode(index: episodeIndex,
        seed: baseSeed + episodeIndex * 7919)
      let stem = candidates[index].source.stem()
      episode.replayPath =
        outDir / &"replay-{stem}-{episodeIndex}.bitreplay"
      let started = getMonoTime()
      var failure = recordEpisode(candidates[index].source,
        candidates[index].gameMap, episode.seed, maxTicks, seats, lives,
        port, episode.replayPath)
      inc port
      if failure.len > 0:
        ## One retry on a fresh port. Recording is a 33-process orchestration
        ## on a shared machine and a starved server does drop its bots; a
        ## flake that silently costs a seed would quietly push a batch under
        ## the three-episode minimum, which is the sample size the whole
        ## dead-space reading depends on.
        echo &"  episode {episodeIndex} failed, retrying once: " &
          failure.splitLines()[0]
        failure = recordEpisode(candidates[index].source,
          candidates[index].gameMap, episode.seed, maxTicks, seats, lives,
          port, episode.replayPath)
        inc port
      if failure.len == 0:
        failure = extractEpisode(candidates[index].source,
          candidates[index].gameMap, episode.replayPath,
          outDir / &"playtest-{stem}-{episodeIndex}.json", episode)
      episode.ok = failure.len == 0
      episode.reason = failure
      candidates[index].episodes.add episode
      let elapsed = (getMonoTime() - started).inMilliseconds.float / 1000.0
      if episode.ok:
        ## META-RULE 4: a capture ENDS the episode, so length is itself an
        ## outcome. Print it every time.
        echo &"  episode {episodeIndex} seed {episode.seed}: " &
          &"{episode.ticks}t, {episode.steals} steals -> " &
          &"{episode.captures} captures, {episode.deaths} deaths " &
          &"[{elapsed:.0f}s]"
        if episode.warning.len > 0:
          echo "    !! " & episode.warning
      else:
        echo &"  episode {episodeIndex} seed {episode.seed}: FAILED — " &
          episode.reason

  echo ""
  echo "=== episode ledger (length is an outcome, not a nuisance) ==="
  echo "    ticks include the lobby and any banked action-clock overtime, " &
    &"so they legitimately exceed the {maxTicks}-tick playing cap."
  var controlSteals, controlCaptures = 0
  for index in selected:
    var line = &"  {candidates[index].source.label:<16}"
    for episode in candidates[index].episodes:
      line.add(
        if not episode.ok: " [failed]"
        else: &" {episode.ticks}t/" &
          (if episode.captures > 0: &"{episode.captures}-capture"
           else: "no-capture") & &"/{episode.steals}-steal")
      if index == controlIndex and episode.ok:
        controlSteals += episode.steals
        controlCaptures += episode.captures
    echo line

  ## The bot-side trap, enforced. A map once "converted 0 of 43" until a
  ## plain arena on the same enlarged canvas also converted nothing: the
  ## defect followed the CANVAS, not the map. If the control does not
  ## convert, conversion is not a map measurement in this batch and must not
  ## be read as one.
  if controlCaptures == 0:
    echo ""
    echo &"!! NO SIGNAL ON CONVERSION: the CONTROL took {controlSteals} " &
      "steal(s) and converted 0."
    echo "   Conversion carries no map information in this batch — every "
    echo "   map's 0 captures is the baseline bot, not the terrain. Raise "
    echo "   --lives (the shipped 3 decides a 16-seat game by attrition "
    echo "   before anyone scores) or re-validate the bot's home-run logic "
    echo "   before reading conversion as a map score."
  elif controlSteals > 0:
    echo ""
    echo &"   control conversion: {controlCaptures}/{controlSteals} " &
      &"({controlCaptures.float * 100 / controlSteals.float:.0f}%) — " &
      "the yardstick every other map's conversion is read against."

  echo ""
  echo "artifacts in " & outDir
  echo "now render the heatmaps and the gap report:"
  echo &"  python3 tools/map_eval.py {outDir}"

when isMainModule:
  main()

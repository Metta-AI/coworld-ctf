## map_eval — the map-generator fitness harness.
##
## The loop is: load or generate -> HARD GATES (the sim's own validator) ->
## static score -> (top-k only) simulate N episodes -> rank. Static scoring is
## free next to simulation: a standard board scores in tens of milliseconds,
## while one headless 32-seat episode on a giant map costs ~97s. So the harness
## scores everything statically and only ever pays for simulation on the few
## candidates that survived.
##
## FIVE RULES, enforced here by the harness rather than by discipline —
##
## 1. The default `arena` is the CONTROL in EVERY batch. It is prepended
##    automatically; `--no-control` exists only so a test can prove the default
##    is on. A metric that flags the control is wrong, and a metric that skips
##    the control is worse, so nothing here may special-case a layout.
## 2. No count without its fraction. Every count printed below has its
##    fraction on the same line.
## 3. >= 3 seeds before judging a DYNAMIC number. `--episodes` below 3 prints
##    a refusal banner on any dead-space verdict.
## 4. A capture ENDS the episode, so episode length is itself an outcome. Each
##    episode's length and result print individually, never only the mean.
## 5. Thresholds are calibrated against the control and every bound prints its
##    remaining slack, marked `tight` when it is nearly spent.
##
## Usage:
##   map_eval score   [gen:1003 pool:2 spec.json ...]   # static, always + arena
##   map_eval pool                                       # the 20 curated seeds
##   map_eval rank    --seeds 1001-1060 [--top 8]        # generate + rank
##   map_eval control                                    # the arena's numbers
##   map_eval play    <map> --episodes 3 [--out DIR]     # record N episodes
##
## `play` drives the same orchestration `tools/benchmark_game.nim` uses
## (build -> config -> server -> bots -> wait -> parse) with the one piece it
## was missing: COGAME_SAVE_REPLAY_URI, so each episode leaves a replay. The
## replays then feed `tools/extract_events.nim --frames`, which is the only
## thing in this repo that carries per-tick spatial state, and it rides the
## existing hash-validated re-simulation at zero extra cost.

import
  std/[algorithm, json, monotimes, net, os, osproc, sequtils, streams,
       strformat, strutils, times],
  ../src/ctf/[sim, map_metrics, map_pool]

const
  GameDir = currentSourcePath().parentDir().parentDir()
  ControlMapPath = "arena"

type CliError = object of CatchableError

proc fail(msg: string) {.noreturn.} =
  raise newException(CliError, msg)

# --- argument parsing (same shape as tools/mapkit.nim) ----------------------

type Args = object
  positionals: seq[string]
  flags: seq[(string, string)]
  bools: seq[string]

proc parseArgs(argv: seq[string]): Args =
  var i = 0
  while i < argv.len:
    let a = argv[i]
    if a.startsWith("--"):
      let body = a[2 .. ^1]
      if body.contains('='):
        let kv = body.split('=', 1)
        result.flags.add (kv[0], kv[1])
      elif i + 1 < argv.len and not argv[i + 1].startsWith("--"):
        result.flags.add (body, argv[i + 1])
        inc i
      else:
        result.bools.add body
    elif a == "-o" and i + 1 < argv.len:
      inc i
      result.flags.add ("out", argv[i])
    else:
      result.positionals.add a
    inc i

proc flag(a: Args, key, default: string): string =
  for (k, v) in a.flags:
    if k == key: return v
  default

proc intFlag(a: Args, key: string, default: int): int =
  let raw = a.flag(key, "")
  if raw.len == 0: default else: raw.parseInt

proc has(a: Args, key: string): bool = key in a.bools

# --- map loading ------------------------------------------------------------

proc loadCandidate(path: string): CtfMap =
  ## "arena", "gen:<seed>", "pool:<i>" resolve through the sim's own loader;
  ## anything else is read as a mapSpec JSON file, the same working document
  ## mapkit edits. Never installs the map (purity).
  if path.endsWith(".json"):
    if not fileExists(path): fail("no such spec file: " & path)
    mapFromSpecJson(readFile(path))
  else:
    loadCtfMapMetadata(path)

# --- reporting --------------------------------------------------------------

proc summaryLine(m: MapMetrics): string =
  ## One line per map. Rule 2: every count carries its fraction.
  let gate = if m.valid: "ok  " else: "GATE"
  &"{gate} {m.name:<14} {m.width}x{m.height} {m.teams}t " &
    &"score={m.staticScore():.3f}  " &
    &"interior={m.interiorFrac * 100:.1f}% exposed={m.exposedFrac * 100:.1f}%  " &
    &"routes={m.routeCountMin}/{m.routeCapacityFrac:.2f}(cut {m.bottleneckPx}px)  " &
    &"chokes={m.chokeCount}(tightest {m.chokeMinClearPx}px, " &
    &"""covered={(if m.chokeCovered: "YES" else: "no")})  """ &
    &"mid={m.midCrossCount}x/{m.midOpenFrac * 100:.1f}%  " &
    &"stand={m.standRingOpenMin * 100:.1f}-{m.standRingOpenMax * 100:.1f}%"

proc detailReport(m: MapMetrics): string =
  var s: seq[string]
  s.add &"=== {m.name}  {m.width}x{m.height}  {m.teams} teams  " &
    &"{m.layout}/{m.symmetry}/{m.endzone}"
  if not m.valid:
    s.add &"    HARD GATE FAILED: {m.reason}"
  s.add &"    cover           {m.coverPermille}permille " &
    &"(min {m.minCoverPermille}), open floor {m.openFloorPx}px"
  s.add &"    architecture    interior {m.interiorFrac * 100:.1f}%  " &
    &"covered {m.coveredFrac * 100:.1f}%  wide open {m.exposedFrac * 100:.1f}%"
  s.add &"    vision          open run p50 {m.openRunP50Px}px  " &
    &"p95 {m.openRunP95Px}px  max {m.openRunMaxPx}px  " &
    &"over600 {m.longRunFrac * 100:.1f}%"
  s.add &"    clearance       p50 {m.clearP50Px}px  p95 {m.clearP95Px}px"
  s.add &"    routes          capacity {m.routeCountMin}..{m.routeCountMax} " &
    &"(mean {m.routeCountMean:.1f}) in {RouteCellPx}px units; " &
    &"tightest cut {m.bottleneckPx}px at ({m.bottleneckX},{m.bottleneckY})"
  s.add &"    chokepoints     {m.chokeCount} genuine cut(s), tightest " &
    &"{m.chokeMinClearPx}px clearance at " &
    (block:
      var pts: seq[string]
      for i in 0 ..< m.chokeX.len: pts.add &"({m.chokeX[i]},{m.chokeY[i]})"
      if pts.len == 0: "-" else: pts.join(" ")) &
    &"; one {IsovistRangePx}px isovist covers " &
    &"""all: {(if m.chokeCovered: "YES at (" & $m.chokeCoverX & "," & $m.chokeCoverY & ")" else: "no")}"""
  s.add &"    collision pt    ({m.collisionX},{m.collisionY}) spread " &
    &"{m.collisionSpreadPx}px, {m.collisionRoutes} frontier component(s); " &
    &"cover {m.collisionCoverFrac * 100:.1f}% = " &
    &"{m.collisionCoverRatio:.2f}x the map average"
  s.add "    stands          cover " &
    m.standCover.mapIt(&"{it * 100:.1f}%").join(" / ") &
    "   ring open " &
    m.standRingOpen.mapIt(&"{it * 100:.1f}%").join(" / ") &
    "   arcs " & m.standRingArcs.mapIt($it).join("/")
  s.add &"    midfield        {m.midCrossCount} crossing(s) across a seam " &
    &"""{m.midOpenFrac * 100:.1f}% open ({(if m.midAxisVertical: "vertical" else: "horizontal")})"""
  s.add &"    detour          {m.detourMin:.2f}..{m.detourMax:.2f} " &
    &"(mean {m.detourMean:.2f})"
  s.add &"    visibility      {m.visSamples} samples, degree mean " &
    &"{m.visDegreeMean:.1f} ({m.visDegreeFrac * 100:.1f}% of board) " &
    &"p10 {m.visDegreeP10:.0f} p90 {m.visDegreeP90:.0f} cv {m.visDegreeCv:.2f}"
  s.add &"    STATIC SCORE    {m.staticScore():.3f}"
  s.add m.bandReport()
  s.join("\n")

proc controlWarnings(control, m: MapMetrics): seq[string] =
  ## Rule 1, made operational: a bound that the CONTROL breaches is a bug in
  ## the bound, not a verdict on the map. Printed once per batch, loudly.
  for r in control.scoreBands():
    if r.breached:
      result.add &"METRIC BUG: band '{r.band.name}' BREACHES THE CONTROL " &
        &"(arena = {r.value:.3f}, band [{r.band.lo:.2f}..{r.band.hi:.2f}]). " &
        "A metric that flags the control is wrong — fix the band, not the map."
  discard m

proc evaluateBatch(paths: seq[string], withControl: bool): seq[MapMetrics] =
  ## Always evaluates the control FIRST so every downstream comparison has it.
  var wanted = paths
  if withControl and ControlMapPath notin wanted:
    wanted.insert(ControlMapPath, 0)
  for path in wanted:
    let started = getMonoTime()
    var m = evaluateMap(loadCandidate(path), path)
    let ms = (getMonoTime() - started).inMilliseconds
    stderr.writeLine &"  scored {path} in {ms}ms"
    result.add m

# --- commands ---------------------------------------------------------------

proc printBatch(metrics: seq[MapMetrics], detail: bool) =
  let control = metrics[0]
  for w in controlWarnings(control, control):
    echo w
  echo ""
  if detail:
    for m in metrics:
      echo m.detailReport()
      echo ""
  else:
    for m in metrics:
      echo m.summaryLine()
  echo ""
  echo "CONTROL is the first row (arena). Read every other row as a delta " &
    "from it, never against an absolute idea of a good map."

proc cmdScore(a: Args) =
  var paths = a.positionals
  if paths.len == 0: paths = @[ControlMapPath]
  let metrics = evaluateBatch(paths, not a.has("no-control"))
  printBatch(metrics, detail = a.has("detail") or paths.len == 1)

proc cmdControl(a: Args) =
  let metrics = evaluateBatch(@[], withControl = true)
  echo metrics[0].detailReport()

proc cmdPool(a: Args) =
  var paths: seq[string]
  for i in 0 ..< MapPoolSeeds.len:
    paths.add "pool:" & $i
  let metrics = evaluateBatch(paths, not a.has("no-control"))
  printBatch(metrics, detail = a.has("detail"))
  # Rule 5: print the pool distribution against the control so a band that is
  # merely restating the pool's own median is visible as such.
  echo ""
  echo "pool vs control:"
  proc column(name: string, get: proc (m: MapMetrics): float) =
    var values: seq[float]
    for m in metrics[1 .. ^1]: values.add get(m)
    values.sort()
    let
      lo = values[0]
      mid = values[values.len div 2]
      hi = values[^1]
    echo &"  {name:<20} arena {get(metrics[0]):8.3f}   " &
      &"pool min {lo:7.3f}  median {mid:7.3f}  max {hi:7.3f}"
  column("interiorFrac", proc (m: MapMetrics): float = m.interiorFrac)
  column("exposedFrac", proc (m: MapMetrics): float = m.exposedFrac)
  column("longRunFrac", proc (m: MapMetrics): float = m.longRunFrac)
  column("openRunP95Px", proc (m: MapMetrics): float = m.openRunP95Px.float)
  column("routeCountMin", proc (m: MapMetrics): float = m.routeCountMin.float)
  column("routeCapacityFrac", proc (m: MapMetrics): float = m.routeCapacityFrac)
  column("standCoverMin", proc (m: MapMetrics): float = m.standCoverMin)
  column("standCoverSpread",
    proc (m: MapMetrics): float = m.standCoverMax - m.standCoverMin)
  column("chokeCount", proc (m: MapMetrics): float = m.chokeCount.float)
  column("collisionCoverRatio",
    proc (m: MapMetrics): float = m.collisionCoverRatio)
  column("standRingOpenMin", proc (m: MapMetrics): float = m.standRingOpenMin)
  column("standRingSpread",
    proc (m: MapMetrics): float = m.standRingOpenMax - m.standRingOpenMin)
  column("midCrossCount", proc (m: MapMetrics): float = m.midCrossCount.float)
  column("midOpenFrac", proc (m: MapMetrics): float = m.midOpenFrac)
  column("detourMax", proc (m: MapMetrics): float = m.detourMax)
  column("visDegreeCv", proc (m: MapMetrics): float = m.visDegreeCv)
  column("staticScore", proc (m: MapMetrics): float = m.staticScore())

const ShiftMetrics = [
  "interiorFrac", "exposedFrac", "longRunFrac", "routeCapacityFrac",
  "chokeCount", "collisionCoverRatio", "standRingOpenMin", "standRingSpread",
  "standCoverSpread", "midCrossCount", "midOpenFrac", "detourMax",
  "visDegreeCv", "coverPermille",
]
  ## Every band-backed metric, so the best-of-K report is a DISTRIBUTION SHIFT
  ## across the whole rubric rather than one flattering example. A selection
  ## that only moves the scalar and no metric is selecting noise.

proc quantile(sorted: seq[float], q: float): float =
  if sorted.len == 0: return 0.0
  let idx = clamp(int(q * float(sorted.len - 1) + 0.5), 0, sorted.len - 1)
  sorted[idx]

proc spread(values: seq[float]): string =
  var s = values
  s.sort()
  var mean = 0.0
  for v in s: mean += v
  if s.len > 0: mean /= float(s.len)
  &"min {s.quantile(0.0):7.3f}  p25 {s.quantile(0.25):7.3f}  " &
    &"med {s.quantile(0.5):7.3f}  p75 {s.quantile(0.75):7.3f}  " &
    &"max {s.quantile(1.0):7.3f}  mean {mean:7.3f}"

proc cmdBestOf(a: Args) =
  ## The verification harness for best-of-K selection: the same seeds
  ## generated BOTH ways (K=1, i.e. the old first-valid draw, and the shipped
  ## best-of-K), with the hand-authored arena as control. Reports the shift as
  ## a distribution over every band metric, plus the real per-size-class cost.
  let
    spec = a.flag("seeds", "1001-1200")
    parts = spec.split('-')
    lo = parts[0].parseInt
    hi = if parts.len > 1: parts[1].parseInt else: lo
    teams = a.intFlag("teams", 2)
    kFlag = a.intFlag("k", 0)
    overrides = MapGenOverrides(windows: -1, pits: -1, pitDensity: -1)
  if not mapFitnessInstalled():
    fail("no map fitness installed — selection would be first-valid")
  let control = evaluateMap(loadCandidate(ControlMapPath), ControlMapPath)
  for w in controlWarnings(control, control): echo w
  var
    firstMetrics, bestMetrics: seq[MapMetrics]
    perClassMs, perClassCount, perClassAttempts, perClassValid:
      array[MapSizeClass, int]
    improved, tied, regressed = 0
    degenerateSeeds: seq[int]
  for seed in lo .. hi:
    # K=1 IS the old behaviour: the loop stops at the first valid candidate.
    let firstMap = generateCtfMap(seed, overrides, teams, k = 1)
    let started = getMonoTime()
    ## The SELECTION, not just the map. `degenerate` is the failure mode that
    ## looks like success — a full-price search whose scorer separated nothing
    ## — and the old replay-based accounting here could not see it, because a
    ## replay re-derives attempts and valid but never the SCORES.
    let selection = generateCtfMapSelection(seed, overrides, teams, k = kFlag)
    let bestMap = selection.gameMap
    let ms = int((getMonoTime() - started).inMilliseconds)
    let cls = bestMap.mapSizeClass()
    perClassMs[cls] += ms
    inc perClassCount[cls]
    let (attempts, valid) = (selection.attempts, selection.valid)
    perClassAttempts[cls] += attempts
    perClassValid[cls] += valid
    if selection.degenerate:
      degenerateSeeds.add seed
    let
      fm = evaluateMap(firstMap, &"gen:{seed}")
      bm = evaluateMap(bestMap, &"gen:{seed}")
    if bm.staticScore() > fm.staticScore() + 1e-9: inc improved
    elif bm.staticScore() < fm.staticScore() - 1e-9: inc regressed
    else: inc tied
    firstMetrics.add fm
    bestMetrics.add bm
    stderr.writeLine &"  seed {seed} {cls.sizeName():<9} " &
      &"first={fm.staticScore():.3f} best={bm.staticScore():.3f} " &
      &"({valid} valid / {attempts} attempts, {ms}ms" &
      (if selection.degenerate: ", DEGENERATE" else: "") & ")"
  echo ""
  echo &"BEST-OF-K SELECTION, seeds {lo}-{hi}, {teams} teams, " &
    &"""k={(if kFlag > 0: $kFlag else: "per size class")}"""
  echo &"ranker: {mapFitnessLabel()}"
  if degenerateSeeds.len > 0:
    ## The one result here that invalidates the rest of the report: on these
    ## seeds every ranked candidate scored EXACTLY the same, so best-of-K paid
    ## full price to return the first valid draw. Any "improvement" measured
    ## over them is noise, not selection.
    echo ""
    echo &"!! DEGENERATE SELECTION on {degenerateSeeds.len}/{hi - lo + 1} " &
      "seeds: the ranker separated no candidate, so best-of-K reduced to " &
      "first-valid at full cost."
    echo "   seeds: " & degenerateSeeds[0 ..< min(12, degenerateSeeds.len)]
      .join(", ") & (if degenerateSeeds.len > 12: ", ..." else: "")
  echo ""
  echo &"CONTROL  arena  staticScore = {control.staticScore():.3f}"
  echo ""
  var firstScores, bestScores: seq[float]
  for m in firstMetrics: firstScores.add m.staticScore()
  for m in bestMetrics: bestScores.add m.staticScore()
  echo "staticScore"
  echo "  K=1  (first valid)  " & firstScores.spread()
  echo "  best-of-K           " & bestScores.spread()
  echo &"  seeds improved {improved}, unchanged {tied}, regressed {regressed}"
  echo ""
  echo "PER-METRIC DISTRIBUTION SHIFT (median, then p25..p75)"
  echo &"""  {"metric":<22}{"control":>9}{"K=1 med":>10}{"best med":>10}""" &
    &"""{"delta":>9}   {"K=1 p25..p75":>18}   {"best p25..p75":>18}"""
  for name in ShiftMetrics:
    var fv, bv: seq[float]
    for m in firstMetrics: fv.add m.metricValue(name)
    for m in bestMetrics: bv.add m.metricValue(name)
    fv.sort(); bv.sort()
    let
      fMed = fv.quantile(0.5)
      bMed = bv.quantile(0.5)
    echo &"  {name:<22}{control.metricValue(name):9.3f}{fMed:10.3f}" &
      &"{bMed:10.3f}{bMed - fMed:+9.3f}   " &
      &"{fv.quantile(0.25):8.3f}..{fv.quantile(0.75):<8.3f}   " &
      &"{bv.quantile(0.25):8.3f}..{bv.quantile(0.75):<8.3f}"
  echo ""
  echo "COST (generate + validate + score, per shipped map)"
  echo &"""  {"class":<10}{"maps":>6}{"K":>4}{"attempts":>10}{"valid":>7}""" &
    &"""{"ms/map":>9}"""
  for cls in MapSizeClass:
    if perClassCount[cls] == 0: continue
    let n = perClassCount[cls]
    echo &"  {cls.sizeName():<10}{n:6}{selectionK(cls):4}" &
      &"{perClassAttempts[cls] / n:10.1f}{perClassValid[cls] / n:7.1f}" &
      &"{perClassMs[cls] / n:9}"

proc cmdRank(a: Args) =
  let
    spec = a.flag("seeds", "1001-1040")
    parts = spec.split('-')
    lo = parts[0].parseInt
    hi = if parts.len > 1: parts[1].parseInt else: lo
    top = a.intFlag("top", 8)
    teams = a.intFlag("teams", 2)
  var paths: seq[string]
  for seed in lo .. hi:
    paths.add "gen:" & $seed
  var metrics: seq[MapMetrics]
  # The control is scored first and kept OUT of the ranking, so a batch can
  # never rank the control away and lose its own yardstick.
  let control = evaluateMap(loadCandidate(ControlMapPath), ControlMapPath)
  for w in controlWarnings(control, control): echo w
  for path in paths:
    let gameMap =
      if teams == 2: loadCandidate(path)
      else: generateCtfMap(path.split(':')[1].parseInt,
        MapGenOverrides(windows: -1, pits: -1, pitDensity: -1), teams)
    metrics.add evaluateMap(gameMap, path)
  var ranked = metrics
  ranked.sort(proc (x, y: MapMetrics): int =
    cmp(y.staticScore(), x.staticScore()))
  echo ""
  echo "CONTROL:"
  echo "  " & control.summaryLine()
  echo ""
  echo &"RANKED {ranked.len} candidates (top {top} shown):"
  for i in 0 ..< min(top, ranked.len):
    echo &"  #{i + 1:<3}" & ranked[i].summaryLine()
  var gated = 0
  for m in metrics:
    if not m.valid: inc gated
  echo ""
  echo &"{gated} of {metrics.len} failed the sim's hard gates."
  echo "(expect 0: `gen:<seed>` goes through generateCtfMap, which RE-ROLLS " &
    "up to 100 attempts until a seed validates. A best-of-K ranker that wants " &
    "to see rejections has to call generateMapAttempt directly — the " &
    "validators are a crash guard, not a filter.)"

# --- episode orchestration (the simulation half) ----------------------------

proc buildBinary(outPath, source: string) =
  stderr.writeLine "building " & outPath & " (release)..."
  let p = startProcess("nim", args = ["c", "-d:release", "--out:" & outPath,
    source], options = {poUsePath, poParentStreams})
  let code = p.waitForExit()
  p.close()
  if code != 0: fail("build failed: " & source)

proc portListening(port: int): bool =
  let socket = newSocket()
  defer: socket.close()
  try:
    socket.connect("127.0.0.1", Port(port), timeout = 250)
    true
  except CatchableError:
    false

proc portBindable(port: int): bool =
  ## Whether we can actually take this port right now.
  ##
  ## Probing with `portListening` alone is not enough and produced a silent
  ## wrong result: this machine routinely runs many agents, one of them already
  ## held 21501, so the "wait for the port to listen" loop was satisfied
  ## INSTANTLY by a stranger's server. The bots then attached to it, our own
  ## server had already died with "Address already in use", and the episode
  ## reported ticks=-1 and walked on. Bind-probing rejects that port up front.
  let socket = newSocket()
  defer: socket.close()
  try:
    socket.bindAddr(Port(port), "127.0.0.1")
    true
  except CatchableError:
    false

proc pickPort(start: int): int =
  ## The first port at or above `start` that nothing else holds. Offset by the
  ## process id so two concurrent harness runs do not race for the same one.
  var port = start + (getCurrentProcessId() mod 97) * 4
  for _ in 0 ..< 400:
    if not portListening(port) and portBindable(port):
      return port
    inc port
  fail("no free port near " & $start)

proc drainToFile(arg: tuple[handle: FileHandle, path: string]) {.thread.} =
  ## The server echoes every game event, more than a pipe buffer holds — left
  ## undrained it fills and deadlocks the game mid-match.
  var input: File
  if not input.open(arg.handle, fmRead): return
  let output = open(arg.path, fmWrite)
  var line = ""
  while input.readLine(line):
    output.writeLine(line)
    output.flushFile()
  output.close()
  input.close()

proc tailFile(path: string, lines: int): string =
  if not fileExists(path): return ""
  let all = readFile(path).strip().splitLines()
  all[max(0, all.len - lines) .. ^1].join("\n")

proc writeEpisodeConfig(
  mapPath: string, seed, maxTicks, seats, teams: int
): string =
  let config = parseJson(readFile(GameDir / "config.json"))
  config["seed"] = %seed
  config["maxTicks"] = %maxTicks
  config["maxGames"] = %1
  config["teams"] = %teams
  config["minPlayers"] = %seats
  config["fastMode"] = %true
  if mapPath.startsWith("gen:"):
    config["mapPath"] = %"gen"
    config["mapSeed"] = %mapPath.split(':')[1].parseInt
  elif mapPath.startsWith("pool:"):
    config["mapPath"] = %"pool"
    config["mapPoolIndex"] = %mapPath.split(':')[1].parseInt
  elif mapPath.endsWith(".json"):
    config["mapSpec"] = parseJson(readFile(mapPath))
  else:
    config["mapPath"] = %mapPath
  if config.hasKey("slots"): config.delete("slots")
  var tokens = newJArray()
  for slot in 0 ..< seats: tokens.add(%("0xBADA55_" & $slot))
  config["tokens"] = tokens
  var players = newJArray()
  for slot in 0 ..< seats:
    players.add(%*{"name": &"eval_{slot}"})
  config["players"] = players
  result = getTempDir() / &"ctf-eval-cfg-{getCurrentProcessId()}-{seed}.json"
  writeFile(result, $config)

proc runEpisode(
  mapPath: string, seed, maxTicks, seats, teams, port: int, replayPath: string
): tuple[ticks: int, ok: bool] =
  ## One headless episode, recorded. This is `benchmark_game.nim`'s
  ## orchestration plus the single piece it lacked: COGAME_SAVE_REPLAY_URI.
  ## Without a replay there is no frame stream, and without a frame stream
  ## there is no travel heatmap — the whole dynamic half hangs off this env
  ## var, which is why it is set here rather than left to the caller.
  let
    configPath = writeEpisodeConfig(mapPath, seed, maxTicks, seats, teams)
    serverLog = replayPath.changeFileExt("server.log")
    eventsPath = replayPath.changeFileExt("summary.jsonl")
  removeFile(replayPath)
  removeFile(eventsPath)
  var
    serverProcess: Process = nil
    bots: seq[Process]
  proc shutdown() =
    if serverProcess != nil and serverProcess.running: serverProcess.kill()
    for bot in bots:
      if bot.running: bot.kill()
  try:
    putEnv("COGAME_HOST", "127.0.0.1")
    putEnv("COGAME_PORT", $port)
    putEnv("COGAME_CONFIG_URI", "file://" & configPath)
    putEnv("COGAME_EVENTS_URI", "file://" & eventsPath)
    putEnv("COGAME_SAVE_REPLAY_URI", "file://" & replayPath.absolutePath())
    serverProcess = startProcess(GameDir / "bin/ctf-server",
      workingDir = GameDir, options = {poStdErrToStdOut})
    var logThread: Thread[tuple[handle: FileHandle, path: string]]
    createThread(logThread, drainToFile, (serverProcess.outputHandle, serverLog))
    let started = getMonoTime()
    while not portListening(port):
      if not serverProcess.running:
        joinThread(logThread)
        fail("server died during startup; log tail:\n" & tailFile(serverLog, 12))
      if (getMonoTime() - started).inSeconds > 480:
        fail("server never listened; log tail:\n" & tailFile(serverLog, 12))
      sleep(200)
    putEnv("CTF_BOT_FAST_READY", "1")
    for slot in 0 ..< seats:
      putEnv("COWORLD_PLAYER_WS_URL",
        &"ws://127.0.0.1:{port}/player?slot={slot}&token=0xBADA55_{slot}")
      bots.add startProcess(GameDir / "players/baseline/baseline.out",
        workingDir = GameDir, options = {poStdErrToStdOut})
    let botsUp = getMonoTime()
    while serverProcess.running:
      if (getMonoTime() - botsUp).inSeconds > 1200:
        fail("episode still running after 20 minutes; see " & serverLog)
      sleep(100)
    joinThread(logThread)
    for bot in bots:
      if bot.running: bot.kill()
      discard bot.outputStream.readAll()
    result.ticks = -1
    if fileExists(eventsPath):
      for line in readFile(eventsPath).strip().splitLines():
        if line.len == 0: continue
        let row = parseJson(line)
        if row{"type"}.getStr() == "summary":
          result.ticks = row["ticks"].getInt()
    # A written replay under ~10KB is a truncated episode, not evidence. This
    # must be LOUD: the whole dynamic half hangs off the replay existing, and
    # an episode that quietly produced nothing once walked past as "MISSING"
    # while the batch carried on averaging the ones that worked.
    result.ok = fileExists(replayPath) and getFileSize(replayPath) > 10_000
    if not result.ok:
      fail("episode produced no usable replay (" & replayPath &
        "); server log tail:\n" & tailFile(serverLog, 15))
  finally:
    shutdown()
    removeFile(configPath)

proc cmdPlay(a: Args) =
  if a.positionals.len == 0: fail("play needs a map (gen:1003 / pool:2 / arena)")
  let
    mapPath = a.positionals[0]
    episodes = a.intFlag("episodes", 3)
    maxTicks = a.intFlag("max-ticks", 5000)
    seats = a.intFlag("seats", 16)
    teams = a.intFlag("teams", 2)
    basePort = a.intFlag("port", 21500)
    outDir = a.flag("out", getTempDir() / "ctf-map-eval")
  createDir(outDir)
  if not fileExists(GameDir / "bin/ctf-server") or a.has("rebuild"):
    buildBinary(GameDir / "bin/ctf-server", GameDir / "src/ctf.nim")
  if not fileExists(GameDir / "players/baseline/baseline.out") or a.has("rebuild"):
    buildBinary(GameDir / "players/baseline/baseline.out",
      GameDir / "players/baseline/baseline.nim")
  if episodes < 3:
    echo "REFUSING A DEAD-SPACE VERDICT: episode LENGTH dominates dead space " &
      "(one 1725-tick sample once read a map as 53% dead floor; across three " &
      "it was 22%). Fewer than 3 episodes records evidence but proves nothing."
  let slug = mapPath.multiReplace(("/", "_"), (":", "-"), (".", "_"))
  var lines: seq[string]
  for episode in 0 ..< episodes:
    let
      replayPath = outDir / &"{slug}-ep{episode}.bitreplay"
      seed = 1 + episode
      run = runEpisode(mapPath, seed, maxTicks, seats, teams,
        pickPort(basePort), replayPath)
    # Rule 4: each episode's length and result print individually. A capture
    # ENDS the episode, so length IS an outcome and a mean hides it.
    lines.add &"  ep{episode} seed={seed} ticks={run.ticks} " &
      "replay=" & (if run.ok: "ok" else: "MISSING") & " " & replayPath
    echo lines[^1]
  echo ""
  echo &"recorded {episodes} episode(s) of {mapPath} into {outDir}"
  echo &"next: for r in {outDir}/*.bitreplay; do \\"
  echo &"        map_playtest \"$r\" --name {mapPath} --out \"${{r%.bitreplay}}.json\"; done"
  echo &"      python3 tools/map_playtest.py {outDir}/*.json"
  echo "      ...and pass an `arena` evidence set in the SAME invocation: " &
    "every dynamic flag is a delta from the control, and dead space has no " &
    "absolute bar (the arena reads 24% dead at one long episode and 51% at " &
    "three short ones)."

const usage = """
map_eval — the map-generator fitness harness (arena is ALWAYS the control)

  map_eval control                      the arena's numbers, in full
  map_eval score  [map ...] [--detail]  static metrics (arena prepended)
  map_eval pool   [--detail]            the 20 curated pool seeds vs arena
  map_eval rank   --seeds LO-HI [--top N] [--teams N]
  map_eval bestof --seeds LO-HI [--teams N] [--k N]
                                        K=1 vs best-of-K, per-metric shift
  map_eval play   <map> --episodes N [--out DIR] [--seats N] [--teams N]

maps are "arena", "gen:<seed>", "pool:<index>", or a mapSpec .json path.
"""

when isMainModule:
  let argv = commandLineParams()
  if argv.len == 0 or argv[0] in ["-h", "--help", "help"]:
    echo usage
    quit(0)
  let a = parseArgs(argv[1 .. ^1])
  try:
    case argv[0]
    of "control": cmdControl(a)
    of "score": cmdScore(a)
    of "pool": cmdPool(a)
    of "rank": cmdRank(a)
    of "bestof": cmdBestOf(a)
    of "play": cmdPlay(a)
    else:
      stderr.writeLine "unknown command: " & argv[0]
      echo usage
      quit(2)
  except CliError as e:
    stderr.writeLine "map_eval: " & e.msg
    quit(2)
  except CtfError as e:
    stderr.writeLine "map_eval: " & e.msg
    quit(1)

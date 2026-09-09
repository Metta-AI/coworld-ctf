## Barrier match: starts bin/ctf-server plus 8 baseline bot processes
## locally (no Docker) in the ordinary 2-team / 8-seat combat shape
## (NOT the paintball loadout, which silently suppresses barrier pickups)
## with `barrierPickups` armed, waits for a full game, and reports the
## cardboard-barrier event counts logged by the sim.
##
## Adapted from tools/benchmark_game.nim — same process-spawn / log-drain
## machinery, trimmed to 2 teams x 4 bots and with barrierPickups armed.
##
## Usage: nim r tools/barrier_match.nim [seed] [maxTicks]
## Env overrides: PORT (21455), REBUILD=1 (force rebuild)

import std/[algorithm, json, monotimes, net, os, osproc, streams, strformat,
  strutils, times]

const
  GameDir = currentSourcePath().parentDir().parentDir()
  Seats = 8
  TeamCount = 2
  PolicyNames = ["redshift:v1", "bluesteel:v1"]
  BarrierPickupsPerTeam = 2

proc envOr(name, default: string): string =
  let value = getEnv(name)
  if value.len > 0: value else: default

proc seconds(a, b: MonoTime): float =
  (b - a).inMilliseconds.float / 1000.0

proc buildBinary(outPath, source: string) =
  echo "building ", outPath, " (release)..."
  let process = startProcess(
    "nim",
    args = ["c", "-d:release", "--out:" & outPath, source],
    options = {poUsePath, poParentStreams}
  )
  let code = process.waitForExit()
  process.close()
  if code != 0:
    quit("build failed: " & source)

proc writeMatchConfig(seed, maxTicks: int): string =
  ## Derives the match config from the repo config: 8 seats dealt round
  ## two teams (slot mod 2), the ordinary arena map (NOT gen/giant, NOT
  ## paintball loadout), barrierPickups armed, pinned seed, one game.
  let config = parseJson(readFile("config.json"))
  config["seed"] = %seed
  config["maxTicks"] = %maxTicks
  config["maxGames"] = %1
  config["teams"] = %TeamCount
  config["minPlayers"] = %Seats
  config["fastMode"] = %true
  config["barrierPickups"] = %BarrierPickupsPerTeam
  if config.hasKey("slots"):
    config.delete("slots")
  var tokens = newJArray()
  for slot in 0 ..< Seats:
    tokens.add(%("0xBADA55_" & $slot))
  config["tokens"] = tokens
  var players = newJArray()
  var seatCounts: array[TeamCount, int]
  for slot in 0 ..< Seats:
    let team = slot mod TeamCount
    inc seatCounts[team]
    players.add(%*{"name": &"{PolicyNames[team]}_({seatCounts[team]})"})
  config["players"] = players
  result = getTempDir() / &"ctf-barrier-cfg-{getCurrentProcessId()}.json"
  writeFile(result, $config)

proc drainToFile(arg: tuple[handle: FileHandle, path: string]) {.thread.} =
  ## Copies a child process's output pipe into a log file as it arrives.
  ## The server echoes every game event, more than a pipe buffer holds —
  ## left undrained it would fill up and deadlock the game mid-match.
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

proc countOccurrences(path, needle: string): int =
  if not fileExists(path):
    return 0
  for line in readFile(path).splitLines():
    if line.contains(needle):
      inc result

proc main() =
  setCurrentDir(GameDir)
  let params = commandLineParams()
  let
    seed = if params.len > 0: parseInt(params[0]) else: 1
    maxTicks = if params.len > 1: parseInt(params[1]) else: 4000
    port = parseInt(envOr("PORT", "21455"))
    rebuild = getEnv("REBUILD") == "1"
    serverLogPath = envOr("LOG", "/tmp/barr/server.log")
    botLogPath = envOr("BOTLOG", "/tmp/barr/bots.log")
    eventsPath = envOr("EVENTS", "/tmp/barr/events.jsonl")
    metricsPath = envOr("METRICS", "/tmp/barr/metrics.json")
    replayPath = envOr("REPLAY", "/tmp/barr/match.bitreplay")

  ## Build (release) — outside the timed region
  if rebuild or not fileExists("bin/ctf-server"):
    buildBinary("bin/ctf-server", "src/ctf.nim")
  if rebuild or not fileExists("players/baseline/baseline.out"):
    buildBinary("players/baseline/baseline.out", "players/baseline/baseline.nim")

  let configPath = writeMatchConfig(seed, maxTicks)
  removeFile(eventsPath)
  removeFile(metricsPath)
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
    ## Start the server; startup time covers map generation
    let timeStart = getMonoTime()
    putEnv("COGAME_HOST", "127.0.0.1")
    putEnv("COGAME_PORT", $port)
    putEnv("COGAME_CONFIG_URI", "file://" & configPath)
    putEnv("COGAME_EVENTS_URI", "file://" & eventsPath)
    putEnv("COGAME_METRICS_URI", "file://" & metricsPath)
    putEnv("COGAME_SAVE_REPLAY_URI", "file://" & replayPath)
    serverProcess = startProcess(
      GameDir / "bin/ctf-server",
      workingDir = GameDir,
      options = {poStdErrToStdOut}
    )
    var serverLogThread: Thread[tuple[handle: FileHandle, path: string]]
    createThread(serverLogThread, drainToFile,
      (serverProcess.outputHandle, serverLogPath))

    while not portListening(port):
      if not serverProcess.running:
        joinThread(serverLogThread)
        echo "server died during startup; log tail:"
        echo tailFile(serverLogPath, 40)
        quit(1)
      if seconds(timeStart, getMonoTime()) > 480.0:
        echo "server never listened; log tail:"
        echo tailFile(serverLogPath, 40)
        quit(1)
      sleep(200)
    let timeListen = getMonoTime()

    ## Spawn all 8 bots as plain processes; the game clock starts here
    putEnv("CTF_BOT_FAST_READY", "1")
    for slot in 0 ..< Seats:
      putEnv("COWORLD_PLAYER_WS_URL",
        &"ws://127.0.0.1:{port}/player?slot={slot}&token=0xBADA55_{slot}")
      botProcesses.add(startProcess(
        GameDir / "players/baseline/baseline.out",
        workingDir = GameDir,
        options = {poStdErrToStdOut}
      ))
    let timeBots = getMonoTime()

    ## The server exits on its own after maxGames=1; a hang must be loud
    while serverProcess.running:
      if seconds(timeBots, getMonoTime()) > 1200.0:
        echo "server still running after 20 minutes — killing; log tail:"
        echo tailFile(serverLogPath, 40)
        quit(1)
      sleep(100)
    let timeEnd = getMonoTime()
    joinThread(serverLogThread)

    ## Bot pipes stay unread during the game (their output is tiny, far
    ## under one pipe buffer); collect them into the bot log afterwards.
    let botLog = open(botLogPath, fmWrite)
    for bot in botProcesses:
      if bot.running:
        bot.kill()
      botLog.write(bot.outputStream.readAll())
    botLog.close()

    var ticks, events = -1
    if fileExists(eventsPath):
      for line in readFile(eventsPath).strip().splitLines():
        let row = parseJson(line)
        if row{"type"}.getStr() == "summary":
          ticks = row["ticks"].getInt()
          events = row["events"].getInt()

    let gameSeconds = seconds(timeBots, timeEnd)
    echo ""
    echo &"barrier match: {TeamCount} teams x {Seats div TeamCount} bots " &
      &"({Seats} seats), barrierPickups={BarrierPickupsPerTeam}, seed={seed}"
    echo &"  server startup:            {seconds(timeStart, timeListen):8.2f} s"
    echo &"  game (bots spawn -> over): {gameSeconds:8.2f} s"
    echo &"  total:                     {seconds(timeStart, timeEnd):8.2f} s"
    if ticks >= 0:
      echo &"  ticks: {ticks}   events: {events}   " &
        &"ticks/sec: {ticks.float / gameSeconds:.1f}"
    else:
      echo "  (no events summary found — tick stats unavailable)"

    if fileExists(replayPath):
      echo &"  replay: {replayPath} ({getFileSize(replayPath)} bytes)"
    else:
      echo "  (no replay file was written)"

    echo ""
    echo "cardboard barrier event counts (server log):"
    for needle in ["picked up a cardboard barrier", "placed a cardboard barrier",
                    "shredded a cardboard barrier", "flattened a cardboard barrier"]:
      echo &"  {needle}: {countOccurrences(serverLogPath, needle)}"
  finally:
    shutdown()
    removeFile(configPath)

main()

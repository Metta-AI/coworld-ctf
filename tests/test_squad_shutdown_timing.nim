## Real end-to-end proof of the certification-headroom fix (2026-08-31):
## on squadMode's final shutdown, roster/takeover player sockets now close
## as soon as the last frame is queued, instead of riding out the full
## `ShutdownGraceSeconds` (20s) window with everyone else. See
## src/ctf/server.nim's `closePlayerSocketsPromptly` for the mechanism and
## test_squad_shutdown_scoping.nim for the fast unit-level scoping check;
## this file is the real thing -- an actual compiled `bin/ctf-server`
## process, actual `whisky` websocket clients standing in for the bundled
## baseline bots and a spectator page, over a real TCP loopback connection.
##
## Why a subprocess and not an in-process call to `runServerLoop`: tried
## that first (spawning `runServerLoop` on a Nim `{.thread.}` inside this
## same test binary) and hit a reproducible ORC cycle-collector SIGSEGV
## (`system::unregisterCycle`) once the spawned thread's server state and
## this thread's own GC activity overlapped after shutdown -- a
## pre-existing property of running the full render/broadcast chain
## outside its normal "sole thread of a soon-to-exit process" assumption,
## unrelated to this fix. A real child process sidesteps it entirely (the
## OS reclaims its threads/heap independently of this test process's own
## GC) and is also a MORE faithful stand-in for the certification, which
## observes an actual process exit, not an in-process call return.
##
## Red-proofed: reverting `closePlayerSocketsPromptly`'s call site
## (restoring the old "everyone waits out the full grace window" behavior)
## makes the `< PromptBoundSeconds` checks below fail outright -- players
## take the full ~20s, not comfortably under it. Verified by hand during
## development: with the call site removed, this test's player-close
## checks time out and fail exactly as expected.

import std/[os, osproc, strutils, times, unittest]
import whisky

const
  TestPort = 21778
  PromptBoundSeconds = 10.0
    ## Generous margin under the real ShutdownGraceSeconds=20 and the
    ## certification's ~30s total budget -- a loaded test box still has
    ## headroom without the assertion becoming a coin flip.
  ConnectDeadlineSeconds = 60.0
    ## Board render caches take several seconds to bake before the
    ## listener opens, and the FIRST run in a checkout without a prebuilt
    ## binary also has to compile bin/ctf-server (see ensureServerBinary)
    ## -- so this is generously long.
  ServerBinaryPath = "bin" / "ctf-server"

proc ensureServerBinary() =
  ## CI's "build" job never compiles bin/ctf-server (only the four test
  ## shard binaries) -- it is normally a manual/dev-tooling artifact (see
  ## tools/record_fixture.sh and friends). Build it on demand, once, so
  ## this test is self-contained rather than silently skipping the one
  ## thing it exists to prove. A stale binary already sitting in a dev
  ## worktree from unrelated work is reused as-is (matching every other
  ## tool in tools/record_*.sh, which carry the same "you built it"
  ## assumption) -- CI always starts from a clean checkout, so this path
  ## is a real compile there every time.
  if fileExists(ServerBinaryPath):
    return
  createDir("bin")
  # src/ctf.nim's own import graph reaches shell/runtime.nim (server.nim ->
  # shell/episode -> shell/module_cache -> shell/runtime, since af8158f5),
  # which hard-{.error.}s without -d:noSignalHandler --threads:on -- the
  # same requirement build.yml's `nim check` and all 4 shard compiles
  # already carry (see this branch's b406bd2e/af9bf122). This is a THIRD,
  # separate build invocation of the same entry point that needed the same
  # two flags and didn't have them yet.
  let (output, exitCode) = execCmdEx(
    "nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on " &
    "--opt:speed --stackTrace:on --hints:off --out:" & ServerBinaryPath &
    " src/ctf.nim"
  )
  doAssert exitCode == 0, "failed to build " & ServerBinaryPath & ":\n" & output

proc connectWithRetry(url: string, process: Process,
                      budgetSeconds = ConnectDeadlineSeconds): whisky.WebSocket =
  ## Own fresh `budgetSeconds` window per call, not a deadline shared
  ## across sequential connects (player0/player1/spectator used to split
  ## one ConnectDeadlineSeconds three ways -- under load, a slow player0
  ## connect could starve spectator's share to nearly nothing). Fails
  ## fast if the server process has already exited instead of waiting
  ## out the full window for a connection that can now never succeed.
  let deadlineAt = epochTime() + budgetSeconds
  while true:
    if not process.running:
      doAssert false, "server process exited before " & url & " could connect"
    try:
      return whisky.newWebSocket(url)
    except CatchableError:
      if epochTime() > deadlineAt:
        raise
      sleep(100)

proc drainUntilClosed(
  ws: whisky.WebSocket, deadlineAt: float
): tuple[lastMessageAt, closedAt: float, messageCount: int] =
  ## Reads messages until the peer closes/errors, or `deadlineAt`
  ## (epochTime-scale) passes with the socket still open. `closedAt` stays
  ## 0.0 in the "never closed in time" case -- the property this test is
  ## checking failing to hold.
  while epochTime() < deadlineAt:
    try:
      let msg = ws.receiveMessage(300)
      if msg.isSome:
        result.lastMessageAt = epochTime()
        inc result.messageCount
    except CatchableError:
      result.closedAt = epochTime()
      return

suite "squad-mode final shutdown closes player sockets promptly (real server)":
  test "live classic boot without deprecated-mode override refuses before serving":
    ensureServerBinary()
    let
      configPath =
        getTempDir() / "test_deprecated_boot_config_" & $TestPort & ".json"
      resultsPath =
        getTempDir() / "test_deprecated_boot_results_" & $TestPort & ".json"
      configJson = """{
        "seed": 1, "brMode": false, "num_agents": 16,
        "maxTicks": 1, "maxGames": 1
      }"""
    writeFile(configPath, configJson)
    defer:
      discard tryRemoveFile(configPath)
      discard tryRemoveFile(resultsPath)

    putEnv("COGAME_HOST", "127.0.0.1")
    putEnv("COGAME_PORT", $TestPort)
    putEnv("COGAME_CONFIG_URI", "file://" & configPath)
    putEnv("COGAME_RESULTS_URI", "file://" & resultsPath)
    let (output, exitCode) = execCmdEx(ServerBinaryPath)
    delEnv("COGAME_HOST")
    delEnv("COGAME_PORT")
    delEnv("COGAME_CONFIG_URI")
    delEnv("COGAME_RESULTS_URI")

    check exitCode != 0
    check "deprecated since 0.7.253" in output
    check "allowDeprecatedModes" in output
    check "starting ctf" notin output

  test "players close within seconds of results; spectator is untouched at that checkpoint":
    ensureServerBinary()

    let resultsPath =
      getTempDir() / "test_squad_shutdown_e2e_results_" & $TestPort & ".json"
    discard tryRemoveFile(resultsPath)

    # A minimal squad (paintball KOTH) config: 2 seats, 4 cogs each, one
    # game, on the hand-tuned arena -- the same shape tests/pb_helpers.nim's
    # paintballConfigJson uses throughout the paintball suite, small enough
    # to finish in well under a minute. `speed: 16` + `fastMode` keep it
    # from running at real wall-clock pace.
    let configJson = """{
      "seed": 679961, "num_agents": 2, "minPlayers": 2, "cogsPerTeam": 4,
      "maxTicks": 600, "maxGames": 1, "regimes": ["resident"],
      "lives": 12, "hitPoints": 3, "sprayDamage": 1, "respawnTicks": 48,
      "mapPath": "arena", "loadout": "paintball", "floorPaint": true,
      "paintBuff": true, "hill": true, "turnTicks": 108,
      "turnSpacingMs": 0, "startWaitTicks": 0, "gameOverTicks": 4,
      "lobbyJoinTimeoutTicks": 0, "fastMode": true,
      "showPlayerLabels": false, "speed": 16,
      "allowDeprecatedModes": true,
      "tokens": ["t0", "t1"],
      "players": [{"name": "daveey"}, {"name": "daveey-1"}],
      "slots": [{"team": "red"}, {"team": "blue"}]
    }"""
    let configPath =
      getTempDir() / "test_squad_shutdown_e2e_config_" & $TestPort & ".json"
    writeFile(configPath, configJson)

    putEnv("COGAME_HOST", "127.0.0.1")
    putEnv("COGAME_PORT", $TestPort)
    putEnv("COGAME_CONFIG_URI", "file://" & configPath)
    putEnv("COGAME_RESULTS_URI", "file://" & resultsPath)

    var serverProcess = startProcess(
      ServerBinaryPath,
      workingDir = getCurrentDir(),
      options = {poParentStreams}
    )

    delEnv("COGAME_HOST")
    delEnv("COGAME_PORT")
    delEnv("COGAME_CONFIG_URI")
    delEnv("COGAME_RESULTS_URI")

    try:
      # Two roster seats (matches the config's 2-seat/2-team squad) plus
      # one spectator on the live-broadcast path -- exactly the two
      # connection classes the fix must treat differently. Each gets its
      # own fresh ConnectDeadlineSeconds budget (see connectWithRetry).
      let player0 = connectWithRetry(
        "ws://127.0.0.1:" & $TestPort & "/player?slot=0&token=t0",
        serverProcess
      )
      let player1 = connectWithRetry(
        "ws://127.0.0.1:" & $TestPort & "/player?slot=1&token=t1",
        serverProcess
      )
      let spectator = connectWithRetry(
        "ws://127.0.0.1:" & $TestPort & "/global",
        serverProcess
      )

      # "Results written" proxy: the same file runServerLoop's shutdown
      # path writes synchronously (via COGAME_RESULTS_URI) before the
      # squadMode grace/close sequence runs. HEARTBEAT-RESET, not a flat
      # deadline: the spectator is already connected to the live-broadcast
      # path and otherwise idle until Property 3's check far below, so
      # every frame it receives here is a real, observable progress event
      # from the same game simulation this loop is waiting on to finish --
      # reset the no-progress deadline on each one, exactly like #344's
      # markProgress(), just observed over the wire instead of a shared
      # atomic (this is a real child process, no shared memory). Also
      # fails fast if the server process exits before writing results,
      # instead of waiting out the full window for a file that can now
      # never appear. Was a flat ConnectDeadlineSeconds (60s) shared with
      # nothing else timing-sensitive about it; this is the setup/polling
      # scaffolding, not the certified property (that stays exactly
      # PromptBoundSeconds, event-anchored, below -- unchanged).
      var lastProgressAt = epochTime()
      let stallBudget = ConnectDeadlineSeconds
      while not fileExists(resultsPath):
        doAssert serverProcess.running,
          "server process exited before writing " & resultsPath
        doAssert epochTime() - lastProgressAt < stallBudget,
          "no progress for " & $stallBudget &
          "s waiting for results (server alive, no spectator frames, no file)"
        try:
          if spectator.receiveMessage(50).isSome:
            lastProgressAt = epochTime()
        except CatchableError:
          doAssert false, "spectator socket closed before results were written"
      check fileExists(resultsPath)
      let resultsAt = epochTime()

      let promptDeadline = resultsAt + PromptBoundSeconds
      let p0 = drainUntilClosed(player0, promptDeadline)
      let p1 = drainUntilClosed(player1, promptDeadline)

      # Measured, not just asserted: print the actual close latency so a
      # human (or the PR that introduced this fix) has a real number, not
      # just a pass/fail against PromptBoundSeconds. Compare against the
      # old ShutdownGraceSeconds=20 window this fix removes player sockets
      # from -- these prints are the "after" side of that comparison.
      echo "player0 socket closed ", p0.closedAt - resultsAt,
        "s after results (was riding out the full 20s grace window before this fix)"
      echo "player1 socket closed ", p1.closedAt - resultsAt,
        "s after results (was riding out the full 20s grace window before this fix)"

      # Property 1: player sockets close well inside the grace period, not
      # after it.
      check p0.closedAt > 0.0
      check p1.closedAt > 0.0
      check p0.closedAt - resultsAt < PromptBoundSeconds
      check p1.closedAt - resultsAt < PromptBoundSeconds

      # Property 2 (delivery ordering): each player received real frames
      # before its socket closed -- an abrupt/truncating close would show
      # up here as messageCount == 0 or a close with no data ever received.
      check p0.messageCount > 0
      check p1.messageCount > 0

      # Property 3 (scoping): the spectator is unaffected -- still alive
      # at the exact checkpoint where BOTH players have already closed.
      var spectatorAlive = true
      try:
        discard spectator.receiveMessage(200)
      except CatchableError:
        spectatorAlive = false
      check spectatorAlive

      player0.close()
      player1.close()
      spectator.close()
    finally:
      # The server process is still inside its own ShutdownGraceSeconds
      # window at this point (spectators/HTTP polling ride it out, on
      # purpose -- see the fix's own doc comment); this test already has
      # everything it needs, so it does not wait the window out. A hard
      # kill (never a pattern-based one -- this exact Process handle only)
      # keeps the test from ever leaving an orphan bound to TestPort.
      try:
        if serverProcess.running:
          serverProcess.kill()
        discard serverProcess.waitForExit()
      except CatchableError:
        discard
      serverProcess.close()
      discard tryRemoveFile(configPath)
      discard tryRemoveFile(resultsPath)

## Quick shell-metadata + final-ledger dump for one replay file. Built for
## the SEASON 2 replay-viewer HUD lane: `dump_glory_from_replay.nim` already
## answers "did glory mint in this episode", but nothing prints whether a
## replay's `.shell` metadata carries a huddle transcript or a ballot (the
## two records `parseReplayBytes` discards -- see `parseCtfReplayBytesFull`'s
## own doc comment, src/ctf/replays.nim) without opening a debugger. Used to
## survey every fixture under tests/ and confirm the finding this lane's
## report leans on: every real replay in this repo carries `lobbyTranscript:
## 0` and `ballots: 0` -- the shell records exist in the codec, but nothing
## in the live recording path calls `writeLobbyChat`/`writeBallot` yet, so
## the "no huddle/vote" state IS the normal case today, not a rare edge case.
##
## Usage: inspect_replay_scratch <replay.bitreplay>

import ../src/ctf/[replays, sim, replay_runtime]
import std/os

when isMainModule:
  if paramCount() < 1:
    quit("Usage: inspect_replay_scratch <replay.bitreplay>", 1)
  let path = paramStr(1)
  let bytes = readFile(path)
  echo "file: ", path, " (", bytes.len, " bytes)"
  let ctfData = parseCtfReplayBytesFull(bytes)
  echo "  gameVersion: ", ctfData.replay.gameVersion
  echo "  configJson len: ", ctfData.replay.configJson.len
  echo "  lobbyTranscript: ", ctfData.shell.lobbyTranscript.len
  echo "  ballots: ", ctfData.shell.ballots.len
  echo "  calls: ", ctfData.shell.calls.len
  echo "  manifestVerified: ", ctfData.shell.manifestVerified

  # Walk the whole replay to see the final glory ledger + achievement feed.
  var initialized = initReplayRuntime(ctfData.replay, mismatchQuit = false,
    gameEventLoggingEnabled = false)
  var game = initialized.sim
  var replay = initialized.player
  replay.looping = false
  while replay.playing:
    replay.stepReplay(game)
  echo "  final phase: ", game.phase
  for team in game.teams():
    echo "  team ", team, " glory=", game.teamGlory[team],
      " lives=", game.teamLivesRemaining(team)
  echo "  achievementFeed claims: ", game.achievementFeed.len
  echo "  gloryPops at end: ", game.gloryPops.len

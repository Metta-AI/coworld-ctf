import std/unittest

include ../src/ctf/server

suite "replay requests":
  test "duplicate URI is ignored while pending, loading, and current":
    initAppState()

    "file:///replay-a.bitreplay".queueReplayUri()
    "file:///replay-a.bitreplay".queueReplayUri()
    check appState.pendingReplayUri == "file:///replay-a.bitreplay"

    withLock appState.lock:
      appState.loadingReplayUri = appState.pendingReplayUri
      appState.pendingReplayUri = ""
    "file:///replay-a.bitreplay".queueReplayUri()
    check appState.pendingReplayUri == ""

    withLock appState.lock:
      appState.currentReplayUri = appState.loadingReplayUri
      appState.loadingReplayUri = ""
    "file:///replay-a.bitreplay".queueReplayUri()
    check appState.pendingReplayUri == ""

    "file:///replay-b.bitreplay".queueReplayUri()
    check appState.pendingReplayUri == "file:///replay-b.bitreplay"

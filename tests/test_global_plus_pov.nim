import
  helpers,
  std/unittest

# Pulls in os/strutils/curly/mummy transitively (same rig
# test_route_honesty.nim uses) -- importing them again here would only
# produce a duplicate-import hint.
include ../src/ctf/server

## global_plus_pov: the god's-eye board with a selectable seat's POV
## composited as a corner inset (the fourth viability-PRD render view).
## Almost the entire feature is client-side (client/global_plus_pov.html:
## a second BroadcastCore connection, and send()'s 'v:'-command redirect
## that drives it instead of swapping this page's own board away) — there
## is no Nim symbol to type-check for that, so this file follows the exact
## precedent test_first_person_pip.nim already set for the OTHER PiP
## feature: a real end-to-end HTTP check for the route (same rig
## test_route_honesty.nim uses — mummy's Request cannot be fabricated
## outside a live server), plus a static text-scan of the shipped bundle
## for the control-path wiring a Nim test cannot otherwise reach.
##
## Scope discipline: nothing here touches sim.nim, global.nim, gameHash, or
## GameVersion — the server.nim change under test is pure HTTP routing
## (two new path constants, two new `elif` branches, one new staticRead-
## embedded HTML constant), and the bundle scan reads static file bytes.

const TestPort = 18774
  ## Distinct from test_route_honesty.nim's 18773 -- both suites may run
  ## concurrently across shards.

suite "global_plus_pov routes serve the composited page, not the catch-all":
  test "the live and hosted-replay routes both answer real content, discriminated from /client/global":
    initAppState()
    let httpServer = newServer(httpHandler, websocketHandler, workerThreads = 1)
    var serverThread: Thread[ServerThreadArgs]
    createThread(
      serverThread,
      serverThreadProc,
      ServerThreadArgs(
        server: cast[ptr Server](unsafeAddr httpServer),
        address: "127.0.0.1",
        port: TestPort
      )
    )
    httpServer.waitUntilReady()

    let base = "http://127.0.0.1:" & $TestPort
    let curl = newCurly()

    # The live route: real HTML, not the ten-byte "CTF server" fallback,
    # and it must carry THIS view's own marker (the inset canvas) -- not
    # merely reuse /client/global's response verbatim, which would mean
    # the route silently fell through to the wrong embedded constant.
    let liveResp = curl.get(base & GlobalPlusPovClientPath)
    check liveResp.code == 200
    check liveResp.body != "CTF server"
    check "text/html" in liveResp.headers["Content-Type"]
    check "povInsetCanvas" in liveResp.body
    check "setInsetSlot" in liveResp.body

    # The hosted-replay route serves the identical embedded page (same
    # constant server-side) under a distinct path, mirroring how
    # /client/global and /client/replay both already serve
    # EmbeddedBroadcastReplayHtml.
    let replayResp = curl.get(base & ReplayPlusPovClientPath)
    check replayResp.code == 200
    check "povInsetCanvas" in replayResp.body

    # Discriminated from the plain global_observer route: that page has NO
    # POV inset at all, so its response must NOT carry this view's marker.
    # If a future edit collapsed the two routes onto the same handler
    # branch by mistake, this is what would catch it.
    let plainGlobalResp = curl.get(base & "/client/global")
    check plainGlobalResp.code == 200
    check "povInsetCanvas" notin plainGlobalResp.body

    # A path that merely LOOKS related must still 404, not fall through to
    # the permissive /client/* or top-level catch-all (test_route_honesty.nim
    # covers the general mechanism; this pins it for these two new paths
    # specifically, since a typo'd path constant would otherwise silently
    # 200 via the catch-all and this suite would never notice).
    let bogusResp = curl.get(base & "/client/global_plus_pov_typo")
    check bogusResp.code == 404
    check bogusResp.body != "CTF server"

    curl.close()
    httpServer.close()
    joinThread(serverThread)
    initAppState()

suite "global_plus_pov's bundle carries the composited control path":
  ## Static scans, same idiom as test_first_person_pip.nim's asset-path
  ## check: the logic lives in inline JS inside the HTML, so there is no
  ## Nim symbol to type-check and no cheap way to run the page here.
  let bundle = readFile(GameDir / "client" / "global_plus_pov.html")

  test "the page owns a SECOND independent board+POV connection for the inset":
    # The whole "reuse the already-computed sprite stream" argument for this
    # view rests on there being two live BroadcastCore instances -- the
    # page's own `core` (always the board) and `insetCore` (POV, on demand)
    # -- not one connection re-rendered into two canvases. A single
    # `.create(` call would mean the inset is fake (CSS over nothing).
    check bundle.count("BroadcastCore.create(") >= 1
    check bundle.count("replayAdapter.createCore(") >= 1
    check "insetCore = replayAdapter" in bundle
    check "povInsetCanvas" in bundle

  test "'v:<slot>' is redirected to the inset, not the page's own board connection":
    # send()'s interception is the ENTIRE control-path fix: every existing
    # POV entry point (squad-pip click, achievement deep link, postMessage
    # bridge) already spells the command 'v:'+slot and funnels through
    # send() unmodified -- this one redirect is what makes all of them
    # drive the corner window instead of swapping the board away.
    check "function send(cmd)" in bundle
    let sendIdx = bundle.find("function send(cmd)")
    let sendBody = bundle[sendIdx ..< min(bundle.len, sendIdx + 800)]
    check "setInsetSlot(" in sendBody
    check "core.sendCommand(cmd)" in sendBody
    # The achievement focus and postMessage 'pov' case must still read
    # exactly like every other page (send('v:'+slot)) -- NOT call
    # setInsetSlot directly at their own call sites, which would be the
    # "parallel control scheme" the brief rules out. One redirect point,
    # not several call sites re-implementing it.
    check "send('v:' + s.ach[i].s)" in bundle
    check "send('v:' + m.slot)" in bundle

  test "board-click-to-select is disabled, not left to hijack the god's-eye board":
    # replay_broadcast.html (the page this was forked from) wires a canvas
    # click to core.clickMap(...), which toggles selectedJoinOrder -- the
    # SAME full-board-swap mechanism 'v:' drives -- on whichever connection
    # sent it. If that call survived the fork, a stray click on a soldier
    # would swap THIS page's own board connection into POV, defeating the
    # entire view (the god's-eye board is supposed to never swap away).
    check "core.clickMap(" notin bundle

  test "squad-pip glow and getState() read the INSET's slot, not the board connection's own":
    # renderSquad's 4th arg drives the '.pov' CSS glow on each pip
    # (chrome_common.js). This connection's own `s.pov` is always -1 (send()
    # never lets a 'v:' reach it) -- passing insetSlot instead is what makes
    # the pip for whoever is showing in the corner light up correctly.
    check bundle.count("renderSquad($('squad-' + team), s, team, insetSlot)") == 2
    check "merged.pov = insetSlot" in bundle

  test "?pov=<slot> is a real deep link, applied once core.start() has run":
    check "get('pov')" in bundle
    check "POV_DEEP_LINK" in bundle
    check "setInsetSlot(POV_DEEP_LINK)" in bundle

  test "a dead or departed inset seat degrades to a caption or a clean clear, never a stuck frame":
    # Ghost view (dead, still a valid seat): buildSpriteProtocolPlayerUpdates
    # already renders this correctly server-side (unfogged, no entities) --
    # this only checks the client surfaces it as a caption instead of
    # silently leaving a static frame with no explanation.
    check "eliminated" in bundle
    # Invalid/departed seat (selectedPlayerIndex resolves to -1 server-side,
    # so the connection silently falls back to board mode): the client must
    # notice its OWN confirmed slot disagrees with what it asked for and
    # clear, rather than show a full board crammed into the corner box.
    check "confirmedSlot !== insetSlot" in bundle
    check "setInsetSlot(-1)" in bundle

  test "the LIVE path carries the #364/#369 mode latch and the heart gate":
    # Hotfix lane 2026-09-02: this page is the OTHER live client, forked
    # before #364/#369, so it still latched PB_MODE off `regime` (a signal
    # every squad-seated frame carries — BR duos and Campaign alike) and
    # rendered heart banners on BR wire events. The ported latch reads the
    # genuine Paintball tell, the endcard's endRule switch requires PB_MODE,
    # and the steal/return/capture handlers sit behind the heart gate.
    check "function isPaintballMode(s) { return !!(s && s.hillOwner !== undefined); }" in bundle
    check "if (!PB_MODE && isPaintballMode(s) && !isElim(s)) PB_MODE = true;" in bundle
    check "s.regime !== undefined) PB_MODE = true" notin bundle
    check "if (o.endRule !== undefined && PB_MODE) {" in bundle
    check "if (elim) return 'LAST TEAM STANDING';" in bundle
    check "if ((e.k === 'steal' || e.k === 'return' || e.k === 'capture') &&" in bundle
    check "(isElim(s) || isFlagless(s) || PB_MODE)) return;" in bundle
    check "if (self.carry && !isElim(lastState) && !isFlagless(lastState) && !PB_MODE)" in bundle
    check "if (!s.beats || isElim(s) || isFlagless(s) || PB_MODE) return;" in bundle
    check "ingestBeats(heartGatedBeats(s));" in bundle
    check "function heartGatedBeats(s)" in bundle

  test "a reconnect re-arms the requested POV slot instead of settling into board mode":
    # broadcast_core.js retries the socket itself after a drop, but a fresh
    # connection starts in board mode -- 'v:' has to be resent on the very
    # next 'open', or an inset that survives a network blip silently reverts
    # to nothing with no error. (This is also what the initial connect's own
    # race needs: the first 'v:' send is a no-op until OPEN.)
    check "st === 'open' && insetSlot >= 0" in bundle
    check "insetCore.sendCommand('v:' + insetSlot)" in bundle

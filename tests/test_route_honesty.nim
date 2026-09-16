import std/unittest

include ../src/ctf/server

## The landmine this guards: server.nim's httpHandler ends in a catch-all
## that answers 200 "CTF server" for ANY unmatched path. Measured live, that
## made /health and /status (neither a real route) indistinguishable from a
## genuine 200 to anything checking status alone -- and this project's own
## deploy ritual (pbnf-swap) was, before the honest-routes fix, one status
## check away from doing exactly that. This is a REAL end-to-end HTTP test,
## not a unit call into httpHandler directly: mummy's Request is a pointer
## into a live connection (server/clientSocket/clientId are private fields
## respond() unconditionally dereferences), so there is no way to fabricate
## one outside an actual server -- see the mummy source for RequestObj. The
## same real-server pattern server.nim's own runServerLoop uses
## (newServer + createThread(serverThreadProc) + waitUntilReady) is reused
## here, on a fixed high test-only port distinct from anything else this
## repo binds. The HTTP client is `curly` (already this file's own import,
## via the include above) rather than std/httpclient, which defines its own
## HttpHeaders and collides with mummy's identically-named type the moment
## both are in scope in the same module.
const TestPort = 18773

suite "the catch-all cannot silently shadow a real route":
  test "known top-level routes answer real content; an unknown path 404s, never the catch-all's 200":
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

    # /healthz is the real health route: genuine content, not the fallback.
    let healthzResp = curl.get(base & HealthPath)
    check healthzResp.code == 200
    check healthzResp.body == "healthy"
    check healthzResp.body != "CTF server"

    # /health (no z) is not HealthPath -- this is exactly the bug: before
    # the alias fix, this fell through to the catch-all's 200 "CTF server"
    # and no status-only check could tell the difference from a real route.
    let healthResp = curl.get(base & "/health")
    check healthResp.code == 200
    check healthResp.body == "healthy"
    check healthResp.body != "CTF server"

    # /capabilities is a real route with real JSON, not the ten-byte fallback.
    let capsResp = curl.get(base & CapabilitiesPath)
    check capsResp.code == 200
    check "seatTakeover" in capsResp.body
    check capsResp.body != "CTF server"

    # A path this server has never served, at the top level (outside
    # /client/, which already had its own narrower 404 guard): must 404,
    # not fall through to the 200 catch-all. If a future edit widens the
    # catch-all's reach again -- or a real route's path constant silently
    # drifts from what this test expects -- this assertion is what catches
    # it, rather than a monitor discovering it live.
    let bogusResp = curl.get(base & "/this-route-has-never-existed-honest-routes-guard")
    check bogusResp.code == 404
    check bogusResp.body != "CTF server"

    # Sanity anchor: prove the catch-all itself still exists and still
    # answers exactly "CTF server" for a path that IS a known route hit with
    # the wrong method -- so this suite is testing discrimination, not
    # measuring a catch-all that has been deleted outright. /admin
    # (AdminWebSocketPath) requires a websocket upgrade; a plain GET without
    # upgrade headers falls past that branch to the still-permissive
    # fallback for KNOWN paths, which this test does not attempt to change.
    let knownPathWrongMethodResp = curl.get(base & AdminWebSocketPath)
    check knownPathWrongMethodResp.code == 200
    check knownPathWrongMethodResp.body == "CTF server"

    curl.close()
    httpServer.close()
    joinThread(serverThread)
    initAppState()

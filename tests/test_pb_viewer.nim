## The STATIC half of the paintball viewer smoke: the guarantees the merged
## broadcast page makes about serving BOTH modes from one file. The classic
## chrome survives untouched; the paintball game block is APPENDED and
## activates only when a frame carries a squad field.
import std/[os, strutils, unittest]

const
  ## Bump ONLY for a deliberate edit to the shared chrome, and say what moved.
  ## Last: resetEpisode() added + exported (episode-transition reset, owner
  ## hotfix 2026-09-02). A live spectator page outlives its episode — the
  ## next episode's server takes over the same URL and broadcast_core
  ## reconnects the SAME page to a DIFFERENT match — so every once-per-match
  ## latch in the shared chrome closure (beat timeline, verdict chip,
  ## momentum series, lull spans, placed scrubber markers) now has one reset
  ## entry point the pages call from their reconnect hook.
  ChromeCommonFingerprint = "f99ef73a84c5f67d"
    ## chrome_common.js pinned: everything paintball adds lives in the
    ## appended game block, so an edit to the shared chrome fails a test
    ## instead of silently drifting. Re-pinned during the season2 main
    ## merge (main's paintball work pinned this against chrome_common.js
    ## before 70f01860 "ship all 16 team identities" landed on our side —
    ## that commit predates this merge and legitimately changed the file
    ## by deriving TEAM_ORDER/TEAM_COLOR from window.CTF_WIRE; the
    ## appended-paintball-block guarantee this test exists for is untouched).
  Page = "client/replay_broadcast.html"
  Chrome = "client/chrome_common.js"
  Core = "client/broadcast_core.js"
  Shell = "replay-viewer/static_replay.js"

proc read(path: string): string = readFile(path)

proc fingerprint(text: string): string =
  ## FNV-1a 64 over the whole file, rendered as 16 hex digits.
  var hash = 14695981039346656037'u64
  for ch in text:
    hash = hash xor uint64(ord(ch))
    hash = hash * 1099511628211'u64
  toHex(hash, 16).toLowerAscii()

suite "broadcast chrome (both modes, one page)":
  let page = read(Page)
  let chrome = read(Chrome)
  let core = read(Core)

  test "the classic transport, scorebug, feed and endcard survive":
    for id in ["\"stage\"", "\"board\"", "\"lockerroom\"", "\"scorebug\"",
               "\"bannerlane\"", "\"killfeed\"", "\"fpv\"", "\"povBadge\"",
               "\"mmwarn\"", "\"transport\"", "\"endcard\"", "\"scrub\"",
               "\"tick-clock\"", "\"momentum\"", "\"btn-play\"",
               "\"btn-skip\"", "\"clock-time\"", "\"clock-caption\""]:
      check ("id=" & id) in page or ("$(" & id & ")") in page or
        ("$('" & id.strip(chars = {'"'}) & "')") in page

  test "the classic view controls survive (classic boards can be colossal)":
    check "id=\"viewpanel\"" in page
    check "id=\"minimap\"" in page
    check "attachMinimap" in page

  test "both modes' beat kinds have CSS, and paintball beats are BUTTONS":
    for kind in [".beat-marker.gamestart", ".beat-marker.hillflip.red",
                 ".beat-marker.hillflip.blue", ".beat-marker.tagout.red",
                 ".beat-marker.tagout.blue", ".beat-marker.gameover",
                 ".beat-marker.steal", ".beat-marker.capture"]:
      check kind in page
    check "button.beat-marker" in page
    check "createElement('button')" in page

  test "the game block is APPENDED under its banner, never a rewrite":
    check "PAINTBALL additions to the inherited coworld-ctf chrome" in page
    let banner = page.find("PAINTBALL additions to the inherited")
    check page.find("function relayout()") < banner
    check page.find("id=\"transport\"") < banner
    check page.find("window.ChromeCommon") < banner

  test "the game block defines no identifier the chrome alias block owns":
    ## The tandem 2026-08-23 hoisting trap: a game-block `function markBeat`
    ## is swallowed by the alias block's `var markBeat = C.markBeat`, leaving
    ## unlabelled div markers that never seek.
    let banner = page.find("PAINTBALL additions to the inherited")
    let appended = page[banner .. ^1]
    for alias in ["markBeat", "renderBeatMarkers", "ingestBeats", "setVerdict",
                  "renderClock", "renderTransport", "recordMomentum",
                  "ingestLeadSeries", "ingestLullSpans",
                  "killMarkerTeam", "captureTeam", "setHandicap"]:
      check ("function " & alias) notin appended
      check ("var " & alias) notin appended
    check "function pbBeat(" in appended

  test "the paintball chrome activates by frame content, never by default":
    check "var PB_MODE = false;" in page
    # modechrome lane: `s.regime` rides every squad-seated frame (BR AND
    # Campaign/classic squad variants alike, not just Paintball), so the
    # latch reads the wire's actual Paintball-exclusive tell (`hillOwner`,
    # only ever emitted behind `sim.config.hill`, which only the `paintball`
    # manifest variant sets) via isPaintballMode() instead.
    check "function isPaintballMode(s) { return !!(s && s.hillOwner !== undefined); }" in page
    check "if (!PB_MODE && isPaintballMode(s) && !isElim(s)) PB_MODE = true;" in page
    check "if (PB_MODE && window.PaintballChrome" in page

  test "heart banners are classic-CTF-only chrome (BR/flagless/PB gated)":
    # Hotfix lane 2026-09-02: the wire's steal/return/capture events are
    # diffed off sim.flags carrier flips, a mechanism #370's loot rework now
    # also exercises on BR frames — a LIVE battle royale rendered a
    # "BLUE HEART RETURNED" banner. The heart banner/beat/cap-heart paths
    # must sit behind the same mode tells #364/#369 established.
    check "if ((e.k === 'steal' || e.k === 'return' || e.k === 'capture') &&" in page
    check "(isElim(s) || isFlagless(s) || PB_MODE)) return;" in page
    check "if (self.carry && !isElim(lastState) && !isFlagless(lastState) && !PB_MODE)" in page
    check "if (!s.beats || isElim(s) || isFlagless(s) || PB_MODE) return;" in page
    # The up-front beat timeline path too: replays ship every heart beat on
    # the first HUD frame, so without this a BR scrubber still grew steal
    # markers even with applyEvent gated.
    check "ingestBeats(heartGatedBeats(s));" in page
    check "function heartGatedBeats(s)" in page

  test "an episode transition resets every once-per-match latch":
    # Owner hotfix 2026-09-02, second half: the live S2 page auto-advances —
    # the next episode's server takes over the same URL and broadcast_core
    # reconnects the SAME page to a DIFFERENT match. Without a full reset the
    # old episode's chrome (PB_MODE, beat timeline, verdict, momentum,
    # cap-hearts, scrubber markers) and the old episode's board OBJECTS
    # (hearts/med kits the new server's empty per-viewer ledger can never
    # diff-delete) play over the new episode until a manual refresh.
    check "if (streamsOpened > 1) resetEpisodeChrome();" in page
    check "function resetEpisodeChrome()" in page
    check "C.resetEpisode();" in page
    check "resetEpisode: resetEpisode," in chrome
    check "function resetEpisode()" in chrome
    # broadcast_core clears its render state (layers/sprites/objects/zone)
    # at the top of every connect, so a reconnect can never composite the
    # previous stream's objects over the new board.
    check "function resetStreamState()" in core
    check "resetStreamState();" in core

  test "chrome_common.js is byte-identical to the shared original":
    check fingerprint(chrome) == ChromeCommonFingerprint
    check "window.ChromeCommon = function (ctx)" in chrome

  test "broadcast_core.js reads the ctf wire global only":
    check "window.CTF_WIRE" in core
    check "PAINTBALL_WIRE" notin core

  test "the shell sets BOTH load and failure markers on <html>":
    let shell = read(Shell)
    check "'data-replay-error'" in shell
    check "'data-replay-loaded', 'true'" in shell

  test "a seek is never dropped for want of a frame, and lands promptly":
    check "function seekToFraction(s, frac)" in page
    check "SEEK_FRAC = frac; return;" in page
    check "if (SEEK_FRAC != null && s.en)" in page
    let handler = page.find("$('scrub').addEventListener('click'")
    check handler >= 0
    check "if (!lastState || !lastState.en) return;" notin
      page[handler ..< min(page.len, handler + 600)]
    let worker = read("replay-viewer/static_replay_worker.js")
    check "function applyInputNow()" in worker
    let commandBranch = worker.find("message.type === 'command'")
    check commandBranch >= 0
    check worker.find("applyInputNow();", commandBranch) > commandBranch
    let shellText = read(Shell)
    check "lastAdvanceMs > frameMs ? 1 : 6" in shellText

  test "the appended block routes every derived event kind the sim emits":
    let banner = page.find("PAINTBALL additions to the inherited")
    let appended = page[banner .. ^1]
    for kind in ["'gamestart'", "'hillflip'", "'tagout'", "'gameover'",
                 "'hillhold'", "'paint'", "'heal'", "'spray'", "'tag'"]:
      check ("case " & kind) in appended

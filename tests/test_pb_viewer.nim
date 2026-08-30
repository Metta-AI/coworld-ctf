## The STATIC half of the paintball viewer smoke: the guarantees the merged
## broadcast page makes about serving BOTH modes from one file. The classic
## chrome survives untouched; the paintball game block is APPENDED and
## activates only when a frame carries a squad field.
import std/[os, strutils, unittest]

const
  ChromeCommonFingerprint = "fbcd687dda368276"
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
    check "s.regime !== undefined" in page
    check "if (PB_MODE && window.PaintballChrome" in page

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

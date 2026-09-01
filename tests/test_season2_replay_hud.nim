## SEASON 2 broadcast/replay viewer: text-scan red-proofs for the
## glory/achievements/huddle/vote rendering added to the shared client
## chrome (client/replay_broadcast.html, baked into the static replay
## viewer bundle by Dockerfile.replay-viewer / tools/build_replay_viewer.sh).
##
## Same idiom as test_first_person_pip.nim's "bundle asset paths" suite:
## the HUD lives in inline JS/CSS inside a single-page HTML file, so there
## is no Nim symbol to type-check and this is the cheap way to prove the
## rendering code is actually still THERE and actually still WIRED to the
## per-frame chrome pipeline, not just present somewhere unreachable in the
## file. It does not (and cannot, without a browser) prove the pixels look
## right -- that is the screenshot verification pass, done separately.
##
## Checks BOTH copies on purpose: `client/replay_broadcast.html` is the
## SOURCE, `static-replay-viewer/index.html` is the SHIPPED, checked-in
## build output (tools/build_replay_viewer.sh's Docker stage bakes one into
## the other) -- exactly the "served bundle is not stale" contract
## tools/qa_module_eval.cjs's own header comment names. A source fix that
## never got rebuilt into the served copy looks green everywhere else and
## is broken in the browser.

import
  helpers,
  std/[os, strutils, unittest]

const
  SourcePage = GameDir / "client" / "replay_broadcast.html"
  ServedPage = GameDir / "static-replay-viewer" / "index.html"

proc bothPages(): seq[tuple[label, text: string]] =
  @[
    (label: "source (client/replay_broadcast.html)", text: readFile(SourcePage)),
    (label: "served bundle (static-replay-viewer/index.html)",
      text: readFile(ServedPage))]

template checkInBoth(needle: string) =
  for page in bothPages():
    checkpoint(page.label & " is missing: " & needle)
    check page.text.contains(needle)

suite "SEASON 2 replay viewer HUD: glory":
  test "topbar glory numeral is wired to the per-team ledger field":
    # DOM: ensureScorebug's plate template carries a .glory-num element…
    checkInBoth "class=\"glory-num\""
    # …and renderScorebug actually reads the wire's unconditional per-team
    # "glory" key (broadcast.nim teamStateJson) to fill it in, gated by
    # .has-glory so a pre-glory-port replay's topbar is unchanged.
    checkInBoth "tr[team] && tr[team].glory"
    checkInBoth "has-glory"

  test "per-deed glory pops read the sim's live cosmetic pop queue":
    # #gloryPops is the world-anchored positioning root; renderGloryPops
    # reads state.pops (broadcast.nim gloryPopsJson, sim.gloryPops) every
    # frame and is actually called from the onFrame pipeline (not just
    # defined and orphaned).
    checkInBoth "id=\"gloryPops\">"
    checkInBoth "function renderGloryPops(s)"
    checkInBoth "(s.pops || [])"
    checkInBoth "renderGloryPops(s);"
    # p.row is the sim's own site-collision stack depth (addGloryPop,
    # sim.nim's GloryPopMaxStack): two simultaneous pops at one site (e.g. a
    # rank-up beside an unrelated deed pop at a spawn point) must stack
    # visually, not draw on top of each other. Caught by rendering a real
    # replay's opening frame and looking at it, not by a text-scan.
    checkInBoth "p.row"

  test "endcard carries MATCH GLORY totals and the achievements ledger":
    # Per-team endcard glory total, gated the same has-glory way as the
    # topbar, plus the "N/ACH_TOTAL · +bonus" achievements line built from
    # the wire's over.achievements feed (broadcast.nim buildStateJson).
    checkInBoth "class=\"ec-glory\""
    checkInBoth "o.teams && o.teams[team] && o.teams[team].glory"
    checkInBoth "function teamAchievementsHtml(o, team)"
    checkInBoth "o.achievements || []"
    checkInBoth "ACH_TOTAL"

suite "SEASON 2 replay viewer HUD: huddle + vote":
  test "lobby panels exist, are wired to the send-once shell chrome, and degrade to nothing":
    checkInBoth "id=\"huddlePanel\""
    checkInBoth "id=\"votePanel\""
    checkInBoth "function renderLobbyPanels(s)"
    checkInBoth "renderLobbyPanels(s);"
    # Cached on first sight (the huddle/vote chrome ships once, like ach/
    # beats/lead) and only ever SHOWN during the lobby phase — never a
    # full-match takeover.
    checkInBoth "s.ph === 'lobby'"
    # The degrade-to-nothing path: absent s.huddle/s.vote (no shell records
    # on this replay) never toggles the panel visible — there is no
    # unconditional ".show" anywhere for either panel.
    for page in bothPages():
      checkpoint(page.label & ": huddlePanel must not be unconditionally shown")
      check not page.text.contains("$('huddlePanel').classList.add('show')")
      checkpoint(page.label & ": votePanel must not be unconditionally shown")
      check not page.text.contains("$('votePanel').classList.add('show')")

  test "vote panel renders the A-D ballot and highlights the resolved winner":
    checkInBoth "VOTE_LETTERS = ['A', 'B', 'C', 'D']"
    checkInBoth "resolved.final === i"
    checkInBoth "class=\"vo-crown\""

  test "huddle panel renders seats by team color and escapes chat text":
    checkInBoth "class=\"huddle-seat\""
    # esc() is the shared chrome_common.js HTML-escape helper — chat text
    # must never be interpolated raw (an unescaped '<' from a policy's
    # message would otherwise inject markup into the transcript).
    checkInBoth "esc(m.text)"

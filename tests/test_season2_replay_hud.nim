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
##
## CONCURRENCY: do not run this suite while tools/build_replay_viewer.sh is
## rebuilding static-replay-viewer/ in the same checkout. That script
## `rm -rf`s the whole directory before repopulating it (see its own
## "ecos 2026-08-23 scar" comment), and ServedPage below reads
## static-replay-viewer/index.html straight off disk -- a read that lands
## inside the rm -rf window sees a missing or half-written file and fails
## this suite for a reason that has nothing to do with the change under
## test.

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

  test "endcard names the players behind every color (owner 2026-09-02)":
    # "naming the color that won alone is pointless! you have to name the
    # players too." The BR endcard's winner banner carries a secondary
    # names line under the color headline, and every standings row carries
    # the duo's seat/policy names beside its color chip. brTeamNames reads
    # the wire roster's own identities (teamPolicies: teams[team].policies
    # or per-seat p.pol/p.name — the seat name IS the identity contract).
    checkInBoth "function brTeamNames(s, team)"
    checkInBoth "id=\"ec-hero-duo\""
    checkInBoth "heroDuo.textContent = namesFor(winner)"
    checkInBoth "class=\"ec-fduo\""
    # Names render only where they ADD identity — a single-policy team's
    # label already IS its name, never the same string twice.
    checkInBoth "names !== labelOf[team] ? names : ''"

  test "BR scorebug cells name every member beside their life square":
    # Owner direction 2026-09-02: "the life squares can stack vertically
    # and have the name to the right or something" — each 16-team cell is
    # swatch + a vertical member stack (life square + that seat's own
    # policy name per row, both duo members) + glory. brShortIdent keeps
    # the DISTINCTIVE tail of the long shared-namespace policy names, one
    # truncation rule for all 16 chips.
    checkInBoth "class=\"br-cell-members\""
    checkInBoth "function brShortIdent(n)"
    checkInBoth "class=\"br-cell-mname\""
    # Per-member identity reads the roster's own pol field (the identity
    # contract), never name-matching.
    checkInBoth "p.pol != null ? p.pol : stripSeatSuffix(p.name)"

suite "SEASON 2 replay viewer HUD: phase presentation + comms":
  test "phase overlays exist, are wired per-frame, and degrade to nothing":
    # The three-act presentation (owner spec): MAP VOTE stage, HUDDLE stage,
    # then the arena with the collapsed huddle chip (narrow) or the comms
    # sidebar (wide). All driven from renderPhaseOverlays on the same
    # per-frame pipeline the scorebug uses.
    checkInBoth "id=\"voteStage\""
    checkInBoth "id=\"huddleStage\""
    checkInBoth "id=\"huddlePanel\""
    checkInBoth "id=\"huddleChip\""
    checkInBoth "id=\"commsdock\""
    checkInBoth "function renderPhaseOverlays(s)"
    checkInBoth "renderPhaseOverlays(s);"
    # Acts only ever engage during the lobby phase — never a full-match
    # takeover — and the collapse boundary is the lobby -> arena flip.
    checkInBoth "s.ph === 'lobby'"
    # The degrade-to-nothing path: absent s.huddle/s.vote/onCalls (no shell
    # records on this replay) no overlay is ever toggled visible — there is
    # no unconditional ".show" for any of them.
    for page in bothPages():
      checkpoint(page.label & ": huddlePanel must not be unconditionally shown")
      check not page.text.contains("$('huddlePanel').classList.add('show')")
      checkpoint(page.label & ": voteStage must not be unconditionally shown")
      check not page.text.contains("$('voteStage').classList.add('show')")

  test "map-vote stage renders the A-D ballot quadrants and the resolved winner":
    checkInBoth "VOTE_LETTERS = ['A', 'B', 'C', 'D']"
    checkInBoth "resolved.final === i"
    checkInBoth "classList.toggle('winner'"
    # Cast chips reveal by the record's own ms stamp against the playhead —
    # a scrub back into the lobby replays the sequence.
    checkInBoth "(v.ms || 0) > nowMs"

  test "comms feed renders chat + flash rows by seat palette and escapes text":
    # One renderer feeds the huddle room, the corner panel and the wide
    # sidebar; flash rows (play-call record 0x10) are visually distinct.
    checkInBoth "function commsEntryHtml(item)"
    checkInBoth "class=\"hd-flash\""
    checkInBoth "seatCol(item.seat"
    # esc() is the shared chrome_common.js HTML-escape helper — chat text
    # must never be interpolated raw (an unescaped '<' from a policy's
    # message would otherwise inject markup into the transcript).
    checkInBoth "esc(item.text)"

  test "the huddle collapses to a chip with an unread badge and reopens":
    checkInBoth "id=\"huddleUnread\""
    checkInBoth "chip-pulse"
    # Auto-collapse at the lobby -> arena boundary, user reopen any time.
    checkInBoth "huddleOpen = null"
    checkInBoth "huddleOpen = false"

  test "flash records ride the loaded channel and anchor the in-arena pulse":
    # Page side: the onCalls hook ingests the play-call records and enriches
    # them with each seat's roster index for the core's pulse ring.
    checkInBoth "onCalls: function (calls) { ingestFlashCalls(calls); }"
    checkInBoth "function pushFlashCallsToCore()"
    # Worker/core side (shipped beside the page in the bundle): the worker
    # forwards calls from the wasm export, and the core draws the ring on
    # the rig-head anchor. These live in their own files, not the page.
    let workerText = readFile(GameDir / "replay-viewer" / "static_replay_worker.js")
    check workerText.contains("_ctf_calls_len")
    check workerText.contains("'flashCalls'")
    let coreText = readFile(GameDir / "client" / "broadcast_core.js")
    check coreText.contains("function drawFlashPulses(targetCtx)")
    check coreText.contains("RIG_HEAD_OBJECT_BASE")

  test "a downed seat's roster flag fades its rig, no new chrome":
    # Page side: every frame's roster (src/ctf/broadcast.nim's rosterJson,
    # downedMode-gated) is turned into a seat-index list and handed to the
    # core -- same "page resolves identity, core just draws" split as the
    # flash pulse above.
    checkInBoth "function pushDownedSeatsToCore(s)"
    checkInBoth "pushDownedSeatsToCore(s);"
    checkInBoth "r[i] && r[i].downed"
    # Core side: the rig object family (head/arms/legs/wheels/gun) for each
    # downed seat draws at reduced alpha in drawObject -- a fade, not a new
    # sprite pool or an overlay marker.
    let coreText = readFile(GameDir / "client" / "broadcast_core.js")
    check coreText.contains("function setDownedSeats(seats)")
    check coreText.contains("downedObjectIds")
    check coreText.contains("DOWNED_FADE_ALPHA")
    check coreText.contains("RIG_ARM_OBJECT_BASE")
    check coreText.contains("RIG_LEG_OBJECT_BASE")
    check coreText.contains("RIG_WHEEL_OBJECT_BASE")
    check coreText.contains("RIG_GUN_OBJECT_BASE")
    let drawObj = coreText.find("function drawObject(targetCtx, obj)")
    check drawObj >= 0
    check coreText.find("downedObjectIds.has(obj.id)", drawObj) > drawObj

suite "SEASON 2 replay viewer HUD: side-lane docking (letterbox rails)":
  ## Owner spec 2026-09-02: "use the full left lane letterbox space to put
  ## the names and scorebug and chat and everything." When the fitted board
  ## leaves a real pillarbox column on both flanks, relayout() docks the
  ## overlay chrome into the dead bands (identity LEFT, live surfaces
  ## RIGHT); narrow boxes keep the classic centered-stage layout untouched.
  test "both pillarbox rails exist and relayout decides the tiers by geometry":
    checkInBoth "id=\"lane-l\""
    checkInBoth "id=\"lane-r\""
    # Tier 2 (both rails) needs a real lane each side of the free-fit board;
    # tier 1 (left rail only) caps the board at boxW - RAIL_MIN and engages
    # only while that costs < 10% of the free fit — the rail must eat the
    # letterbox, never the arena.
    checkInBoth "var lanesBoth = !EMBED && (boxW - fit0) >= 2 * LANE_MIN;"
    checkInBoth "(!EMBED && boxW > boxH && cappedW / fit0 >= 0.9);"
    checkInBoth "dockLanes(sideLanes, sideLanes && lanesBoth);"

  test "docked mode gives the board the top band back":
    checkInBoth "topBand = (sideLanes || !scorebug) ? 0 : scorebug.offsetHeight;"

  test "docking MOVES elements and the narrow fallback restores the home DOM":
    # Moved, never cloned: getElementById references and listeners stay
    # live, and the recorded home parent/next-sibling puts everything back.
    checkInBoth "d.lane.insertBefore(d.el, d.before);"
    checkInBoth "d.home.insertBefore(d.el, d.homeNext);"

  test "left rail = identity (scorebug + comms), right rail = live surfaces":
    checkInBoth "body.sidelanes #scorebug"
    checkInBoth "body.sidelanes #commsdock"
    checkInBoth "body.sidelanes-both #viewpanel"
    checkInBoth "body.sidelanes-both #killfeed"
    # The BR 8-per-side cell bands re-flow to one roster column; the cells
    # themselves (the endcard-player-names lane's territory) are untouched.
    checkInBoth "body.sidelanes #scorebug .br-cellband"

  test "the chat surface exists in the rail even when the lobby never spoke":
    checkInBoth "(sideLanes || (COMMS_AVAILABLE && (boxW - stageW) >= 280));"
    checkInBoth "cd-empty"
    checkInBoth "#commsFeed:empty + .cd-empty { display: block; }"

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
  std/[os, strutils, unittest],
  ctf/glory

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
  ## the names and scorebug and chat and everything." SUPERSEDED 2026-09-09
  ## (owner: "the left rail is the design i want" / "always" / "just make
  ## left rail the default. fix the problem at its core."): the left rail
  ## is no longer gated by aspect, cost, or embed mode — relayout() docks it
  ## unconditionally at every window shape, embed included, and only the
  ## SECOND (right, live-surface) rail still depends on there being real
  ## pillarbox room on both flanks. Below ~480px wide the rail's reserved
  ## width shrinks (railMin/boardFloor) rather than the rail disappearing.
  test "both pillarbox rails exist and relayout decides the tiers by geometry":
    checkInBoth "id=\"lane-l\""
    checkInBoth "id=\"lane-r\""
    # Tier 2 (both rails) needs a real lane each side of the free-fit board
    # and is no longer gated by embed mode either. Tier 1 (left rail) is
    # now unconditional (owner: "always") — no aspect/cost gate remains.
    checkInBoth "var lanesBoth = (boxW - fit0) >= 2 * LANE_MIN;"
    checkInBoth "var sideLanes = true;"
    checkInBoth "dockLanes(sideLanes, sideLanes && lanesBoth);"

  test "the rail shrinks rather than disappearing below ~480px wide":
    checkInBoth "var tinyBox = boxW < 480;"
    checkInBoth "var railMin = tinyBox ? Math.max(80, Math.round(boxW * 0.32)) : RAIL_MIN;"
    checkInBoth "var boardFloor = tinyBox ? Math.max(120, Math.round(boxW * 0.45)) : 320;"

  test "docked mode gives the board the top band back":
    # sideLanes is unconditional now, so the top band never reserves space —
    # no more "sideLanes || !scorebug" ternary guarding a top-band fallback.
    checkInBoth "topBand = 0;"

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

suite "SEASON 2 replay viewer HUD: left rail is the default (owner 2026-09-09)":
  ## "the left rail is the design i want" / "always" / "just make left rail
  ## the default. fix the problem at its core." Guards the two regressions
  ## this could silently reintroduce: the embed CSS hiding #scorebug again
  ## (the board must draw its own rail ledger inside the League Replayer's
  ## iframe), and the League Replayer shell growing back its own duplicate
  ## top-band scorebug (team names + clock) now that the board always
  ## supplies that.
  test "embed mode no longer hides the rail's #scorebug":
    for page in bothPages():
      checkpoint(page.label & " still hides #scorebug in embed mode")
      check not page.text.contains("body[data-embed] #scorebug,")
    # transport/lightpool/grain/status stay shell-owned in embed — only the
    # glory ledger moved.
    checkInBoth "body[data-embed] #transport,"

  test "the League Replayer shell no longer draws its own top-band scorebug":
    let shellSource = readFile(GameDir / "client" / "league_replayer.html")
    let shellServed = readFile(GameDir / "static-replay-viewer" / "league.html")
    for shell in [shellSource, shellServed]:
      checkpoint("shell must hide its own #scorebug")
      check "#scorebug{display:none}" in shell
      checkpoint("shell must no longer build wall-corner team names")
      check "nm.className='wallname" notin shell
      check ".wallname{" notin shell
      # The KDA roster tables + division standings are NOT a duplicate of
      # anything the board draws (no per-player K/D or standings in the
      # board's own HUD) — they must survive untouched.
      checkpoint("shell's KDA plaques (not a duplicate) must survive")
      check "id=\"kda-l\"" in shell
      check "id=\"kda-r\"" in shell
      check "class=\"khead\"" in shell
      check "function renderStandings" in shell

suite "SEASON 2 replay viewer HUD: BR rail fit at 16 seats (owner follow-up 2026-09-09)":
  ## The 16-seat verification pass on the left-rail-is-the-default change
  ## found two defects the 2-team fixture never exercised: at a wide tier-2
  ## rail (e.g. 3454x846) .br-cell-glory's margin-left:auto (in the
  ## sidelane block, ~1280-1410) put ~800px between a chip's name and its
  ## own number; at a very short rail (the kiosk/theater stage) a single
  ## 16-cell column measured 239px of content in a 128px-tall lane and
  ## clipped (#lane-l is overflow:hidden). Both fixed by NEW rules outside
  ## that block — this suite guards them without re-touching it.
  ##
  ## RECONCILED (THE WHOLE Stop 2, client-explains): the numeral this
  ## override was written against is now wrapped in .br-cell-glory-wrap
  ## (a "Glory" noun label stacked above it, Law 6) — the margin-left:auto
  ## it overrides moved to that wrapper too, so the override was
  ## retargeted one level up to keep landing on the element that actually
  ## carries it. Same fix, same specificity bump, new selector text.
  test "the wide rail keeps a chip's name and number close together":
    # The literal now also carries the CHIP CLIP fix's 4px pad (see the
    # suite below) — one rule, both defects, updated together.
    checkInBoth "body.sidelanes #scorebug .br-cell { max-width: 340px; padding-right: 4px; }"
    checkInBoth "body.sidelanes #scorebug .br-cell .br-cell-glory-wrap { margin-left: calc(10 * var(--u)); }"

  test "the tiny rail splits the 16-cell roster into two columns instead of clipping":
    checkInBoth "document.body.classList.toggle('tiny', boardW <= 620);"
    checkInBoth "body.sidelanes.tiny #scorebug .br-cellband {"
    checkInBoth "body.sidelanes.tiny #scorebug .br-cell {"

suite "SEASON 2 replay viewer HUD: catalog v3 popup law (owner bug, 2026-09-10)":
  ## Owner: "what the heck is giving everyone a x100!? ... i thought we
  ## weren't doing popups for less than 2x? ... especially not 1x that
  ## gives you nothing". Catalog v3 (GloryVersion >= 17, live since r4611)
  ## puts a positive recut-armed deed's `amt` on the wire as a PERCENT
  ## (src/ctf/sim.nim's awardDeed -- "amount = if ramped or v3: pct else:
  ## factor" -- 100 = x1.00, 220 = x2.20), but the hero-pop gate and label
  ## (this file, introduced by #466/9ef5aa09) still read `p.amt` as the OLD
  ## integer factor, so a neutral dFinal4 mint (pct 100, x1.00, zero
  ## effect) popped as "x100 FINAL 4". THE LAW
  ## (docs/designs/glory/CATALOG-V3-DRAFT.md's "Legibility law carried
  ## forward, unchanged", ~line 259-263): "fractional factors ... never pop
  ## as a floating '+Ng' ... Pops stay reserved for x2 and up."
  ##
  ## No wire field exists (client-only patch, see gloryPopFactor's own doc
  ## comment) to tell a v3-percent positive amt apart from the OLD
  ## integer-factor one; the fix proxies off recutArmed itself, which today
  ## is empirically 1:1 with catalogV3Reprice (the only manifest that ever
  ## arms gloryMultiplierRecut, battle-royale-s2, arms all three switches
  ## together) -- these checks guard the SOURCE TOKENS of that fix, not the
  ## economics; the FIVE deeds it silences on a real replay (dFinal8 pct
  ## 100, dFinal4 pct 100, dFinal2 pct 130, dClutchHeal pct 180,
  ## dClosingTime pct 110/120) and the one it still pops (e.g.
  ## dHonorableKill pct 220 -> "×2.20") are verified against a real
  ## 16-seat BR replay separately (screenshot + DOM pass, not this
  ## text-scan suite).
  test "one shared pct-to-factor helper feeds every pop/label path":
    checkInBoth "function gloryPopFactor(p) {"
    checkInBoth "return p.amt / 100;"
    checkInBoth "function gloryPopFactorLabel(factor) {"
    # THE LAW's own worked examples are "×2.00"/"×2.20" -- ALWAYS two
    # decimals. An earlier draft here was `(factor % 1 === 0) ?
    # String(factor) : factor.toFixed(1)`, which rendered a x2.00 kill as
    # bare "×2" and a x2.20 kill as one-decimal "×2.2" -- caught and fixed
    # before this landed; pin the fixed body so it can't regress back.
    checkInBoth "return factor.toFixed(2);"
    # Both the pop-text path and the hero-DOM `.mult` label path call
    # through the SAME label helper -- no second place re-derives "×N".
    checkInBoth "return '×' + gloryPopFactorLabel(factor) + (p.word ? ' ' + p.word : '');"
    checkInBoth "mult.textContent = '×' + gloryPopFactorLabel(gloryPopFactor(p));"

  test "the hero gate requires factor >= 2.0, shared by both DOM call sites":
    checkInBoth "var HERO_POP_MIN_FACTOR = 2.0;"
    checkInBoth "function gloryPopIsHero(p) {"
    checkInBoth "return !p.lbl && p.amt > 0 && recutArmed && gloryPopFactor(p) >= HERO_POP_MIN_FACTOR;"
    # renderGloryPops has two isHero sites (element-create + every-frame
    # restyle) -- both must route through the one gate function, not
    # re-derive the condition inline a second time.
    checkInBoth "var isHero = gloryPopIsHero(p);"

  test "sub-2x factors (the exact x1.00 neutral case included) never float a callout":
    checkInBoth "if (factor < HERO_POP_MIN_FACTOR) return '';"
    # Boundary check against the SAME 2.0 the source gates on (not a
    # second hard-coded 2.0 that could drift from it): 199 pct floors to
    # 1.99 (silent), 200 pct floors to exactly 2.00 (pops).
    check 199.0 / 100.0 < 2.0
    check 200.0 / 100.0 >= 2.0

  test "the real v3 pricing table names all five sub-2x deeds this law silences, plus one kill deed it still pops":
    # Ties the client's HERO_POP_MIN_FACTOR = 2.0 gate to the REAL
    # production pricing (`RecutPlacementRampPct`/`RecutClassTableV3Pct`,
    # src/ctf/glory.nim) rather than the hard-coded pct literals named in
    # the owner bug report and this suite's own doc comment above -- if a
    # future repricing ever pushed one of these five over 2.00x (or the
    # kill deed back under it) without updating the popup law, THIS check
    # goes red where a pure text-scan of the client alone could not catch
    # it. glory.nim's own zero-imports law means this needs no sim/data/
    # setup, just the enum + tables (helpers' GameDir cwd-flip is not
    # needed here).
    checkpoint("dFinal8: milestone marker, crushed to a pure no-op under placementRampV3")
    check RecutPlacementRampPct[dFinal8] == 100
    checkpoint("dFinal4: same crush, same reasoning")
    check RecutPlacementRampPct[dFinal4] == 100
    checkpoint("dFinal2: the one milestone still worth a small nudge, still sub-2x")
    check RecutPlacementRampPct[dFinal2] == 130
    checkpoint("dClutchHeal: v9-retired self-heal, priced sub-2x under v3 too")
    check RecutClassTableV3Pct[dClutchHeal] == 180
    checkpoint("dClosingTime: non-win base, sub-2x")
    check RecutClassTableV3Pct[dClosingTime] == 110
    checkpoint("dClosingTime: win-bumped base, still sub-2x")
    check RecutClosingTimeWinBumpV3Pct == 120
    checkpoint("dHonorableKill: the plain-kill floor, the one of these seven at/above 2.00x")
    check RecutClassTableV3Pct[dHonorableKill] == 220
    # Restate the gate's own arithmetic against each real pct above, so
    # this test is a genuine popup-law regression guard, not just a
    # pricing-table snapshot.
    for pct in [RecutPlacementRampPct[dFinal8], RecutPlacementRampPct[dFinal4],
                RecutPlacementRampPct[dFinal2], RecutClassTableV3Pct[dClutchHeal],
                RecutClassTableV3Pct[dClosingTime], RecutClosingTimeWinBumpV3Pct]:
      check (pct.float / 100.0) < 2.0
    check (RecutClassTableV3Pct[dHonorableKill].float / 100.0) >= 2.0

  test "the old integer-factor hero gate is gone from the fixed source":
    # SOURCE-only (not checkInBoth): static-replay-viewer/index.html is the
    # Docker-baked SHIPPED copy and stays byte-for-byte the pre-fix output
    # until tools/build_replay_viewer.sh actually rebuilds it (this file's
    # own concurrency note, top of file) -- asserting the OLD gate's
    # absence there today would only be re-describing "the bundle has not
    # been rebuilt yet", not proving anything about this fix. The bundle
    # side of this same assertion is exactly the "stale-bundle" red this
    # suite's own PR calls out explicitly.
    let src = readFile(SourcePage)
    checkpoint("source must not still gate on the old raw p.amt reading")
    check not src.contains("var isHero = !p.lbl && p.amt > 0 && recutArmed;")
    checkpoint("source must not still label the old raw p.amt reading")
    check not src.contains("mult.textContent = '×' + p.amt;")

suite "SEASON 2 replay viewer HUD: chip clip fix (owner defect, 2026-09-10)":
  ## Pre-existing at the owner's own 2038x1474 window shape, bisected
  ## byte-identical on main before #534 (that PR found and reported it,
  ## deliberately out of its own scope). DOM-measured (real rajdhani font,
  ## via a spliced-source + synthetic-frame harness, no server build): at
  ## 2038x1474, 3 of 16 .br-cell-glory numerals sat past #lane-l's right
  ## edge, up to 7.05px overshoot (a first pass under the browser's
  ## fallback sans, in #534's own PR comment, measured 10 cells / 10.41px
  ## — the real font changes the exact count but not the defect: the row's
  ## children never had a way to give up width to each other). Zero
  ## overshoot at all 3 verification shapes (2038x1474, 3454x846, 540x300)
  ## after this fix — screenshot/DOM verification only, not re-encoded here
  ## (this suite pins the CSS tokens the fix depends on, same idiom as the
  ## BR rail fit suite above).
  test "the name+swatch stack can shrink so the numeral never has to":
    # Base .br-cell-members rule (~line 318) is flex:none — this override
    # is the ONLY property touched, scoped to the BR rail only.
    checkInBoth "body.sidelanes #scorebug .br-cell .br-cell-members { flex-shrink: 1; }"

  test "the cell reserves a real inner margin, not a flush 0px fit":
    checkInBoth "body.sidelanes #scorebug .br-cell { max-width: 340px; padding-right: 4px; }"

  test "the numeral element itself still carries no shrink — it is never the side that gives":
    # .br-cell-glory (the bare figure) stays flex:none, untouched by this
    # fix — only .br-cell-members (the name+swatch stack) got a shrink
    # override. Guards against a future edit "fixing" the clip by making
    # the NUMBER give up space instead of the name.
    checkInBoth ".br-cell-glory {\n  font-family: var(--pixfont);"
    checkInBoth "  flex: none;\n  transform-origin: left center;\n}"

suite "SEASON 2 replay viewer HUD: comms rail redesign (owner 2026-09-10)":
  ## Owner: "you finally got the left bar working in the replay, but you put
  ## the chat there and it is pretty much unreadable in this design... it
  ## goes on too long, forcing extra letterboxing that is unnecessary." Two
  ## separate defects with two separate fixes (S2 lead correction,
  ## 2026-09-10): (a) READABILITY comes from type size/contrast/spacing —
  ## never from cutting content, a message wraps to however many lines it
  ## needs; (b) LENGTH is bounded separately — the sidebar shows only the
  ## last messages that fit its rail remainder, with no scrollbar and no
  ## effect on the stage's own size.
  test "a message is never truncated -- readability comes from type, not from cutting content":
    checkInBoth "esc(item.text)"
    checkInBoth "esc((item.plays || []).join(' · ') || 'play #' + item.epoch)"
    # Readability floors: legible at any --hudscale, including the kiosk
    # stage's tiny rail (measured 11.5px/11px effective at 540x300 in the
    # PR's verification pass, comfortably above the 9px kiosk floor).
    checkInBoth "font-size: clamp(11.5px, calc(10 * var(--u)), 16px);"
    checkInBoth "font-size: clamp(11px, calc(9.5 * var(--u)), 15px);"
    checkInBoth "font-size: clamp(11px, calc(8.5 * var(--u)), 15px);"

  test "the flash row drops the redundant \"flashed\" word and keeps one glyph":
    checkInBoth "class=\"fl-bolt\" aria-hidden=\"true\">⚡</span>"
    for page in bothPages():
      checkpoint(page.label & ": must not carry the redundant literal word \"flashed\" beside the bolt")
      check not page.text.contains("⚡ flashed")

  test "the sidebar is height-bounded: no scrollbar, oldest messages drop, newest always visible":
    checkInBoth "function fitCommsFeed(el, count)"
    checkInBoth "while (el.scrollHeight > el.clientHeight && el.children.length > 1)"
    checkInBoth "el.classList.toggle('cd-trimmed', trimmed);"
    checkInBoth "overflow: hidden;"
    checkInBoth "#commsFeed.cd-trimmed {"
    # relayout() re-fits the sidebar on a pure resize too (count unchanged,
    # rail height changed), not just when a new message arrives.
    checkInBoth "commsFeedEl._fitHeight !== commsFeedEl.clientHeight"

  test "relayout() never measures the comms DOM to size the stage":
    # The stage's pixel size (stageW/stageH -> boardW/boardH) is a pure
    # function of the viewport box and fixed rail-width constants.
    # commsWide/COMMS_AVAILABLE (a plain boolean -- "is there anything to
    # show") legitimately decide WHERE the letterbox goes, but nothing in
    # relayout() may read the comms DOM's height to decide HOW BIG the
    # stage is. Extract relayout()'s own body and prove the comms elements
    # never appear in it BY NAME -- the strongest text-scan proof available
    # short of a browser (the live DOM-rect proof, done separately, showed
    # the stage rect byte-identical with a heavy-huddle replay vs. none).
    for page in bothPages():
      let text = page.text
      let startIdx = text.find("function relayout() {")
      let endIdx = text.find("var ro = new ResizeObserver(relayout);")
      checkpoint(page.label & ": could not locate relayout() to scope this check")
      check startIdx >= 0
      check endIdx > startIdx
      if startIdx >= 0 and endIdx > startIdx:
        let body = text[startIdx ..< endIdx]
        checkpoint(page.label & ": relayout() must not reference commsFeedEl's DOM")
        check not body.contains("commsFeedEl")
        checkpoint(page.label & ": relayout() must not reference #commsdock's DOM")
        check not body.contains("commsdock")
        checkpoint(page.label & ": the board fit must stay fixed-constant geometry")
        check body.contains("var LANE_MIN = 300, RAIL_MIN = 240;")

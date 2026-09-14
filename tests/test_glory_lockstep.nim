## GLORY v12 (contract §7): the replay CROSS-VALIDATION gate — the
## version-sync check extended to TIMING. An offline scorer that re-derives
## claims from the wire (tools/ladder/gloryscore.py) must reproduce not just
## WHICH tiers minted but WHEN, which requires pinning the engine's exact
## evaluation schedule:
##
##   1. THE PER-STEP SWEEP — `evalAchievementsAllTeams` (sim.nim), called at
##      the top of `step` before any of the tick's game logic, so tick T's
##      sweep judges the state as of the END of tick T-1. Playing-gated.
##   2. THE CONCLUSION SWEEP — `evalAchievementsAtConclusion` (sim.nim),
##      called once from `finishGame` as part of the game-over transition,
##      so it judges the exact ending state INCLUDING the facts of the act
##      that ended the game, and stamps claims with the ending tick. Runs on
##      every conclusion (draws included), never on an abort.
##
## This suite replays the capture-ending fixture through the engine itself
## (hash-validated every step — `extractEvents` raises on any recorded-hash
## mismatch) and asserts the full glory ledger — every achievement claim
## (tick, team, tree, tier, first-flag, glory) AND every deed mint (tick,
## team, deed, earner, glory; v12 fold) — against a committed golden. A scorer change that
## drifts from the schedule fails against the same golden; an engine change
## that moves the schedule fails HERE first, in the shard, before the scorer
## ever sees it.
##
## Re-record ritual (a GameVersion bump invalidates the fixture AND this
## golden): tools/record_all_fixtures.sh does BOTH — it re-records the
## fixtures and then regenerates this golden from the fresh recording (its
## "derived goldens" step runs
##   nim c -r -d:recordGloryGolden tests/test_glory_lockstep.nim
## after capture-seed1 is re-cut). Commit fixture and golden together. The
## golden is DERIVED from the fixture by the engine's own walk, so
## recording it is deterministic given the fixture bytes.

import
  helpers,
  std/[json, os, strutils, unittest],
  ctf/[glory, replays, sim],
  "../tools/extract_events"

const
  FixturePath = GameDir / "tests" / "fixtures" / "capture-seed1.bitreplay"
  GoldenPath = GameDir / "tests" / "fixtures" / "capture-seed1.claims.json"

proc claimRows(extraction: ExtractResult): JsonNode =
  ## The FULL glory ledger as the wire shows it, in emission order: one row
  ## per Achievement event (`claimAchievement` repurposes the generic slots:
  ## target = team ordinal, weapon = $tree, hp = tier, blocked = first-claim
  ## flag, amount = glory paid — see test_extract_events) AND one row per
  ## GloryDeed event (v12 FOLD: `awardDeed` emits weapon = $deed, source =
  ## the credited earner, target = team ordinal, amount = minted glory).
  ## Deed rows joined the golden with the alliance-vocab fold — a mint the
  ## golden cannot see is dark, and dAssist/dRescue mint at kill sites the
  ## achievement rows never witness.
  result = newJArray()
  for event in extraction.events:
    if event.kind == Achievement:
      result.add(%*{
        "kind": "claim",
        "tick": event.tick,
        "team": event.target,
        "tree": event.weapon,
        "tier": event.hp,
        "first": event.blocked,
        "glory": event.amount
      })
    elif event.kind == GloryDeed:
      result.add(%*{
        "kind": "deed",
        "tick": event.tick,
        "team": event.target,
        "deed": event.weapon,
        "by": event.source,
        "glory": event.amount
      })

suite "glory schedule lockstep (contract §7)":

  test "the claim ledger matches the golden, tick for tick":
    let extraction = extractEvents(loadReplay(FixturePath))
    check extraction.finished
    let claims = claimRows(extraction)
    when defined(recordGloryGolden):
      writeFile(GoldenPath, pretty(claims) & "\n")
      echo "recorded golden: ", GoldenPath, " (", claims.len, " claims)"
    check fileExists(GoldenPath)
    let golden = parseJson(readFile(GoldenPath))
    check claims.len > 0
    check claims == golden

  test "the conclusion sweep is ON the schedule: Delivered stamps the ending tick":
    ## The structural property no golden refresh may lose: this fixture ENDS
    ## on a capture (its reason to exist), and a 2-team ending capture's
    ## Delivered can only come from the conclusion sweep — so the claim must
    ## exist and must carry the exact tick the phase flipped to gameover.
    let extraction = extractEvents(loadReplay(FixturePath))
    var gameOverTick = -1
    for event in extraction.events:
      if event.kind == PhaseChange and event.weapon == "gameover":
        gameOverTick = event.tick
    check gameOverTick >= 0
    var deliveredTick = -1
    for event in extraction.events:
      if event.kind == Achievement and event.weapon == $treeCarrier and
         event.hp == AchievementTiers - 1:
        deliveredTick = event.tick
    check deliveredTick == gameOverTick

  test "the fold's deeds are ON the golden: dAssist and dRescue mint for real":
    ## The alliance-vocab fold (Amendment 3 Option C) is covered by this
    ## suite only if the fixture episode actually EXERCISES the two new kill
    ## site mints -- and the current recording does (3 dAssist, 1 dRescue at
    ## the v12 fold's recording). If a future re-record rolls an episode
    ## with zero of either, that recording does not cover the fold: re-roll
    ## it (see record_all_fixtures.sh), do not relax this check silently.
    let golden = parseJson(readFile(GoldenPath))
    var assistRows, rescueRows = 0
    for row in golden:
      if row{"kind"}.getStr == "deed":
        if row{"deed"}.getStr == "dAssist": inc assistRows
        elif row{"deed"}.getStr == "dRescue": inc rescueRows
    check assistRows >= 1
    check rescueRows >= 1

suite "S6 attribution instrument (gloryS6AttrInstrument) is hash-neutral":
  ## `awardDeed` (sim.nim, `when defined(gloryS6AttrInstrument):` around its
  ## tier-2 GloryDeed emit) is a compile-time define, OFF by default: the
  ## OFF branch is the byte-for-byte pre-existing `emitEvent(...)` call
  ## (no `content` argument at all), and every native/wasm shard in CI
  ## compiles that OFF branch. The ON branch's ONLY difference is that it
  ## also passes `content = mintNote`, a "classPct|heatPct|carryPct|stackPct"
  ## string built from the SAME sub-factor helpers `recutFactor` itself
  ## folds (glory.nim: recutShiftedClass, heatMult, CarrierHoldMultPct,
  ## recutStackMult) -- see that call site's own comment, "Analysis-only
  ## (never gameHash)".
  ##
  ## `gameHash` (sim_state.nim, `proc gameHash*` starting at line 298) never
  ## reads `sim.events` or any event's `.content` anywhere in its ~270-line
  ## body (confirmed by grep, zero hits) -- so no value that field can ever
  ## hold moves the hash, on principle. This test makes that concrete
  ## against a REAL recorded fixture rather than trusting the grep alone: it
  ## replays glory-product-cap.bitreplay (S2 round 4828 -- the exact
  ## gloryMultiplierRecut=true/deedMintCaps=true/brMode=true recut shape the
  ## instrument's own guard condition targets) with the tier-2 sink on,
  ## stuffs a real classPct|heatPct|carryPct|stackPct note -- built with the
  ## identical glory.nim helpers the define calls -- into every drained
  ## GloryDeed event's `content` (exactly the field the ON branch writes,
  ## and the ONLY field the two branches ever disagree on), and checks
  ## `gameHash` before and after. Equal hash on a real fixture full of real
  ## recut mints is the ON-vs-OFF neutrality proof: OFF ships no `content`
  ## at all (an empty string, strictly less information than this test's
  ## stuffed note), so if a non-empty, realistically-shaped note cannot move
  ## the hash, neither can OFF's stricter subset.
  test "stuffing a real classPct|heatPct|carryPct|stackPct note into every GloryDeed event's content leaves gameHash unchanged":
    let fixturePath = GameDir / "tests" / "fixtures" / "glory-product-cap.bitreplay"
    let data = loadReplay(fixturePath)
    var config = defaultGameConfig()
    config.update(data.configJson)
    check config.gloryMultiplierRecut  # the shape the instrument's guard reads
    var sim = initSimServer(config)
    sim.gameEventLoggingEnabled = false
    sim.collectEvents = true
    var replay = initReplayPlayer(data)
    replay.looping = false
    replay.mismatchQuit = true
    while replay.playing:
      replay.stepReplay(sim)
    let hashBefore = sim.gameHash()

    var gloryDeedCount, recutNoteCount = 0
    for i in 0 ..< sim.events.len:
      if sim.events[i].kind != GloryDeed:
        continue
      inc gloryDeedCount
      # Not every GloryDeed event's `weapon` is a `Deed` name -- `capHit`,
      # `achModeLit`, `pactWipe`/`pactDuoDown` (sim.nim) are pre-existing
      # literal-string GloryDeed mints outside `awardDeed`, and the last two
      # ALREADY carry non-empty `content` today ("GLORY_PACT_WIPE" etc) --
      # this fixture's own hash-validated recording already proves gameHash
      # tolerates non-empty content in production, before this instrument
      # exists. Where `weapon` IS a real deed, reconstruct the ON branch's
      # exact note with the identical helpers (team 0's live post-replay
      # heat state; the drained event cannot recover the ORIGINAL minting
      # team -- `target` is remapped through `eventSlot`, the same
      # pre-existing quirk this file's port-header note documents -- but
      # that has no bearing on hash-neutrality, which this note's CONTENT
      # never touches).
      try:
        let deed = parseEnum[Deed](sim.events[i].weapon)
        let team = Team(0)
        let sitePct = sim.deedSitePct(team, int(sim.events[i].x), int(sim.events[i].y))
        let classPct = recutShiftedClass(deed, sitePct, sim.config.winAsMultiplier)
        let heatPct = (if paysHeat(deed): heatMult(sim.heatEmbers[team]) else: 100)
        let carryPct = (if isDrama(deed): CarrierHoldMultPct else: 100)
        let stackPct = recutStackMult(3)
        sim.events[i].content =
          $classPct & "|" & $heatPct & "|" & $carryPct & "|" & $stackPct
        inc recutNoteCount
      except ValueError:
        sim.events[i].content = "GLORY_S6_ATTR_INSTRUMENT_TEST_PLACEHOLDER"
    check gloryDeedCount > 0
    check recutNoteCount > 0
    check sim.gameHash() == hashBefore

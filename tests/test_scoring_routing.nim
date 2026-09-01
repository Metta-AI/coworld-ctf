## Regression coverage for roster.nim's playerResultsJson scoring-schema
## switch (the "every live round scores 0.5/0.5" incident).
##
## The manifest unification on Aug 6 (c8fa5558, "Unify CTF into the Paintbot
## Coworld") set `num_agents` on every now-archived classic variant (2v2,
## 4ffa, 4ffa8, 1v1, ctf-default, ctf-1v1) for an unrelated squad/seat-broadcast
## reason. The Aug 25 Paintball KOTH commit (b25ee1444) then keyed the
## scoring-schema switch on that same `numAgents` field, assuming it meant
## "paintball is on". It didn't -- it meant "this game has seats" -- so
## every classic match silently misrouted into squadResultsJson, the
## hill-only paintball scorer. Its halves never populate without hill=true
## or a played gameHill entry, so every seat fell through to the literal
## 500/500 fault tie, discarding real kills and captures.
##
## The fix keys the switch on `loadout` instead, which is the only field
## that actually means "paintball vs classic". These tests are the direct
## discriminator: reverting roster.nim's `sim.config.loadout ==
## LoadoutPaintball` back to `sim.config.numAgents > 0` fails the first two
## tests below for the right reason (a 500/500 tie with no `kills` key /
## the wrong schema entirely), while paintball scoring is provably
## untouched either way.
##
## The first test's `scores` assertions were updated for the glory-as-
## league-score pass: the CTF path's `scores` field now carries banked
## glory (winner = its team's ledger total, loser = 0), not the old
## WinReward/LossReward RL figures -- see test_glory_league_score.nim for
## the dedicated winner/loser/draw/abort/zero-glory coverage and the
## paintball-untouched MD5 proof.

import
  std/[json, os, unittest],
  helpers, pb_helpers

proc paintbotSchemaDefaults(): JsonNode =
  let props = parseFile(GameDir / "coworld_manifest_paintbot.json")[
    "game"]["config_schema"]["properties"]
  result = newJObject()
  for key, prop in props:
    if prop.hasKey("default"):
      result[key] = prop["default"]

proc effectivePaintbotVariantConfig(variantId: string): JsonNode =
  ## Classic variants live in the deprecated-variants archive since the
  ## season-2 slim; the published manifest carries only battle-royale-s2.
  ## Search both so this anchor keeps proving the platform's
  ## defaults-then-overlay materialization for whichever file holds the id.
  result = paintbotSchemaDefaults()
  for path in ["coworld_manifest_paintbot.json", "deprecated_variants_paintbot.json"]:
    for variant in parseFile(GameDir / path)["variants"]:
      if variant["id"].getStr() == variantId:
        for key, value in variant["game_config"]:
          result[key] = value
        return
  doAssert false, "missing paintbot variant " & variantId

suite "scoring schema routing":
  test "squad mode requires an explicit multi-cog config":
    var classic16 = defaultGameConfig()
    classic16.numAgents = 16
    check classic16.cogsPerTeam == 1
    check not classic16.squadModeConfigured()

    var classic32 = defaultGameConfig()
    classic32.numAgents = 32
    check classic32.cogsPerTeam == 1
    check not classic32.squadModeConfigured()

    var paintball = defaultGameConfig()
    paintball.update(paintballConfigJson())
    check paintball.numAgents == 2
    check paintball.cogsPerTeam == 4
    check paintball.squadModeConfigured()

    # Landed-manifest anchor: the platform materializes config_schema
    # defaults before overlaying a variant's game_config.
    var manifestClassic = defaultGameConfig()
    manifestClassic.update($effectivePaintbotVariantConfig("2v2"))
    check manifestClassic.numAgents == 16
    check manifestClassic.cogsPerTeam == 1
    check not manifestClassic.squadModeConfigured()

    var manifestBr = defaultGameConfig()
    manifestBr.update($effectivePaintbotVariantConfig("battle-royale"))
    check manifestBr.numAgents == 32
    check manifestBr.cogsPerTeam == 1
    check not manifestBr.squadModeConfigured()

  test "a classic match keeps num_agents > 0 (the manifest collision) and still scores through the CTF path":
    ## Reproduces the live collision directly: num_agents set the way every
    ## flagship classic variant sets it (16 seats), loadout left at its
    ## LoadoutCtf default, hill left false -- exactly round #3450's replay
    ## config (num_agents=16, loadout="ctf", hill=false).
    var sim = twoTeamGame()
    sim.config.numAgents = 16
    check sim.config.loadout == LoadoutCtf
    check not sim.config.hill
    check sim.totalCogs() == 16

    # A real kill through the real credit path, then a real decisive finish
    # -- not a fabricated results field.
    sim.recordKillCredit(0, 1)
    # A real glory mint (not a fabricated results field either) so `scores`
    # has something nonzero from the ledger to report.
    sim.awardDeed(Red, dHonorableKill, 10, 10)
    sim.finishGame(Red)
    # Read the ledger AFTER finishGame: finishGame's own conclusion sweep
    # (v12, evalAchievementsAtConclusion -- Clean Sheet, Delivered, any
    # terminal-tick fact) can still add to it, so the total the results doc
    # must report is whatever the ledger holds once the match has fully
    # wrapped up, not a snapshot mid-way.
    let redGlory = sim.teamGlory[Red]
    check redGlory > 0  # sanity: this scenario actually minted something.

    let results = parseJson(sim.playerResultsJson())
    # The CTF schema, not the squad/hill schema: presence of `kills`
    # (CTF-only) and absence of `hillTicks` (squad-only) is itself proof of
    # which proc answered the call.
    check results.hasKey("kills")
    check not results.hasKey("hillTicks")
    check results["kills"][0].getInt() == 1
    check results["win"][0].getBool()
    check not results["win"][1].getBool()
    # `scores` is now the GLORY-AS-LEAGUE-SCORE field (see roster.nim's
    # ctfPlayerResultsJson doc comment): the winner banks its team's exact
    # ledger total, the loser banks exactly 0 -- not the old WinReward/
    # LossReward RL-training figures.
    check results["scores"][0].getInt() != results["scores"][1].getInt()
    check results["scores"][0].getInt() == redGlory
    check results["scores"][1].getInt() == 0
    # The RL training reward signal itself is UNTOUCHED: it never lived in
    # this results document (a separate, real-time `buildRewardPacket`
    # websocket message reads `player.reward`), so repurposing `scores` here
    # cannot have perturbed it.
    check sim.players[0].reward == WinReward
    check sim.players[1].reward == LossReward

  test "a full 16-seat classic config fields one cog per seat and reports decisive per-seat results":
    var sim = initCtfForTest(defaultGameConfig())
    sim.config.numAgents = 16
    check sim.config.cogsPerTeam == 1
    check sim.totalCogs() == 16
    for i in 0 ..< 16:
      discard sim.addPlayer("policy" & $i, i, "", trusted = true)
    sim.startGame()
    check sim.players.len == 16

    sim.recordKillCredit(0, 1)
    sim.awardDeed(Red, dHonorableKill, 10, 10)
    sim.finishGame(Red)

    let results = parseJson(sim.playerResultsJson())
    check results.hasKey("kills")
    check not results.hasKey("hillTicks")
    check results["scores"].len == 16
    check results["names"].len == 16
    check results["kills"].len == 16
    check results["kills"][0].getInt() == 1
    check results["win"][0].getBool()
    check not results["win"][1].getBool()
    check results["scores"][0].getInt() > 0
    check results["scores"][1].getInt() == 0

  test "a paintball config with num_agents == 0 still routes on loadout, not the seat count":
    ## The discriminating edge in the OTHER direction: a hypothetical
    ## paintball config that never sets num_agents (or sets it to 0) must
    ## still take the squad/hill path, because loadout -- never numAgents --
    ## is what means "paintball vs classic". Under the pre-fix
    ## `numAgents > 0` switch this misrouted into ctfPlayerResultsJson (whose
    ## slot count comes from the two real joined players, not from
    ## numAgents, so it would have reported 2 slots with a `kills` key
    ## instead of 1 seat with a `hillTicks` key).
    ##
    ## squadResultsJson itself still derives its seat COUNT from
    ## `max(1, numAgents)` -- unrelated to this fix, and unchanged by it --
    ## so numAgents=0 collapses it to exactly one seat. That seat count is
    ## itself the proof of which proc answered: 1 seat only exists on the
    ## squad path.
    var sim = newPaintballSim()
    sim.config.numAgents = 0
    sim.hillTicks[Red] = 900
    sim.hillTicks[Blue] = 0
    let results = parseJson(sim.playerResultsJson())
    check results.hasKey("hillTicks")
    check not results.hasKey("kills")
    check results["scores"].len == 1
    check results["scores"][0].getFloat() > 0.5

  test "a genuine paintball match still scores through the squad/hill path, unchanged":
    ## newPaintballSim's config is exactly the deprecated paintball config
    ## shape: loadout="paintball", hill=true, num_agents=2. This must stay on
    ## squadResultsJson exactly as it did before the fix -- this is a pure
    ## routing change, not a scoring change.
    var sim = newPaintballSim()
    check sim.config.loadout == LoadoutPaintball
    sim.hillTicks[Red] = 900
    sim.hillTicks[Blue] = 0
    let results = parseJson(sim.playerResultsJson())
    check results.hasKey("hillTicks")
    check not results.hasKey("kills")
    check results["scores"][0].getFloat() > 0.5
    check results["scores"][1].getFloat() < 0.5

suite "results seat arity (the coworld hosted-certification regression)":
  ## #327 fixed the SCORING (real kills/captures instead of a 500/500 tie)
  ## but exposed a pre-existing arity bug in the classic path it now routes to:
  ## `ctfPlayerResultsJson` reported one row per joined SLOT (== per cog),
  ## which equals `numAgents` only when every seat fields exactly one cog.
  ## Historically, `cogsPerTeam` defaulted to 4, so classic variants with
  ## `numAgents > 0` accidentally entered server.nim's squad mode and
  ## auto-filled trusted cogs past the real seats toward `sim.totalCogs()`,
  ## capped by `MaxPlayers` (32) rather than by the seat count. A 16-seat
  ## classic match's accidental squad-fill therefore silently parked 32 total
  ## cogs in `sim.players`, and the pre-fix proc reported 32 rows: hosted
  ## certification rejected it outright --
  ## `error=game returned 32 scores for 16 seats`
  ## (cow_c546b854-2f58-4499-9c51-bed924333a51, run 33443353700).
  ##
  ## The fix folds every extra cog's stats onto its OWNING seat
  ## (`cogSeat`'s own rule, sim.nim: `joinOrder mod numAgents` -- seat k's
  ## squadmates are cogs k, k+numAgents, k+2*numAgents, ... -- this
  ## project's own "k, k+16" duo-seat spacing, not adjacent indices)
  ## instead of emitting a separate row. Reverting the fold (restore the
  ## old one-row-per-slot loop) fails both tests below for the right
  ## reason: `scores.len` back at the raw joined-cog count (32 / 8) instead
  ## of the seat count (16 / 4).
  test "explicit squad shape: 16 seats squad-filled to 32 cogs folds back to 16 scores":
    var sim = initCtfForTest(defaultGameConfig())
    sim.config.numAgents = 16
    sim.config.cogsPerTeam = 2
    check sim.config.loadout == LoadoutCtf
    for i in 0 ..< 16:
      discard sim.addPlayer("policy" & $i, i, "", trusted = true)
    sim.startGame()
    # A real kill by seat 0's own (primary) cog.
    sim.recordKillCredit(0, 1)
    # Squad-fill exactly the way server.nim's squadMode does: cogs 16..31
    # join at their own joinOrder. Cog 16 lands on SEAT 0 (`cogSeat` =
    # joinOrder mod numAgents = 16 mod 16 = 0) as its squadmate.
    for i in 16 ..< 32:
      discard sim.addPlayer("squad-alias-" & $i, i, "", trusted = true)
    let squadmateIndex = sim.playerIndexForSlot(16)
    check squadmateIndex >= 0
    # A real kill by seat 0's SQUADMATE too -- must fold onto seat 0's row,
    # not spawn a 17th.
    sim.recordKillCredit(squadmateIndex, 1)
    sim.finishGame(Red)

    let results = parseJson(sim.playerResultsJson())
    check results["scores"].len == 16
    check results["names"].len == 16
    check results["kills"].len == 16
    # Both the primary cog's kill AND its squadmate's kill land on seat 0.
    check results["kills"][0].getInt() == 2
    check results["win"][0].getBool()

  test "a differently-sized agents-vs-seats shape (4 seats, 2 cogs each) folds the same way":
    ## Not a special case pinned to 16/32: the same `joinOrder mod
    ## numAgents` fold at a different seat count.
    var sim = initCtfForTest(defaultGameConfig())
    sim.config.numAgents = 4
    sim.config.cogsPerTeam = 2
    for i in 0 ..< 4:
      discard sim.addPlayer("policy" & $i, i, "", trusted = true)
    sim.startGame()
    for i in 4 ..< 8:
      discard sim.addPlayer("squad-alias-" & $i, i, "", trusted = true)
    # Seat 1's squadmate is cog 5 (1 + numAgents).
    let squadmateIndex = sim.playerIndexForSlot(5)
    check squadmateIndex >= 0
    # cog 5 is Blue (odd slot); cog 0 is Red -- an enemy kill.
    sim.recordKillCredit(squadmateIndex, 0)
    sim.finishGame(Blue)

    let results = parseJson(sim.playerResultsJson())
    check results["scores"].len == 4
    check results["kills"][1].getInt() == 1

  test "BR shape: 32 seats with one cog each is already correct arity (the fold is a no-op)":
    ## The other real production shape sharing this code path (PR #331, the
    ## BR variant): `num_agents=32`, `cogsPerTeam` left at its restored
    ## classic default, so BR seats exactly 32 REAL players -- one cog per
    ## seat, no squad multiplier and no auto-fill. This is NOT the historical
    ## certification bug shape (`namesArr.len == seatCount`, so the fold/pad
    ## block above is a no-op) -- 32 scores for 32 seats is the CORRECT answer
    ## here, a different shape from the 16-seat classic config that broke
    ## certification, and must stay 32, not collapse further.
    var sim = initCtfForTest(defaultGameConfig())
    sim.config.numAgents = 32
    for i in 0 ..< 32:
      discard sim.addPlayer("policy" & $i, i, "", trusted = true)
    sim.startGame()
    check sim.players.len == 32
    sim.recordKillCredit(0, 1)
    sim.finishGame(Red)

    let results = parseJson(sim.playerResultsJson())
    check results["scores"].len == 32
    check results["names"].len == 32
    check results["kills"][0].getInt() == 1
    # No cross-seat bleed: seat 1 (a different real cog, not a squadmate of
    # seat 0) reports nothing from seat 0's kill.
    check results["kills"][1].getInt() == 0

  test "the seat-arity fold composes with #330's glory-as-league-score: a squadmate's TEAM-scalar glory is not double-counted":
    ## #330 repurposed `scores[slot]` to `sim.teamGlory[team]` on a win
    ## (roster.nim's GLORY-AS-LEAGUE-SCORE comment). Because glory is a
    ## TEAM scalar, every cog on one seat's squad would read the SAME
    ## value -- the fold above deliberately does not SUM `scoresArr` the
    ## way it sums kills/deaths/etc (see its own comment), so a seat with a
    ## squadmate still reports its team's exact glory total once, not
    ## doubled.
    var sim = initCtfForTest(defaultGameConfig())
    sim.config.numAgents = 16
    sim.config.cogsPerTeam = 2
    for i in 0 ..< 16:
      discard sim.addPlayer("policy" & $i, i, "", trusted = true)
    sim.startGame()
    sim.awardDeed(Red, dHonorableKill, 10, 10)
    # Seat 0's squadmate (cog 16, same team as seat 0 -- `cogSeat` = 16 mod
    # 16 = 0) joins AFTER the mint, so the ledger is already nonzero when
    # the fold runs.
    discard sim.addPlayer("squad-alias-16", 16, "", trusted = true)
    sim.finishGame(Red)
    let redGlory = sim.teamGlory[Red]
    check redGlory > 0

    let results = parseJson(sim.playerResultsJson())
    check results["scores"].len == 16
    check results["scores"][0].getInt() == redGlory  # exact total, not 2x

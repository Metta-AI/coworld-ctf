## Regression coverage for roster.nim's playerResultsJson scoring-schema
## switch (the "every live round scores 0.5/0.5" incident).
##
## The manifest unification on Aug 6 (c8fa5558, "Unify CTF into the Paintbot
## Coworld") set `num_agents` on every flagship CLASSIC variant (2v2, 4ffa,
## 4ffa8, 1v1, ctf-default, ctf-1v1) for an unrelated squad/seat-broadcast
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
  std/[json, unittest],
  helpers, pb_helpers

suite "scoring schema routing":
  test "a classic match keeps num_agents > 0 (the manifest collision) and still scores through the CTF path":
    ## Reproduces the live collision directly: num_agents set the way every
    ## flagship classic variant sets it (16 seats), loadout left at its
    ## LoadoutCtf default, hill left false -- exactly round #3450's replay
    ## config (num_agents=16, loadout="ctf", hill=false).
    var sim = twoTeamGame()
    sim.config.numAgents = 16
    check sim.config.loadout == LoadoutCtf
    check not sim.config.hill

    # A real kill through the real credit path, then a real decisive finish
    # -- not a fabricated results field.
    sim.recordKillCredit(0, 1)
    # A real glory mint (not a fabricated results field either) so `scores`
    # has something nonzero from the ledger to report.
    sim.awardDeed(Red, dHonorableKill, 10, 10)
    sim.finishGame(Red)
    # Read the ledger AFTER finishGame: finishGame's own conclusion-only
    # mints (e.g. Clean Sheet, evalCleanSheetAtConclusion) can still add to
    # it, so the total the results doc must report is whatever the ledger
    # holds once the match has fully wrapped up, not a snapshot mid-way.
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
    ## newPaintballSim's config is exactly what a live paintball round
    ## sends: loadout="paintball", hill=true, num_agents=2. This must stay
    ## on squadResultsJson exactly as it did before the fix -- this is a
    ## pure routing change, not a scoring change.
    var sim = newPaintballSim()
    check sim.config.loadout == LoadoutPaintball
    sim.hillTicks[Red] = 900
    sim.hillTicks[Blue] = 0
    let results = parseJson(sim.playerResultsJson())
    check results.hasKey("hillTicks")
    check not results.hasKey("kills")
    check results["scores"][0].getFloat() > 0.5
    check results["scores"][1].getFloat() < 0.5

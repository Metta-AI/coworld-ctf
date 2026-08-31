## "Glory is the league score": coverage for roster.nim's ctfPlayerResultsJson
## `scores` field, repurposed from the RL WinReward/LossReward figures to the
## GV48 glory ledger (`sim.teamGlory`), banked winner-take-all on a decided
## win. Design (owner's words): "to get the glory you have to win, and if you
## win you get that score."
##
## Each test is a discriminator, not a restatement: it mints REAL glory
## through the REAL mint point (`sim.awardDeed`, the same call every kill/
## capture/achievement in the live sim goes through) and a REAL `finishGame`
## call, then asserts against the ledger the sim itself reports
## (`sim.teamGlory`) rather than a hardcoded number that would silently stay
## green if a pricing formula in glory.nim changed.
##
## Explicitly covered, per the design's own honesty requirement: a draw, an
## aborted/incomplete match, and a winner whose glory ledger is exactly zero
## -- plus a byte-for-byte MD5 proof that squadResultsJson (the paintball
## path) is untouched by any of this.

import
  std/[json, md5, unittest],
  helpers, pb_helpers

suite "glory as league score":
  test "winner banks its team's exact glory ledger total; loser banks zero even with its own nonzero ledger":
    var sim = twoTeamGame()
    sim.recordKillCredit(0, 1)
    # Mint glory on BOTH teams -- the loser must still report 0 even though
    # its own ledger is provably nonzero. A naive `teamGlory[playerTeam]`
    # read with no win-gate would leak this value into Blue's score.
    sim.awardDeed(Red, dHonorableKill, 10, 10)
    sim.awardDeed(Blue, dHonorableKill, 20, 20)
    sim.finishGame(Red)
    let
      redGlory = sim.teamGlory[Red]
      blueGlory = sim.teamGlory[Blue]
    check redGlory > 0
    check blueGlory > 0

    let results = parseJson(sim.playerResultsJson())
    check results["win"][0].getBool()
    check not results["win"][1].getBool()
    check results["scores"][0].getInt() == redGlory
    check results["scores"][1].getInt() == 0
    # The loser's own ledger total never shows up anywhere in what it banks.
    check results["scores"][1].getInt() != blueGlory

  test "a team can win with exactly zero glory: win stays true, score reports the true zero":
    var sim = twoTeamGame()
    sim.recordKillCredit(0, 1)
    sim.finishGame(Red)
    # Force the ledger to exactly zero post-conclusion (finishGame's own
    # achievement mints, e.g. Clean Sheet, would otherwise make this
    # scenario hard to reach honestly) -- proves the reporter trusts the
    # ledger's literal value, including zero, rather than assuming a winner
    # always has something to show.
    sim.teamGlory[Red] = 0

    let results = parseJson(sim.playerResultsJson())
    check results["win"][0].getBool()
    check results["scores"][0].getInt() == 0

  test "a draw banks zero for both sides, even with a nonzero ledger on both":
    var sim = twoTeamGame()
    sim.awardDeed(Red, dHonorableKill, 10, 10)
    sim.awardDeed(Blue, dHonorableKill, 20, 20)
    sim.finishGame(Red, isDraw = true)
    check sim.isDraw
    check sim.teamGlory[Red] > 0
    check sim.teamGlory[Blue] > 0

    let results = parseJson(sim.playerResultsJson())
    # Nobody won, so nobody banks -- the existing `win` field already goes
    # false for both under isDraw; `scores` follows the same gate.
    check not results["win"][0].getBool()
    check not results["win"][1].getBool()
    check results["scores"][0].getInt() == 0
    check results["scores"][1].getInt() == 0

  test "an aborted/incomplete match (finishGame never ran) banks zero for everyone":
    ## `sim.winner` defaults to `Red` (Team's zero value) and `sim.isDraw`
    ## defaults to `false` until `finishGame` actually runs. Without the
    ## `sim.phase == GameOver` gate in ctfPlayerResultsJson, a still-seated
    ## Red-team slot on an episode that never concluded (e.g. the roster
    ## empties mid-`Playing` with `maxGames <= 0`, which routes to
    ## `resetToLobby` rather than `finishGame`) would read
    ## `playerWon = not false and Red == Red = true` and falsely bank
    ## whatever Red's ledger happened to hold. This reproduces that exact
    ## shape directly, without needing the full roster-loss plumbing: mint
    ## Red glory, never call finishGame, and confirm nothing pays out.
    var sim = twoTeamGame()
    sim.awardDeed(Red, dHonorableKill, 10, 10)
    check sim.teamGlory[Red] > 0
    check sim.phase == Playing  # never concluded
    check sim.winner == Red     # the zero-value default, not a real decision
    check not sim.isDraw

    let results = parseJson(sim.playerResultsJson())
    check results["scores"][0].getInt() == 0
    check results["scores"][1].getInt() == 0

  test "paintball's scores stay hill-territory permille, byte-unchanged by the glory pass":
    ## The exact scenario test_scoring_routing.nim's third test uses, hashed:
    ## proves squadResultsJson's whole output is untouched, the way #327's
    ## own verification did, rather than checking a handful of fields and
    ## hoping nothing else moved.
    var sim = newPaintballSim()
    sim.hillTicks[Red] = 900
    sim.hillTicks[Blue] = 0
    let resultsStr = sim.playerResultsJson()
    let results = parseJson(resultsStr)
    # The invariant this pass does NOT touch: paintball's scores are a
    # normalized hill-territory permille that always sums to 1.0 -- a
    # completely different meaning from CTF's banked-glory score above.
    # (Flagged prominently in the PR: a future league rotation that mixes
    # the Paintball KOTH variant into a glory-scored ladder would silently
    # mix these two incompatible meanings of the same `scores` key.)
    check abs(results["scores"][0].getFloat() + results["scores"][1].getFloat() - 1.0) < 1e-9
    check getMD5(resultsStr) == "f3000c1e1d377827c4a05679cca895f3"

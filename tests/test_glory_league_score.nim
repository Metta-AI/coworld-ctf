## "Glory is the league score": coverage for roster.nim's ctfPlayerResultsJson
## `scores` field, repurposed from the RL WinReward/LossReward figures to the
## GV48 glory ledger (`sim.teamGlory`). Every concluded slot reports its OWN
## team's already-tracked glory total -- win, lose, or draw -- rather than
## only the winner banking anything. (Previously gated on `playerWon`,
## flattening every non-winner to 0; that gate was dropped because glory is
## tracked per-duo already, so nothing is lost by reporting a loser's or a
## drawn side's own total instead of discarding it. This can carry a
## NEGATIVE score through to the platform's league ledger for a
## friendly-fire-heavy duo -- intentional, the literal contents of that
## duo's own ledger.)
##
## Each test is a discriminator, not a restatement: it mints REAL glory
## through the REAL mint point (`sim.awardDeed`, the same call every kill/
## capture/achievement in the live sim goes through) and a REAL `finishGame`
## call, then asserts against the ledger the sim itself reports
## (`sim.teamGlory`) rather than a hardcoded number that would silently stay
## green if a pricing formula in glory.nim changed.
##
## Explicitly covered: a draw, an aborted/incomplete match (the one case
## that still banks 0 for everyone -- the episode never concluded), and a
## winner whose glory ledger is exactly zero -- plus a byte-for-byte MD5
## proof that squadResultsJson (the paintball path) is untouched by any of
## this.

import
  std/[json, md5, unittest],
  helpers, pb_helpers

suite "glory as league score":
  test "DISCRIMINATOR: a losing seat's row reports its own team's non-zero glory, not a flattened 0":
    ## Minimal, standalone proof of the behavior change: Blue LOSES this
    ## game but its own ledger is provably nonzero (kill credit +
    ## `awardDeed`, same as Red's win-side mints from `finishGame`'s own
    ## conclusion sweep). Under the old `hasTeam and playerWon` gate, the
    ## losing seat's score is unconditionally 0 regardless of its own
    ## ledger -- this test's final `> 0` check FAILS on that old code
    ## (0 > 0 is false) and PASSES once the `playerWon` condition is
    ## dropped, so it discriminates the two behaviors rather than passing
    ## either way.
    var sim = twoTeamGame()
    sim.recordKillCredit(0, 1)
    sim.awardDeed(Blue, dHonorableKill, 5, 5)  # the LOSER's own ledger mints
    sim.finishGame(Red)
    check sim.teamGlory[Blue] > 0

    let results = parseJson(sim.playerResultsJson())
    check results["win"][0].getBool()
    check not results["win"][1].getBool()  # seat 1 (Blue) is the loser
    check results["scores"][1].getInt() == sim.teamGlory[Blue]
    check results["scores"][1].getInt() > 0  # <-- fails under the old `playerWon` gate

  test "winner banks its team's exact glory ledger total; loser banks its OWN nonzero ledger too":
    var sim = twoTeamGame()
    sim.recordKillCredit(0, 1)
    # Mint glory on BOTH teams -- the loser must report its own total, not a
    # flattened 0. A stale `playerWon`-gated read would leak this back to 0
    # even though Blue's own ledger is provably nonzero.
    sim.awardDeed(Red, dHonorableKill, 10, 10)
    sim.awardDeed(Blue, dHonorableKill, 20, 20)
    sim.finishGame(Red)
    let
      redGlory = sim.teamGlory[Red]
      blueGlory = sim.teamGlory[Blue]
    check redGlory > 0
    check blueGlory > 0
    check redGlory != blueGlory

    let results = parseJson(sim.playerResultsJson())
    check results["win"][0].getBool()
    check not results["win"][1].getBool()
    check results["scores"][0].getInt() == redGlory
    # The loser still reports `win = false`, but `scores` now carries its
    # own team's real ledger total, not a win-gated 0.
    check results["scores"][1].getInt() == blueGlory

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

  test "a draw still banks each side's own nonzero ledger, even though nobody won":
    var sim = twoTeamGame()
    sim.awardDeed(Red, dHonorableKill, 10, 10)
    sim.awardDeed(Blue, dHonorableKill, 20, 20)
    sim.finishGame(Red, isDraw = true)
    check sim.isDraw
    check sim.phase == GameOver  # finishGame sets this before the isDraw branch
    let
      redGlory = sim.teamGlory[Red]
      blueGlory = sim.teamGlory[Blue]
    check redGlory > 0
    check blueGlory > 0

    let results = parseJson(sim.playerResultsJson())
    # `win` still goes false for both under isDraw -- that field is
    # unaffected -- but `scores` is no longer gated on `playerWon`, so a
    # draw's episode (which DID conclude: `sim.phase == GameOver`) still
    # reports each side's real, and here different, glory total.
    check not results["win"][0].getBool()
    check not results["win"][1].getBool()
    check results["scores"][0].getInt() == redGlory
    check results["scores"][1].getInt() == blueGlory

  test "an aborted/incomplete match (finishGame never ran) banks zero for everyone":
    ## `sim.phase` only reaches `GameOver` once `finishGame` actually runs.
    ## Now that glory is no longer gated on `playerWon`, this
    ## `sim.phase == GameOver` check is the ONLY thing left protecting an
    ## aborted episode -- e.g. the roster empties mid-`Playing` with
    ## `maxGames <= 0`, which routes to `resetToLobby` rather than
    ## `finishGame`, leaving `sim.teamGlory` populated but never finalized.
    ## Without this gate, a still-seated slot on such an episode would bank
    ## whatever its team's ledger happened to hold mid-game. This
    ## reproduces that exact shape directly, without needing the full
    ## roster-loss plumbing: mint Red glory, never call finishGame, and
    ## confirm nothing pays out.
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

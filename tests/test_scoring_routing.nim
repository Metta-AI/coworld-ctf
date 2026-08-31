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
    sim.finishGame(Red)

    let results = parseJson(sim.playerResultsJson())
    # The CTF schema, not the squad/hill schema: presence of `kills`
    # (CTF-only) and absence of `hillTicks` (squad-only) is itself proof of
    # which proc answered the call.
    check results.hasKey("kills")
    check not results.hasKey("hillTicks")
    check results["kills"][0].getInt() == 1
    check results["win"][0].getBool()
    check not results["win"][1].getBool()
    # The bug's signature was EVERY seat landing on the literal 500/500
    # (0.5/0.5) tie. A real decisive win must not.
    check results["scores"][0].getInt() != results["scores"][1].getInt()
    check results["scores"][0].getInt() == WinReward
    check results["scores"][1].getInt() == LossReward

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

suite "results seat arity (the coworld hosted-certification regression)":
  ## #327 fixed the SCORING (real kills/captures instead of a 500/500 tie)
  ## but exposed a pre-existing arity bug in the classic path it now routes
  ## to: `ctfPlayerResultsJson` reported one row per joined SLOT (== per
  ## cog), which equals `numAgents` only when every seat fields exactly one
  ## cog. server.nim's `squadMode` (gated on `numAgents > 0 and
  ## cogsPerTeam > 1` -- true for every classic variant, since
  ## `cogsPerTeam` defaults to 4 and none of them override it) auto-fills
  ## trusted cogs past the real seats toward `sim.totalCogs()`, capped by
  ## `MaxPlayers` (32) rather than by the seat count. A 16-seat classic
  ## match's squad-fill therefore silently parks 32 total cogs in
  ## `sim.players`, and the pre-fix proc reported 32 rows: hosted
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
  test "certification shape: 16 seats squad-filled to 32 cogs folds back to 16 scores":
    var sim = initCtfForTest(defaultGameConfig())
    sim.config.numAgents = 16
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

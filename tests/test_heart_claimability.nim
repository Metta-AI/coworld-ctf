## DECISIVE EXPERIMENT (evidence, 2026-08-31): can the live engine mint the
## capture-gated "The Heart" (treeCarrier) tiers — Delivered (II, captures>=1),
## Uphill (IV, capturedOutnumbered), Fast Break (V, capturedFastBreak)?
##
## A peer code-read (made against a stale GV10 worktree) claimed these tiers
## are STRUCTURALLY UNCLAIMABLE: the per-tick sweep `evalAchievementsAllTeams`
## runs at the top of `step` (before `checkWinCondition`), both eval procs
## early-return unless phase == Playing, and `finishGame` (which flips to
## GameOver) runs in the same `checkWinCondition` call that pins the capture
## facts — so the facts allegedly exist only after the last Playing-phase
## sweep has already run.
##
## What this file demonstrates against origin/main (GV11):
##   * The peer's read is HALF right: it holds exactly when the capture ENDS
##     the game — i.e. every classic 2-team capture, and the FINAL capture of
##     an N-team game (the wipe check in the same `checkWinCondition` call
##     sees one team standing and finishes the game before any next sweep).
##   * It is WRONG for the general engine: since GV32 a capture ELIMINATES
##     the captured team instead of ending the game. A non-final capture on a
##     4-team board leaves phase == Playing, the pinned facts persist on the
##     player (nothing clears them until `startGame`), and the NEXT tick's
##     `evalAchievementsAllTeams` mints tiers II/IV/V. One-tick lag, not
##     structural unclaimability.
##   * Victory Lap (treeSquad V, `kits >= 4 and anyCapture`) IS unclaimable
##     on main, but NOT by the peer's mechanism: `teamConvertedKits` caps at
##     3 (the `med` leg reads `supplyShared`, absent on this port —
##     GLORY-PORT-TODO), so `kits >= 4` never holds and `anyCapture`'s
##     timing is never even consulted. No sweep-timing fix can mint it.
##   * The phase boundary was a KNOWN, special-cased fact: Clean Sheet
##     (treeSquad IV) gets a dedicated conclusion-time mint,
##     `evalCleanSheetAtConclusion`, called once from `finishGame` — its doc
##     comment says `satisfiedAchievements` never reports that tier and this
##     is "its one and only mint site". No such conclusion mint exists for
##     the capture-gated carrier tiers on a game-ending capture.
##
## Compile-time toggle -d:heartOption1 selects the WITH-PATCH expectations for
## the peer's minimal Option-1 fix (a sweep inside `checkWinCondition` after
## the capture facts are pinned, while phase is still Playing). That patch is
## EVIDENCE-ONLY and lives in a separate commit reverted at branch tip; the
## define fails to change anything (and this file's patched branch fails)
## unless that commit is applied.

import
  helpers,
  std/unittest,
  bitworld/spriteprotocol,
  ctf/[glory, sim]

proc centerOn(sim: var SimServer, playerIndex, x, y: int) =
  ## Places one player so its collision CENTER sits at (x, y).
  sim.players[playerIndex].x = x - CollisionW div 2
  sim.players[playerIndex].y = y - CollisionH div 2

proc fourTeamConfig(): GameConfig =
  result = defaultGameConfig()
  result.teams = 4
  result.mapPath = "gen"
  result.mapGen.layout = "corners"
  result.mapSeed = 42

const
  DeliveredKey  = achievementKey(treeCarrier, 1) # tier II, captures >= 1
  UphillKey     = achievementKey(treeCarrier, 3) # tier IV, capturedOutnumbered
  FastBreakKey  = achievementKey(treeCarrier, 4) # tier V, capturedFastBreak
  KitsTwoKey    = achievementKey(treeSquad, 0)   # kits >= 2
  KitsThreeKey  = achievementKey(treeSquad, 1)   # kits >= 3
  VictoryLapKey = achievementKey(treeSquad, 4)   # kits >= 4 AND anyCapture

suite "heart tier claimability (the decisive experiment)":

  test "4-team NON-FINAL capture: Delivered/Uphill/Fast Break mint next tick":
    ## Five players: slots deal Red,Blue,Green,Yellow,Red; the fifth is
    ## re-seated onto Green so Red (1 alive) captures OUTNUMBERED by
    ## Green (2 alive) — pinning capturedOutnumbered at the capture site.
    var sim = initCtfForTest(fourTeamConfig())
    for i in 0 ..< 5:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    sim.players[4].team = Green
    check sim.phase == Playing

    # Give Red every kit conversion the port can count, so `kits` sits at its
    # MAXIMUM when the capture lands. `teamConvertedKits` (sim.nim) tops out
    # at 3 — its `med` leg reads `player.supplyShared`, which does not exist
    # on this port (GLORY-PORT-TODO in the proc's own doc comment) — so the
    # Victory Lap gate `kits >= 4 and anyCapture` is IMPOSSIBLE on main for a
    # reason UPSTREAM of, and independent from, any sweep-timing question.
    sim.players[0].grenadeKills = 1
    sim.players[0].sprayKills = 1
    sim.players[0].assists = 1

    # A REAL steal (pins stealTickThisLife, so the capture is a Fast Break).
    let greenHome = sim.gameMap.flagHome(Green)
    sim.centerOn(0, greenHome.x, greenHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Green].carrier == 0
    check sim.players[0].stealTickThisLife >= 0

    # Walk the carrier into Red's capture zone and let the LIVE step loop
    # resolve the capture (sweep runs first, checkWinCondition later, same
    # ordering as production).
    let anchor = sim.gameMap.teamAnchor(Red)
    sim.centerOn(0, anchor.x, anchor.y)
    sim.step(sim.none(), sim.none())

    # The capture happened, facts pinned, game GOES ON (3 teams stand)...
    check sim.players[0].captures == 1
    check sim.players[0].capturedOutnumbered
    check sim.players[0].capturedFastBreak
    check sim.phase == Playing
    when not defined(heartOption1):
      # ...but nothing minted THIS tick: the sweep at this step's top ran
      # before the capture existed. This is the one-tick lag the peer's
      # read observed (and over-generalized into "never").
      check not sim.claimed[Red][DeliveredKey]
      check not sim.claimed[Red][UphillKey]
      check not sim.claimed[Red][FastBreakKey]
    else:
      # Option-1 patch: the in-checkWinCondition sweep mints same-tick.
      check sim.claimed[Red][DeliveredKey]
      check sim.claimed[Red][UphillKey]
      check sim.claimed[Red][FastBreakKey]

    # Next tick's Playing-phase sweep mints all three capture-gated tiers.
    sim.step(sim.none(), sim.none())
    check sim.claimed[Red][DeliveredKey]
    check sim.claimed[Red][UphillKey]
    check sim.claimed[Red][FastBreakKey]

    # Victory Lap (treeSquad V): anyCapture is TRUE and phase is Playing —
    # the peer's phase-boundary mechanism does NOT apply here — yet the tier
    # still cannot mint, patched or not, because `kits` is capped at 3 (the
    # 2- and 3-kit tiers below prove all reachable kits were counted). Its
    # unclaimability on main is the MISSING MEDKIT LEG, not sweep timing.
    check sim.claimed[Red][KitsTwoKey]
    check sim.claimed[Red][KitsThreeKey]
    check not sim.claimed[Red][VictoryLapKey]

  test "2-team capture ends the game in the same tick: tiers never mint":
    ## Classic 2-team: the capture eliminates the ONLY rival, the wipe check
    ## in the SAME checkWinCondition call finishes the game, and phase is
    ## GameOver before any subsequent sweep can run. The pinned facts are
    ## then reset by startGame before phase is ever Playing again.
    var sim = twoTeamGame()

    let blueHome = sim.gameMap.flagHome(Blue)
    sim.centerOn(0, blueHome.x, blueHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Blue].carrier == 0
    check sim.players[0].stealTickThisLife >= 0

    let anchor = sim.gameMap.teamAnchor(Red)
    sim.centerOn(0, anchor.x, anchor.y)
    sim.step(sim.none(), sim.none())

    # Capture resolved and the game is OVER in the same step.
    check sim.players[0].captures == 1
    check sim.players[0].capturedFastBreak
    check sim.phase == GameOver
    when not defined(heartOption1):
      check not sim.claimed[Red][DeliveredKey]
      check not sim.claimed[Red][FastBreakKey]

      # Drive through GameOver -> Lobby -> (possibly a fresh game): the
      # Playing-gated sweeps never see the facts, and startGame wipes both
      # the facts (sim.nim startGame per-player loop) and the claim ledger
      # (resetGloryLedger) before Playing resumes. UNCLAIMABLE, structurally.
      for tick in 0 ..< 3000:
        sim.step(sim.none(), sim.none())
        check not sim.claimed[Red][DeliveredKey]
        check not sim.claimed[Red][FastBreakKey]
        if sim.phase == Playing:
          break
      if sim.phase == Playing:
        # A fresh game started: the capture facts are gone with the claims.
        check sim.players[0].captures == 0
        check not sim.players[0].capturedFastBreak
    else:
      # Option-1 patch: the sweep between recordCapture and finishGame runs
      # while phase is STILL Playing, so the tiers mint even though this
      # same tick ends the game.
      check sim.claimed[Red][DeliveredKey]
      check sim.claimed[Red][FastBreakKey]

## GLORY v12: the HEART RECUT + the STRUCTURAL CONCLUSION SWEEP (the ruled
## 2026-08-31 recut contract + its Amendment 1), pinned at the SimServer
## level. The decisive claimability experiment (branch
## maxwell/heart-claimability-test, run against main @ GV11) proved the
## terminal-tick hole this version closes: the per-tick sweep at the top of
## `step` runs BEFORE `checkWinCondition`, and both Playing-gated eval procs
## are dead the moment `finishGame` flips phase — so a fact created by the
## act that ENDS the game (a capture's `captures`, the final kill's
## counters) could never mint. In Season 2's modes that shape is the COMMON
## case, not the edge: every 2-team 8v8 CTF capture ends the game, and every
## 16-duo BR round ends on a terminal elimination. The suites below cover
## the S2 shapes as the primary cases, the retiring 4-team next-tick path as
## a regression, the double-mint dedupe, the recut gate table, and the
## corrected budget arithmetic (contract §6).

import
  helpers,
  std/[json, os, unittest],
  bitworld/spriteprotocol,
  ctf/[broadcast, glory, sim]

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

proc claimCount(sim: SimServer, tree: Tree, tier: int): int =
  ## How many times a (tree, tier) appears in the claim feed — the
  ## double-mint probe: any value above one per team is a dedupe failure.
  for claim in sim.achievementFeed:
    if claim.tree == tree and claim.tier == tier:
      inc result

proc claimTick(sim: SimServer, team: Team, tree: Tree, tier: int): int =
  ## The tick a team's (tree, tier) claim minted at, or -1.
  result = -1
  for claim in sim.achievementFeed:
    if claim.team == team and claim.tree == tree and claim.tier == tier:
      return claim.tick

const
  # The RECUT keys (contract §1). Tier indexes are the new table's.
  HandsOnKey       = achievementKey(treeCarrier, 0) # contestedSteals >= 1
  FightingCarryKey = achievementKey(treeCarrier, 1) # carryKills >= 1
  DoubleStealKey   = achievementKey(treeCarrier, 2) # contestedSteals >= 2
  HardCarryKey     = achievementKey(treeCarrier, 3) # both of the above
  DeliveredKey     = achievementKey(treeCarrier, 4) # captures >= 1
  FirstTagKey      = achievementKey(treeGun, 0)     # gunKills >= 1
  FullKitKey       = achievementKey(treeSquad, 2)   # TOMBSTONED (Amendment 1)
  CleanSheetKey    = achievementKey(treeSquad, 3)   # full-game, conclusion-only
  VictoryLapKey    = achievementKey(treeSquad, 4)   # kits >= KitLegsImplemented
                                                    # and anyCapture

suite "the heart recut (contract §1): the ladder climbs":

  test "contested steals and carry kills gate II-IV, live":
    var sim = twoTeamGame()

    sim.players[0].contestedSteals = 1
    sim.step(sim.none(), sim.none())
    check sim.claimed[Red][HandsOnKey]
    check not sim.claimed[Red][DoubleStealKey]
    check not sim.claimed[Red][FightingCarryKey]

    sim.players[0].contestedSteals = 2
    sim.step(sim.none(), sim.none())
    check sim.claimed[Red][DoubleStealKey]
    # Hard Carry is the STRICT superset: two contested steals alone are not
    # enough without the carry kill.
    check not sim.claimed[Red][HardCarryKey]

    sim.players[0].carryKills = 1
    sim.step(sim.none(), sim.none())
    check sim.claimed[Red][FightingCarryKey]
    check sim.claimed[Red][HardCarryKey]

    # No capture happened, so the terminal tier stays open.
    check not sim.claimed[Red][DeliveredKey]

suite "S2 primary shape: the 2-team game-ending capture":

  proc captureEndsGame(kitsConverted = false): SimServer =
    ## A 2-team game driven through a REAL capture that ends it: pre-mints
    ## Hands On mid-game (the double-mint probe), steals the blue heart off
    ## its pedestal, then walks it home through the live step loop — the
    ## sweep-runs-first / win-check-later ordering of production. With
    ## `kitsConverted`, Red has every kit leg this port implements converted
    ## BEFORE the capture, so Victory Lap's whole gate rides the terminal
    ## tick.
    result = twoTeamGame()
    result.players[0].contestedSteals = 1
    if kitsConverted:
      result.players[0].grenadeKills = 1
      result.players[0].sprayKills = 1
      result.players[0].assists = 1
    result.step(result.none(), result.none())
    doAssert result.claimed[Red][HandsOnKey] # minted by the LIVE sweep
    let blueHome = result.gameMap.flagHome(Blue)
    result.centerOn(0, blueHome.x, blueHome.y)
    result.tryPickupFlags(0)
    doAssert result.flags[Blue].carrier == 0
    let anchor = result.gameMap.teamAnchor(Red)
    result.centerOn(0, anchor.x, anchor.y)
    result.step(result.none(), result.none())
    doAssert result.players[0].captures == 1
    doAssert result.phase == GameOver

  test "Delivered mints AT the ending tick, via the conclusion sweep":
    ## THE case the decisive experiment proved broken on main: a 2-team
    ## capture eliminates the only rival, `finishGame` runs in the same
    ## `checkWinCondition` call that pinned the capture facts, and no
    ## Playing-phase sweep ever sees them. Every S2 CTF capture is this
    ## shape. The conclusion sweep must mint it — at the ending tick, not a
    ## tick late and not never.
    var sim = captureEndsGame()
    check sim.claimed[Red][DeliveredKey]
    check sim.claimTick(Red, treeCarrier, 4) == sim.tickCount
    # The retired distinctions are pins now, not claims: pinned, unclaimed.
    check sim.players[0].capturedFastBreak

  test "double-mint proof: a live-minted tier does not re-mint at conclusion":
    var sim = captureEndsGame()
    # Hands On minted by the last Playing sweep; the conclusion sweep reads
    # it as satisfied AGAIN and `claimed[]` must swallow the re-claim.
    check sim.claimCount(treeCarrier, 0) == 1
    let feedAtConclusion = sim.achievementFeed.len
    let gloryAtConclusion = sim.teamGlory[Red]
    # And the game-over ticks after conclusion mint nothing further.
    for _ in 0 ..< 3:
      sim.step(sim.none(), sim.none())
    check sim.achievementFeed.len == feedAtConclusion
    check sim.teamGlory[Red] == gloryAtConclusion
    check sim.claimCount(treeCarrier, 0) == 1

  test "Clean Sheet folds into the sweep: never live, minted at conclusion":
    var duringPlay = twoTeamGame()
    for _ in 0 ..< 5:
      duringPlay.step(duringPlay.none(), duringPlay.none())
    # Zero team kills the whole way — and still unclaimable while Playing,
    # exactly the semantics the retired special case enforced.
    check not duringPlay.claimed[Red][CleanSheetKey]
    check not duringPlay.claimed[Blue][CleanSheetKey]

    var sim = captureEndsGame()
    # Both rosters finished without a friendly kill: both claim at the end.
    check sim.claimed[Red][CleanSheetKey]
    check sim.claimed[Blue][CleanSheetKey]

  test "a team with a friendly kill never takes Clean Sheet":
    var sim = twoTeamGame()
    sim.players[1].teamKills = 1
    sim.finishGame(Red)
    check sim.claimed[Red][CleanSheetKey]
    check not sim.claimed[Blue][CleanSheetKey]

  test "Victory Lap (Amendment 1): every implemented kit + the ending capture":
    ## `anyCapture` pins at the terminal tick, so with the amended gate
    ## (`kits >= KitLegsImplemented`) the tier's MAIN mint path is the
    ## conclusion sweep — this is the first version where Victory Lap is
    ## genuinely claimable at all.
    var sim = captureEndsGame(kitsConverted = true)
    check sim.claimed[Red][VictoryLapKey]
    check sim.claimTick(Red, treeSquad, 4) == sim.tickCount
    # Full Kit stays TOMBSTONED (same missing med leg, zero-claim): the
    # kits counter sat at its cap all game and the tier still never mints.
    check not sim.claimed[Red][FullKitKey]

  test "the endcard ships the distinctions (contract §3), display-only":
    var sim = captureEndsGame()
    let state = parseJson(sim.buildStateJson(
      newJArray(), false, 1, 1000, false, true, -1, -1
    ))
    check state["ph"].getStr == "gameover"
    let distinctions = state["over"]["distinctions"]
    # A 1v1 capture at full strength is a Fast Break (steal -> home in one
    # scripted run) and never Uphill (1 alive vs 1 alive is not outnumbered).
    check distinctions.len == 1
    check distinctions[0]["name"].getStr == "Fast Break"
    check distinctions[0]["team"].getStr == "red"
    check distinctions[0]["slot"].getInt == sim.players[0].joinOrder
    check distinctions[0]["desc"].getStr ==
      captureDistinctionDescription(cdFastBreak)
    # Display-only: no glory figure on the wire, no claim in the feed, and
    # the retired names appear nowhere in the claimable curriculum.
    check not distinctions[0].hasKey("glory")
    for claim in sim.achievementFeed:
      check achievementName(claim.tree, claim.tier) notin ["Uphill", "Fast Break"]
    for tree in Tree:
      for tier in 0 ..< AchievementTiers:
        check achievementName(tree, tier) notin ["Uphill", "Fast Break"]

suite "S2 flagship shape: the BR terminal elimination":

  test "16-duo BR: the final kill's own facts mint in the conclusion sweep":
    ## The S2 flagship board — 16 duos, brMode, the real brmapkit golden
    ## map (tests/fixtures/br-golden-map.json): the round ends on a
    ## terminal elimination, and the kill that ends it crosses its killer's
    ## first gun-kill threshold IN the ending call — after the last Playing
    ## sweep, before GameOver. Exactly the in-step ordering of a real BR
    ## final kill (damage resolves, THEN the same step's `checkWinCondition`
    ## sees one team standing), driven proc-level for determinism.
    var config = defaultGameConfig()
    config.brMode = true
    config.teams = 16
    config.mapSpec = readFile(
      GameDir / "tests" / "fixtures" / "br-golden-map.json")
    var sim = initCtfForTest(config)
    for i in 0 ..< 32:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    check sim.config.brMode
    check sim.phase == Playing
    # One live tick: the last Playing sweep runs and, with no counters yet,
    # mints nothing.
    sim.step(sim.none(), sim.none())
    check sim.achievementFeed.len == 0
    let killerTeam = sim.players[0].team
    # 30 storm deaths (no killer, nothing priced) leave two teams standing...
    var spared = -1
    for i in countdown(sim.players.len - 1, 1):
      if spared < 0 and sim.players[i].team != killerTeam:
        spared = i
        continue
      if sim.players[i].team == killerTeam:
        continue
      sim.killPlayer(i, -1, cause = "eliminated")
    check sim.phase == Playing
    # ...and the terminal kill ends the round in the same win-check call,
    # with the killer's FIRST gun kill created after any Playing sweep
    # could see it.
    sim.killPlayer(spared, 0)
    check sim.players[0].gunKills == 1
    sim.checkWinCondition()
    check sim.phase == GameOver
    check sim.winner == killerTeam
    check sim.claimed[killerTeam][FirstTagKey]
    check sim.claimTick(killerTeam, treeGun, 0) == sim.tickCount

suite "conclusion coverage: draws and the retiring 4-team path":

  test "a draw still concludes: satisfied facts mint on the mutual outcome":
    ## Draws bank no league score, but the sweep runs before `finishGame`'s
    ## draw early-return, so facts at the draw tick evaluate exactly like a
    ## decisive ending's (the timeout tiebreak and mutual wipe both route
    ## here).
    var sim = twoTeamGame()
    sim.players[0].contestedSteals = 1 # never seen by a Playing sweep
    sim.finishGame(Red, isDraw = true, timeLimitReached = true)
    check sim.isDraw
    check sim.claimed[Red][HandsOnKey]
    check sim.claimTick(Red, treeCarrier, 0) == sim.tickCount
    check sim.claimed[Red][CleanSheetKey]
    check sim.claimed[Blue][CleanSheetKey]

  test "4-team regression: a NON-final capture still mints one tick later":
    ## The retiring flagship's shape (GV32: a capture ELIMINATES, only <=1
    ## standing ends the game): pinned facts persist and the NEXT tick's
    ## Playing sweep mints them. The conclusion sweep must not have
    ## disturbed the live path.
    var sim = initCtfForTest(fourTeamConfig())
    for i in 0 ..< 5:
      discard sim.addPlayer("p" & $i)
    sim.startGame()
    sim.players[4].team = Green
    check sim.phase == Playing

    let greenHome = sim.gameMap.flagHome(Green)
    sim.centerOn(0, greenHome.x, greenHome.y)
    sim.tryPickupFlags(0)
    check sim.flags[Green].carrier == 0

    let anchor = sim.gameMap.teamAnchor(Red)
    sim.centerOn(0, anchor.x, anchor.y)
    sim.step(sim.none(), sim.none())

    # Captured, facts pinned, game GOES ON (3 teams stand) — and nothing
    # minted THIS tick (the top-of-step sweep ran before the capture).
    check sim.players[0].captures == 1
    check sim.players[0].capturedOutnumbered
    check sim.phase == Playing
    check not sim.claimed[Red][DeliveredKey]

    sim.step(sim.none(), sim.none())
    check sim.claimed[Red][DeliveredKey]
    # The pins stay endcard material, never claims: the tier the old table
    # hung on `capturedOutnumbered` now requires contested steals + a carry
    # kill, neither of which this run produced.
    check not sim.claimed[Red][HardCarryKey]

suite "budget arithmetic (contract §6, corrected)":

  test "law 3 against the ATTAINABLE curriculum":
    ## test_glory.nim asserts the design-table CEILING (600 nominal); this
    ## is the truthful hard check against what `satisfiedAchievements` can
    ## actually report on this port. `UnattainableAchievementTiers` lives
    ## beside the proc that makes it true (sim.nim): five treeMedKit tiers
    ## (no `supplyShared`) and the tombstoned "Full Kit" (Amendment 1).
    ## With the conclusion sweep, EVERYTHING else is attainable — including
    ## Delivered, Clean Sheet, and (first version ever) Victory Lap.
    var nominal = 0
    for tier in 0 ..< AchievementTiers:
      nominal += tierGlory(tier) * AchievementTrees
    check nominal == 600
    var attainable = nominal
    for entry in UnattainableAchievementTiers:
      attainable -= tierGlory(entry[1])
    check attainable == 511 # 600 - 75 (treeMedKit) - 14 (Full Kit)
    check attainable < deedGlory(dCapture) + deedGlory(dWipe)

suite "the alliance-vocab fold (Amendment 3 Option C): stream-asserted mints":
  ## dAssist / dRescue, promoted as CTF deeds (2026-08-31 ruling; spec Part
  ## 1). Every mint assertion here reads the TIER-2 EVENT STREAM
  ## (`GloryDeed` rows via `emitEvent`), never the engine counters: the
  ## stream is what the offline ledger provably rebuilds from, and for
  ## dRescue the counter and the deed deliberately DISAGREE (aliveness).

  proc deedEvents(sim: SimServer, deed: string): seq[SimEvent] =
    for event in sim.events:
      if event.kind == GloryDeed and event.weapon == deed:
        result.add event

  test "dAssist mints to the ASSISTER on the stream, beside the kill deed":
    var sim = namedGame(4) # 0,2 Red; 1,3 Blue
    sim.collectEvents = true
    # B (Red, 2) softened the victim inside AssistWindowTicks; A (Red, 0)
    # finishes. The deed credits B; A banks the ordinary kill deed.
    sim.players[1].lastDamagedBy = 2
    sim.players[1].lastDamagedByTick = sim.tickCount
    sim.killPlayer(1, 0)
    let assists = sim.deedEvents("dAssist")
    check assists.len == 1
    check assists[0].source == sim.players[2].joinOrder
    check assists[0].amount > 0
    # ...and the kill deed itself still minted, credited to the KILLER:
    # the assist rides beside it, it does not replace or re-route it.
    var killerDeeds = 0
    for event in sim.events:
      if event.kind == GloryDeed and event.weapon != "dAssist" and
         event.source == sim.players[0].joinOrder:
        inc killerDeeds
    check killerDeeds >= 1

  test "an out-of-window softener earns no dAssist on the stream":
    var sim = namedGame(4)
    sim.collectEvents = true
    sim.players[1].lastDamagedBy = 2
    sim.players[1].lastDamagedByTick = sim.tickCount - AssistWindowTicks - 1
    sim.killPlayer(1, 0)
    check sim.deedEvents("dAssist").len == 0

  test "dRescue mints to the rescuer -- and requires the partner ALIVE":
    var sim = namedGame(4)
    sim.collectEvents = true
    # The victim (Blue, 1) recently menaced the killer's partner (Red, 2)
    # down to clutch hp; the partner still stands. Killing the menacer is
    # the celebrated act.
    sim.players[1].menacingTick = sim.tickCount
    sim.players[1].menacingVictim = 2
    sim.killPlayer(1, 0)
    let rescueEvents = sim.deedEvents("dRescue")
    check rescueEvents.len == 1
    check rescueEvents[0].source == sim.players[0].joinOrder
    check rescueEvents[0].amount > 0

  test "a dead partner blocks the DEED while the counter still counts":
    ## THE predicate difference (spec Part 1, deliberate): `rescues`
    ## increments regardless, but "the whole point is the partner
    ## survived" -- the deed reads aliveness the counter never did. This
    ## is why mint tests assert the stream, not the counter.
    var sim = namedGame(4)
    sim.collectEvents = true
    sim.players[2].alive = false
    sim.players[1].menacingTick = sim.tickCount
    sim.players[1].menacingVictim = 2
    let rescuesBefore = sim.players[0].rescues
    sim.killPlayer(1, 0)
    check sim.players[0].rescues == rescuesBefore + 1 # telemetry unchanged
    check sim.deedEvents("dRescue").len == 0          # no celebrated act

  test "both mints are CTF-only: the brMode gate holds (increment-2 overlay)":
    var sim = namedGame(4)
    sim.collectEvents = true
    sim.config.brMode = true # the mint sites read this at kill time
    sim.players[1].lastDamagedBy = 2
    sim.players[1].lastDamagedByTick = sim.tickCount
    sim.players[1].menacingTick = sim.tickCount
    sim.players[1].menacingVictim = 2
    sim.killPlayer(1, 0)
    check sim.deedEvents("dAssist").len == 0
    check sim.deedEvents("dRescue").len == 0

  test "the fold's prices sit where the ruling put them":
    ## Parity is the CONTRACT (dEscortKill for the assist, dRevengeKill for
    ## the rescue) -- assert the relation against the table, not restated
    ## literals, so a future re-pricing of the anchor moves both or fails
    ## here. The 56g life-value derivation for dRescue was explicitly NOT
    ## taken (breaches the dAceTag ordinal ceiling; owner feel-check item).
    check deedGlory(dAssist) == deedGlory(dEscortKill)
    check deedDrama(dAssist) == deedDrama(dEscortKill)
    check deedGlory(dRescue) == deedGlory(dRevengeKill)
    check deedDrama(dRescue) == deedDrama(dRevengeKill)
    check deedGlory(dRescue) < deedGlory(dAceTag)

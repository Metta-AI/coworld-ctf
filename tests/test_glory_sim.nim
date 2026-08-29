## Glory wired into the sim: the ladder is causal, the buffs land, the supply
## drop cannot be farmed, and every deed can actually FIRE.
##
## That last one is the whole reason this file exists. Muster shipped five
## reward layers that never fired -- each plausible in review, each silently
## paying nothing for millions of steps -- and banked the rule that a layer
## ships with an audit accumulator or it is presumed dead. We own the same
## scar: `arcStandoff` proved a lever that never fires makes an A/B read as a
## clean no-op, indistinguishable from a lever that does nothing.

import
  std/[os, strutils, unittest],
  bitworld/spriteprotocol,
  ctf/[glory, global, labels, sim]

const GameDir = currentSourcePath.parentDir.parentDir

proc initCtfForTest(config: GameConfig): SimServer =
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    result = initSimServer(config)
  finally:
    setCurrentDir(previousDir)

proc twoTeamGame(): SimServer =
  ## A started game: Red player 0, Blue player 1.
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue

proc redVsTwoBlue(): SimServer =
  ## Red player 0 facing two Blue players (1, 2) -- for scenarios that need a
  ## genuine multi-victim cone or blast, which a single-cog enemy team cannot
  ## supply.
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("blue0")
  discard result.addPlayer("blue1")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Blue
  result.players[2].team = Blue

proc twoRedOneBlue(): SimServer =
  ## Two Red teammates (0, 1) and one Blue (2) -- for scenarios that need a
  ## genuine FRIENDLY kill, which a single-cog team cannot supply.
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("red1")
  discard result.addPlayer("blue0")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Red
  result.players[2].team = Blue

proc twoRedTwoBlue(): SimServer =
  ## Red 0, Red 1 (teammates) vs Blue 2, Blue 3 -- for RESCUE/Second-Wind
  ## scenarios that need a rescuer, a rescued cog with its OWN separate kill
  ## to land, and a menacer distinct from both.
  result = initCtfForTest(defaultGameConfig())
  discard result.addPlayer("red0")
  discard result.addPlayer("red1")
  discard result.addPlayer("blue0")
  discard result.addPlayer("blue1")
  result.startGame()
  result.players[0].team = Red
  result.players[1].team = Red
  result.players[2].team = Blue
  result.players[3].team = Blue

proc noInput(sim: SimServer): seq[InputState] =
  newSeq[InputState](sim.players.len)

proc stepWith(sim: var SimServer, inputs, prev: seq[InputState]) =
  sim.step(inputs, prev)

proc chargeAndThrow(sim: var SimServer, playerIndex, holdTicks: int) =
  ## Holds C for holdTicks then releases -- the real grenade-throw input
  ## path, so the landing point, flight and blast all run through the actual
  ## engine rather than a hand-built `AirborneGrenade`.
  var held = sim.noInput()
  held[playerIndex].c = true
  var prev = sim.noInput()
  for _ in 0 ..< holdTicks:
    sim.stepWith(held, prev)
    prev = held
  sim.stepWith(sim.noInput(), prev)

proc viewerFrame(
  sim: var SimServer,
  state: GlobalViewerState,
  next: var GlobalViewerState
) =
  ## One spectator frame, built from the game dir so the board art resolves.
  ## The full board renderer loads data/ assets that a bare `initSimServer`
  ## never touches, so a test that skips the chdir dies on arena_floor.png.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    discard sim.buildSpriteProtocolUpdates(state, next)
  finally:
    setCurrentDir(previousDir)

proc spectatorFrameText(sim: var SimServer): string =
  ## One spectator frame, flattened to its ascii run. Only sprite LABELS are
  ## text on the wire (everything else is pixels), so this is what proves a
  ## board object actually shipped rather than merely being constructible.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  var
    state = initGlobalViewerState()
    next: GlobalViewerState
  var packet: seq[uint8]
  try:
    packet = sim.buildSpriteProtocolUpdates(state, next)
  finally:
    setCurrentDir(previousDir)
  for b in packet:
    result.add(if b >= 32'u8 and b < 127'u8: char(b) else: ' ')

proc playerFrameText(sim: var SimServer, playerIndex: int): string =
  ## The same flattening for a PLAYABLE seat's view -- the view a policy is
  ## actually shown.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  var
    state = initPlayerViewerState()
    next: PlayerViewerState
  var packet: seq[uint8]
  try:
    packet = sim.buildSpriteProtocolPlayerUpdates(playerIndex, state, next)
  finally:
    setCurrentDir(previousDir)
  for b in packet:
    result.add(if b >= 32'u8 and b < 127'u8: char(b) else: ' ')

suite "glory in the sim: the ladder is causal":

  test "a level actually changes what the cog can do":
    # The whole point of inverting Muster's ruling: levelling must grant real
    # power, not a cosmetic pip. Every REMAINING buff site must move. (v6,
    # GLORY C2: gun range is no longer one of them -- the +15% rung was
    # geometrically dead, always past the map's own diagonal, so it never
    # gated a single shot at any level; see `LevelGunRangePct`'s comment.)
    var sim = twoTeamGame()
    let
      baseWindup = sim.playerWindupTicks(0)
      baseCooldown = sim.playerFireCooldown(0)
      baseRange = sim.playerGunRange(0)
      baseHp = sim.playerMaxHp(0)
      baseCarry = sim.playerCarrierSpeedPct(0)

    sim.addXp(0, LevelThresholds[MaxLevel - 1])
    check sim.players[0].level == MaxLevel

    check sim.playerWindupTicks(0) < baseWindup
    check sim.playerFireCooldown(0) < baseCooldown
    check sim.playerGunRange(0) == baseRange         # retired (C2): dead reach
    check sim.playerMaxHp(0) > baseHp
    check sim.playerCarrierSpeedPct(0) > baseCarry   # the heart stops slowing you

  test "a level grants HEADROOM, never a free heal":
    # Otherwise a level-up is a full heal at the exact moment you are winning
    # a fight, which is the snowball the per-life reset is meant to bound.
    var sim = twoTeamGame()
    sim.players[0].hp = 1
    sim.addXp(0, LevelThresholds[MaxLevel - 1])
    check sim.playerMaxHp(0) > 3
    check sim.players[0].hp == 1     # still one hit from death

  test "death forfeits the entire ladder":
    # THE anti-snowball rule. A runaway cog is bounded to one life.
    var sim = twoTeamGame()
    sim.addXp(0, LevelThresholds[MaxLevel - 1])
    check sim.players[0].level == MaxLevel
    sim.killPlayer(0, 1, weapon = "gun")
    check sim.players[0].xp == 0
    check sim.players[0].level == 0
    check sim.playerWindupTicks(0) == sim.config.fireWindupTicks

  test "friendly fire de-levels the shooter":
    var sim = twoTeamGame()
    sim.players[1].team = Red        # now a teammate
    sim.addXp(0, LevelThresholds[0] + 5)
    check sim.players[0].level == 1
    sim.killPlayer(1, 0, weapon = "gun")
    check sim.players[0].level == 0
    check sim.teamGlory[Red] < 0     # and the team pays for the body

suite "glory in the sim: deeds are priced where they happen":

  test "the peel is priced apart from a plain kill":
    # The carrier kill is the highest-value defensive act in the game and is
    # invisible in every readout we own today. If the context were read AFTER
    # the flag-return loop it would price as a plain kill -- which is exactly
    # the bug this test exists to catch.
    var plain = twoTeamGame()
    plain.killPlayer(1, 0, weapon = "gun")
    let plainGlory = plain.teamGlory[Red]

    var peel = twoTeamGame()
    peel.flags[Red].carrier = 1
    peel.players[1].carryingFlag = true
    peel.killPlayer(1, 0, weapon = "gun")

    check peel.deedCounts[dCarrierKill] + peel.deedCounts[dDenial] == 1
    check peel.teamGlory[Red] > plainGlory

  test "first blood fires once and only once":
    var sim = twoTeamGame()
    sim.killPlayer(1, 0, weapon = "gun")
    check sim.deedCounts[dFirstBlood] == 1
    sim.players[1].alive = true
    sim.killPlayer(1, 0, weapon = "gun")
    check sim.deedCounts[dFirstBlood] == 1

  test "one kill mints exactly one kill-class deed":
    # The double-pay class: Muster re-paid a single combo ~390 times because
    # nothing cleared the event list.
    var sim = twoTeamGame()
    sim.killPlayer(1, 0, weapon = "spray")
    var killClass = 0
    for deed in [dHonorableKill, dSprayKill, dGrenadeKill, dPointBlankKill,
                 dLongshotKill, dSplashMultiKill, dRevengeKill, dRunDown,
                 dAceTag, dCarrierKill, dDenial, dTeamKill]:
      killClass += sim.deedCounts[deed]
    check killClass == 1

  test "killing a veteran pays the ace tag bounty":
    # The counter-play to the power fantasy has to be worth doing.
    var sim = twoTeamGame()
    sim.addXp(1, LevelThresholds[AceLevel - 1])
    check sim.players[1].level >= AceLevel
    sim.killPlayer(1, 0, weapon = "gun")
    check sim.deedCounts[dAceTag] == 1
    check sim.players[0].aceKills == 1   # the `Bounty` achievement gate

  test "the site gradient reads nearest pedestal, not an x-midline":
    # Every spawn address in this engine is a 2-team formula, so a home/away
    # rule written the obvious way is silently wrong on four bases.
    var sim = twoTeamGame()
    let redHome = sim.gameMap.flagHome(Red)
    let blueHome = sim.gameMap.flagHome(Blue)
    check sim.groundOwner(redHome.x, redHome.y) == Red
    check sim.groundOwner(blueHome.x, blueHome.y) == Blue
    # Initiative into defended ground pays more than defending your own.
    check sim.deedSitePct(Red, blueHome.x, blueHome.y) >
          sim.deedSitePct(Red, redHome.x, redHome.y)

suite "glory in the sim: the wipe deed":
  # `dWipe` is the largest single deed in the table (400g/400 drama) and once
  # shipped with ZERO mint sites -- `sim.deedCounts[dWipe]` was permanently 0,
  # exactly the dead-layer class this whole file exists to catch. These two
  # tests are the guard: the next deed that goes dead fails HERE instead of
  # sitting silent for months.

  test "eliminating the enemy's last life mints the wipe, once, at the site":
    var sim = twoTeamGame()
    sim.players[1].lives = 0        # this life is Blue's last
    sim.killPlayer(1, 0, weapon = "gun")     # Red eliminates Blue
    sim.checkWinCondition()

    check sim.phase == GameOver
    check sim.winner == Red
    check not sim.isDraw
    check sim.deedCounts[dWipe] == 1
    check sim.deedGloryMass[dWipe] > 0
    check sim.teamGlory[Red] >= sim.deedGloryMass[dWipe]

    # A second poll (the win-condition check runs every tick) must never
    # mint twice -- `finishGame`'s GameOver guard makes checkWinCondition a
    # no-op past the first resolve.
    sim.checkWinCondition()
    check sim.deedCounts[dWipe] == 1

  test "a mutual wipe is a draw -- neither side banks the 400g windfall":
    var sim = twoTeamGame()
    sim.players[0].lives = 0
    sim.players[1].lives = 0
    sim.killPlayer(1, 0, weapon = "gun")     # both fall on the same tick
    sim.killPlayer(0, 1, weapon = "gun")
    sim.checkWinCondition()

    check sim.phase == GameOver
    check sim.isDraw
    check sim.deedCounts[dWipe] == 0

suite "glory in the sim: the supply drop -- SUITE DROPPED (v1 port)":
  # GLORY PORT (GV46): every test in main's "the supply drop cannot be
  # farmed" suite exercised the supply-drop mechanic directly
  # (`sim.supplyDropPickups`, `SupplyDropCooldownTicks`, `SupplyDropXp`,
  # `SupplyDropMaxPerLife`, `player.supplyDropsThisLife`,
  # `sim.expireSupplyDrops()`, `LabelSupplyHalo`) -- none of which exist on
  # this port. v1 BR ships without the supply drop (glory.nim's own
  # header); there is no mechanic left for these tests to describe, so the
  # suite is dropped rather than stubbed to pass vacuously. Restoring it is
  # exactly the supply-drop follow-up work this port's report flags.
  discard


suite "glory in the sim: determinism and the audit":

  test "the ladder is in gameHash because it changes gameplay":
    # A replay that diverged on xp would desync, since level drives hit
    # points, fire timing and range.
    var a = twoTeamGame()
    var b = twoTeamGame()
    check a.gameHash() == b.gameHash()
    a.addXp(0, LevelThresholds[0])
    check a.gameHash() != b.gameHash()

  test "the ledger resets at the game boundary":
    var sim = twoTeamGame()
    sim.killPlayer(1, 0, weapon = "gun")
    check sim.teamGlory[Red] != 0
    sim.startGame()
    check sim.teamGlory[Red] == 0
    check sim.heatEmbers[Red] == 0
    check not sim.firstBloodDone
    # GLORY PORT: main also asserts `sim.supplyDropPickups.len == 0` here --
    # that field doesn't exist on this port (no supply drop, v1).

  test "heat climbs on a streak and cools when it stops":
    var sim = twoTeamGame()
    check heatMult(sim.heatEmbers[Red]) == 1
    for _ in 1 .. HeatThresholds[^1]:
      sim.players[1].alive = true
      sim.killPlayer(1, 0, weapon = "gun")
    check heatMult(sim.heatEmbers[Red]) == HeatLadder[^1]
    # Go quiet; the flames must bleed.
    let hot = sim.heatEmbers[Red]
    for _ in 1 .. HeatDecayTicks * 3:
      sim.tickCount += 1
      sim.heatCool()
    check sim.heatEmbers[Red] < hot

  test "AUDIT -- deeds that fire in a scripted episode":
    # Not a pass/fail bar, a READOUT: the accumulator that makes a dead layer
    # visible. A deed sitting at 0 here is either unreachable in this scenario
    # or dead code, and the two look identical without the number in front of
    # you.
    var sim = twoTeamGame()
    sim.flags[Red].carrier = 1
    sim.players[1].carryingFlag = true
    sim.killPlayer(1, 0, weapon = "gun")                 # a peel
    sim.players[1].alive = true
    sim.players[1].carryingFlag = false
    sim.flags[Red].carrier = -1
    sim.killPlayer(1, 0, weapon = "spray", multi = true) # a spray multikill
    sim.players[1].alive = true
    sim.addXp(0, LevelThresholds[AceLevel - 1])
    sim.players[0].hp = 1
    sim.tryPickupMedKits(0)

    echo ""
    echo "  deed                      fired   glory"
    echo "  ----------------------------------------"
    var totalMass = 0
    for deed in Deed:
      totalMass += sim.deedGloryMass[deed]
    for deed in Deed:
      if sim.deedCounts[deed] == 0:
        continue
      let share =
        if totalMass != 0: sim.deedGloryMass[deed] * 100 div totalMass else: 0
      echo "  ", deedName(deed).alignLeft(24), " ",
           ($sim.deedCounts[deed]).align(5), "   ",
           ($sim.deedGloryMass[deed]).align(5), "  (", share, "%)"
    echo "  team glory: Red ", sim.teamGlory[Red], "  Blue ", sim.teamGlory[Blue]
    echo ""

    # The scenario was built to exercise these, so a zero is a REAL failure.
    check sim.deedCounts[dCarrierKill] + sim.deedCounts[dDenial] > 0
    check sim.deedCounts[dSplashMultiKill] > 0
    check sim.deedCounts[dFirstBlood] == 1
    check sim.deedCounts[dLevelUp] > 0

suite "glory in the sim: every priced deed mints somewhere (fire-counter audit)":

  test "AUDIT -- every nonzero-priced deed is minted in a scripted scenario":
    # glory.nim section 8's rule, made an assertion rather than a readout: a
    # deed with a price and zero mint sites is dead code wearing a name, and
    # it is indistinguishable from a live one until something COUNTS. Every
    # deed below gets its own minimal, real-engine trigger; `seen` is proof it
    # actually fired, not a hand-set counter standing in for one.
    #
    # `dFlagReturn` is not here: it no longer exists in the enum. The
    # tombstone comment on `Deed` (glory.nim) is the record of why it was
    # retired instead of wired -- every path that can return a heart traces
    # back to either a kill (already priced as dCarrierKill/dDenial) or a
    # non-act (disconnect / stale index) with no honest earner to credit.
    var seen: array[Deed, int]
    template mark(sim: SimServer) =
      for deed in Deed:
        seen[deed] += sim.deedCounts[deed]

    # dFirstBlood (stacks on the episode's first kill) + dHonorableKill (a
    # plain gun kill at mid-range: clear of both PointBlankPx and LongshotPx).
    block:
      var sim = twoTeamGame()
      sim.players[0].x = 300
      sim.players[0].y = 300
      sim.players[1].x = 600
      sim.players[1].y = 300
      sim.killPlayer(1, 0, weapon = "gun")
      mark(sim)

    # dSprayKill
    block:
      var sim = twoTeamGame()
      sim.players[0].x = 300
      sim.players[0].y = 300
      sim.players[1].x = 600
      sim.players[1].y = 300
      sim.killPlayer(1, 0, weapon = "spray")
      mark(sim)

    # dGrenadeKill
    block:
      var sim = twoTeamGame()
      sim.players[0].x = 300
      sim.players[0].y = 300
      sim.players[1].x = 600
      sim.players[1].y = 300
      sim.killPlayer(1, 0, weapon = "grenade")
      mark(sim)

    # dPointBlankKill
    block:
      var sim = twoTeamGame()
      sim.players[0].x = 300
      sim.players[0].y = 300
      sim.players[1].x = 300 + PointBlankPx - 10
      sim.players[1].y = 300
      sim.killPlayer(1, 0, weapon = "gun")
      mark(sim)

    # dLongshotKill
    block:
      var sim = twoTeamGame()
      sim.players[0].x = 100
      sim.players[0].y = 300
      sim.players[1].x = 100 + LongshotPx + 10
      sim.players[1].y = 300
      sim.killPlayer(1, 0, weapon = "gun")
      mark(sim)

    # dRevengeKill: the killer answers the cog that killed them, in-window.
    block:
      var sim = twoTeamGame()
      sim.players[0].x = 300
      sim.players[0].y = 300
      sim.players[1].x = 600
      sim.players[1].y = 300
      sim.players[0].lastKilledBy = 1
      sim.players[0].lastKilledByTick = sim.tickCount
      sim.killPlayer(1, 0, weapon = "gun")
      mark(sim)

    # dRunDown: the victim's velocity is opening the gap.
    block:
      var sim = twoTeamGame()
      sim.players[0].x = 300
      sim.players[0].y = 300
      sim.players[1].x = 600
      sim.players[1].y = 300
      sim.players[1].velX = 50
      sim.killPlayer(1, 0, weapon = "gun")
      mark(sim)

    # dAceTag: a level>=AceLevel victim.
    block:
      var sim = twoTeamGame()
      sim.players[0].x = 300
      sim.players[0].y = 300
      sim.players[1].x = 600
      sim.players[1].y = 300
      sim.addXp(1, LevelThresholds[AceLevel - 1])
      sim.killPlayer(1, 0, weapon = "gun")
      mark(sim)

    # dTeamKill: a friendly kill.
    block:
      var sim = twoRedOneBlue()
      sim.killPlayer(1, 0, weapon = "gun")
      mark(sim)

    # dCarrierKill: the victim carries, far from their OWN home.
    block:
      var sim = twoTeamGame()
      let farHome = sim.gameMap.flagHome(Red)   # far from Blue's own home
      sim.flags[Red].carrier = 1
      sim.players[1].carryingFlag = true
      sim.players[1].x = farHome.x
      sim.players[1].y = farHome.y
      sim.killPlayer(1, 0, weapon = "gun")
      mark(sim)

    # dDenial: the victim carries, inside DenialPx of their OWN home.
    block:
      var sim = twoTeamGame()
      let ownHome = sim.gameMap.flagHome(Blue)
      sim.flags[Red].carrier = 1
      sim.players[1].carryingFlag = true
      sim.players[1].x = ownHome.x
      sim.players[1].y = ownHome.y
      sim.killPlayer(1, 0, weapon = "gun")
      mark(sim)

    # dEscortKill: a kill lands while a TEAMMATE (not the killer) carries.
    block:
      var sim = twoRedOneBlue()      # Red 0, Red 1, Blue 2
      sim.flags[Blue].carrier = 1    # Red 1 (a teammate of the killer) runs it
      sim.players[1].carryingFlag = true
      sim.players[0].x = 300
      sim.players[0].y = 300
      sim.players[2].x = 600
      sim.players[2].y = 300
      sim.killPlayer(2, 0, weapon = "gun")    # Red 0 kills Blue while Red 1 carries
      mark(sim)

    # dSplashMultiKill
    block:
      var sim = twoTeamGame()
      sim.killPlayer(1, 0, weapon = "gun", multi = true)
      mark(sim)

    # dFlagSteal
    block:
      var sim = twoTeamGame()
      sim.players[0].x = sim.flags[Blue].x
      sim.players[0].y = sim.flags[Blue].y
      sim.tryPickupFlags(0)
      mark(sim)

    # dCapture: a live carrier inside their own capture zone.
    block:
      var sim = twoTeamGame()
      let home = sim.gameMap.flagHome(Red)
      sim.flags[Blue].carrier = 0
      sim.players[0].carryingFlag = true
      sim.players[0].x = home.x
      sim.players[0].y = home.y
      sim.checkWinCondition()
      mark(sim)

    # dClutchHeal
    block:
      var sim = twoTeamGame()
      sim.players[0].hp = 1
      sim.players[0].x = sim.medKitSpawns[0].x
      sim.players[0].y = sim.medKitSpawns[0].y
      sim.tryPickupMedKits(0)
      mark(sim)

    # dShieldSoak
    block:
      var sim = twoTeamGame()
      sim.players[0].hasShield = true
      sim.players[0].shieldHp = 3
      sim.absorbDamage(0, 3)
      mark(sim)

    # dWipe
    block:
      var sim = twoTeamGame()
      sim.players[1].lives = 0
      sim.killPlayer(1, 0, weapon = "gun")
      sim.checkWinCondition()
      mark(sim)

    # dLevelUp
    block:
      var sim = twoTeamGame()
      sim.addXp(0, LevelThresholds[0])
      mark(sim)

    # dAchievement
    block:
      var sim = twoTeamGame()
      sim.phase = Playing
      sim.players[0].gunKills = 1
      sim.evalAchievements(Red)
      mark(sim)

    var missing: seq[string]
    for deed in Deed:
      if deed == dNone:
        continue
      if deedGlory(deed) == 0 and deedDrama(deed) == 0:
        continue          # priced at nothing: not this test's business
      if seen[deed] == 0:
        missing.add deedName(deed)
    if missing.len > 0:
      echo "  DEAD DEED(S): ", missing.join(", ")
    check missing.len == 0

suite "glory in the sim: the achievement curriculum FIRES":

  test "tier I claims on the mechanic, once, and only once":
    var sim = twoTeamGame()
    sim.players[0].gunKills = 1        # v3 tier I: First Tag (a gun kill)
    sim.phase = Playing
    sim.evalAchievements(Red)
    check sim.claimed[Red][achievementKey(treeGun, 0)]
    let firstCount = sim.deedCounts[dAchievement]
    # Law 1: one-shot per team per game. Polling a satisfied requirement
    # again must be a no-op, or the claim becomes per-tick income.
    for _ in 1 .. 50:
      sim.evalAchievements(Red)
    check sim.deedCounts[dAchievement] == firstCount

  test "every team can earn it; only the FIRST claimant takes the x3 -- AND ONLY AT TIER V":
    # Law 2. A first-only reward teaches the other teams nothing, so the base
    # must reach everyone. v9 (GLORY LAW E4): the race itself is now
    # restricted to the LAST tier of a tree -- driven here on `treeGun`'s
    # tier V ("Longshot", `longshotKills >= 1`), not tier 0 any more, since
    # tier 0-3 can never read as first at all (see the next test).
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.players[0].longshotKills = 1
    sim.evalAchievements(Red)
    let redGlory = sim.teamGlory[Red]
    sim.players[1].longshotKills = 1
    sim.evalAchievements(Blue)
    check sim.claimed[Blue][achievementKey(treeGun, 4)]
    check sim.teamGlory[Blue] > 0                 # Blue still earns
    check sim.teamGlory[Blue] < redGlory          # but Red took the x3
    check sim.achievementFeed[0].first
    check not sim.achievementFeed[1].first

  test "GLORY LAW E4 -- tiers I-IV NEVER race, no matter who gets there first":
    # The FIRST cap: only tier V (index AchievementTiers-1) of each tree can
    # ever read `first: true` or take `AchievementFirstMultPct`. Driven here
    # on `treeGun` tier 0 ("First Tag") -- Red claims it entirely ALONE
    # (no Blue claim exists to "lose" a race to) and still must NOT read as
    # first, because the race itself does not exist at this tier.
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.players[0].gunKills = 1
    sim.evalAchievements(Red)
    check sim.claimed[Red][achievementKey(treeGun, 0)]
    check sim.achievementFeed.len == 1
    check not sim.achievementFeed[0].first
    check sim.achievementFeed[0].glory == tierGlory(0)   # base price, no x3

  test "a genuine SAME-TICK tie pays FIRST to both teams, not enum order":
    # C10's gap: the naive `for team in Team: evalAchievements(team)` marked
    # `claimedFirst` as it went, so when both teams completed a tier on the
    # SAME tick the x3 went to Red purely because Team's enum order puts Red
    # first -- a systematic bias, not a real "who got there first". The fix
    # is `evalAchievementsAllTeams`, which snapshots every team's satisfied
    # tiers BEFORE any team claims. This test drives that exact path: both
    # teams satisfy Longshot (tree V -- the ONE tier that can ever race,
    # GLORY LAW E4) on the identical tick via ONE evalAchievementsAllTeams()
    # call, and both must read as first.
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.players[0].longshotKills = 1   # Red satisfies Longshot...
    sim.players[1].longshotKills = 1   # ...and so does Blue, same tick.
    sim.evalAchievementsAllTeams()
    check sim.claimed[Red][achievementKey(treeGun, 4)]
    check sim.claimed[Blue][achievementKey(treeGun, 4)]
    check sim.achievementFeed.len == 2
    var redFirst, blueFirst = false
    for claim in sim.achievementFeed:
      if claim.tree == treeGun and claim.tier == 4:
        if claim.team == Red: redFirst = claim.first
        if claim.team == Blue: blueFirst = claim.first
    check redFirst
    check blueFirst
    # And the glory minted must actually match -- both took the x3, not one
    # of them quietly paid base while still flagged `first` on the wire.
    check sim.teamGlory[Red] == sim.teamGlory[Blue]

  test "an achievement never climbs the heat ladder":
    # Law 4. Only combat drama lights flames.
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.players[0].gunKills = 1
    sim.evalAchievements(Red)
    check sim.deedCounts[dAchievement] > 0
    check sim.heatEmbers[Red] == 0

  test "the tiers escalate in what they actually pay":
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.players[0].gunKills = 3        # First Tag (>=1) AND Marksman (>=3)
    sim.evalAchievements(Red)
    var tier0, tier1 = 0
    for claim in sim.achievementFeed:
      if claim.tree == treeGun and claim.tier == 0: tier0 = claim.glory
      if claim.tree == treeGun and claim.tier == 1: tier1 = claim.glory
    check tier0 > 0
    check tier1 > tier0

  test "AUDIT -- every tree and tier is REACHABLE":
    # THE test this whole port exists for. Muster shipped five reward layers
    # that never fired; a requirement no scenario can satisfy is the same
    # dead code wearing a name. Drive one cog to satisfy everything, then
    # assert all 40 claimed -- an unreachable tier fails HERE, loudly,
    # instead of silently paying nothing in the field forever.
    #
    # v3: no tier below reads a pickup/possession flag any more (law 2b), so
    # the old `tookX`/`hasX`/hp-trick simulation is gone -- every tier is now
    # driven straight off the counter it actually gates on.
    var sim = twoTeamGame()
    sim.phase = Playing
    # Deed clocks are absolute ticks, so the scenario has to sit far enough
    # into a game that "200 ticks ago" is a real tick and not a negative one.
    sim.tickCount = 1200
    sim.players[0].gunKills = 6
    sim.players[0].longshotKills = 1
    sim.players[0].aceKills = 1         # Bounty
    sim.players[0].sprayKills = 2
    sim.players[0].sprayKillsThisPickup = 3
    sim.players[0].sprayMultiKills = 1       # Double Splash
    sim.players[0].grenadeKills = 3
    sim.players[0].grenadeMultiKills = 2     # Blast Radius (>=1) AND the
                                             # v7 Double Blast (>=2: TWO
                                             # multi-kill blasts, E4)
                                              # (reuses sprayMultiKills/
                                              # grenadeMultiKills -- see the
                                              # gate's comment)
    sim.players[0].kills = 1
    # v9 (GLORY LAW E2/E3): The Provider (re-founded treeMedKit) and the
    # teamwork tree (re-founded treeShield) counters. `clutchHeals`/
    # `soakedHp` are DELIBERATELY left at their zero default here -- the
    # golden-law test below asserts they gate NOTHING, and this AUDIT
    # scenario is the natural place that would have caught it if they still
    # did (the old soak-threshold `treeShield` would have failed to claim at
    # all under this exact scenario).
    # GLORY PORT (GV46): main also drives `supplyShared = 6`/`supplySaves = 2`
    # here (treeMedKit: First Delivery/Regular Route/Supply Chain/Clutch
    # Delivery/Emergency Route) -- neither field exists on this port
    # (treeMedKit is UNREACHABLE without the supply drop; see glory.nim's
    # header and `satisfiedAchievements`' own GLORY-PORT-TODO). The tree's
    # 5 tiers, and the squad tree's two `kits >= 4` tiers that need
    # treeMedKit's leg to ever reach 4, are excluded from this test's
    # "every tier reachable" assertion below instead of asserted here.
    sim.players[0].assists = 1               # Cover Fire
    sim.players[0].escortKills = 1           # Escort Duty
    sim.players[0].rescues = 1               # The Save
    sim.players[0].secondWind = true         # Second Wind, re-gated (set at
                                              # the kill site off
                                              # `rescuedTick` in the real
                                              # engine; see the dedicated
                                              # real-mechanic test below)
    sim.squadVolleyDone[Red] = true          # Squad Volley (team-wide; set
                                              # once by `recordTeamKillRing`
                                              # in the real engine)
    sim.players[0].contestedSteals = 1       # Hands On
    sim.players[0].carryKills = 1            # Fighting Carry
    sim.players[0].carrierKills = 2          # The Peel + Double Peel
    sim.players[0].denials = 2
    sim.players[0].captures = 1
    sim.players[0].capturedOutnumbered = true  # Uphill (v6, GLORY C3b: set
                                                # ONCE at recordCapture in the
                                                # real engine -- see the
                                                # dedicated real-mechanic
                                                # test below -- not re-read
                                                # from live alive-counts here)
    sim.players[0].capturedFastBreak = true    # Fast Break (v8, GLORY FAST
                                                # BREAK wave: set ONCE at
                                                # recordCapture in the real
                                                # engine off this life's own
                                                # stealTickThisLife delta --
                                                # see the dedicated real-
                                                # mechanic test below)
    sim.players[0].level = MaxLevel
    sim.players[0].stealTickThisLife = sim.tickCount - 200  # also drives Turnaround below
    sim.players[0].peelTick = sim.tickCount - 300
    sim.evalAchievements(Red)

    # Clean Sheet is FULL-GAME and conclusion-only (v3): no per-tick poll,
    # however many times run above, can ever claim it -- `finishGame` is its
    # one mint site. Red has taken no team kills anywhere in this scenario,
    # so a clean conclusion claims it here, and only here.
    check not sim.claimed[Red][achievementKey(treeSquad, 3)]
    sim.finishGame(Red)

    echo ""
    echo "  achievement                        tier  glory  first"
    echo "  ---------------------------------------------------"
    for claim in sim.achievementFeed:
      echo "  ", achievementName(claim.tree, claim.tier).alignLeft(34),
           " ", ($(claim.tier + 1)).align(3),
           "  ", ($claim.glory).align(5),
           "  ", (if claim.first: "yes" else: "-")
    echo "  claimed ", sim.achievementFeed.len, " of ",
         AchievementTrees * AchievementTiers,
         "   achievement glory: ", sim.deedGloryMass[dAchievement]
    echo ""

    # GLORY-PORT-TODO: `treeMedKit` (all 5 tiers) and the squad tree's two
    # `kits >= 4` tiers (II, V) are KNOWN-unreachable on this port -- see
    # this test's own comment above and `satisfiedAchievements`'s header.
    # Excluded from the "every tier reachable" bar rather than silently
    # weakening it: everything else in the curriculum (35 of 40 tiers)
    # still has to claim, or this fails loudly exactly as main's version
    # would.
    var missing: seq[string]
    for tree in Tree:
      for tier in 0 ..< AchievementTiers:
        if tree == treeMedKit:
          continue
        if tree == treeSquad and tier in [2, 4]:
          continue
        if not sim.claimed[Red][achievementKey(tree, tier)]:
          missing.add achievementName(tree, tier)
    if missing.len > 0:
      echo "  UNREACHABLE: ", missing.join(", ")
    check missing.len == 0

suite "glory in the sim: THE GOLDEN LAW -- no gate reads a self-care counter":
  # v9 (GLORYVERSION 9 WAVE, LAW AUDIT E7). Maxwell's re-affirmed law:
  # achievements and glory reward play ABOVE AND BEYOND normal, never
  # self-benefiting acts. A WHOLE TREE (the old `treeShield`, self-heal
  # `treeMedKit`) was caught violating it this wave -- `clutchHeals`
  # (healing YOURSELF) and `soakedHp` (a shield that protects ONLY its
  # wearer, per this wave's own ground truth) are the two counters that
  # class of violation reads. This test does not restate the achievement
  # gates from the outside (a second copy that could drift the same way a
  # stale comment already did) -- it DRIVES the real `evalAchievements` path
  # and asserts these two counters, ALONE, satisfy NOTHING, so a future
  # self-care gate fails HERE, loudly, forever, instead of waiting for
  # another human audit.
  test "clutchHeals and soakedHp, pumped to an absurd value, claim NOTHING":
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.players[0].clutchHeals = 999
    sim.players[0].soakedHp = 999
    sim.evalAchievements(Red)
    check sim.achievementFeed.len == 0
    for tree in Tree:
      for tier in 0 ..< AchievementTiers:
        check not sim.claimed[Red][achievementKey(tree, tier)]

  test "the same is true team-wide: a squad soaked and self-healed to the sky converts NO kit":
    # `teamConvertedKits` used to read `clutchHeals`/`soakedHp` directly for
    # its "med"/"shield" booleans -- the team tree laundering the same
    # self-care counters into a TEAM achievement even after the individual
    # trees were fixed. Both booleans now require a genuinely OTHER-facing
    # fact (`supplyShared`/`assists`), so this must stay at 0/4, not 2/4.
    var sim = twoRedOneBlue()   # Red 0, Red 1 -- a genuine TEAM, not a lone cog.
    sim.phase = Playing
    sim.players[0].clutchHeals = 999
    sim.players[0].soakedHp = 999
    sim.players[1].clutchHeals = 999
    sim.players[1].soakedHp = 999
    sim.evalAchievements(Red)
    check not sim.claimed[Red][achievementKey(treeSquad, 0)]  # Kitted (>=2/4)

suite "glory in the sim: the v3 counters fire off REAL engine mechanics":
  # The AUDIT above proves the PREDICATES read the right counters; it sets
  # every counter directly, the same shortcut the pre-v3 file always used.
  # That is not enough for the three counters this rewrite invented -- a
  # per-activation tally is exactly the shape of bug the double-count
  # warning in glory.nim's task brief called out, so these drive the REAL
  # engine paths (a real cone, a real blast, a real pickup) end to end.

  # The left capture column (x < 210) is protected floor -- never walled --
  # so arc-fire tests anchor the attacker there for guaranteed line of
  # sight, the same trick test_plasma_arc.nim uses.
  let
    ClearX = 60
    ClearY = MapHeight div 2

  test "a genuine one-activation spray double kill fires Double Splash once":
    var sim = redVsTwoBlue()
    sim.players[0].x = ClearX
    sim.players[0].y = ClearY
    sim.players[0].aimBrads = 0                # east
    sim.players[0].hasSprayPaint = true
    sim.players[1].x = ClearX + 40
    sim.players[1].y = ClearY
    sim.players[1].hp = 1
    sim.players[2].x = ClearX + 80
    sim.players[2].y = ClearY
    sim.players[2].hp = 1
    sim.tryFireArc(0)
    check not sim.players[1].alive
    check not sim.players[2].alive
    check sim.players[0].sprayMultiKills == 1
    check sim.deedCounts[dSplashMultiKill] >= 1
    # And a THIRD enemy in the same activation must not double-count it: a
    # triple activation is still exactly one Double Splash.
    var triple = redVsTwoBlue()
    discard triple.addPlayer("blue2")
    triple.players[3].team = Blue
    triple.players[0].x = ClearX
    triple.players[0].y = ClearY
    triple.players[0].aimBrads = 0
    triple.players[0].hasSprayPaint = true
    for i in [1, 2, 3]:
      triple.players[i].x = ClearX + 30 * i
      triple.players[i].y = ClearY
      triple.players[i].hp = 1
    triple.tryFireArc(0)
    check not triple.players[1].alive
    check not triple.players[2].alive
    check not triple.players[3].alive
    check triple.players[0].sprayMultiKills == 1

  test "a genuine one-blast grenade double kill fires Double Blast once":
    var sim = redVsTwoBlue()
    sim.players[0].x = 300
    sim.players[0].y = 300
    sim.players[0].aimBrads = 0                # east
    sim.players[0].hasGrenade = true
    sim.players[1].x = 300 + GrenadeMaxRange
    sim.players[1].y = 300
    sim.players[1].hp = GrenadeDamage
    sim.players[2].x = 300 + GrenadeMaxRange
    sim.players[2].y = 300 + 10                # inside GrenadeBlastRadius
    sim.players[2].hp = GrenadeDamage
    sim.chargeAndThrow(0, GrenadeChargeTicks)
    check sim.airborneGrenades.len == 1
    let flight = sim.airborneGrenades[0].flightTicks
    let prev = sim.noInput()
    for _ in 0 .. flight:
      sim.stepWith(sim.noInput(), prev)
    check not sim.players[1].alive
    check not sim.players[2].alive
    check sim.players[0].grenadeMultiKills == 1
    check sim.deedCounts[dSplashMultiKill] >= 1   # grenade multikills share the deed

  test "GLORY LAW E2 -- TEST DROPPED (v1 port, no supply drop)":
    # GLORY PORT (GV46): main's "a TEAMMATE consuming a supply drop fires
    # supplyShared/supplySaves on the DROPPER" drove `supplyDropPickups`/
    # `tryPickupSupplyDrops`/`SupplyDropXp`/`SupplyDropCycle` end to end --
    # none of which exist on this port (no supply drop, v1; see glory.nim's
    # header). `supplyShared`/`supplySaves` themselves, and the achievement
    # tree they gate (`treeMedKit`), are consequently UNREACHABLE here too
    # (see the AUDIT test above). Dropped, not stubbed against a mechanic
    # that doesn't exist -- restoring this is exactly the supply-drop
    # follow-up work this port's report flags.
    discard

suite "glory in the sim: the v3.1 counters fire off REAL engine mechanics":
  # v3.1 re-cut treeCarrier tier I/II off possession (CURRICULUM audit
  # C1/C8) and fixed Second Wind's missing order check (C6/C7). Same rule as
  # the v3 suite above: drive the REAL engine path, with a negative control,
  # rather than trusting a hand-set counter to mean what its gate claims.

  test "a steal next to a live enemy fires the CONTESTED counter; an unguarded one does not":
    var contested = twoTeamGame()
    contested.players[1].x = contested.flags[Blue].x + 10
    contested.players[1].y = contested.flags[Blue].y
    contested.players[0].x = contested.flags[Blue].x
    contested.players[0].y = contested.flags[Blue].y
    contested.tryPickupFlags(0)
    check contested.players[0].carryingFlag
    check contested.players[0].contestedSteals == 1

    # The same steal, but the enemy is far away: an uncontested walk-in.
    var alone = twoTeamGame()
    alone.players[1].x = 0
    alone.players[1].y = 0
    alone.players[0].x = alone.flags[Blue].x
    alone.players[0].y = alone.flags[Blue].y
    check distSq(alone.players[0].x, alone.players[0].y,
                 alone.players[1].x, alone.players[1].y) >
          ContestedStealPx * ContestedStealPx
    alone.tryPickupFlags(0)
    check alone.players[0].carryingFlag
    check alone.players[0].steals == 1        # still a steal...
    check alone.players[0].contestedSteals == 0   # ...but not a contested one

    # A DEAD nearby enemy does not manufacture a contest either.
    var deadNearby = twoTeamGame()
    deadNearby.players[1].x = deadNearby.flags[Blue].x + 10
    deadNearby.players[1].y = deadNearby.flags[Blue].y
    deadNearby.players[1].alive = false
    deadNearby.players[0].x = deadNearby.flags[Blue].x
    deadNearby.players[0].y = deadNearby.flags[Blue].y
    deadNearby.tryPickupFlags(0)
    check deadNearby.players[0].contestedSteals == 0

  test "a kill while carrying fires Fighting Carry; the same kill unarmed does not":
    var carrying = twoTeamGame()
    carrying.flags[Blue].carrier = 0
    carrying.players[0].carryingFlag = true
    carrying.killPlayer(1, 0, weapon = "gun")
    check carrying.players[0].carryKills == 1

    var unarmed = twoTeamGame()
    unarmed.killPlayer(1, 0, weapon = "gun")
    check unarmed.players[0].carryKills == 0

  test "GLORY LAW E3 -- ASSIST credits the SET-UP, never the finisher or a self-hit":
    # A real gunfight: Blue 2 wounds Red 0's target first (a survived hit,
    # non-lethal), then Red 1 lands the actual kill. `lastDamagedBy` on the
    # victim must name Blue 2 -- wait, ASSIST is about CREDITING a teammate
    # of the KILLER, so this drives it the other way: two REDS damage one
    # BLUE, a different Red finishes it.
    var sim = twoRedTwoBlue()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    sim.players[2].x = cx        # Blue 2, the eventual victim
    sim.players[2].y = cy
    sim.players[2].hp = 2
    sim.players[0].x = cx - 20   # Red 0: deals the SET-UP hit
    sim.players[0].y = cy
    sim.players[0].aimBrads = 0
    sim.players[0].fireCooldown = 0
    sim.resolveSimultaneousFire([0])
    check sim.players[2].alive
    check sim.players[2].hp == 1
    check sim.players[2].lastDamagedBy == 0

    # Red 1 lands the finishing blow -- a DIFFERENT teammate, inside the
    # window: credits Red 0 with the assist, never Red 1 (who already banked
    # the kill deed) and never Blue 2 itself.
    sim.tickCount += 5
    sim.killPlayer(2, 1, weapon = "gun")
    check sim.players[0].assists == 1
    check sim.players[1].assists == 0

    # A SOLO kill (the same cog dealt every hit) must not self-credit: the
    # killer's own prior hit is exactly what `lastDamagedBy`'s "not the
    # finisher" gate is for.
    var solo = twoRedTwoBlue()
    solo.players[3].x = cx
    solo.players[3].y = cy
    solo.players[3].hp = 2
    solo.players[1].x = cx - 20
    solo.players[1].y = cy
    solo.players[1].aimBrads = 0
    solo.players[1].fireCooldown = 0
    solo.resolveSimultaneousFire([1])
    check solo.players[3].alive
    solo.killPlayer(3, 1, weapon = "gun")
    check solo.players[1].assists == 0

  test "GLORY LAW E3 -- RESCUE credits the killer, and re-gated Second Wind arms the RESCUED cog, not the rescuer":
    # RE-GATED (was treeMedKit's self-heal Second Wind, retired with the rest
    # of that tree): "get rescued, then land a kill of your own" now, driven
    # end to end through the real damage-site `menacingTick` pin and the real
    # `killPlayer` RESCUE/Second-Wind logic -- not hand-set counters.
    var sim = twoRedTwoBlue()
    let cx = sim.gameMap.center.x
    let cy = sim.gameMap.center.y
    # Blue 2 menaces Red 0: one real gunshot that leaves Red 0 alive, at
    # exactly ClutchHpThreshold.
    sim.players[0].x = cx - 20        # Red 0 (about to be menaced)
    sim.players[0].y = cy
    sim.players[0].hp = ClutchHpThreshold + 1
    sim.players[2].x = cx + 20        # Blue 2 (the menacer)
    sim.players[2].y = cy
    sim.players[2].aimBrads = 128     # west, toward Red 0
    sim.players[2].fireCooldown = 0
    sim.resolveSimultaneousFire([2])
    check sim.players[0].alive
    check sim.players[0].hp == ClutchHpThreshold
    check sim.players[2].menacingTick == sim.tickCount
    check sim.players[2].menacingVictim == 0

    # Red 1 answers: kills Blue 2 inside RescueWindowTicks. Credits Red 1
    # with a rescue, and pins `rescuedTick` on Red 0 -- the cog who was
    # ACTUALLY in danger, never the rescuer.
    sim.tickCount += 10
    sim.killPlayer(2, 1, weapon = "gun")
    check sim.players[1].rescues == 1
    check sim.players[0].rescuedTick == sim.tickCount
    check not sim.players[1].secondWind    # the RESCUER wasn't rescued

    # Red 0, the RESCUED cog, lands its OWN kill inside SecondWindTicks --
    # THIS arms Second Wind, and only for Red 0.
    sim.tickCount += 5
    sim.killPlayer(3, 0, weapon = "gun")
    check sim.players[0].secondWind
    check not sim.players[1].secondWind

    # A rescue OUTSIDE RescueWindowTicks (the menace is stale) must not
    # credit anything.
    var stale = twoRedTwoBlue()
    stale.players[0].x = cx - 20
    stale.players[0].y = cy
    stale.players[0].hp = ClutchHpThreshold + 1
    stale.players[2].x = cx + 20
    stale.players[2].y = cy
    stale.players[2].aimBrads = 128
    stale.players[2].fireCooldown = 0
    stale.resolveSimultaneousFire([2])
    check stale.players[2].menacingTick == stale.tickCount
    stale.tickCount += RescueWindowTicks + 1
    stale.killPlayer(2, 1, weapon = "gun")
    check stale.players[1].rescues == 0
    check stale.players[0].rescuedTick == -1

  test "GLORY LAW E3 -- SQUAD VOLLEY needs 3+ DISTINCT teammates, not one cog farming kills":
    # A team-wide fact: no single cog can trigger it alone, however many
    # kills they personally land.
    var solo = redVsTwoBlue()
    solo.killPlayer(1, 0, weapon = "gun")
    solo.players[1].alive = true
    solo.killPlayer(1, 0, weapon = "gun")
    solo.players[1].alive = true
    solo.killPlayer(1, 0, weapon = "gun")
    check not solo.squadVolleyDone[Red]     # three kills, ONE killer: no volley

    # Three DIFFERENT teammates, each with a kill inside the window: fires.
    var volley = twoRedTwoBlue()
    discard volley.addPlayer("red2")
    volley.players[4].team = Red
    volley.killPlayer(2, 0, weapon = "gun")
    volley.players[2].alive = true
    volley.killPlayer(2, 1, weapon = "gun")
    volley.players[2].alive = true
    volley.killPlayer(2, 4, weapon = "gun")
    check volley.squadVolleyDone[Red]

  test "a capture while outnumbered fires Uphill; an even capture does not":
    # v6 (GLORY C3b): capturedOutnumbered is PINNED at recordCapture, so this
    # drives the real steal -> carry -> checkWinCondition path rather than
    # setting the flag by hand, the same discipline every other real-
    # mechanic test in this suite already holds itself to.
    var outnumbered = redVsTwoBlue()   # Red 1 body, Blue 2 -- Red is behind
    let redHome = outnumbered.gameMap.flagHome(Red)
    outnumbered.flags[Blue].carrier = 0
    outnumbered.players[0].carryingFlag = true
    outnumbered.players[0].x = redHome.x
    outnumbered.players[0].y = redHome.y
    outnumbered.checkWinCondition()
    check outnumbered.players[0].captures == 1
    check outnumbered.players[0].capturedOutnumbered

    # The identical capture, but the sides are EVEN (1v1): must NOT claim.
    var even = twoTeamGame()
    let evenHome = even.gameMap.flagHome(Red)
    even.flags[Blue].carrier = 0
    even.players[0].carryingFlag = true
    even.players[0].x = evenHome.x
    even.players[0].y = evenHome.y
    even.checkWinCondition()
    check even.players[0].captures == 1
    check not even.players[0].capturedOutnumbered

  test "a capture within FastBreakTicks of the steal fires Fast Break; a slower one does not":
    # v8 (GLORY FAST BREAK wave): capturedFastBreak is PINNED at
    # recordCapture off THIS life's own stealTickThisLife, so this drives the
    # real checkWinCondition path rather than setting the flag by hand, the
    # same discipline the Uphill test above holds itself to. The steal itself
    # is not what's under test here (Uphill's own test bypasses
    # `tryPickupFlags` the same way) -- what's under test is the pin's delta
    # arithmetic, so `stealTickThisLife` is set directly to a controlled
    # tick, mirroring how Uphill controls `teamAliveCount` via roster shape
    # rather than driving a real fight.
    var fast = twoTeamGame()
    fast.tickCount = 1000
    fast.players[0].stealTickThisLife = fast.tickCount - 200  # delta 200 < FastBreakTicks (240)
    let fastHome = fast.gameMap.flagHome(Red)
    fast.flags[Blue].carrier = 0
    fast.players[0].carryingFlag = true
    fast.players[0].x = fastHome.x
    fast.players[0].y = fastHome.y
    fast.checkWinCondition()
    check fast.players[0].captures == 1
    check fast.players[0].capturedFastBreak

    # The identical capture, but the steal happened 300 ticks ago -- past the
    # window. Must NOT claim.
    var slow = twoTeamGame()
    slow.tickCount = 1000
    slow.players[0].stealTickThisLife = slow.tickCount - 300  # delta 300 > FastBreakTicks (240)
    let slowHome = slow.gameMap.flagHome(Red)
    slow.flags[Blue].carrier = 0
    slow.players[0].carryingFlag = true
    slow.players[0].x = slowHome.x
    slow.players[0].y = slowHome.y
    slow.checkWinCondition()
    check slow.players[0].captures == 1
    check not slow.players[0].capturedFastBreak

suite "glory in the sim: Clean Sheet is full-game, conclusion-only":

  test "the per-tick poll can never claim it, at tick 599 or anywhere else":
    # v3's whole point: `satisfiedAchievements` never reports this tier, so
    # no amount of polling -- at the OLD tick>=600 threshold or past it --
    # can claim it, however clean the team actually is.
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.tickCount = 599
    for _ in 1 .. 50:
      sim.evalAchievementsAllTeams()
      inc sim.tickCount
    check not sim.claimed[Red][achievementKey(treeSquad, 3)]
    check not sim.claimed[Blue][achievementKey(treeSquad, 3)]

  test "a clean team claims it at conclusion; a dirty team never does":
    var sim = twoRedOneBlue()
    sim.killPlayer(1, 0, weapon = "gun")   # Red 0 backstabs Red 1: a real team kill
    sim.recordTeamKill(0, 1)      # the counter every real call site pairs it with
    check sim.players[0].teamKills == 1
    sim.finishGame(Blue)
    check not sim.claimed[Red][achievementKey(treeSquad, 3)]    # Red is dirty
    check sim.claimed[Blue][achievementKey(treeSquad, 3)]       # Blue is clean

    # And the loser can bank it too -- Clean Sheet is not a winner's prize.
    var loser = twoRedOneBlue()
    loser.killPlayer(1, 0, weapon = "gun")
    loser.recordTeamKill(0, 1)
    loser.finishGame(Blue)         # Red loses; Blue, the clean team, wins
    check not loser.claimed[Red][achievementKey(treeSquad, 3)]

  test "both teams clean at the same conclusion both claim -- NEITHER reads first (GLORY LAW E4)":
    # v9 (GLORY LAW E4): Clean Sheet is tier IV (index 3), not tier V -- the
    # FIRST race no longer reaches it at all, so this same-tick tie now
    # resolves as "both claim, both at base price," not "both take the x3."
    var sim = twoTeamGame()
    sim.finishGame(Red)
    check sim.claimed[Red][achievementKey(treeSquad, 3)]
    check sim.claimed[Blue][achievementKey(treeSquad, 3)]
    var redFirst, blueFirst = true   # default true so a missing claim fails loud
    for claim in sim.achievementFeed:
      if claim.tree == treeSquad and claim.tier == 3:
        if claim.team == Red: redFirst = claim.first
        if claim.team == Blue: blueFirst = claim.first
    check not redFirst
    check not blueFirst
    check sim.teamGlory[Red] == sim.teamGlory[Blue]   # both paid base, equally

suite "glory in the sim: the hover inspector -- SUITE DROPPED (v1 port)":
  # GLORY PORT (GV46): main's hover-inspector suite drives
  # `sim.inspectorLines(playerIndex)` -- a spectator/UI tooltip-text
  # generator (rank name, buffs, per-weapon deed counters, the team
  # ledger, achievement claims, supply-drop tap) that does not exist on
  # this port. This is the same "FX pop RENDERING is out of scope" line
  # this port's report draws elsewhere: the ENGINE-side data
  # (`teamGlory`/`player.xp`/`player.level`/`deedCounts`/`achievementFeed`)
  # is all live and hashed; `inspectorLines` itself, and everywhere it
  # would live (global.nim has zero glory references on this lineage,
  # confirmed by grep), is a client/rendering-layer port this pass did
  # not reach. Dropped, not stubbed against an undeclared proc.
  discard


suite "glory observer -- SUITE DROPPED (v1 port)":
  # GLORY PORT (GV46): main's `gloryObserver` dev rig (a spectator-only lens
  # that replays a PRE-glory recording with the ledger overlaid as pure
  # accounting -- no buff lands, physics reads base) is NOT ported: it
  # exists to keep old, pre-glory recordings replayable, and there is no
  # pre-glory BR recording for it to protect (GV46 is glory's FIRST BR
  # appearance). `SimServer` carries no `gloryObserver` field here (see
  # sim_types.nim's own GLORY PORT block). The suite's own name called
  # this rig "deletable scaffolding"; dropped on the same terms, not
  # stubbed to pass vacuously against a field that doesn't exist.
  discard

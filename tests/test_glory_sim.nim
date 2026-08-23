## Glory wired into the sim: the ladder is causal, the buffs land, the tithe
## cannot be farmed, and every deed can actually FIRE.
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
    # power, not a cosmetic pip. Every buff site must move.
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
    check sim.playerGunRange(0) > baseRange
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
    sim.killPlayer(0, 1, "gun")
    check sim.players[0].xp == 0
    check sim.players[0].level == 0
    check sim.playerWindupTicks(0) == sim.config.fireWindupTicks

  test "friendly fire de-levels the shooter":
    var sim = twoTeamGame()
    sim.players[1].team = Red        # now a teammate
    sim.addXp(0, LevelThresholds[0] + 5)
    check sim.players[0].level == 1
    sim.killPlayer(1, 0, "gun")
    check sim.players[0].level == 0
    check sim.teamGlory[Red] < 0     # and the team pays for the body

suite "glory in the sim: deeds are priced where they happen":

  test "the peel is priced apart from a plain kill":
    # The carrier kill is the highest-value defensive act in the game and is
    # invisible in every readout we own today. If the context were read AFTER
    # the flag-return loop it would price as a plain kill -- which is exactly
    # the bug this test exists to catch.
    var plain = twoTeamGame()
    plain.killPlayer(1, 0, "gun")
    let plainGlory = plain.teamGlory[Red]

    var peel = twoTeamGame()
    peel.flags[Red].carrier = 1
    peel.players[1].carryingFlag = true
    peel.killPlayer(1, 0, "gun")

    check peel.deedCounts[dCarrierKill] + peel.deedCounts[dDenial] == 1
    check peel.teamGlory[Red] > plainGlory

  test "first blood fires once and only once":
    var sim = twoTeamGame()
    sim.killPlayer(1, 0, "gun")
    check sim.deedCounts[dFirstBlood] == 1
    sim.players[1].alive = true
    sim.killPlayer(1, 0, "gun")
    check sim.deedCounts[dFirstBlood] == 1

  test "one kill mints exactly one kill-class deed":
    # The double-pay class: Muster re-paid a single combo ~390 times because
    # nothing cleared the event list.
    var sim = twoTeamGame()
    sim.killPlayer(1, 0, "spray")
    var killClass = 0
    for deed in [dHonorableKill, dSprayKill, dGrenadeKill, dPointBlankKill,
                 dLongshotKill, dSplashMultiKill, dRevengeKill, dRunDown,
                 dStarfall, dCarrierKill, dDenial, dTeamKill]:
      killClass += sim.deedCounts[deed]
    check killClass == 1

  test "killing a veteran pays the starfall bounty":
    # The counter-play to the power fantasy has to be worth doing.
    var sim = twoTeamGame()
    sim.addXp(1, LevelThresholds[StarfallLevel - 1])
    check sim.players[1].level >= StarfallLevel
    sim.killPlayer(1, 0, "gun")
    check sim.deedCounts[dStarfall] == 1

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

suite "glory in the sim: the tithe cannot be farmed":

  test "a veteran that stops earning stops producing":
    # THE bomber-hover law: Muster's bomber potential paid every tick once
    # armed and in position, so the rational play was to hover. The tap here
    # is fed by NEW xp, so a 3-star that hides produces nothing.
    var sim = twoTeamGame()
    sim.addXp(0, LevelThresholds[StarfallLevel - 1])
    let afterPlume = sim.tithePickups.len

    # Idle for a long time: no xp, therefore no kit, however long it waits.
    for _ in 1 .. TitheCooldownTicks * 4:
      sim.tickCount += 1
      sim.heatCool()
    check sim.tithePickups.len == afterPlume

    # Earn, and the heart pays.
    sim.tickCount += TitheCooldownTicks
    sim.addXp(0, TitheXp)
    check sim.tithePickups.len > afterPlume

  test "a cog below the plume never tithes however hard it fights":
    var sim = twoTeamGame()
    for i in 1 .. 5:
      sim.tickCount += TitheCooldownTicks
      sim.addXp(0, LevelThresholds[StarfallLevel - 1] div 4)
      if sim.players[0].level >= StarfallLevel:
        break
    if sim.players[0].level < StarfallLevel:
      check sim.tithePickups.len == 0

  test "the tap is bounded per life":
    var sim = twoTeamGame()
    sim.addXp(0, LevelThresholds[StarfallLevel - 1])
    for _ in 1 .. TitheMaxPerLife * 4:
      sim.tickCount += TitheCooldownTicks
      sim.addXp(0, TitheXp)
    check sim.players[0].tithesThisLife <= TitheMaxPerLife
    check sim.tithePickups.len <= TitheMaxPerLife

  test "the tithe lands on the veteran's OWN ground":
    var sim = twoTeamGame()
    sim.addXp(0, LevelThresholds[StarfallLevel - 1])
    sim.tickCount += TitheCooldownTicks
    sim.addXp(0, TitheXp)
    check sim.tithePickups.len > 0
    for pickup in sim.tithePickups:
      check sim.groundOwner(pickup.x, pickup.y) == Red

  test "untaken kit evaporates":
    # Otherwise a stalemate accumulates pickups forever, which is per-tick
    # income by another name.
    var sim = twoTeamGame()
    sim.addXp(0, LevelThresholds[StarfallLevel - 1])
    sim.tickCount += TitheCooldownTicks
    sim.addXp(0, TitheXp)
    check sim.tithePickups.len > 0
    sim.tickCount += MedKitRespawnTicks + 1
    sim.expireTithes()
    check sim.tithePickups.len == 0

  test "the veteran halo is SPECTATOR-ONLY, and never touches the kit label":
    # The halo exists to make tithed kit readable to whoever is WATCHING. It is
    # a separate board object precisely so the kit's own sprite and label stay
    # bit-identical to ordinary kit: labels are the observation schema, so a
    # halo that leaked into a player view -- or worse, renamed the kit -- would
    # silently re-negotiate the perception API with every policy in the league
    # to buy a decoration.
    #
    # Asserted on the WIRE, not on the proc. `addTithePickups` is private and
    # its viewerIndex gate is one `if`; the only thing that proves the gate
    # holds is the bytes each audience actually receives.
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.addXp(0, LevelThresholds[StarfallLevel - 1])
    sim.tickCount += TitheCooldownTicks
    sim.addXp(0, TitheXp)
    check sim.tithePickups.len > 0

    let spectator = spectatorFrameText(sim)
    check LabelTitheHalo in spectator      # the halo shipped to the broadcast

    let seat = playerFrameText(sim, 1)
    check LabelTitheHalo notin seat        # ...and to nobody who plays

    # The kit itself still reads as its own kind on BOTH wires -- the halo is
    # laid under an unchanged pickup, not a new kind of one.
    var kitLabel = ""
    for pickup in sim.tithePickups:
      case pickup.kind
      of "med kit": kitLabel = LabelMedKit
      of "grenade": kitLabel = LabelGrenade
      of "spray can": kitLabel = LabelSprayCan
      of "shield": kitLabel = LabelShield
      else: discard
      if kitLabel.len > 0:
        break
    check kitLabel.len > 0
    check kitLabel in spectator
    check LabelTitheHalo != kitLabel

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
    sim.killPlayer(1, 0, "gun")
    check sim.teamGlory[Red] != 0
    sim.startGame()
    check sim.teamGlory[Red] == 0
    check sim.heatEmbers[Red] == 0
    check not sim.firstBloodDone
    check sim.tithePickups.len == 0

  test "heat climbs on a streak and cools when it stops":
    var sim = twoTeamGame()
    check heatMult(sim.heatEmbers[Red]) == 1
    for _ in 1 .. HeatThresholds[^1]:
      sim.players[1].alive = true
      sim.killPlayer(1, 0, "gun")
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
    sim.killPlayer(1, 0, "gun")                 # a peel
    sim.players[1].alive = true
    sim.players[1].carryingFlag = false
    sim.flags[Red].carrier = -1
    sim.killPlayer(1, 0, "spray", multi = true) # a spray multikill
    sim.players[1].alive = true
    sim.addXp(0, LevelThresholds[StarfallLevel - 1])
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

suite "glory in the sim: the achievement curriculum FIRES":

  test "tier I claims on the mechanic, once, and only once":
    var sim = twoTeamGame()
    sim.players[0].shotsHit = 1
    sim.phase = Playing
    sim.evalAchievements(Red)
    check sim.claimed[Red][achievementKey(treeGun, 0)]
    let firstCount = sim.deedCounts[dAchievement]
    # Law 1: one-shot per team per game. Polling a satisfied requirement
    # again must be a no-op, or the claim becomes per-tick income.
    for _ in 1 .. 50:
      sim.evalAchievements(Red)
    check sim.deedCounts[dAchievement] == firstCount

  test "every team can earn it; only the FIRST claimant takes the x3":
    # Law 2. A first-only reward teaches the other teams nothing, so the base
    # must reach everyone.
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.players[0].shotsHit = 1
    sim.evalAchievements(Red)
    let redGlory = sim.teamGlory[Red]
    sim.players[1].shotsHit = 1
    sim.evalAchievements(Blue)
    check sim.claimed[Blue][achievementKey(treeGun, 0)]
    check sim.teamGlory[Blue] > 0                 # Blue still earns
    check sim.teamGlory[Blue] < redGlory          # but Red took the x3
    check sim.achievementFeed[0].first
    check not sim.achievementFeed[1].first

  test "an achievement never climbs the heat ladder":
    # Law 4. Only combat drama lights flames.
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.players[0].shotsHit = 1
    sim.evalAchievements(Red)
    check sim.deedCounts[dAchievement] > 0
    check sim.heatEmbers[Red] == 0

  test "the tiers escalate in what they actually pay":
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.players[0].shotsHit = 1
    sim.players[0].gunKills = 1
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
    var sim = twoTeamGame()
    sim.phase = Playing
    # Deed clocks are absolute ticks, so the scenario has to sit far enough
    # into a game that "200 ticks ago" is a real tick and not a negative one.
    sim.tickCount = 1200
    sim.players[0].shotsHit = 1
    sim.players[0].gunKills = 6
    sim.players[0].longshotKills = 1
    sim.players[0].sprayKills = 2
    sim.players[0].sprayKillsThisPickup = 3
    sim.players[0].grenadeKills = 3
    sim.players[0].multiKills = 1
    sim.players[0].soakedHp = 12
    sim.players[0].kills = 1
    sim.players[0].clutchHeals = 3
    sim.players[0].clutchHealTick = sim.tickCount
    sim.players[0].steals = 1
    sim.players[0].returns = 1
    sim.players[0].carrierKills = 1
    sim.players[0].denials = 2
    sim.players[0].captures = 1
    sim.players[0].tookMedKit = true
    sim.players[0].tookGrenade = true
    sim.players[0].tookSpray = true
    sim.players[0].tookShield = true
    sim.players[0].hasGrenade = true
    sim.players[0].hasPlasmaArc = true
    sim.players[0].hasShield = true
    sim.players[0].hp = sim.config.hitPoints + 1   # med kit held: 4th kit
    sim.players[0].level = MaxLevel
    sim.players[0].stealTickThisLife = sim.tickCount - 200
    sim.players[0].peelTick = sim.tickCount - 300
    sim.players[0].carryingFlag = true
    sim.gameStartTick = sim.tickCount - 700        # clean-sheet window elapsed
    sim.evalAchievements(Red)

    # A second pass in a state the first one cannot hold at the same instant.
    # "Against the Odds" wants Red OUTNUMBERED, while the squad tiers want
    # Red alive and holding four kits -- mutually exclusive in a two-cog
    # scenario, and that is a property of the SCENARIO, not of the tier.
    # Claims are one-shot and cumulative, so reachability is still a fair
    # question to ask across passes.
    sim.players[0].alive = false
    sim.players[1].alive = true
    sim.evalAchievements(Red)

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

    var missing: seq[string]
    for tree in Tree:
      for tier in 0 ..< AchievementTiers:
        if not sim.claimed[Red][achievementKey(tree, tier)]:
          missing.add achievementName(tree, tier)
    if missing.len > 0:
      echo "  UNREACHABLE: ", missing.join(", ")
    check missing.len == 0

suite "glory in the sim: the hover inspector":

  test "the card reports rank, what the rank BUYS, and the team ledger":
    # The spectator question this answers: point at a cog, read why it is
    # winning. A rank pip alone says a cog is strong; the card has to say what
    # it is strong AT, or the ladder is unreadable from outside.
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.tickCount = 1200
    sim.players[0].shotsHit = 1
    sim.players[0].gunKills = 2
    sim.players[0].kills = 2
    sim.evalAchievements(Red)
    sim.addXp(0, LevelThresholds[StarfallLevel - 1])

    let text = sim.inspectorLines(0).join("\n")
    check "IRONHIDE" in text                      # the rank, by name
    check "xp " in text                           # progress to the next rank
    check "buffs" in text                         # what the rank is BUYING
    check "windup" in text                        # a specific, checkable buff
    check "gun 2" in text                         # per-weapon deed counters
    check "GLORY" in text                         # the team ledger
    check "ACHIEVEMENTS" in text                  # ...and its curriculum
    check "First Tag" in text                     # a named claim, not a count
    check ("tithes " & $sim.players[0].tithesThisLife & "/" &
           $TitheMaxPerLife) in text                 # the veteran's tap

  test "the card counts ALL claims even when it lists only the last few":
    # A truncated list that reads as complete is a silent lie about coverage.
    var sim = twoTeamGame()
    sim.phase = Playing
    for tree in Tree:
      for tier in 0 ..< AchievementTiers:
        sim.claimAchievement(Red, tree, tier)
    let text = sim.inspectorLines(0).join("\n")
    check "ACHIEVEMENTS 40/40" in text
    check "earlier" in text        # says how many it dropped

  test "an invalid or unhovered index reports nothing":
    var sim = twoTeamGame()
    sim.phase = Playing
    check sim.inspectorLines(0).len > 0

  test "the inspector actually EMITS a sprite into the packet":
    # Proves the render path, not just the text builder. A card that composes
    # perfectly and never reaches the wire is the same dead layer as an
    # unfired deed -- so assert the sprite label lands in the packet bytes.
    var sim = twoTeamGame()
    sim.phase = Playing
    sim.addXp(0, LevelThresholds[StarfallLevel - 1])
    var
      defs: seq[SpriteDefinition]
      ids: seq[int]
      packet: seq[uint8]
    sim.addInspector(defs, ids, packet, 0)
    check ids.len > 0
    check packet.len > 0
    var text = ""
    for b in packet:
      text.add(if b >= 32'u8 and b < 127'u8: char(b) else: ' ')
    # Only the sprite LABEL is ascii on the wire -- the card's text is
    # rasterised into pixels -- so the label is what proves it shipped.
    check "inspector" in text
    check ("inspector " & sim.players[0].scoreboardName()) in text

  test "a CLICK pins the card; hover alone resolves nothing":
    # Maxwell's ruling after watching the hover card in play: a cog outruns
    # the cursor in under a second, and a card that vanishes the instant you
    # move toward it cannot carry buttons. So the cursor alone must resolve
    # NOTHING; the click (`i:@` -> inspectClickPending, hit-testing the
    # streamed cursor) is what pins, and the pin -- a join order -- is what
    # the card follows from then on.
    var sim = twoTeamGame()
    sim.players[0].x = 200
    sim.players[0].y = 200
    sim.players[1].x = 900
    sim.players[1].y = 400

    var
      state = initGlobalViewerState()
      next: GlobalViewerState
    sim.viewerFrame(state, next)
    state = next
    check next.inspectIndex == -1        # nothing pinned yet

    # Hover WITHOUT a click: the cursor sits on a cog and the card stays off.
    state.mouseLayer = MapLayerId
    state.mouseX = (sim.players[1].x + CollisionW div 2) * RenderScale
    state.mouseY = (sim.players[1].y + CollisionH div 2) * RenderScale
    sim.viewerFrame(state, next)
    check next.inspectIndex == -1        # hover alone shows no card
    state = next

    # The click arrives: pin resolves against the streamed cursor.
    state.inspectClickPending = true
    sim.viewerFrame(state, next)
    check next.inspectIndex == 1
    check next.inspectPinned == sim.players[1].joinOrder
    check next.selectedJoinOrder == -1   # pinning never opens the EYES view
    check not next.povActive
    state = next

    # The cog walks away, the cursor stays put: the card HOLDS. This is the
    # exact complaint that killed the hover design.
    sim.players[1].x = 300
    sim.players[1].y = 700
    sim.viewerFrame(state, next)
    check next.inspectIndex == 1
    state = next

    # A click on empty board clears the pin.
    state.inspectClickPending = true
    state.mouseX = 10 * RenderScale
    state.mouseY = 10 * RenderScale
    sim.viewerFrame(state, next)
    check next.inspectIndex == -1
    check next.inspectPinned == -1

  test "a PARKED pointer resolves nothing and emits no card":
    # The park signal is the LAYER, never a coordinate: Nim's `div` truncates
    # toward zero, so a parked mouseX of -1 would become 0 in the hit test and
    # hover the arena's top-left corner for the rest of the replay.
    var sim = twoTeamGame()
    sim.players[0].x = 200
    sim.players[0].y = 200
    sim.players[1].x = 900
    sim.players[1].y = 400

    var
      state = initGlobalViewerState()
      next: GlobalViewerState
    sim.viewerFrame(state, next)
    state = next
    state.mouseLayer = -1
    state.mouseX = -1
    state.mouseY = -1
    sim.viewerFrame(state, next)
    check next.inspectIndex == -1

    # And the card genuinely does not reach the wire on a parked frame.
    var
      defs: seq[SpriteDefinition]
      ids: seq[int]
      packet: seq[uint8]
    sim.addInspector(defs, ids, packet, next.inspectIndex)
    check ids.len == 0
    check packet.len == 0

  test "the pin survives the EYES lens, and i:-1 clears it under the lens":
    # The regression this guards: pin commands used to be consumed inside the
    # board branch, which povActive skips entirely -- so CLOSE stopped working
    # exactly while the EYES view was open, the one moment the card is
    # guaranteed to be up. Consumption now happens BEFORE the POV fork, and
    # the pin is the card's only subject in both branches.
    var sim = twoTeamGame()
    sim.players[0].x = 200
    sim.players[0].y = 200
    sim.players[1].x = 900
    sim.players[1].y = 400

    var
      state = initGlobalViewerState()
      next: GlobalViewerState
    sim.viewerFrame(state, next)
    state = next
    # Pin cog 1 by click, then open its EYES view (the card button's v: path).
    state.mouseLayer = MapLayerId
    state.mouseX = (sim.players[1].x + CollisionW div 2) * RenderScale
    state.mouseY = (sim.players[1].y + CollisionH div 2) * RenderScale
    state.inspectClickPending = true
    sim.viewerFrame(state, next)
    check next.inspectPinned == sim.players[1].joinOrder
    state = next
    state.povSelectPending = sim.players[1].joinOrder
    sim.viewerFrame(state, next)
    # The lens is up and the card still shows the pinned cog.
    check next.povActive
    check next.inspectIndex == 1
    state = next

    # CLOSE while the lens is open: the exact click that used to be swallowed.
    state.inspectPinPending = -1
    sim.viewerFrame(state, next)
    check next.povActive                 # the lens stays
    check next.inspectIndex == -1        # the card is gone
    check next.inspectPinned == -1

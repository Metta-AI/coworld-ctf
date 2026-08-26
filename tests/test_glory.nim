## Glory economy laws. These are ASSERTIONS AGAINST THE TABLE, not restatements
## of it: every check below is a property that must hold for ANY pricing, so a
## re-tune that breaks a law fails here instead of in the field.
##
## Each law cites the failure that bought it. Muster's ledger of reward-economy
## mistakes (`.muster/knowledge/experiments/failed.md`) is the source for most
## of them; a few are ours.

import
  std/unittest,
  ctf/glory

suite "glory: deed pricing":

  test "every deed is priced, or it is dead weight in the catalog":
    # Muster shipped five reward layers that never fired, each plausible in
    # review (`unit.glory` on a type that has no `glory`; a spacing check on
    # `.pos` for units that carry `.x`/`.y`). The banked rule is that a layer
    # must be PROVEN to carry a value, never assumed. A deed worth neither
    # glory nor drama cannot ever matter, so it must not be in the enum.
    #
    # `dClutchHeal` is exempted too, as of v9 (GLORY LAW E1): ZERO+
    # TOMBSTONED on purpose (self-heal is never above-and-beyond), not an
    # oversight -- see its own comment on `Deed`. Unlike `dFlagReturn`
    # (fully deleted, the ORIGINAL member of this exemption class), this one
    # stays in the enum and its mint site stays wired, deliberately worth
    # nothing, so this is the one place that has to know it is exempt on
    # purpose rather than reading as an accidental dead deed.
    for deed in Deed:
      if deed in {dNone, dAchievement, dClutchHeal}:
        continue  # dNone is the null; dAchievement is tier-priced; dClutchHeal
                  # is the intentional zero+tombstone above.
      check (deedGlory(deed) != 0 or deedDrama(deed) != 0)

  test "penalties are negative and stay negative":
    check deedGlory(dTeamKill) < 0
    check XpTeamKill < 0

  test "the objective line outprices the combat line":
    # Paintbot is not Muster. A kill here is only ~16% banked, one life saved
    # is worth 5.6 kills made, and a death costs 3.4x a kill. So capture,
    # denial and the peel must all outprice a plain kill, or the table is
    # telling policies to farm bodies — which is the thing we already do.
    check deedGlory(dCapture) > deedGlory(dHonorableKill)
    check deedGlory(dDenial) > deedGlory(dHonorableKill)
    check deedGlory(dCarrierKill) > deedGlory(dHonorableKill)
    # Kills level NOBODY (Maxwell's ruling: work levels -- damage, healing,
    # tools, flag play). The carrier kill is the one exception, priced as the
    # RETURN it causes, so it must still pay -- as a flag action.
    check killXp(KillContext(victimCarrying: true)) == XpPerReturn
    check killXp(KillContext()) == 0

  test "a plain kill is the floor of the kill class":
    for deed in [dSprayKill, dGrenadeKill, dPointBlankKill, dLongshotKill,
                 dSplashMultiKill, dRevengeKill, dRunDown, dAceTag]:
      check deedGlory(deed) >= deedGlory(dHonorableKill)

  test "passive deeds carry zero drama":
    # Muster's live telemetry had passive deeds at 93-100% of all glory. A
    # deed that funds you without being a moment must price at zero drama so
    # that mass cannot leak into the watched game as correlated noise.
    check deedDrama(dShieldSoak) == 0
    check not isDrama(dShieldSoak)
    # Friendly fire is anti-drama: it costs glory and must never light heat.
    check deedDrama(dTeamKill) == 0
    check not paysHeat(dTeamKill)

suite "glory: one kill, one deed":

  test "a friendly kill can never be dressed up as a highlight":
    # The precedence exists so that a kill satisfying five descriptions mints
    # once. Friendly fire outranks every flattering description there is.
    var ctx = KillContext(
      friendly: true, victimCarrying: true, nearVictimHome: true,
      victimLevel: 5, multi: true, rangePx: PointBlankPx, avengesKiller: true,
      fleeing: true, weaponSpray: true
    )
    check killDeed(ctx) == dTeamKill
    check killXp(ctx) < 0

  test "the objective context outranks the shot":
    # What the victim was DOING is worth more than how they were shot.
    var ctx = KillContext(victimCarrying: true, rangePx: 10, weaponSpray: true)
    check killDeed(ctx) == dCarrierKill
    ctx.nearVictimHome = true
    check killDeed(ctx) == dDenial

  test "a kill resolves to exactly one deed for every context":
    # Exhaustive over the boolean context: the point is that `killDeed` is
    # total and single-valued, so no combination can ever mint twice. This is
    # the double-pay bug class -- Muster re-paid one combo ~390 times because
    # nothing cleared the event list, and that was the entire reward-magnitude
    # explosion a normalisation constant had been masking.
    var seen: array[Deed, int]
    for friendly in [false, true]:
      for carrying in [false, true]:
        for home in [false, true]:
          for lvl in [0, AceLevel]:
            for multi in [false, true]:
              for rng in [10, 400, LongshotPx + 10]:
                for avenge in [false, true]:
                  for flee in [false, true]:
                    let ctx = KillContext(
                      friendly: friendly, victimCarrying: carrying,
                      nearVictimHome: home, victimLevel: lvl, multi: multi,
                      rangePx: rng, avengesKiller: avenge, fleeing: flee)
                    let deed = killDeed(ctx)
                    check deed != dNone
                    inc seen[deed]
    # And the precedence must be REACHABLE: a branch nobody can hit is the
    # same dead code as an unfired reward layer.
    for deed in [dTeamKill, dDenial, dCarrierKill, dAceTag, dSplashMultiKill,
                 dLongshotKill, dPointBlankKill, dRevengeKill, dRunDown,
                 dHonorableKill]:
      check seen[deed] > 0

suite "glory: the heat ladder":

  test "flames cost a streak, not a kill apiece":
    # Muster's scar: +1 rung per deed pinned the WHOLE server at max flames
    # (measured heat_sum 14.7 = everyone maxed) because three kills bought x8.
    check heatMult(0) == 1
    check heatMult(1) == 1      # ONE deed is an incident, not a streak (v5)
    check heatMult(2) == 2
    check heatMult(4) == 2      # still climbing, not yet x4
    check heatMult(5) == 4
    check heatMult(10) == 8

  test "the ember cap bounds the multiplier":
    check heatMult(HeatEmberCap) == HeatLadder[^1]
    check heatMult(HeatEmberCap * 100) == HeatLadder[^1]

  test "heat cannot be hoarded past the cap":
    # No streak may bank a multiplier it has stopped earning.
    check HeatEmberCap <= HeatThresholds[^1] + HeatEmberDecay

suite "glory: the mint":

  test "a penalty takes no multiplier from any source":
    # A team on a rampage must not pay eight times for a friendly kill, and a
    # penalty must never be cheaper on home ground.
    let raw = deedGlory(dTeamKill)
    check mintGlory(dTeamKill, 12, SiteMultEnemyPct, true) == raw
    check mintGlory(dTeamKill, 0, SiteMultHomePct, false) == raw

  test "the site gradient pays initiative into defended ground":
    let home = mintGlory(dHonorableKill, 0, SiteMultHomePct, false)
    let neutral = mintGlory(dHonorableKill, 0, SiteMultNeutralPct, false)
    let enemy = mintGlory(dHonorableKill, 0, SiteMultEnemyPct, false)
    check home < neutral
    check neutral < enemy

  test "possession lights a multiplier, it never pays income":
    # The `trophy_held` lesson: a per-tick possession reward always gets
    # farmed, so carrying pays only when the carrying team actually fights.
    let idle = mintGlory(dNone, 0, SiteMultNeutralPct, true)
    check idle == 0
    let fighting = mintGlory(dHonorableKill, 0, SiteMultNeutralPct, true)
    let notCarrying = mintGlory(dHonorableKill, 0, SiteMultNeutralPct, false)
    check fighting > notCarrying

  test "achievements never climb heat":
    check not paysHeat(dAchievement)
    # ...and take the site gradient plus the first-claim bonus, nothing else.
    check mintAchievement(4, SiteMultHomePct, false) == TierGlory[4]
    check mintAchievement(4, SiteMultHomePct, true) == TierGlory[4] * 3

suite "glory: the achievement curriculum":

  test "law 3 -- big enough to chase, too small to win on":
    # Muster states law 3 against a MEDIAN WINNER's match glory. We have no
    # measured median for paintbot yet, and inventing the denominator would be
    # the "ship-gate thresholds asserted from guesses" mistake -- a guessed
    # bar can be too easy or too hard and you cannot tell which without a
    # known-answer reference.
    #
    # So assert the DERIVED form, which needs no guess: sweeping the ENTIRE
    # curriculum must be worth less than winning the game outright. That is
    # exactly what "too small to win on" means, and every term comes from the
    # table itself.
    var sweep = 0
    for tier in 0 ..< AchievementTiers:
      sweep += tierGlory(tier) * AchievementTrees
    check sweep < deedGlory(dCapture) + deedGlory(dWipe)

    # And no single achievement may rival the win condition it sits beside.
    check tierGlory(AchievementTiers - 1) < deedGlory(dCapture)

  test "every tree has a full set of named tiers":
    for tree in Tree:
      for tier in 0 ..< AchievementTiers:
        check achievementName(tree, tier).len > 0

  test "achievement keys are unique across the curriculum":
    var seen: seq[int]
    for tree in Tree:
      for tier in 0 ..< AchievementTiers:
        let key = achievementKey(tree, tier)
        check key notin seen
        seen.add key
    check seen.len == AchievementTrees * AchievementTiers

  test "tiers escalate in both currencies":
    for tier in 1 ..< AchievementTiers:
      check tierGlory(tier) > tierGlory(tier - 1)
      check tierDrama(tier) >= tierDrama(tier - 1)

suite "glory: the per-life ladder":

  test "level is monotonic in xp and never dips mid-life":
    var previous = 0
    for xp in 0 .. LevelThresholds[^1] + 50:
      let level = levelForXp(xp)
      check level >= previous
      check level <= MaxLevel
      previous = level

  test "the thresholds make L5 rare and L1 reachable":
    # Work-based sources, fit to the real field (gloryscore.py): an active
    # life peaks at p50=9 / p90=21 / p99=45 xp.
    check levelForXp(XpPerPickup) == 0             # one pickup is not a star
    check levelForXp(XpPerSteal) >= 1              # a steal is
    check levelForXp(XpPerCapture + XpPerSteal + XpPerDamage * 3) >= MaxLevel - 2
    check levelForXp(60) == MaxLevel               # a legendary life is

  test "friendly fire de-levels a cog":
    # The one place the ladder bites back. A cog that kills a teammate must
    # be able to LOSE a level it had earned.
    let earned = LevelThresholds[0] + 5
    check levelForXp(earned) == 1
    check levelForXp(earned + XpTeamKill) == 0

  test "buffs are floored so no rung can break the gunfight":
    # A zero windup deletes the peek-and-duck read the whole gunfight is
    # built on; a zero cooldown fires every tick.
    for level in 0 .. MaxLevel:
      check levelWindupTicks(5, level) >= 1
      check levelFireCooldown(12, level) >= 1
      check levelSprayReset(20, level) >= 1
      check levelGunRange(1300, level) >= 1300
      check levelMaxHp(3, level) >= 3
      check levelGrenadeCharges(level) >= 1

  test "no rung is a pure stat bump -- each buys a distinct capability":
    # Balance-audit rubric: a levelled cog should PLAY differently, not just
    # harder. Every level must change at least one capability its predecessor
    # did not have.
    for level in 1 .. MaxLevel:
      let changed =
        levelWindupTicks(5, level) != levelWindupTicks(5, level - 1) or
        levelGunRange(1300, level) != levelGunRange(1300, level - 1) or
        levelMaxHp(3, level) != levelMaxHp(3, level - 1) or
        levelFireCooldown(12, level) != levelFireCooldown(12, level - 1) or
        levelSprayReset(20, level) != levelSprayReset(20, level - 1) or
        levelGrenadeCharges(level) != levelGrenadeCharges(level - 1) or
        levelCarrierSpeedPct(70, level) != levelCarrierSpeedPct(70, level - 1)
      check changed

  test "no effective-power outlier above ~2x":
    # Muster's balance rubric: balance EFFECTIVE power (stats x multipliers),
    # never raw stats, and hold every unit inside ~2x of another in its
    # intended matchup. Effective power here ~ survivability x throughput x
    # reach, in hundredths.
    proc power(level: int): int =
      let
        hp = levelMaxHp(3, level)
        shotTicks = levelFireCooldown(12, level) + levelWindupTicks(5, level)
        baseShot = 12 + 5
        rng = levelGunRange(1300, level)
      # survivability x rate x reach, all relative to a recruit.
      (hp * 100 div 3) * (baseShot * 100 div shotTicks) div 100 *
        (rng * 100 div 1300) div 100

    let recruit = power(0)
    let legend = power(MaxLevel)
    check legend * 100 div recruit <= 220

  test "a L5 cog stays inside the hp band policies already read":
    # A shield carrier shows 6 hp and that is how a policy detects its own
    # shield. A levelled cog must not collide with that reading.
    check levelMaxHp(3, MaxLevel) < 6

suite "glory: the supply drop cannot be farmed":

  test "a hiding veteran produces nothing":
    # THE bomber-hover law, applied. Muster's bomber potential paid 1-3 per
    # tick forever once armed and positioned -- "a rational agent farms the
    # shaping by hovering." The banked rule: the potential must FLATLINE once
    # preconditions are met, and real reward comes only from the action.
    #
    # Our tap is fed by NEW XP, so simulate the exploit directly: a cog that
    # reaches the plume and then earns nothing for the rest of the episode.
    proc supplyDropsFor(xpEarnedAfterPlume: int): int =
      ## Pickups produced by a cog at AceLevel that goes on to earn
      ## `xpEarnedAfterPlume` more xp.
      min(xpEarnedAfterPlume div SupplyDropXp, SupplyDropMaxPerLife)

    check supplyDropsFor(0) == 0          # hides forever: earns nothing
    check supplyDropsFor(SupplyDropXp - 1) == 0
    check supplyDropsFor(SupplyDropXp) == 1    # only landed effect opens the tap

  test "the tap is bounded per life however hard a cog fights":
    check min(1_000_000 div SupplyDropXp, SupplyDropMaxPerLife) == SupplyDropMaxPerLife

  test "the plume is lit at the level that also makes you a bounty":
    # The power fantasy and its counter-play must arm at the SAME threshold,
    # or a visible veteran is either un-huntable or unrewarding to hunt.
    check AceLevel <= MaxLevel
    check deedGlory(dAceTag) > deedGlory(dHonorableKill)

  test "the kit cycle is deterministic and covers every pickup":
    # A roll would consume RNG draws that replay determinism depends on.
    check SupplyDropCycle.len == 4
    for kit in ["med kit", "grenade", "spray can", "shield"]:
      check kit in SupplyDropCycle

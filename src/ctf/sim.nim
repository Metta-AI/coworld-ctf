## The deterministic gameplay core: movement/collision, combat, grenades,
## shouts, pickups, fog-of-war, endgame, and the per-tick step loop. Types,
## consts, map, art, config, state services and roster live in the sibling
## modules this file imports and re-exports (see
## docs/plans/2026-08-01-sim-split.md).
import
  std/[algorithm, json, math, os, random, strutils],
  bitworld/pixelfonts, bitworld/profile, bitworld/spriteprotocol,
  bitworld/server,
  pixie

import sim_types, rig_art, arena, map_art, sim_config, sim_state, roster,
  paint, ballot, zone_field
export sim_types, rig_art, arena, map_art, sim_config, sim_state, roster,
  paint, ballot, zone_field

# ─────────────────────────────────────────────────────────────────────────
# GLORY PORT, increment 2/3 — the team ledger, the per-life ladder,
# achievements. Deed/xp/achievement mints only: the ladder does NOT yet
# change how a cog plays.
# ─────────────────────────────────────────────────────────────────────────
#
# Ported from main's src/ctf/sim.nim (GloryVersion 10 era) onto this split,
# N-team, flagless-capable lineage. Pricing lives in glory.nim (untouched);
# this is the plumbing, generalized in exactly the places the two-team
# original couldn't have been: `enemy(team)` (a Red<->Blue-only flip) is
# gone from every proc below, replaced with a loop over `sim.teams()` (the
# active-team prefix this file's own convention already uses everywhere
# else an N-team-safe iteration is needed).
#
# INCREMENT BOUNDARY: main's level-ladder BUFF accessors (playerWindupTicks/
# playerFireCooldown/playerGunRange/playerSprayReset/playerMaxHp/
# playerCarrierSpeedPct, each `levelX(base, level)`) are deliberately NOT
# ported here -- that is increment 3's job. `xp`/`level` mint and are
# visible on the wire (`rosterJson`'s "xp"/"lvl"), but no gameplay call site
# reads them back: `config.gunRange`/`fireCooldownTicks`/`fireWindupTicks`/
# `maxHpFor`/`carrierSpeedPct` are all untouched, so a level today is a
# scoreboard fact, not a combat advantage.
#
# Four cuts from main, all already declared in glory.nim's own header and
# repeated here only as pointers, not re-argued:
#   - No supply drop (`dropSupply`, `supplyDropCredit` et al): v1 BR ships
#     without it. `addXp`'s AceLevel supply-tap block is omitted outright.
#   - No `floorGameClock`: GV41 (sim_types.nim's own GameVersion history)
#     already removed the "action floor" clock model this fed -- the two
#     source call sites (a kill, a heart steal) simply drop the call.
#   - `treeMedKit` (all five tiers) is UNREACHABLE: every tier gates on
#     `supplyShared`/`supplySaves`, fields that do not exist without the
#     supply drop. `satisfiedAchievements` below omits the tree's block
#     entirely (the fields it would read don't exist to read) rather than
#     silently making the tree false with real-looking code.
#   - No level-ladder buff accessors (see INCREMENT BOUNDARY above).

func groundOwner*(sim: SimServer, x, y: int): Team =
  ## Which team's ground a point sits on: the NEAREST HOME PEDESTAL wins.
  ## N-team-safe by construction (nearest-Voronoi-cell, no midline), so this
  ## only needed `sim.teams()` in place of source's `for team in Team` to
  ## port -- see this file's own `Team`-widening note on why a raw
  ## `for team in Team` touches inactive slots on any config seating fewer
  ## than a full roster.
  result = sim.teams().a
  var best = high(int)
  for team in sim.teams():
    let
      home = sim.gameMap.flagHome(team)
      dx = home.x - x
      dy = home.y - y
      d2 = dx * dx + dy * dy
    if d2 < best:
      best = d2
      result = team

func deedSitePct*(sim: SimServer, team: Team, x, y: int): int =
  ## The within-arena gradient for a deed by one team at a point.
  let owner = sim.groundOwner(x, y)
  siteMultPct(ownerIsSelf = owner == team, ownerIsNone = false)

proc teamAliveCount(sim: SimServer, team: Team): int =
  for player in sim.players:
    if player.team == team and player.alive:
      inc result

proc heatCool*(sim: var SimServer) =
  ## Embers bleed with quiet: a stalled rampage falls back down the ladder.
  ## Without this a team banks a multiplier it has stopped earning.
  ## Wired into the per-tick `step*` loop alongside `evalAchievementsAllTeams`.
  for team in sim.teams():
    if sim.heatEmbers[team] <= 0:
      continue
    let quietSince = max(sim.heatLastDeed[team], sim.heatLastDecay[team])
    if sim.tickCount - quietSince >= HeatDecayTicks:
      sim.heatEmbers[team] = max(0, sim.heatEmbers[team] - HeatEmberDecay)
      sim.heatLastDecay[team] = sim.tickCount

proc gloryPopWeaker(aLabelLen, aAmount, bLabelLen, bAmount: int): bool =
  ## True when a pop described by (aLabelLen, aAmount) should yield to one
  ## described by (bLabelLen, bAmount) in a same-earner queue: a named claim
  ## always outranks a bare deed/rank-up number, and within the same kind
  ## the bigger |payout| wins.
  let aClaim = aLabelLen > 0
  let bClaim = bLabelLen > 0
  if aClaim != bClaim:
    return bClaim
  abs(aAmount) < abs(bAmount)

proc addGloryPop(sim: var SimServer, team: Team, x, y, amount: int,
                 label = "", first = false, word = "", earnerIndex = -1) =
  ## Push one floating score pop at a deed site. COSMETIC ONLY: `gloryPops`
  ## is excluded from gameHash exactly like `damagePops`/`splatters`, so
  ## this can never move a replay.
  if amount == 0 and label.len == 0 and word.len == 0:
    return
  if label.len == 0:
    for pop in sim.gloryPops.mitems:
      if pop.tick == sim.tickCount and pop.team == team and pop.label.len == 0 and
          pop.word == word and
          abs(pop.x - x) <= GloryPopCoalescePx and
          abs(pop.y - y) <= GloryPopCoalescePx:
        pop.amount += amount
        return
  var row = 0
  for pop in sim.gloryPops:
    if abs(pop.x - x) <= GloryPopCoalescePx and
        abs(pop.y - y) <= GloryPopCoalescePx:
      row = max(row, pop.row + 1)
  let boundedRow = min(row, GloryPopMaxStack)
  var startDelay = boundedRow * GloryPopStaggerTicks
  if earnerIndex >= 0:
    var earnerIdxs: seq[int] = @[]
    for i, pop in sim.gloryPops:
      if pop.earnerIndex == earnerIndex:
        earnerIdxs.add i
    if earnerIdxs.len >= GloryPopUnitQueueCap:
      var weakestPos = 0
      for p in 1 ..< earnerIdxs.len:
        if gloryPopWeaker(
            sim.gloryPops[earnerIdxs[p]].label.len, sim.gloryPops[earnerIdxs[p]].amount,
            sim.gloryPops[earnerIdxs[weakestPos]].label.len, sim.gloryPops[earnerIdxs[weakestPos]].amount):
          weakestPos = p
      let weakestIdx = earnerIdxs[weakestPos]
      if gloryPopWeaker(
          label.len, amount,
          sim.gloryPops[weakestIdx].label.len, sim.gloryPops[weakestIdx].amount):
        return
      sim.gloryPops.delete(weakestIdx)
      earnerIdxs.delete(weakestPos)
      for p in 0 ..< earnerIdxs.len:
        if earnerIdxs[p] > weakestIdx:
          dec earnerIdxs[p]
    var lastQueuedStart = -1
    for i in earnerIdxs:
      let queued = sim.gloryPops[i]
      lastQueuedStart = max(lastQueuedStart, queued.tick + queued.startDelay)
    startDelay =
      if lastQueuedStart < 0: 0
      else: max(0, lastQueuedStart + GloryPopUnitStaggerTicks - sim.tickCount)
  sim.gloryPops.add GloryFx(
    x: x, y: y, tick: sim.tickCount, amount: amount, team: team, label: label,
    word: word, first: first, row: boundedRow, earnerIndex: earnerIndex,
    startDelay: startDelay
  )

proc awardDeed*(sim: var SimServer, team: Team, deed: Deed, x, y: int,
                times = 1, byIndex = -1, fxActor = -1, stackK = 1) =
  ## THE SINGLE MINT. Every glory award in the engine goes through here.
  ##
  ## `stackK` (RECUT v13, appended — every existing positional call site
  ## unchanged) is the teammates-in-context count for the Fibonacci
  ## ally-stack (glory.nim `RecutStackLadder`), computed ONCE by the kill
  ## site against the shared fact (contract §7a: a property of the EVENT,
  ## never re-evaluated per seat). 1 = no context (the neutral column);
  ## read only when `config.gloryMultiplierRecut` is armed.
  ##
  ## `x, y` is the PRICING site and nothing else -- feeds `deedSitePct`, and
  ## (STALE-COMMENT FIX, glory-league-score pass) even now that `teamGlory`
  ## IS in `gameHash` (GLORY PORT increment 3/3 landed this in sim_state.nim
  ## well before this comment was corrected -- see that proc's own note),
  ## these coordinates must still never be repurposed as a draw position:
  ## this call site should not need to change just because a reader started
  ## consuming the ledger. `byIndex` is the EARNER and is cosmetic only: it
  ## moves the score pop, never the money.
  ##
  ## `fxActor` is a SEPARATE cosmetic-only actor, for the private glory-toast
  ## wire (GameConfig.allowCosmeticFx, GloryDeedFx below) -- deliberately its
  ## OWN parameter rather than a reuse of `byIndex`, so wiring it can never
  ## perturb the score-pop's existing `earned`/popX/popY/earnerIndex
  ## behavior a few lines down. Defaults to -1 (every pre-existing call site
  ## unchanged, no toast) and is only ever passed at the two call sites this
  ## channel actually covers -- the kill-deed mint in `killPlayer` and
  ## `dCapture` in `checkWinCondition` -- same scope the swap9-era wire had,
  ## just re-sourced onto the real deed instead of a hardcoded "kill"/1. A
  ## kill made with a grenade passes -1 here regardless of which deed it
  ## resolved to (see the call site's own comment) -- the swap9-era wire
  ## never wired the grenade blast-kill site at all (fragile GV24-hash
  ## attribution branch), and this keeps that exact exclusion alive rather
  ## than narrowing it to the literal `dGrenadeKill` label, which a
  ## precedence-shadowed grenade kill (an ace tag, a denial, ...) would
  ## dodge.
  if deed == dNone or times <= 0:
    return
  let sitePct = sim.deedSitePct(team, x, y)
  # N-team generalization of source's `sim.flags[enemy(team)].carrier`: this
  # was "is a player on `team` currently carrying THE (single) enemy's
  # flag"; here it is "carrying ANY other team's flag" -- the natural
  # extension, and on every real (flagless) BR map this loop never finds a
  # carrier at all, so `carrying` is always false, matching the flag-keyed
  # deeds' own permanently-inert status (see glory.nim's header).
  var carrying = false
  for otherTeam in sim.teams():
    if otherTeam == team:
      continue
    let c = sim.flags[otherTeam].carrier
    if c >= 0 and sim.players[c].team == team:
      carrying = true
      break
  var amount = mintGlory(deed, sim.heatEmbers[team], sitePct, carrying) * times
  if not sim.config.gloryMultiplierRecut:
    # DARK PATH — GLORY v12, byte-for-byte: the additive ledger.
    sim.teamGlory[team] += amount
  else:
    # ── MULTIPLIER RECUT (v13, armed) ── the pure-product economy.
    # This event contributes exactly ONE element to the per-team (= per-duo
    # in BR) composition, evaluated here at mint time on the shared fact
    # and never again (contract §7a): a positive deed folds ONE integer
    # factor (class × heat × carry × ally-stack, territory-shifted) into
    # the running product; a friendly-fire incident advances the division
    # counter instead (table §4 — a division, not a class).
    #
    # `amount` is REPURPOSED on this path as the event's product-space
    # value — the folded factor for a positive deed (so the score pop, the
    # toast, the log line and the tier-2 GloryDeed event all carry the real
    # per-event factor, which is also what an offline scorer needs to
    # rebuild the product in lockstep, §6), or minus the halvings this
    # incident just charged for `dTeamKill` (0 on the first of a CTF pair).
    if deed == dTeamKill:
      let before = recutFfHalvings(sim.gloryFfIncidents[team],
                                   sim.config.brMode)
      inc sim.gloryFfIncidents[team], times
      let after = recutFfHalvings(sim.gloryFfIncidents[team],
                                  sim.config.brMode)
      amount = -(after - before)
    else:
      let factor = recutFactor(deed, sim.heatEmbers[team], sitePct,
                               carrying, stackK)
      for _ in 1 .. times:
        sim.gloryProduct[team] = recutFold(sim.gloryProduct[team], factor)
      amount = factor
    # The int ledger carries the DERIVED score (floor of the division —
    # see recutScore's own comment), so every existing reader (broadcast
    # "glory", the banked league score, the endcard) reports the recut
    # score with zero reader changes.
    sim.teamGlory[team] = int(recutScore(
      sim.gloryProduct[team],
      recutFfHalvings(sim.gloryFfIncidents[team], sim.config.brMode)))
  inc sim.deedCounts[deed], times
  sim.deedGloryMass[deed] += amount
  if popsScore(deed):
    let
      earned = byIndex >= 0 and byIndex < sim.players.len
      popX = if earned: sim.players[byIndex].x else: x
      popY = if earned: sim.players[byIndex].y else: y
    sim.addGloryPop(team, popX, popY, amount, word = deedPopWord(deed),
                    earnerIndex = (if earned: byIndex else: -1))
  # Glory-toast channel (GameConfig.allowCosmeticFx): the wire counterpart
  # of the score pop just above, fired from THE SINGLE MINT so its
  # word/amount are the real deed's -- never a synthesized stand-in. Fail
  # closed on `fxActor` exactly like the pop's own `earned` check: no valid
  # actor, no toast (there is no honest `self` to report otherwise). Uses
  # the ACTOR's own live position (mirroring the pop's `earned` branch,
  # never `x, y` -- see this proc's own doc comment on why the pricing site
  # must never double as a draw position).
  if sim.config.allowCosmeticFx and fxActor >= 0 and fxActor < sim.players.len:
    sim.gloryDeeds.add GloryDeedFx(
      tick: sim.tickCount,
      word: deedPopWord(deed),
      amount: amount,
      actorIndex: fxActor,
      team: team,
      x: sim.players[fxActor].x + CollisionW div 2,
      y: sim.players[fxActor].y + CollisionH div 2
    )
  if paysHeat(deed):
    sim.heatEmbers[team] = min(HeatEmberCap, sim.heatEmbers[team] + times)
    sim.heatLastDeed[team] = sim.tickCount
  if sim.gameEventLoggingEnabled:
    sim.logGameEvent(teamText(team) & " " & deedName(deed) &
                     (if amount == 0: ""
                      elif amount < 0: " " & $amount
                      else: " +" & $amount))
  # Tier-2 mirror. `target = ord(team)` is ported byte-for-byte from main,
  # including its own pre-existing quirk: `emitEvent`'s `target` param is a
  # PLAYER INDEX everywhere else, and a team ordinal happens to alias one
  # whenever `ord(team) < sim.players.len`. Analysis-only (never gameHash),
  # so this is preserved as-is rather than "fixed" outside this port's
  # mandate -- see this file's port-header note on pricing-vs-plumbing.
  sim.emitEvent(
    GloryDeed, source = byIndex, target = ord(team), weapon = $deed,
    amount = amount, x = float(x), y = float(y)
  )

proc teamConvertedKits(sim: SimServer, team: Team): int =
  ## How many of the four kits this team has CONVERTED. GLORY-PORT-TODO:
  ## main's `med` leg reads `player.supplyShared` (a supply-drop-share
  ## fact) -- that field does not exist on this port (no supply drop, v1;
  ## see this section's header), so `med` is omitted rather than faked as
  ## always-false-but-present. The squad tree's `kits >= 4` tiers are
  ## therefore capped at 3 (nade+spray+shield) until supply drop lands.
  var nade, spray, shield = false
  for player in sim.players:
    if player.team != team:
      continue
    if player.grenadeKills >= 1: nade = true
    if player.sprayKills >= 1: spray = true
    if player.assists >= 1: shield = true
  ord(nade) + ord(spray) + ord(shield)

proc claimAchievement*(sim: var SimServer, team: Team, tree: Tree, tier: int,
                       isFirst: bool, byIndex = -1) =
  ## Mint one achievement tier for a team, with the first-claim multiplier
  ## decided BY THE CALLER (the tie logic lives in evalAchievementsAllTeams).
  let key = achievementKey(tree, tier)
  if sim.claimed[team][key]:
    return
  sim.claimed[team][key] = true
  let
    effectiveFirst = isFirst and tier == AchievementTiers - 1
    home = sim.gameMap.flagHome(team)
  var amount = mintAchievement(tier, sim.deedSitePct(team, home.x, home.y),
                               effectiveFirst)
  sim.claimedFirst[key] = true
  if not sim.config.gloryMultiplierRecut:
    # DARK PATH — GLORY v12, byte-for-byte.
    sim.teamGlory[team] += amount
  else:
    # ── MULTIPLIER RECUT (v13, armed) ── a claim folds RecutTierClass
    # (×1/×1/×2/×2/×4) × the surviving FIRST ×3 into the same single
    # per-team product every deed feeds (contract §7a: one walk, one
    # product). Never heat (law 4), never territory (home-pedestal mint —
    # see recutAchievementFactor). `amount` carries the factor for the
    # feed/pop/log/event, same repurposing as awardDeed's armed path.
    let factor = recutAchievementFactor(tier, effectiveFirst)
    sim.gloryProduct[team] = recutFold(sim.gloryProduct[team], factor)
    amount = factor
    sim.teamGlory[team] = int(recutScore(
      sim.gloryProduct[team],
      recutFfHalvings(sim.gloryFfIncidents[team], sim.config.brMode)))
  inc sim.deedCounts[dAchievement]
  sim.deedGloryMass[dAchievement] += amount
  let byCog = byIndex >= 0 and byIndex < sim.players.len and
              sim.players[byIndex].team == team
  sim.achievementFeed.add AchievementClaim(
    tick: sim.tickCount, team: team, tree: tree, tier: tier,
    glory: amount, first: effectiveFirst,
    slot: (if byCog: sim.players[byIndex].joinOrder else: -1)
  )
  if byCog and sim.players[byIndex].alive:
    sim.addGloryPop(team, sim.players[byIndex].x, sim.players[byIndex].y,
                    amount, label = achievementName(tree, tier),
                    first = effectiveFirst, earnerIndex = byIndex)
  if sim.gameEventLoggingEnabled:
    sim.logGameEvent(
      teamText(team) & " achievement: " & achievementName(tree, tier) &
      (if effectiveFirst: " (FIRST!)" else: "") & " +" & $amount
    )
  sim.emitEvent(
    Achievement, source = (if byCog: byIndex else: -1), target = ord(team),
    weapon = $tree, amount = amount, hp = tier, blocked = ord(effectiveFirst),
    x = float(home.x), y = float(home.y)
  )

proc claimAchievement*(sim: var SimServer, team: Team, tree: Tree, tier: int,
                       byIndex = -1) =
  ## Sequential (first-come) arity: first = nobody has taken the tier yet.
  sim.claimAchievement(
    team, tree, tier,
    isFirst = not sim.claimedFirst[achievementKey(tree, tier)],
    byIndex = byIndex)

type SatisfiedBy = array[Tree, array[AchievementTiers, int]]

const
  Unsatisfied = -2
  NoCog = -1

proc satisfiedAchievements(sim: SimServer, team: Team,
                           atConclusion = false): SatisfiedBy =
  ## Pure satisfaction read over engine-truth counters. See glory.nim /
  ## main's own copy of this proc for the full per-tier design rationale;
  ## comments here are trimmed to what changed in the port.
  ##
  ## `atConclusion` (v12): the conclusion sweep's read. The one tier whose
  ## requirement is scoped to the WHOLE game -- Clean Sheet, "FULL-GAME zero
  ## team kills" -- is reported only under this flag: while the game is
  ## still Playing the fact cannot exist yet, so the per-tick read keeps it
  ## Unsatisfied BY DESIGN (the same semantics the retired
  ## `evalCleanSheetAtConclusion` special case enforced by being a separate
  ## mint site).
  ##
  ## GLORY-PORT-TODO: `treeMedKit` (all 5 tiers) is OMITTED below, not
  ## faked false -- see `teamConvertedKits`'s comment. Every other tree
  ## ported clean: none of Gun/Spray/Grenade/Shield/Carrier/Defender/Squad
  ## depend on anything this lineage lacks. (Keep
  ## `UnattainableAchievementTiers` below in sync with this read: it is the
  ## budget test's source of truth for which tiers CANNOT mint here.)
  var
    best: SatisfiedBy
    anyCapture = false
    anyTeamKill = false
    kits = sim.teamConvertedKits(team)
  for tree in Tree:
    for tier in 0 ..< AchievementTiers:
      best[tree][tier] = Unsatisfied
  for idx, player in sim.players:
    if player.team != team:
      continue
    template earn(tr: Tree, ti: int) =
      if best[tr][ti] == Unsatisfied: best[tr][ti] = idx
    if player.captures > 0: anyCapture = true
    if player.teamKills > 0: anyTeamKill = true

    if player.gunKills >= 1:          earn(treeGun, 0)
    if player.gunKills >= 3:          earn(treeGun, 1)
    if player.aceKills >= 1:          earn(treeGun, 2)
    if player.level >= MaxLevel:      earn(treeGun, 3)
    if player.longshotKills >= 1:     earn(treeGun, 4)

    if player.sprayKills >= 1:        earn(treeSpray, 0)
    if player.sprayKills >= 2:        earn(treeSpray, 1)
    if player.sprayKillsThisPickup >= 2: earn(treeSpray, 2)
    if player.sprayKillsThisPickup >= 3: earn(treeSpray, 3)
    if player.sprayMultiKills >= 1:   earn(treeSpray, 4)

    if player.grenadeKills >= 1:      earn(treeGrenade, 0)
    if player.grenadeKills >= 2:      earn(treeGrenade, 1)
    if player.grenadeMultiKills >= 1: earn(treeGrenade, 2)
    if player.grenadeMultiKills >= 2: earn(treeGrenade, 3)
    if player.grenadeKills >= 3:      earn(treeGrenade, 4)

    if player.assists >= 1:           earn(treeShield, 0)
    if player.escortKills >= 1:       earn(treeShield, 1)
    if player.rescues >= 1:           earn(treeShield, 2)
    if player.secondWind:             earn(treeShield, 3)

    # v12 HEART RECUT (the 2026-08-31 contract table, verbatim): one
    # terminal capture tier instead of three, a ladder that accumulates
    # mid-game below it. `capturedOutnumbered`/`capturedFastBreak` are still
    # PINNED at the capture site (checkWinCondition) but no longer gate any
    # tier -- they ship as endcard distinctions (`CaptureDistinction`,
    # glory.nim; `over.distinctions`, broadcast.nim). Delivered (V) on a
    # game-ENDING capture mints via `evalAchievementsAtConclusion` below.
    if player.contestedSteals >= 1:   earn(treeCarrier, 0)
    if player.carryKills >= 1:        earn(treeCarrier, 1)
    if player.contestedSteals >= 2:   earn(treeCarrier, 2)
    if player.contestedSteals >= 2 and
       player.carryKills >= 1:        earn(treeCarrier, 3)
    if player.captures >= 1:          earn(treeCarrier, 4)

    if player.carrierKills >= 1:      earn(treeDefender, 0)
    if player.denials >= 1:           earn(treeDefender, 1)
    if player.carrierKills >= 2:      earn(treeDefender, 2)
    if player.peelTick >= 0 and player.stealTickThisLife > player.peelTick and
       player.stealTickThisLife - player.peelTick <= RevengeTicks:
                                      earn(treeDefender, 3)
    if player.denials >= 2:           earn(treeDefender, 4)

  if kits >= 2:                       best[treeSquad][0] = NoCog
  if kits >= 3:                       best[treeSquad][1] = NoCog
  # best[treeSquad][2] ("Full Kit", 4 of 4 kits) -- v12 TOMBSTONE
  # (Amendment 1): deliberately zero-claim, no gate line at all. `kits`
  # hard-caps at KitLegsImplemented (3) without the med leg, and a 3-value
  # counter cannot carry three thresholds, so I/II keep their gates and III
  # waits for the med-leg landing (see `KitLegsImplemented`, glory.nim).
  # best[treeSquad][3] (Clean Sheet) is CONCLUSION-ONLY: a full-game
  # requirement cannot be satisfied while the game is still running, so the
  # per-tick read reports it Unsatisfied BY DESIGN and only the
  # `atConclusion` read below can earn it (v12: the general mechanism that
  # replaced the `evalCleanSheetAtConclusion` special case).
  if atConclusion and not anyTeamKill: best[treeSquad][3] = NoCog
  # Victory Lap -- v12 (Amendment 1): every kit leg this port implements,
  # converted, plus a capture. Was `kits >= 4`, structurally dead (the cap
  # above); restore by setting KitLegsImplemented back to 4 when the med
  # leg lands. On a game-ending capture `anyCapture` pins at the terminal
  # tick, so this tier's main mint path is the conclusion sweep.
  if kits >= KitLegsImplemented and anyCapture:
                                      best[treeSquad][4] = NoCog

  if sim.squadVolleyDone[team]:       best[treeShield][4] = NoCog

  result = best

const
  UnattainableAchievementTiers* = [
    ## v12: the (tree, tier) pairs `satisfiedAchievements` can NEVER report
    ## on this port, kept adjacent to the proc that makes them true so the
    ## budget test (test_glory.nim, law 3) asserts against the SOURCE
    ## instead of restating a number. Two causes, both named above:
    ## `treeMedKit` is omitted wholesale (no `supplyShared` on this port)
    ## and "Full Kit" is tombstoned by the same missing leg (Amendment 1).
    (treeMedKit, 0), (treeMedKit, 1), (treeMedKit, 2), (treeMedKit, 3),
    (treeMedKit, 4), (treeSquad, 2),
  ]

proc evalAchievements*(sim: var SimServer, team: Team) =
  ## Poll one team and claim anything newly satisfied, sequential-first.
  ## Called from tests and any single-team poller, NOT from `awardDeed`.
  if sim.phase != Playing:
    return
  let best = sim.satisfiedAchievements(team)
  for tree in Tree:
    for tier in 0 ..< AchievementTiers:
      if best[tree][tier] != Unsatisfied:
        sim.claimAchievement(team, tree, tier, byIndex = best[tree][tier])

proc evalAchievementsAllTeams*(sim: var SimServer) =
  ## The per-tick pass: judge EVERY team's satisfied tiers first, then mint,
  ## so a same-tick multi-team completion is a genuine tie (every same-tick
  ## claimant takes the first-claim multiplier).
  if sim.phase != Playing:
    return
  var sat: array[Team, SatisfiedBy]
  for team in sim.teams():
    sat[team] = sim.satisfiedAchievements(team)
  var untakenAtTickStart: array[AchievementTrees * AchievementTiers, bool]
  for key in 0 ..< untakenAtTickStart.len:
    untakenAtTickStart[key] = not sim.claimedFirst[key]
  for team in sim.teams():
    for tree in Tree:
      for tier in 0 ..< AchievementTiers:
        if sat[team][tree][tier] != Unsatisfied:
          sim.claimAchievement(team, tree, tier,
            isFirst = untakenAtTickStart[achievementKey(tree, tier)],
            byIndex = sat[team][tree][tier])

proc evalAchievementsAtConclusion*(sim: var SimServer) =
  ## v12: THE STRUCTURAL CONCLUSION SWEEP (contract §4). One full
  ## achievement pass -- every team, every tree -- as part of the game-over
  ## transition, called once from `finishGame` before its draw early-return,
  ## so it fires on EVERY conclusion (capture, wipe, mutual-wipe draw, time
  ## limit / BR tiebreak) and never on an aborted game (an abort goes
  ## through `resetToLobby`, which does not conclude anything -- the same
  ## scope the retired `evalCleanSheetAtConclusion` had).
  ##
  ## Why it exists: the per-tick sweep at the top of `step` runs BEFORE the
  ## win check, and both Playing-gated eval procs are dead the moment
  ## `finishGame` flips phase -- so a fact created by the act that ENDS the
  ## game (the capture's `captures`/`anyCapture`, the final kill's
  ## counters) could never mint. In Season 2's modes every episode ends on
  ## a terminal tick (each 2-team capture, BR's last-team-standing), so
  ## conclusion-time evaluation is the MAIN mint path there, not an edge --
  ## the decisive claimability experiment (branch
  ## maxwell/heart-claimability-test) proved the hole; this closes it.
  ##
  ## Laws preserved: the first-claim tie is read-every-team-before-any-mint,
  ## exactly as `evalAchievementsAllTeams` applies it per-tick. A tier the
  ## last Playing sweep already minted cannot mint again --
  ## `claimAchievement`'s `claimed[]` early-return dedupes (pinned by
  ## test_glory_conclusion's double-mint proof). Clean Sheet folds in via
  ## `satisfiedAchievements`' `atConclusion` read: still never reported
  ## while Playing, still minted here and only here.
  if sim.phase != GameOver:
    return
  var sat: array[Team, SatisfiedBy]
  for team in sim.teams():
    sat[team] = sim.satisfiedAchievements(team, atConclusion = true)
  var untakenAtSweepStart: array[AchievementTrees * AchievementTiers, bool]
  for key in 0 ..< untakenAtSweepStart.len:
    untakenAtSweepStart[key] = not sim.claimedFirst[key]
  for team in sim.teams():
    for tree in Tree:
      for tier in 0 ..< AchievementTiers:
        if sat[team][tree][tier] != Unsatisfied:
          sim.claimAchievement(team, tree, tier,
            isFirst = untakenAtSweepStart[achievementKey(tree, tier)],
            byIndex = sat[team][tree][tier])

proc recordTeamKillRing(sim: var SimServer, team: Team, killerIndex: int) =
  ## v9 (GLORY LAW E3): appends one non-friendly kill to `team`'s small
  ## recent-kill ring, prunes it to the live `SquadVolleyWindowTicks` window
  ## (and a hard `SquadVolleyRingCap`), then pins `squadVolleyDone[team]`
  ## ONCE the ring shows `SquadVolleyMinDistinct`+ DISTINCT killers inside
  ## the window -- the `Squad Volley` gate.
  var kept: seq[tuple[killerIndex: int, tick: int]] = @[]
  for entry in sim.teamKillRing[team]:
    if sim.tickCount - entry.tick <= SquadVolleyWindowTicks:
      kept.add entry
  kept.add (killerIndex: killerIndex, tick: sim.tickCount)
  if kept.len > SquadVolleyRingCap:
    kept = kept[kept.len - SquadVolleyRingCap ..< kept.len]
  sim.teamKillRing[team] = kept
  if not sim.squadVolleyDone[team]:
    var distinctKillers: seq[int] = @[]
    for entry in kept:
      if entry.killerIndex notin distinctKillers:
        distinctKillers.add entry.killerIndex
    if distinctKillers.len >= SquadVolleyMinDistinct:
      sim.squadVolleyDone[team] = true

proc addXp*(sim: var SimServer, playerIndex: int, amount: int) =
  ## Move a cog along its per-life ladder, and mint the level-up if it
  ## climbs. Negative amounts are how friendly fire de-levels you.
  ##
  ## GLORY-PORT-TODO: main's AceLevel supply-drop tap
  ## (`supplyDropCredit += amount; sim.dropSupply(playerIndex)`) is CUT --
  ## v1 BR ships without supply drop (glory.nim's header). The level ladder
  ## and its buffs (windup/hp/cooldown/spray-reset/grenade-charges/carrier
  ## speed) are UNCHANGED by this cut.
  if playerIndex < 0 or playerIndex >= sim.players.len or amount == 0:
    return
  let before = sim.players[playerIndex].level
  sim.players[playerIndex].xp = max(0, sim.players[playerIndex].xp + amount)
  sim.players[playerIndex].level =
    levelForXp(sim.players[playerIndex].xp, sim.config.brMode)
  let after = sim.players[playerIndex].level
  if after > before:
    sim.awardDeed(
      sim.players[playerIndex].team, dLevelUp,
      sim.players[playerIndex].x, sim.players[playerIndex].y, after - before,
      byIndex = playerIndex
    )
    # GLORYVERSION 10 (leveling pays POWER, not the scoreboard): `dLevelUp`
    # mints 0g, so `popsScore` excludes it and the generic pop above never
    # fires. The moment still deserves a pop -- mint it directly, `word`
    # (never `label`, see main's own comment on why), short GloryFxTicks
    # life -- it fires ~40x/episode, an AchievementFxTicks-length claim pop
    # would never clear before the next one lands.
    if sim.players[playerIndex].alive:
      sim.addGloryPop(
        sim.players[playerIndex].team,
        sim.players[playerIndex].x, sim.players[playerIndex].y, 0,
        word = deedPopWord(dLevelUp) & " " & repeat("*", clampLevel(after)),
        earnerIndex = playerIndex
      )
    if sim.gameEventLoggingEnabled:
      sim.logGameEvent(
        playerColorText(sim.players[playerIndex].color) & " is " &
        levelName(after)
      )
    sim.emitEvent(
      LevelUp, source = playerIndex, amount = after,
      x = float(sim.players[playerIndex].x), y = float(sim.players[playerIndex].y)
    )

proc resetLadder*(sim: var SimServer, playerIndex: int) =
  ## Death forfeits the whole per-life ladder: xp, level, buffs. THE ANTI-
  ## SNOWBALL RULE -- a runaway cog is a `dAceTag` bounty and killing it
  ## puts it back to a recruit.
  ##
  ## GLORY-PORT-TODO cut: main also zeroes `supplyDropCredit`/
  ## `supplyDropsThisLife`/`lastSupplyDropTick` here -- none exist on this
  ## port (no supply drop, v1).
  sim.players[playerIndex].xp = 0
  sim.players[playerIndex].level = 0
  sim.players[playerIndex].stealTickThisLife = -1

proc resetGloryLedger*(sim: var SimServer) =
  ## Zeroes every TEAM/GAME-level glory field: the ledger, its rampage
  ## state, the one-shot claim gates, the fire-counter audit and the
  ## cosmetic pop queue. Does NOT touch per-player counters (startGame's
  ## own per-player loop owns those). Called from `startGame`.
  for team in sim.teams():
    # RECUT(v13): armed, the ledger opens at the SEED — directive §2's open-
    # guards line verbatim: "Seed = 1; a no-deed episode scores seed" (the
    # league's loser-banks-0 gate is roster.nim's, unchanged). Dark: 0,
    # byte-identical to v12.
    sim.teamGlory[team] =
      if sim.config.gloryMultiplierRecut: RecutSeed else: 0
    # The armed product state resets with the ledger it backs.
    # Unconditional (not flag-gated) on purpose: writing the seed into a
    # dark game's fields costs nothing observable (they are hashed and read
    # only under the armed flag) and means an armed game can never inherit
    # a stale product through any reset path.
    sim.gloryProduct[team] = RecutSeed
    sim.gloryFfIncidents[team] = 0
    sim.heatEmbers[team] = 0
    sim.heatLastDeed[team] = 0
    sim.heatLastDecay[team] = 0
    sim.squadVolleyDone[team] = false
    sim.teamKillRing[team] = @[]
    for key in 0 ..< sim.claimed[team].len:
      sim.claimed[team][key] = false
  for key in 0 ..< sim.claimedFirst.len:
    sim.claimedFirst[key] = false
  for deed in Deed:
    sim.deedCounts[deed] = 0
    sim.deedGloryMass[deed] = 0
  sim.firstBloodDone = false
  sim.achievementFeed = @[]
  sim.gloryPops = @[]
  sim.recutDamageMarks = @[]

proc stealIsContested(sim: SimServer, playerIndex: int): bool =
  ## True when a LIVE enemy stands within `ContestedStealPx` of the stealer
  ## at the exact moment the heart leaves its pedestal -- the fact
  ## `Hands On` gates on. Already N-team-safe (no `enemy()` call).
  let
    team = sim.players[playerIndex].team
    px = sim.players[playerIndex].x
    py = sim.players[playerIndex].y
    rangeSq = ContestedStealPx * ContestedStealPx
  for i, other in sim.players:
    if i == playerIndex or other.team == team or not other.alive:
      continue
    if distSq(px, py, other.x, other.y) <= rangeSq:
      return true
  false

proc grenadeSpawnPoints*(gameMap: CtfMap): array[4, tuple[x, y: int]] =
  ## The four grenade spawn points. Sides maps keep the classic corners;
  ## corner maps move them to the edge midpoints (the corners are endzones
  ## there); plus maps tuck them at the inner corners of the center
  ## intersection, clear of the four endzone arm mouths.
  let inset = ArenaBorder + GrenadeSpawnInset
  case gameMap.layout
  of layoutSides:
    [(inset, inset),
      (inset, gameMap.height - inset),
      (gameMap.width - inset, inset),
      (gameMap.width - inset, gameMap.height - inset)]
  of layoutCorners:
    if gameMap.symmetry == symQuadMirror:
      ## Quad-mirror's group is the reflections, so the set must be a Klein
      ## orbit. The rot90 edge-MIDPOINT seed degenerates there (its mirrorX
      ## image is itself, half a pixel off on an even width), so the seed
      ## slides to a third of the top edge: the orbit is four distinct
      ## points along the top and bottom edges, clear of the corner
      ## endzones, and exactly fair by construction.
      quadMirrorOrbit(
        (gameMap.width div 3, inset), gameMap.width, gameMap.height)
    else:
      rot90Orbit((gameMap.width div 2, inset), gameMap.width)
  of layoutPlus:
    let arm = gameMap.plusArmHalf()
    if gameMap.symmetry == symQuadMirror:
      ## The same four inner corners of the center intersection as rot90,
      ## built as the reflections of the bottom-right one — the group that
      ## actually completes this map.
      quadMirrorOrbit(
        (gameMap.center.x + arm - inset, gameMap.center.y + arm - inset),
        gameMap.width, gameMap.height)
    else:
      rot90Orbit(
        (gameMap.center.x + arm - inset, gameMap.center.y + arm - inset),
        gameMap.width
      )

proc teamOrbitPoints(gameMap: CtfMap, red: MapPoint): seq[tuple[x, y: int]] =
  ## Carries RED's chosen point to every active team by the map's own
  ## symmetry (`teamImagePoint`), so no team's pickup sits in terrain the
  ## others' don't get.
  for team in gameMap.teams():
    let point = gameMap.teamImagePoint(red, team)
    result.add((point.x, point.y))

proc explicitOrOrbit(
  gameMap: CtfMap, explicit: seq[MapPoint], red: MapPoint
): seq[tuple[x, y: int]] =
  ## symNone maps carry EXPLICIT per-team points (no orbit exists); every other
  ## symmetry derives each team's point from RED's via teamImagePoint. The
  ## loader has already validated the explicit set is present + well-formed for
  ## symNone, so here we trust it.
  if gameMap.symmetry == symNone:
    for p in explicit: result.add((p.x, p.y))
  else:
    result = gameMap.teamOrbitPoints(red)

proc shieldSpawnPoints*(gameMap: CtfMap): seq[tuple[x, y: int]] =
  ## One shield point per team, deep in that team's endzone. RED's spot is
  ## the only one chosen; every other team's is its image under the map's own
  ## symmetry (`teamImagePoint`), so no team's shield sits in terrain the
  ## others' don't get. Under symNone the points are authored explicitly.
  ##
  ## Every pickup family here seeds from `slotAnchor(Red)`, the board's OWN
  ## west / top-left pad, never from `teamAnchor(Red)`: a pickup belongs to a
  ## PLACE, not to a team, so the GV44 home rotation must leave the physical
  ## pickup set untouched. Seeding from a rotated anchor would carry an
  ## unrotated offset off a rotated pad and slide the whole orbit.
  let
    inset = ArenaBorder + GrenadeSpawnInset
    red =
      if gameMap.endzone != ezColumn:
        ## A compact endzone has no back column to hide a pickup in: park it
        ## below the pedestal, inside the zone (protected floor, so always
        ## walkable and always connected) and clear of the pedestal art.
        let anchor = gameMap.slotAnchor(Red)
        MapPoint(x: anchor.x, y: anchor.y + 2 * gameMap.endzoneRadius div 3)
      else:
        case gameMap.layout
        of layoutSides:
          ## The classic back column, bottom half; the cans hold the top.
          MapPoint(x: inset, y: 3 * gameMap.height div 4)
        of layoutCorners:
          ## Red's own x edge at anchor height. Blue's copy is the quarter
          ## turn of that — the TOP edge — not the right edge a mirror picks.
          MapPoint(x: inset, y: gameMap.slotAnchor(Red).y)
        of layoutPlus:
          ## The lower half of Red's arm mouth. Anchoring each team's copy to
          ## the integer `center` instead lands it a pixel off the orbit,
          ## since the rot90 axis is at (side - 1)/2.
          MapPoint(x: inset, y: gameMap.center.y + gameMap.plusArmHalf() div 2)
  gameMap.explicitOrOrbit(gameMap.teamPickups.shields, red)

proc sprayPaintSpawnPoints*(gameMap: CtfMap): seq[tuple[x, y: int]] =
  ## One spray can point per team, built exactly like the shields: RED's spot
  ## carried to every other team by the map's own symmetry. Red's can is the
  ## opposite half of its endzone from Red's shield, so the two sets never
  ## collide.
  let
    inset = ArenaBorder + SprayPaintSpawnInset
    red =
      if gameMap.endzone != ezColumn:
        ## The compact-endzone counterpart of the shield spot: same zone,
        ## other side of the pedestal (cans high, shields low).
        let anchor = gameMap.slotAnchor(Red)
        MapPoint(x: anchor.x, y: anchor.y - 2 * gameMap.endzoneRadius div 3)
      else:
        case gameMap.layout
        of layoutSides:
          MapPoint(x: inset, y: gameMap.height div 4)
        of layoutCorners:
          ## Red's shield spot reflected across the diagonal — its own y edge
          ## at anchor width — so the two orbits never share an edge spot.
          MapPoint(x: gameMap.slotAnchor(Red).x, y: inset)
        of layoutPlus:
          MapPoint(x: inset, y: gameMap.center.y - gameMap.plusArmHalf() div 2)
  gameMap.explicitOrOrbit(gameMap.teamPickups.cans, red)

proc barrierSpawnPoints*(gameMap: CtfMap, perTeam: int): seq[tuple[x, y: int]] =
  ## `perTeam` cardboard barrier pickup points per team (config-gated; empty
  ## by default). RED's spots are staged on the line from its anchor toward
  ## map center — the walk out of the base every attacker and defender makes —
  ## and every other team's are its images under the map's own symmetry
  ## (`teamImagePoint` via teamOrbitPoints), so no team's pickup sits in
  ## terrain the others' don't get. One spot lands at the midpoint; two
  ## split the line in thirds.
  if gameMap.symmetry == symNone:
    ## Explicit, team-major (perTeam per team). The LOADER only checked the
    ## count is a multiple of the team count and that each point is walkable —
    ## it does NOT know the config's `perTeam`. So verify HERE, where perTeam is
    ## known, that the spec carries EXACTLY perTeam * activeTeams points; a
    ## mismatch would otherwise silently give teams the wrong barrier count.
    let expected = perTeam * gameMap.layout.teamCount()
    if gameMap.teamPickups.barriers.len != expected:
      raise newException(CtfError,
        "symNone barrier pickups: config asks perTeam=" & $perTeam & " (" &
        $expected & " total for " & $gameMap.layout.teamCount() & " teams) but " &
        "the spec authored " & $gameMap.teamPickups.barriers.len & " points.")
    for p in gameMap.teamPickups.barriers: result.add((p.x, p.y))
    return
  let
    anchor = gameMap.slotAnchor(Red)
    center = gameMap.center
  for k in 0 ..< perTeam:
    let red = MapPoint(
      x: anchor.x + (center.x - anchor.x) * (k + 1) div (perTeam + 1),
      y: anchor.y + (center.y - anchor.y) * (k + 1) div (perTeam + 1)
    )
    result.add(gameMap.teamOrbitPoints(red))

proc paintballLoadout*(sim: SimServer): bool {.inline.} =
  ## True while the paintball loadout is on: every cog holds a spray can and
  ## never loses it, the gun is disabled (the starter's own rule for a can
  ## carrier), NO pickups are placed at all, and there is no heart objective.
  sim.config.loadout == LoadoutPaintball

template placeWalkablePickups(
  sim: var SimServer,
  spawnsField: untyped,
  targets: seq[tuple[x, y: int]]
) =
  ## Shared placement core for the nudged pickup families (med kits, shields,
  ## spray cans, and an AUTHORED grenade pool): sizes the spawn seq to the
  ## targets, nudges each target to the nearest walkable floor, and refills
  ## every spawn. (The classic 4-corner/orbit grenade FORMULA keeps its own
  ## placement in resetGrenades — its points are walkable by construction
  ## and were never nudged before the authored path existed, so that branch
  ## stays byte-identical rather than routing through here.)
  ##
  ## Under the paintball loadout NO pickup is placed at all: the family is
  ## emptied instead. The pickup/update path is already skipped there, so an
  ## un-emptied family could not be taken — but it was still reported in the
  ## seats' first-person JSON, listed as a map item and drawn on the board, so
  ## the picture and the LLM's view both carried objects the rules do not have.
  if sim.paintballLoadout():
    sim.spawnsField.setLen(0)
    return
  let targetsOnce = targets   # evaluate the expression once, not per use
  sim.spawnsField.setLen(targetsOnce.len)
  for i in 0 ..< sim.spawnsField.len:
    let spot = sim.nearestWalkable(targetsOnce[i].x, targetsOnce[i].y)
    sim.spawnsField[i] = PickupSpawn(
      x: spot.x, y: spot.y, present: true, respawnAt: 0
    )

proc resetGrenades*(sim: var SimServer) =
  ## Refills every grenade pickup and clears carried and airborne grenades.
  ##
  ## A map that authored its own neutral pool (gameMap.grenadeSpawns —
  ## brmapkit round 13's per-item gradient, sized to the POI count rather
  ## than a fixed 4) wins over grenadeSpawnPoints()'s 4-corner/orbit
  ## formula, the same "map's own list first, formula fallback" rule
  ## resetShields/resetSprayPaints use. The authored path is nudged to the
  ## nearest walkable floor via placeWalkablePickups, same as the other
  ## three item families (generator points are not guaranteed walkable) —
  ## and, like every placeWalkablePickups family, empties outright under the
  ## paintball loadout. The classic formula path keeps its original UNNUDGED
  ## placement byte-for-byte — those points are walkable by construction (§
  ## the formula's own layout-specific insets) and were never nudged before
  ## this change, so this branch must stay a literal copy of the old loop
  ## for every 2-4 team map's replay to hash identically, MODULO the
  ## paintball gate below (`present`): under the paintball loadout the
  ## corners stay EMPTY (the spawn array is fixed-size, so "not placed" is
  ## `present: false` here); nothing is drawn, reported or takeable.
  ##
  ## BR path defense-in-depth: validateMap (arena.nim) now rejects any
  ## flagless+spawnGroups>1 map that omits grenadeSpawns (the SAME `and`
  ## condition below, not `or` — see validateMap's comment for why), so a
  ## real BR map should never actually reach the classic-formula fallback —
  ## but if one somehow does, nudge grenadeSpawnPoints()'s 4 points to the
  ## nearest walkable floor via placeWalkablePickups (like the authored-pool
  ## branch above) instead of seating them raw for however many seats the
  ## map has: the formula's built-in walkability guarantee only holds for
  ## the hand-authored sides/corners/plus layouts it was written for, not
  ## procedurally-generated BR terrain. Classic (non-BR) maps, and the
  ## smaller flagless-but-not-BR-scale maps validateMap still allows to skip
  ## the neutral pools, never take this branch — they keep the exact
  ## unnudged `else` below.
  if sim.gameMap.grenadeSpawns.len > 0:
    var targets: seq[tuple[x, y: int]]
    for point in sim.gameMap.grenadeSpawns:
      targets.add((point.x, point.y))
    sim.placeWalkablePickups(grenadeSpawns, targets)
  elif sim.gameMap.flagless and sim.gameMap.spawnGroups > 1:
    var targets: seq[tuple[x, y: int]]
    for point in sim.gameMap.grenadeSpawnPoints():
      targets.add(point)
    sim.placeWalkablePickups(grenadeSpawns, targets)
  else:
    let
      points = sim.gameMap.grenadeSpawnPoints()
      present = not sim.paintballLoadout()
    sim.grenadeSpawns.setLen(points.len)
    for i in 0 ..< sim.grenadeSpawns.len:
      sim.grenadeSpawns[i] = PickupSpawn(
        x: points[i].x, y: points[i].y, present: present, respawnAt: 0
      )
  sim.airborneGrenades = @[]
  for i in 0 ..< sim.players.len:
    sim.players[i].hasGrenade = false
    sim.players[i].throwCharge = 0

proc resetMedKits*(sim: var SimServer) =
  ## Places both med kits on the map's active spawn points (generated maps
  ## draw the pair per map; hand-authored maps carry the classic center-line
  ## thirds), nudged to the nearest walkable floor, and refills them.
  ##
  ## Gates on `> 0`, not `>= 2`: the three sibling families (resetShields/
  ## resetSprayPaints/resetGrenades, above) all prefer ANY map-authored pool
  ## over their formula fallback, however small — a BR map always authors
  ## far more than 2 (the showmatch: 33) so this never mattered for BR
  ## itself, but the old `>= 2` silently ignored a map that deliberately
  ## authored exactly 1 med kit spawn and fell back to the classic 2-point
  ## formula instead of the author's own list. Every classic map either
  ## authors 0 (falls to the formula, unaffected) or the classic 2 (still
  ## non-empty, unaffected), so this is byte-identical for every existing
  ## fixture.
  var targets: seq[tuple[x, y: int]]
  if sim.gameMap.medKitSpawns.len > 0:
    for point in sim.gameMap.medKitSpawns:
      targets.add((point.x, point.y))
  else:
    targets = @[
      (MapWidth div 2, MapHeight div 3),
      (MapWidth div 2, 2 * MapHeight div 3),
    ]
  # LOOT(s2): medKitCount caps the placed kits — -1 (default) is the
  # pre-existing full-set path bit-for-bit, 0 places none (the
  # bandage-instead-of-medkit test arm), N keeps the map's first N points.
  if sim.config.medKitCount >= 0 and targets.len > sim.config.medKitCount:
    targets.setLen(sim.config.medKitCount)
  sim.placeWalkablePickups(medKitSpawns, targets)

proc resetBandages*(sim: var SimServer) =
  ## LOOT(s2): places `config.bandagePickups` bandage pickups at the map's
  ## med-kit points (active spawns first, then the drawn candidates,
  ## cycling when the knob exceeds the points), nudged to walkable floor
  ## like every pickup family. Reuses the med-kit geometry on purpose: those
  ## points already passed the map's item-fairness reasoning, and the
  ## intended test arm swaps kits OUT for bandages (medKitCount: 0), so the
  ## bandages inherit exactly the fairness the kits vacated. Empties the
  ## family outright when the knob is 0 — the dark default — so no dark
  ## surface (broadcast lists included) ever sees one.
  if sim.config.bandagePickups <= 0 or sim.paintballLoadout():
    sim.bandageSpawns.setLen(0)
    return
  var base: seq[tuple[x, y: int]]
  for point in sim.gameMap.medKitSpawns:
    base.add((point.x, point.y))
  for point in sim.gameMap.medKitCandidates:
    base.add((point.x, point.y))
  if base.len == 0:
    base = @[
      (MapWidth div 2, MapHeight div 3),
      (MapWidth div 2, 2 * MapHeight div 3),
    ]
  var targets: seq[tuple[x, y: int]]
  for k in 0 ..< sim.config.bandagePickups:
    targets.add(base[k mod base.len])
  sim.placeWalkablePickups(bandageSpawns, targets)

const
  SpawnLootDirs: array[8, tuple[dx, dy: int]] = [
    (0, -1), (1, -1), (1, 0), (1, 1),
    (0, 1), (-1, 1), (-1, 0), (-1, -1),
  ]
    ## SPAWNLOOT: an 8-compass-direction ring, pure integer offsets — no
    ## floats/host libm, following the same "geometry must not use host
    ## libm" replay-determinism rule arena.nim's DiamondCos table documents
    ## (a libm trig call can differ in its last bit across platforms/
    ## compilers; a hashed replay position never may).

template seedSpawnLootFamily(
  sim: var SimServer, spawnsField: untyped,
  anchorX, anchorY, count, radius, dirOffset: int
) =
  ## SPAWNLOOT: appends `count` crates within `radius` px of one spawn
  ## cluster's anchor point to `spawnsField`, each nudged to the nearest
  ## walkable cell via `nearestWalkable` — the SAME expanding-ring
  ## guarantee `placeWalkablePickups` above already relies on for every
  ## other pickup family, so a seeded crate can never land inside a wall or
  ## an unreachable pocket (placement is a GUARANTEE, not a filter). Extra
  ## items beyond the first 8 lap an inner ring a third of the radius
  ## closer in, so a large count does not restack new crates on the outer
  ## ring's own pixels. `dirOffset` phase-shifts the guns/hoppers rings 4
  ## of the 8 directions apart so the two families do not stack on the
  ## exact same pixel either.
  for spawnLootIdx in 0 ..< count:
    let
      spawnLootDir =
        SpawnLootDirs[(spawnLootIdx + dirOffset) mod SpawnLootDirs.len]
      spawnLootRing = spawnLootIdx div SpawnLootDirs.len
      spawnLootDist =
        max(1, radius - spawnLootRing * (radius div 3))
      spawnLootSpot = sim.nearestWalkable(
        anchorX + spawnLootDir.dx * spawnLootDist,
        anchorY + spawnLootDir.dy * spawnLootDist)
    sim.spawnsField.add PickupSpawn(
      x: spawnLootSpot.x, y: spawnLootSpot.y, present: true, respawnAt: 0)

proc seedSpawnLoot(sim: var SimServer) =
  ## SPAWNLOOT: owner-approved starter fix (2026-09-03, verbatim: "i like
  ## the idea of filling spawn areas with guns and hoppers so they
  ## accidentally grab it anyway") for the field's unarmed-cog problem —
  ## live data showed 78.8% of BR downs are zone/environmental because no
  ## policy routes toward loot. Rather than teach every playbook to path to
  ## a crate, put a crate where a cog's own first few steps in ANY
  ## direction already land.
  ##
  ## ADDITIVE ONLY, called from resetLootCrates right after it has already
  ## placed the base weaponSpawns/hopperSpawns (the map's authored pool, or
  ## the grenade/med-kit fallback) — this only APPENDS more crates on top;
  ## that existing placement is untouched. Both families stay one-shot (see
  ## resetLootCrates's own note): a seeded crate is taken exactly like any
  ## other, never refilled. NOTE (loot economy, flagged not solved): this
  ## raises the total gun/hopper count on the field when armed — the
  ## simulator/owner feel-pass should weigh that against fight pacing.
  ##
  ## One cluster PER TEAM, not per seat: arrangeHomePositions (called
  ## earlier in startGame, before resetLootCrates) already staggers a BR
  ## duo's two seats within SpawnShareStagger (24px) of each other around
  ## one shared point (sim_state.nim's spawnPosition), so the FIRST seated
  ## player's own homeX/homeY for that team already IS the cluster's spawn
  ## anchor — no need to re-derive spawnPosition/spawnGroupOffset here, and
  ## no risk of drifting from wherever the players actually spawned.
  ## lootSpawnSeedRadius must comfortably clear that 24px partner spread
  ## for BOTH duo seats to land in range (design requirement: >=2 guns and
  ## >=2 hoppers reachable per pair at the armed starting constants).
  ##
  ## Dark by construction: both counts default to 0, so the early return
  ## below fires and neither family's length changes — byte-identical to a
  ## build without this feature. Never touches sim.rng: placement is a pure
  ## function of homeX/homeY (themselves a pure function of the seed via
  ## spawnPosition/spawnGroupOffset), so arming this cannot perturb any
  ## OTHER rng-consuming draw's sequence, and re-simulating one seed always
  ## seeds the same crates at the same pixels.
  if sim.config.lootSpawnSeedGuns <= 0 and sim.config.lootSpawnSeedHoppers <= 0:
    return
  var seenTeam: array[Team, bool]
  for i in 0 ..< sim.players.len:
    let team = sim.players[i].team
    if seenTeam[team]:
      continue
    seenTeam[team] = true
    let
      anchorX = sim.players[i].homeX
      anchorY = sim.players[i].homeY
    if sim.config.lootSpawnSeedGuns > 0:
      sim.seedSpawnLootFamily(weaponSpawns, anchorX, anchorY,
        sim.config.lootSpawnSeedGuns, sim.config.lootSpawnSeedRadius, 0)
    if sim.config.lootSpawnSeedHoppers > 0:
      sim.seedSpawnLootFamily(hopperSpawns, anchorX, anchorY,
        sim.config.lootSpawnSeedHoppers, sim.config.lootSpawnSeedRadius, 4)

proc resetLootCrates*(sim: var SimServer) =
  ## LOOT(s2): places the loot-start crates — the marker (gun) and the
  ## hopper (its ammo), the two halves a cog must BOTH loot to fire. The
  ## map's authored weaponSpawns/hopperSpawns pools win when present;
  ## otherwise marker crates land on the RESOLVED grenade pickup points
  ## (sim.grenadeSpawns — already placed, already walkable, fairness-gated
  ## on certified BR maps and formula-derived on classic maps) and hopper
  ## crates on the map's med-kit points, so every existing map hosts a
  ## loot-start game with no respec. MUST run after resetGrenades for the
  ## marker fallback points.
  ## Both families empty when lootStart is dark (the default), so no dark
  ## surface ever sees a crate. One-shot by construction: no code path
  ## calls refillElapsedPickups on these families, so a taken crate stays
  ## taken for the whole game (the respawn timer written at pickup is
  ## inert).
  if not sim.config.lootStart or sim.paintballLoadout():
    sim.weaponSpawns.setLen(0)
    sim.hopperSpawns.setLen(0)
    return
  var weaponTargets: seq[tuple[x, y: int]]
  if sim.gameMap.weaponSpawns.len > 0:
    for point in sim.gameMap.weaponSpawns:
      weaponTargets.add((point.x, point.y))
  else:
    for spawn in sim.grenadeSpawns:
      weaponTargets.add((spawn.x, spawn.y))
  var hopperTargets: seq[tuple[x, y: int]]
  if sim.gameMap.hopperSpawns.len > 0:
    for point in sim.gameMap.hopperSpawns:
      hopperTargets.add((point.x, point.y))
  else:
    # NOT the spray-can points: a co-located can pickup would put a can in
    # the looter's hands, and a can carrier cannot fire the gun — the crate
    # would disarm the very cog it just armed. The med-kit points are the
    # harmless fair set (a co-located kit merely heals a hurt looter).
    for point in sim.gameMap.medKitSpawns:
      hopperTargets.add((point.x, point.y))
    for point in sim.gameMap.medKitCandidates:
      hopperTargets.add((point.x, point.y))
    if hopperTargets.len == 0:
      hopperTargets = @[
        (MapWidth div 2, MapHeight div 3),
        (MapWidth div 2, 2 * MapHeight div 3),
      ]
  sim.placeWalkablePickups(weaponSpawns, weaponTargets)
  sim.placeWalkablePickups(hopperSpawns, hopperTargets)
  sim.seedSpawnLoot()

proc resetShields*(sim: var SimServer) =
  ## Places one shield deep in each team's endzone, in the same back column
  ## as the corner grenade pickups but in the BOTTOM half (three quarters of
  ## the map height down) — the spray cans hold the matching top-half spots —
  ## nudged to the nearest walkable floor, and refills both.
  ##
  ## A map that authored its own neutral pool (gameMap.shieldSpawns —
  ## brmapkit round 13, a flagless BR board has no per-team endzone for the
  ## classic formula to anchor into) wins over shieldSpawnPoints()'s
  ## per-team formula, exactly the same "map's own list first, formula
  ## fallback" rule resetMedKits already uses above.
  var targets: seq[tuple[x, y: int]]
  if sim.gameMap.shieldSpawns.len > 0:
    for point in sim.gameMap.shieldSpawns:
      targets.add((point.x, point.y))
  else:
    targets = sim.gameMap.shieldSpawnPoints()
  sim.placeWalkablePickups(shieldSpawns, targets)
  for i in 0 ..< sim.players.len:
    sim.players[i].hasShield = false
    sim.players[i].shieldHp = 0

proc resetSprayPaints*(sim: var SimServer) =
  ## Refills every team's spray can pickup and clears carried cans. Same
  ## "map's own neutral pool first, per-team formula fallback" rule as
  ## resetShields just above (gameMap.spraySpawns — brmapkit round 13).
  var targets: seq[tuple[x, y: int]]
  if sim.gameMap.spraySpawns.len > 0:
    for point in sim.gameMap.spraySpawns:
      targets.add((point.x, point.y))
  else:
    targets = sim.gameMap.sprayPaintSpawnPoints()
  sim.placeWalkablePickups(sprayPaintSpawns, targets)
  sim.sprayPaintFlashes = @[]
  for i in 0 ..< sim.players.len:
    sim.players[i].hasSprayPaint = false
    sim.players[i].arcTicksLeft = 0
    sim.players[i].arcAimBrads = -1
    sim.players[i].arcHitMask = 0

proc resetBarriers*(sim: var SimServer) =
  ## Places the config-gated barrier pickups (none by default), clears every
  ## standing barrier off the field, and empties every cog's hands of
  ## cardboard.
  sim.placeWalkablePickups(
    barrierSpawns,
    sim.gameMap.barrierSpawnPoints(sim.config.barrierPickups)
  )
  sim.placedBarriers = @[]
  for i in 0 ..< sim.players.len:
    sim.players[i].hasBarrier = false

proc resetZone*(sim: var SimServer) =
  ## Draws this game's shrink-zone center ONCE (docs/designs/BR_MAPGEN.md
  ## §4.3): either the AUTHORED `zoneCenter` config point, when set (see
  ## readConfigZoneCenter — already validated at config load to keep the
  ## final rect on-board, so no re-check or RNG draw happens here), or —
  ## the shipping default — deterministically from the sim RNG, uniform
  ## over positions where the FINAL configured phase's rect — the
  ## smallest, most constraining target — fits fully on-board with an
  ## ArenaBorder margin on every side. The whole trajectory (every earlier,
  ## larger phase's rect) derives from this same center; an earlier rect
  ## MAY hang slightly off-board for an off-center draw (only the final
  ## rect's fit is guaranteed — see zoneRectAtScale), which just means
  ## fewer players read as "outside" near that edge during the early game,
  ## exactly like a real battle-royale circle that is not always
  ## dead-center at the drop.
  ##
  ## A no-op when zonePhases is empty: zoneCenter stays (0, 0) and nothing
  ## ever reads it, so an unconfigured game draws nothing extra from the RNG
  ## (byte-identical sim-RNG stream to a build without this field).
  sim.zoneCenter = MapPoint(x: 0, y: 0)
  if sim.config.zonePhases.len == 0:
    return
  if sim.config.zoneCenterConfigured:
    sim.zoneCenter =
      MapPoint(x: sim.config.zoneCenterX, y: sim.config.zoneCenterY)
    return
  let
    finalPermille = sim.config.zonePhases[^1].zPermille
    fw = max(1, sim.gameMap.width * finalPermille div 1000)
    fh = max(1, sim.gameMap.height * finalPermille div 1000)
    loX = ArenaBorder + fw div 2
    hiX = sim.gameMap.width - 1 - ArenaBorder - (fw - 1 - fw div 2)
    loY = ArenaBorder + fh div 2
    hiY = sim.gameMap.height - 1 - ArenaBorder - (fh - 1 - fh div 2)
  sim.zoneCenter =
    if hiX >= loX and hiY >= loY:
      MapPoint(
        x: loX + sim.rng.rand(hiX - loX),
        y: loY + sim.rng.rand(hiY - loY)
      )
    else:
      # The final rect is too large relative to ArenaBorder's margin for ANY
      # center to satisfy the on-board rule (a pathologically large z on a
      # small board) — pin to the map's own center rather than raise
      # mid-match. Draws no RNG either way, so this branch cannot itself
      # desync the rest of the tick's RNG-consuming calls.
      sim.gameMap.center

proc seatCount*(sim: SimServer): int {.inline.} =
  ## How many SEATS (websocket connections) this game has. Classic configs
  ## field one cog per seat; explicit squad configs can field more.
  max(1, sim.config.numAgents)

proc cogSeat*(sim: SimServer, cogIndex: int): int {.inline.} =
  ## Which seat owns a cog. Cogs are dealt round-robin across the teams by
  ## the roster's own slot rule, so cog index parity IS the team ordinal and
  ## therefore the seat: 0, 2, 4, 6 are RED-alpha..delta and 1, 3, 5, 7 are
  ## BLUE-alpha..delta. Keeping the interleave means `teamForSlot` and
  ## `slotIdentityIndex` are inherited unchanged.
  if cogIndex < 0: 0 else: cogIndex mod sim.seatCount()

proc cogIdentityIndex*(sim: SimServer, cogIndex: int): int {.inline.} =
  ## The cog's rank inside its squad: 0 = alpha, 1 = beta, 2 = gamma, 3 = delta.
  if cogIndex < 0: 0 else: (cogIndex div sim.seatCount()) mod IdentityNames.len

proc cogAlias*(sim: SimServer, cogIndex: int): string =
  ## The cog's ANONYMOUS in-game name — "RED-alpha". This is the only name a
  ## seat, a prompt or a shout ever sees; real policy names live spectator
  ## side only (the replay config, roster[].name, teams.<color>.policies,
  ## results.names and the DOM chrome).
  if cogIndex < 0 or cogIndex >= sim.players.len:
    return "?"
  toUpperAscii(teamText(sim.players[cogIndex].team)) & "-" &
    IdentityNames[sim.cogIdentityIndex(cogIndex)]

proc totalCogs*(sim: SimServer): int {.inline.} =
  ## Every cog on the board: one squad per seat.
  sim.seatCount() * max(1, sim.config.cogsPerTeam)

proc seatCommands*(sim: SimServer, seat, cogIndex: int): bool =
  ## Whether `seat` drives this cog under the game's CURRENT regime.
  ## `resident` = the whole squad; `visitor` = alpha only, the other three
  ## run the published `holdline` baseline.
  if sim.cogSeat(cogIndex) != seat:
    return false
  case sim.regime
  of regimeResident: true
  of regimeVisitor: sim.cogIdentityIndex(cogIndex) == 0

proc squadCogs*(sim: SimServer, seat: int): seq[int] =
  ## Every cog of one seat's squad, in index order.
  for i in 0 ..< sim.players.len:
    if sim.cogSeat(i) == seat:
      result.add(i)

proc commandedCogs*(sim: SimServer, seat: int): seq[int] =
  ## The cogs this seat actually commands this game (4 resident, 1 visitor).
  for i in 0 ..< sim.players.len:
    if sim.seatCommands(seat, i):
      result.add(i)

proc armSprayCans*(sim: var SimServer) =
  ## Puts a spray can in every cog's hand and keeps it there — on spawn, on
  ## respawn, on death, ever. With the can held the starter already disables
  ## the gun (docs/RULES.md, canFire), so `resolveSimultaneousFire` is never
  ## populated in a paintball game and no new code is needed for that half.
  if not sim.paintballLoadout():
    return
  for i in 0 ..< sim.players.len:
    sim.players[i].hasSprayPaint = true

proc retireHearts*(sim: var SimServer) =
  ## There is no heart objective under the paintball loadout: `hill` replaces
  ## the capture win condition. Marking every flag RETIRED is the starter's own
  ## out-of-play state (GV32/GV33) — a retired heart is never drawn, cannot be
  ## stolen and cannot be captured — so the objective disappears from the board
  ## and from every observation stream with no new render or pickup branch.
  if not sim.paintballLoadout():
    return
  for team in Team:
    sim.flags[team].carrier = -1
    sim.flags[team].captured = true
  for i in 0 ..< sim.players.len:
    sim.players[i].carryingFlag = false

proc startGame*(sim: var SimServer) =
  sim.logGameEvent("game started: players=" & $sim.players.len)
  sim.recentShots = @[]
  sim.hitFlashes = @[]
  sim.bubbleImpacts = @[]
  sim.splatters = @[]
  sim.paintStains = @[]        ## each match starts on a clean arena.
  sim.diamondStains = @[]
  sim.damagePops = @[]
  sim.shotFeedback = @[]
  sim.gloryDeeds = @[]
  sim.recentShouts = @[]
  sim.arrangeHomePositions()
  # GLORY: every ledger, multiplier and one-shot achievement gate resets at
  # the game boundary -- a per-episode economy that leaked across games
  # would make the first game's heat/claims silently price the second one.
  sim.resetGloryLedger()
  let groupOffset = sim.spawnGroupOffset()
    ## Same offset arrangeHomePositions just used to place every seat (a pure
    ## function of the config seed) — spawnAimBrads' BR path needs it too, so
    ## a rotated team's facing matches the point it actually spawned at.
  for i in 0 ..< sim.players.len:
    sim.players[i].lastShoutTick = -1
    sim.players[i].alive = true
    ## seatLivesFor, not livesFor: this reset runs at MATCH START and used
    ## to overwrite the roster's seating, so a brMode cog got its spares
    ## back here and the header went on lying.
    sim.players[i].lives = sim.config.seatLivesFor(sim.players[i].team)
    sim.players[i].lastDeathTick = -1
    sim.players[i].hp =
      sim.config.maxHpFor(sim.players[i].team, sim.players[i].perks)
    sim.resetLadder(i)
    sim.players[i].grenadeCharges = 0
    sim.players[i].sprayKillsThisPickup = 0
    sim.players[i].gunKills = 0
    sim.players[i].sprayKills = 0
    sim.players[i].grenadeKills = 0
    sim.players[i].longshotKills = 0
    sim.players[i].soakedHp = 0
    sim.players[i].clutchHeals = 0
    sim.players[i].steals = 0
    sim.players[i].carrierKills = 0
    sim.players[i].denials = 0
    sim.players[i].aceKills = 0
    sim.players[i].sprayMultiKills = 0
    sim.players[i].grenadeMultiKills = 0
    sim.players[i].clutchCarryHeals = 0
    sim.players[i].contestedSteals = 0
    sim.players[i].carryKills = 0
    sim.players[i].assists = 0
    sim.players[i].rescues = 0
    sim.players[i].escortKills = 0
    sim.players[i].avengedPartner = false
    sim.players[i].clutchHealTick = -1
    sim.players[i].peelTick = -1
    sim.players[i].lastDamagedBy = -1
    sim.players[i].lastDamagedByTick = -1
    sim.players[i].menacingTick = -1
    sim.players[i].menacingVictim = -1
    sim.players[i].rescuedTick = -1
    sim.players[i].secondWind = false
    sim.players[i].capturedOutnumbered = false
    sim.players[i].capturedFastBreak = false
    sim.players[i].lastKilledBy = -1
    sim.players[i].lastKilledByTick = -1
    sim.players[i].arcEnemyKillsThisFire = 0
    sim.players[i].tookMedKit = false
    sim.players[i].tookGrenade = false
    sim.players[i].tookSpray = false
    sim.players[i].tookShield = false
    sim.players[i].respawnTimer = 0
    sim.players[i].fireCooldown = 0
    sim.players[i].fireWindup = 0
    sim.players[i].windupBrads = -1
    sim.players[i].aimBrads =
      sim.gameMap.spawnAimBrads(sim.players[i].team, groupOffset)
    sim.players[i].flipH =
      sim.gameMap.spawnFlipH(sim.players[i].team, groupOffset)
    sim.players[i].carryingFlag = false
    sim.players[i].hasShield = false
    sim.players[i].shieldHp = 0
    sim.players[i].kills = 0
    sim.players[i].deaths = 0
    sim.players[i].captures = 0
    sim.players[i].shotsFired = 0
    sim.players[i].shotsHit = 0
    sim.players[i].multiKills2 = 0
    sim.players[i].multiKills3 = 0
    sim.players[i].teamKills = 0
    sim.players[i].arcKillsThisFire = 0
    sim.players[i].attacksMade = 0
    sim.players[i].damageTaken = 0
    sim.players[i].damageDealt = 0
    sim.players[i].grenadeDamageDealt = 0
    sim.players[i].gunDamageDealt = 0
    sim.players[i].sprayDamageDealt = 0
    sim.players[i].pitDamageDealt = 0
    sim.players[i].killsThisLife = 0
    sim.players[i].bestKillsInLife = 0
    sim.players[i].healsThisLife = 0
    sim.players[i].bestHealsInLife = 0
    sim.players[i].aliveTicks = 0
    sim.players[i].packTicks = 0
    sim.players[i].hurtByMask = 0
    sim.players[i].assassinKills = 0
    sim.players[i].blastsSurvived = 0
    sim.players[i].zoneOutsideTicks = 0
    # LOOT(s2): per-game loot-rework state. The unarmed spawn IS the
    # loot-start mechanic: hasGun/hasHopper start OFF exactly when
    # lootStart arms and ON otherwise (dark values are never read — the
    # canFire gate short-circuits on the config first).
    sim.players[i].hasGun = not sim.config.lootStart
    sim.players[i].hasHopper = not sim.config.lootStart
    sim.players[i].bandages = 0
    sim.players[i].lastDamageTick = 0
    sim.players[i].downed = false
    sim.players[i].downedTick = 0
    sim.players[i].downedCount = 0
    sim.players[i].downedBy = -1
    sim.players[i].reviveProgress = 0
    sim.players[i].zonePaintBleedBank = 0
    sim.recordGameTeamAssigned(i)
  sim.resetFlags()
  sim.lastCaptureTick = -1
  sim.lastCaptureIndex = -1
  sim.achievementFocus = @[]
  sim.resetGrenades()
  sim.resetShields()
  sim.resetSprayPaints()
  sim.resetBarriers()
  # LOOT(s2): fresh bandages and loot crates per game — both no-ops (empty
  # families) on a dark config. resetLootCrates MUST follow resetGrenades/
  # resetSprayPaints: its fallback crates land on their resolved points.
  sim.resetBandages()
  sim.resetLootCrates()
  sim.resetZone()
  # Paintball: the can is issued for good, the hearts leave play, and the
  # floor starts clean. Each GAME of the episode is an independent board.
  sim.armSprayCans()
  sim.retireHearts()
  for i in 0 ..< sim.players.len:
    sim.players[i].paintUnder = puNone
    sim.players[i].ownPaintTicks = 0
  if sim.config.floorPaint:
    sim.clearPaintGrid()
  sim.feedDirectives = @[]
  sim.emitPhaseChange(Playing)
  sim.phase = Playing
  sim.gameStartTick = sim.tickCount
  sim.timeLimitReached = false
  sim.barrageStartTick = -1
  sim.barrageAccum = 0
  sim.isDraw = false
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1

proc signOf(value: int): int {.inline.} =
  ## Returns the sign of one integer.
  if value < 0:
    return -1
  if value > 0:
    return 1
  0

proc slideScanRadius(sim: SimServer, carry, velocity: int): int =
  ## Returns the perpendicular scan radius for blocked movement.
  let
    pending = abs(carry) div sim.config.motionScale
    speed = (
      abs(velocity) + sim.config.motionScale - 1
    ) div sim.config.motionScale
  clamp(max(1, max(pending, speed)), 1, MovementSlideMaxScan)

proc playersOverlapAt(sim: SimServer, movingIndex, x, y: int): bool =
  ## True when a player footprint centered at (x, y) would overlap another
  ## live player's footprint.
  for i in 0 ..< sim.players.len:
    if i == movingIndex or not sim.players[i].alive:
      continue
    if max(abs(x - sim.players[i].x), abs(y - sim.players[i].y)) <=
        PlayerSolidSpan:
      return true
  false

proc blockingPlayerAt(
  sim: SimServer,
  movingIndex, fromX, fromY, toX, toY: int
): int =
  ## Returns the index of a live player whose body blocks this step, or -1.
  ## A step is blocked when it lands overlapping another body without
  ## increasing the separation — moving apart is always allowed, so bodies
  ## that start overlapped (a respawn onto an occupied home) can escape.
  for i in 0 ..< sim.players.len:
    # LOOT(s2): a ghost (downed) has no body — upright cogs walk through it.
    if i == movingIndex or not sim.players[i].alive or sim.players[i].downed:
      continue
    let toDist =
      max(abs(toX - sim.players[i].x), abs(toY - sim.players[i].y))
    if toDist > PlayerSolidSpan:
      continue
    let fromDist =
      max(abs(fromX - sim.players[i].x), abs(fromY - sim.players[i].y))
    # Refuse only steps that bring the bodies CLOSER. A step that keeps the
    # Chebyshev distance unchanged is parallel motion — two cogs abreast on
    # one row both walking up — and used to be refused as well (`<=`),
    # which deadlocked every duo standing within PlayerSolidSpan of each
    # other: each cog's step was blocked by the other, the slide scan
    # (a few px) could not leave the solid band, and the bounce of two
    # equal velocities changed nothing, so both held the button at full
    # velocity until the zone killed them (GV51; local 16-seat run on
    # 0.7.287, seats 3/11 at (1021,1075)/(1027,1075) for 150 ticks).
    if toDist < fromDist:
      return i
  -1

proc canSlideHorizontal(
  sim: SimServer,
  movingIndex, x, y, step, offset: int
): bool =
  ## Returns true when a horizontal step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canOccupy(x, y + slideStep * i) or
        sim.playersOverlapAt(movingIndex, x, y + slideStep * i):
      return false
  sim.canOccupy(x + step, y + offset) and
    not sim.playersOverlapAt(movingIndex, x + step, y + offset)

proc canSlideVertical(
  sim: SimServer,
  movingIndex, x, y, step, offset: int
): bool =
  ## Returns true when a vertical step can slide by one offset.
  if offset == 0:
    return false
  let slideStep = signOf(offset)
  for i in 1 .. abs(offset):
    if not sim.canOccupy(x + slideStep * i, y) or
        sim.playersOverlapAt(movingIndex, x + slideStep * i, y):
      return false
  sim.canOccupy(x + offset, y + step) and
    not sim.playersOverlapAt(movingIndex, x + offset, y + step)

proc trySlideOffset(
  sim: var SimServer,
  movingIndex, step, offset: int,
  horizontal: bool
): bool =
  ## Tries one candidate slide offset for a blocked movement step.
  template player: untyped = sim.players[movingIndex]
  if horizontal:
    if not sim.canSlideHorizontal(movingIndex, player.x, player.y, step, offset):
      return false
    player.x += step
    player.y += offset
  else:
    if not sim.canSlideVertical(movingIndex, player.x, player.y, step, offset):
      return false
    player.x += offset
    player.y += step
  true

proc trySlideMove(
  sim: var SimServer,
  movingIndex, step, radius, preferredSlide: int,
  horizontal: bool
): bool =
  ## Tries nearby slide offsets for one blocked movement step.
  if radius <= 0:
    return false
  let preferred = signOf(preferredSlide)
  for distance in 1 .. radius:
    if preferred != 0:
      if sim.trySlideOffset(
        movingIndex,
        step,
        preferred * distance,
        horizontal
      ):
        return true
      if sim.trySlideOffset(
        movingIndex,
        step,
        -preferred * distance,
        horizontal
      ):
        return true
    else:
      if sim.trySlideOffset(movingIndex, step, -distance, horizontal):
        return true
      if sim.trySlideOffset(movingIndex, step, distance, horizontal):
        return true
  false

proc bouncePlayers(sim: var SimServer, a, b: int, horizontal: bool) =
  ## Applies a slightly elastic equal-mass collision response along one axis
  ## between two touching players: the axis velocities average out (the
  ## shove) plus playerBouncePct percent of the closing speed rebounds (the
  ## bounce). At 100 this is a billiard-ball velocity swap, at 0 a dead-stop
  ## push.
  let
    pct = sim.config.playerBouncePct
    v1 = if horizontal: sim.players[a].velX else: sim.players[a].velY
    v2 = if horizontal: sim.players[b].velX else: sim.players[b].velY
    total = v1 + v2
    rebound = (v1 - v2) * pct div 100
  if horizontal:
    sim.players[a].velX = (total - rebound) div 2
    sim.players[b].velX = (total + rebound) div 2
  else:
    sim.players[a].velY = (total - rebound) div 2
    sim.players[b].velY = (total + rebound) div 2

proc applyMomentumAxis(
  sim: var SimServer,
  playerIndex, preferredSlide: int,
  horizontal: bool
) =
  ## Applies one fixed-point movement axis with collision sliding. Walls
  ## absorb blocked motion; another player's body blocks the same way but
  ## answers with a slightly elastic shove (bouncePlayers).
  template player: untyped = sim.players[playerIndex]
  let velocity = if horizontal: player.velX else: player.velY
  var carry =
    (if horizontal: player.carryX else: player.carryY) + velocity
  while abs(carry) >= sim.config.motionScale:
    let step = if carry < 0: -1 else: 1
    let
      nx = if horizontal: player.x + step else: player.x
      ny = if horizontal: player.y else: player.y + step
    var blocker = -1
    if sim.canOccupy(nx, ny):
      blocker = sim.blockingPlayerAt(playerIndex, player.x, player.y, nx, ny)
    if sim.canOccupy(nx, ny) and blocker < 0:
      if horizontal:
        player.x = nx
      else:
        player.y = ny
      carry -= step * sim.config.motionScale
    else:
      let radius = sim.slideScanRadius(carry, velocity)
      if sim.trySlideMove(
        playerIndex,
        step,
        radius,
        preferredSlide,
        horizontal
      ):
        carry -= step * sim.config.motionScale
      else:
        if blocker >= 0:
          sim.bouncePlayers(playerIndex, blocker, horizontal)
        carry = 0
        break
  if horizontal:
    player.carryX = carry
  else:
    player.carryY = carry


proc isWall*(sim: SimServer, mx, my: int): bool =
  if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
    return true
  sim.wallMask[mapIndex(mx, my)]

proc isArtWall*(sim: SimServer, mx, my: int): bool =
  ## Static baked wall at this point, excluding the live diamonds.
  if mx < 0 or my < 0 or mx >= MapWidth or my >= MapHeight:
    return true
  for patch in sim.diamondPatches:
    if mx >= patch.x0 and mx < patch.x0 + patch.w and
        my >= patch.y0 and my < patch.y0 + patch.h:
      return patch.baseWall[(my - patch.y0) * patch.w + mx - patch.x0]
  sim.isWall(mx, my)

proc animatedDiamondAt*(sim: SimServer, x, y: int): int =
  ## Index of the live diamond covering (x, y), or -1.
  for i in 0 ..< AnimatedDiamonds.len:
    let spot = AnimatedDiamonds[i]
    if animatedDiamondCovers(
        spot, diamondSpinFrame(spot.cx, spot.cy, sim.tickCount), x, y):
      return i
  -1

proc diamondSpinAngle*(sim: SimServer, diamond: int): float =
  ## Cosmetic angle derived from the geometry/render frame source of truth.
  let frame = diamondSpinFrame(
    AnimatedDiamonds[diamond].cx, AnimatedDiamonds[diamond].cy, sim.tickCount)
  float(frame) / float(DiamondSpinFrames) * PI / 2.0

proc seatInWall*(sim: SimServer, x, y: int, ux, uy: float): (int, int) =
  ## Nudges a wall impact from the FIRST wall pixel a little deeper along the
  ## shot's heading, staying inside the wall. The blot is masked to wall pixels,
  ## so a mark centered exactly on the wall's leading edge loses the half that
  ## overhangs the floor and survives as a thin sliver; seating it into the face
  ## it struck keeps the splat whole. Never crosses back out, so paint on a thin
  ## pillar stays on that pillar.
  result = (x, y)
  for step in 1 .. StainSeatDepth:
    let
      nx = x + int(round(ux * float(step)))
      ny = y + int(round(uy * float(step)))
    if not sim.isWall(nx, ny):
      break
    result = (nx, ny)

proc addPaintStain*(sim: var SimServer, x, y: int, color: uint8,
                    onWall = false) =
  ## Records one DRIED terrain stain at an impact site, if it wins the
  ## StainChancePct roll. Cosmetic only — so this must NOT touch `sim.rng`
  ## (that stream drives gameplay, and drawing from it here would shift every
  ## later roll). Instead the roll and the blot variant come from a hash of the
  ## impact site + tick, the same idiom as shotImpactOffset/fuzzedAimBrads: a
  ## replay re-deriving this tick gets the identical stain, and a viewer that
  ## scrubs sees the paint that existed at that tick.
  if sim.paintStains.len >= StainMaxCount:
    return
  var h = 0x9E3779B9'u32 xor 0x85EBCA6B'u32
  h = (h xor uint32(x)) * 0xC2B2AE35'u32
  h = (h xor uint32(y)) * 0x27D4EB2F'u32
  h = (h xor uint32(sim.tickCount)) * 0x165667B1'u32
  h = h xor (h shr 15)
  if StainChancePct < 100 and int(h mod 100'u32) >= StainChancePct:
    return
  # Paint that hit a ROTATING diamond sticks to that stone, not to the map:
  # store it in the diamond's own frame so it turns with the spin. (A static
  # terrain stain here would also be invisible — the diamond sprite draws over
  # it — and would smear onto the floor the art bakes under the diamond.)
  let diamond = sim.animatedDiamondAt(x, y)
  if diamond >= 0:
    if sim.diamondStains.len >= StainMaxCount:
      return
    let
      spot = AnimatedDiamonds[diamond]
      a = sim.diamondSpinAngle(diamond)
      dx = float(x - spot.cx)
      dy = float(y - spot.cy)
    sim.diamondStains.add DiamondStain(
      diamond: uint8(diamond),
      # Screen offset -> the diamond's un-rotated frame, the same transform
      # rotatingDiamondPixels uses to carve its mask.
      lx: float32(dx * cos(a) + dy * sin(a)),
      ly: float32(-dx * sin(a) + dy * cos(a)),
      color: color,
      seed: h
    )
    return
  sim.paintStains.add PaintStain(
    x: x, y: y, color: color, onWall: onWall, seed: h
  )

proc lineOfSightClear*(sim: SimServer, ax, ay, bx, by: int): bool =
  ## Returns true when no wall blocks the segment between two map points.
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  if steps == 0:
    return true
  for s in 1 .. steps:
    let
      rx = ax + dx * s div steps
      ry = ay + dy * s div steps
    if sim.isWall(rx, ry):
      return false
  true

proc segDistSqWithin*(px, py, ax, ay, bx, by, maxDistSq: int): bool =
  ## True when the point is within sqrt(maxDistSq) of the segment. All-integer
  ## (int64 intermediates so wasm32 and native agree bit-for-bit): the closest
  ## point a + (t/len2)*d is compared without the division by scaling both
  ## sides by len2^2.
  let
    dx = int64(bx - ax)
    dy = int64(by - ay)
    len2 = dx * dx + dy * dy
    apx = int64(px - ax)
    apy = int64(py - ay)
  if len2 == 0:
    return apx * apx + apy * apy <= int64(maxDistSq)
  let t = clamp(apx * dx + apy * dy, 0'i64, len2)
  let
    ex = apx * len2 - t * dx
    ey = apy * len2 - t * dy
  ex * ex + ey * ey <= int64(maxDistSq) * len2 * len2

proc barrierIndexAt*(sim: SimServer, mx, my: int): int =
  ## Index of the standing barrier whose cardboard band covers this map pixel,
  ## or -1. A pixel is covered when it lies within BarrierHalfThick of one of
  ## the three half-hex sides.
  const bandSq = BarrierHalfThick * BarrierHalfThick
  for i in 0 ..< sim.placedBarriers.len:
    let b = sim.placedBarriers[i]
    if mx < b.minX or mx > b.maxX or my < b.minY or my > b.maxY:
      continue
    for side in 0 .. 2:
      if segDistSqWithin(mx, my, b.verts[side].x, b.verts[side].y,
          b.verts[side + 1].x, b.verts[side + 1].y, bandSq):
        return i
  -1

proc playerTouchesBarrier(sim: SimServer, playerIndex, barrierIndex: int): bool =
  ## True when the player's solid footprint reaches the barrier's cardboard
  ## band (the footprint box is treated as a disc of PlayerHalf — the same
  ## radius, deterministic, and a hair forgiving on the corners, which reads
  ## right for "drove into the cardboard").
  const reachSq = (PlayerHalf + BarrierHalfThick) * (PlayerHalf + BarrierHalfThick)
  let
    b = sim.placedBarriers[barrierIndex]
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
  if px < b.minX - PlayerHalf or px > b.maxX + PlayerHalf or
      py < b.minY - PlayerHalf or py > b.maxY + PlayerHalf:
    return false
  for side in 0 .. 2:
    if segDistSqWithin(px, py, b.verts[side].x, b.verts[side].y,
        b.verts[side + 1].x, b.verts[side + 1].y, reachSq):
      return true
  false

proc paintPathClear*(sim: SimServer, ax, ay, bx, by: int): bool =
  ## The check every PAINT path uses (gun corridor samples, spray cone): like
  ## lineOfSightClear, but also stopped by standing cardboard barriers.
  ## Vision (fog shadowcast and the render-side LOS) keeps the wall-only
  ## test — cardboard blocks paint, never sight. Zero extra cost when no
  ## barrier stands.
  if not sim.lineOfSightClear(ax, ay, bx, by):
    return false
  if sim.placedBarriers.len == 0:
    return true
  let
    dx = bx - ax
    dy = by - ay
    steps = max(abs(dx), abs(dy))
  for s in 1 .. steps:
    if sim.barrierIndexAt(ax + dx * s div steps, ay + dy * s div steps) >= 0:
      return false
  true

proc paintConeTiles*(sim: var SimServer, attackerIndex: int): tuple[tiles, hillTiles: int] =
  ## NEW (paintball): repaints every PAINTABLE tile whose CENTRE lies inside
  ## this cog's active cone, in the sprayer's team colour. Called once per
  ## active cone per tick from resolveActiveArcCones, in cog index order, so
  ## two cones overlapping a tile on one tick resolve deterministically.
  ##
  ## The predicate is `tileInCone` — the starter's cone geometry with the
  ## victim's body radius set to zero — and paint respects line of sight for
  ## the same reason damage does: paint does not go through a wall.
  ##
  ## Only tiles inside the cone's bounding box are considered, so the sweep
  ## costs a couple of hundred integer tests per burst rather than a scan of
  ## all 740 tiles.
  if not sim.config.floorPaint:
    return (0, 0)
  if attackerIndex < 0 or attackerIndex >= sim.players.len:
    return (0, 0)
  let attacker = sim.players[attackerIndex]
  if attacker.arcTicksLeft <= 0 or attacker.arcAimBrads < 0:
    return (0, 0)
  let
    ax = attacker.x + CollisionW div 2
    ay = attacker.y + CollisionH div 2
    reach = SprayPaintReach
    maxWidth = SprayPaintMaxWidth
    size = sim.paintTileSize()
    team = attacker.team
    x0 = max(0, (ax - reach) div size)
    y0 = max(0, (ay - reach) div size)
    x1 = min(sim.paintGridW - 1, (ax + reach) div size)
    y1 = min(sim.paintGridH - 1, (ay + reach) div size)
  for ty in y0 .. y1:
    for tx in x0 .. x1:
      let tile = ty * sim.paintGridW + tx
      if not sim.paintFloor[tile]:
        continue
      let (cx, cy) = sim.paintTileCentre(tile)
      if not tileInCone(ax, ay, attacker.arcAimBrads, reach, maxWidth, cx, cy):
        continue
      if not sim.paintPathClear(ax, ay, cx, cy):
        continue
      let onHill = sim.hillContains(tile)
      if sim.paintTile(tile, team):
        inc result.tiles
        if onHill:
          inc result.hillTiles

proc flattenBarrier(sim: var SimServer, index: int, color: uint8,
                    cause: string) =
  ## Removes one standing barrier with a crumple splatter at its center
  ## (cosmetic only) and a log line; `color` picks the splatter/log actor.
  let b = sim.placedBarriers[index]
  sim.splatters.add SplatterFx(
    x: b.x, y: b.y, tick: sim.tickCount, color: color, hit: false
  )
  sim.logGameEvent(playerColorText(color) & " " & cause)
  sim.placedBarriers.delete(index)

proc damageBarrier(sim: var SimServer, index, hitX, hitY: int, color: uint8) =
  ## Applies one paintball hit to a standing barrier: a splat on the
  ## cardboard, and after BarrierHp hits the barrier is gone.
  sim.splatters.add SplatterFx(
    x: hitX, y: hitY, tick: sim.tickCount, color: color, hit: false
  )
  dec sim.placedBarriers[index].hp
  if sim.placedBarriers[index].hp <= 0:
    sim.flattenBarrier(index, color, "shredded a cardboard barrier")

proc gameTicksElapsed*(sim: SimServer): int =
  ## Returns ticks elapsed since the current game left the lobby.
  if sim.gameStartTick < 0:
    return 0
  max(0, sim.tickCount - sim.gameStartTick)

proc effectiveMaxTicks*(sim: SimServer): int =
  ## Returns the game's scheduled tick limit (0 = no limit). GV41 removed
  ## the action-floor overtime, so this is exactly config.maxTicks; kept as
  ## a proc because the broadcast chrome reads the schedule through it.
  max(0, sim.config.maxTicks)

proc barrageFullDepth*(): int =
  ## The edge depth at which the four target bands cover the whole board:
  ## past half the shorter axis the two bands on that axis meet.
  min(MapWidth, MapHeight) div 2 + 1

proc barrageProgressPermille*(sim: SimServer): int =
  ## Returns how far the barrage has escalated, 0..1000: 0 at the latch,
  ## 1000 once barrageSaturateSec has elapsed — at the default settings
  ## (latch 30s before the end, saturate in 30s) the whole board is under
  ## maximum bombardment exactly when the clock reads 0:00. Pure integer
  ## math off deterministic state (latch tick + tick count), so native,
  ## wasm, and replays all agree.
  if sim.barrageStartTick < 0 or sim.config.barrageMaxPerSec <= 0:
    return 0
  let rampTicks = max(1, sim.config.barrageSaturateSec * TargetFps)
  min(1000, (sim.tickCount - sim.barrageStartTick) * 1000 div rampTicks)

proc barrageDepth*(sim: SimServer): int =
  ## Returns how deep inside every map edge the barrage currently targets,
  ## in px; 0 while the barrage is off or not yet latched. Starts at
  ## BarrageEdgeBandPx and deepens linearly to full board coverage.
  if sim.barrageStartTick < 0:
    return 0
  let progress = sim.barrageProgressPermille()
  BarrageEdgeBandPx +
    (barrageFullDepth() - BarrageEdgeBandPx) * progress div 1000

proc barrageRatePermille*(sim: SimServer): int =
  ## Returns the current launch rate in permille grenades/second: the
  ## configured start rate at the latch, ramping linearly to the max rate as
  ## the escalation completes.
  if sim.barrageStartTick < 0:
    return 0
  sim.config.barrageStartPerSec * 1000 +
    (sim.config.barrageMaxPerSec - sim.config.barrageStartPerSec) *
      sim.barrageProgressPermille()

proc downPlayer(
  sim: var SimServer,
  targetIndex, killerIndex: int,
  killerSlot = -1
) =
  ## LOOT(s2): turns a lethally-hit cog into a GHOST of itself (downedMode):
  ## frozen in place, non-colliding, unable to act or loot, still holding
  ## its carried items — except a heart, which goes home exactly as a death
  ## sends it home (a ghost cannot score and must not freeze the objective
  ## under its body). The team keeps its chance: an upright teammate tag
  ## revives (updateDowned), an enemy paintball splats (applyFire), and an
  ## untagged ghost bleeds out. Called ONLY from killPlayer's interception,
  ## so every lethal-hit chokepoint funnels here without new call sites.
  template victim: untyped = sim.players[targetIndex]
  for team in sim.teams():
    if sim.flags[team].carrier == targetIndex:
      sim.logGameEvent(teamText(team) & " heart returned home")
      sim.resetFlag(team)
  victim.carryingFlag = false
  victim.hp = 0
  victim.velX = 0
  victim.velY = 0
  victim.carryX = 0
  victim.carryY = 0
  victim.fireWindup = 0
  victim.windupBrads = -1
  victim.arcTicksLeft = 0
  victim.arcAimBrads = -1
  victim.throwCharge = 0
  victim.puddleTicks = 0
  victim.zoneOutsideTicks = 0
  victim.downed = true
  victim.downedTick = sim.tickCount
  inc victim.downedCount
  victim.downedBy = killerIndex
  victim.reviveProgress = 0
  # ZONEPAINT: every down starts with a clean acceleration bank (unhashed,
  # 0-over-0 when dark — sim_types.nim's field note).
  victim.zonePaintBleedBank = 0
  sim.emitEvent(
    Downed, source = targetIndex, target = killerIndex,
    amount = victim.downedCount, hp = 0,
    x = float(victim.x + CollisionW div 2),
    y = float(victim.y + CollisionH div 2),
    targetSlot = killerSlot
  )
  sim.logGameEvent(playerColorText(victim.color) & " is down")

proc recutZonePhase*(sim: SimServer, elapsedTicks: int):
    tuple[closing, final: bool] =
  ## RECUT(v13, table §1b): where the shrink schedule stands at a tick, for
  ## the BR marquee band's two zone deeds. `closing` = the zone is actively
  ## shrinking (inside some phase's shrink segment — instant snaps,
  ## shrinkTicks <= 0, never count as closing); `final` = play has entered
  ## the LAST authored phase (its wait, its shrink, or the hold-forever
  ## after it). Same phase walk as zoneRectAndDpsRaw, minus the geometry —
  ## a pure function of config + elapsed ticks, nothing stored or hashed.
  ## Callers guard `zonePhases.len > 0` (both fields false without a
  ## schedule — no zone, no zone deeds).
  result = (closing: false, final: false)
  if sim.config.zonePhases.len == 0:
    return
  var t = max(0, elapsedTicks)
  for i, phase in sim.config.zonePhases:
    let isLast = i == sim.config.zonePhases.len - 1
    if t < phase.waitTicks:
      return (closing: false, final: isLast)
    t -= phase.waitTicks
    if phase.shrinkTicks > 0 and t < phase.shrinkTicks:
      return (closing: true, final: isLast)
    if phase.shrinkTicks > 0:
      t -= phase.shrinkTicks
  # Every phase's wait+shrink has elapsed: holding at the final circle.
  result = (closing: false, final: true)

proc recutContextK*(sim: SimServer, killerIndex, victimIndex: int): int =
  ## RECUT(v13, table §2): k — teammates-in-context — for the Fibonacci
  ## ally-stack on ONE kill, computed once at the mint against the shared
  ## fact (contract §7a). The context predicate is the contract-named one:
  ## participation in the victim's open damage incident (the dJointAct
  ## window machinery — `recutDamageMarks`, 120-tick merge), counting
  ## distinct participating cogs:
  ##
  ##   - CTF: literal same-team players (§2) — the killer plus every
  ##     teammate with a qualifying hit on this victim inside the window.
  ##   - BR: allies-in-context (§2's ruled widening) — the killer's own
  ##     duo PLUS cogs of OTHER duos co-engaged on the same victim in the
  ##     window (a truce/joint-act moment, the dJointAct predicate). The
  ##     victim's own duo never counts (friendly fire is never an
  ##     alliance — the spec's own exclusion).
  ##
  ## Exact ally-counting refinement (who counts, how a window closes) is
  ## PARKED BEHIND T5 by the table itself; this is the minimal
  ## contract-named predicate, flagged as such to conformance review.
  ## Friendly kills return 1 (no stack on a penalty). k >= the table's last
  ## column clamps in `recutStackMult`.
  if killerIndex < 0 or killerIndex >= sim.players.len or
      victimIndex < 0 or victimIndex >= sim.players.len:
    return 1
  let
    killerTeam = sim.players[killerIndex].team
    victimTeam = sim.players[victimIndex].team
  if killerTeam == victimTeam:
    return 1
  var participants: seq[int] = @[killerIndex]
  if victimIndex < sim.recutDamageMarks.len:
    for mark in sim.recutDamageMarks[victimIndex]:
      if sim.tickCount - mark.tick > AssistWindowTicks:
        continue
      if mark.attacker < 0 or mark.attacker >= sim.players.len:
        continue
      if mark.attacker in participants:
        continue
      let attackerTeam = sim.players[mark.attacker].team
      if attackerTeam == victimTeam:
        continue
      if attackerTeam == killerTeam or sim.config.brMode:
        participants.add mark.attacker
  participants.len

proc killPlayer*(
  sim: var SimServer,
  targetIndex,
  killerIndex: int,
  killerSlot = -1,
  elimination = false,
  cause = "",
  weapon = "",
  multi = false
) =
  ## Applies a fatal hit: return any carried flag to its pedestal, decrement
  ## lives, start respawn. GV35: an `elimination` death (the team's heart was
  ## captured, so everyone folds with it) is a mechanical death only — no
  ## deaths-stat increment and no per-player "killed by" line, because nobody
  ## shot these players; the team lost. The endscreen's D column stays a
  ## record of combat deaths.
  ##
  ## GLORY PORT (increment 2/3): `weapon`/`multi` are appended (never inserted) so
  ## every existing positional call site (`sim.killPlayer(victimIndex,
  ## attacker)`, `sim.killPlayer(i, throwerIndex, throwerSlot, cause = ...)`)
  ## keeps binding its own args exactly where it already did. This is ALSO
  ## the single chokepoint where a kill is PRICED, same discipline main's
  ## own killPlayer used -- the three weapon damage sites (gun/spray-arc/
  ## grenade) each already know their own weapon and multi-kill state
  ## first-hand, so they pass it in here rather than this proc guessing by
  ## counter-diffing.
  if targetIndex < 0 or targetIndex >= sim.players.len:
    return
  if not sim.players[targetIndex].alive:
    return
  # LOOT(s2): under downedMode a lethal hit DOWNS instead of kills. The
  # whole kill flow below (pricing, Death event, deaths stat, lives,
  # respawn) is deferred to the ghost's finalization — finalizeDowned
  # re-enters here with the victim still flagged `downed`, which is what
  # lets it past this check. An `elimination` fold is never downed: the
  # team is gone, nobody is left to tag anyone back. The weapon site's own
  # Kill credit/event (outside this proc) still lands at the DOWN — the
  # down IS the combat achievement; the eventual Death is bookkeeping.
  # Dark-inert: downedMode is false on every existing config.
  if sim.config.downedMode and not elimination and
      not sim.players[targetIndex].downed:
    sim.downPlayer(targetIndex, killerIndex, killerSlot)
    return
  if not elimination:
    # GLORY: read the kill CONTEXT before anything below mutates it -- the
    # flag-return loop a few lines down clears `carryingFlag`, so asking
    # afterwards would price every peel as a plain kill, and the peel is
    # the deed most worth being able to see. Skipped for an `elimination`
    # death (a captured team folding, not a combat kill -- nobody shot
    # these players) for the same reason the deaths-stat/log-line guard
    # above it exists.
    block priceTheKill:
      if killerIndex < 0 or killerIndex >= sim.players.len:
        break priceTheKill
      let
        victim = sim.players[targetIndex]
        killer = sim.players[killerIndex]
        victimHome = sim.gameMap.flagHome(victim.team)
        dxHome = victim.x - victimHome.x
        dyHome = victim.y - victimHome.y
        dx = victim.x - killer.x
        dy = victim.y - killer.y
        opening = dx * victim.velX + dy * victim.velY
      # N-team generalization of source's `sim.flags[enemy(killer.team)]`:
      # "a TEAMMATE (not the killer) currently runs ANY enemy heart", same
      # extension `awardDeed`'s own carry-hold check above uses.
      var escortCarrier = -1
      for otherTeam in sim.teams():
        if otherTeam == killer.team: continue
        let c = sim.flags[otherTeam].carrier
        if c >= 0 and sim.players[c].team == killer.team and c != killerIndex:
          escortCarrier = c
          break
      # GLORY v11 (BR increment 3): the three distance gates below are
      # priced as a FRACTION of THIS map's gunRange, not an absolute px
      # figure -- see `CtfReferenceGunRange`'s own comment on `glory.nim`.
      # `denialPxFor` resolves once here (rather than inline in the
      # KillContext literal below) so the SAME number backs both
      # `nearVictimHome` and any future caller; `pointBlankPxFor`/
      # `longshotPxFor` resolve inside `killDeed` itself off `ctx.gunRange`.
      let denialPxNow = denialPxFor(sim.config.gunRange)
      # GLORY v11 (BR increment 3): "PAYBACK" (`dRevengeKill`) re-gated onto
      # the DEAD DUO PARTNER's killer in brMode, where `avengesKiller` above
      # can never fire -- a killer who had ever died is already permanently
      # eliminated in a one-life episode, so it can never be the one
      # pulling the trigger now. A duo's partner is simply the other cog
      # sharing `killer.team` (BR seats exactly two per team). Tapered to
      # at most one mint per cog per episode via `avengedPartner`, checked
      # here so a cog that already collected its payback never re-arms.
      var avengesPartner = false
      if sim.config.brMode and not killer.avengedPartner:
        for i, p in sim.players:
          if p.team == killer.team and i != killerIndex:
            if not p.alive and p.lastKilledBy == targetIndex:
              avengesPartner = true
            break
      let ctx = KillContext(
        friendly: victim.team == killer.team,
        victimCarrying: victim.carryingFlag,
        nearVictimHome: dxHome * dxHome + dyHome * dyHome <=
                        denialPxNow * denialPxNow,
        victimLevel: victim.level,
        multi: multi,
        rangePx: int(sqrt(float(dx * dx + dy * dy))),
        gunRange: sim.config.gunRange,
        weaponSpray: weapon == "spray",
        weaponGrenade: weapon == "grenade",
        avengesKiller: killer.lastKilledBy == targetIndex and
                       killer.lastKilledByTick >= 0 and
                       sim.tickCount - killer.lastKilledByTick <= RevengeTicks,
        avengesPartner: avengesPartner,
        fleeing: opening > 0,
        escorted: escortCarrier >= 0
      )
      var deed = killDeed(ctx)
      # ── MULTIPLIER RECUT (v13, armed) ── kill-site context, computed
      # ONCE against the shared fact and passed down to the single mint
      # (contract §7a). Dark path: stackK stays 1 and `deed` is exactly
      # `killDeed(ctx)` — not a byte of the v12 flow moves.
      var stackK = 1
      if sim.config.gloryMultiplierRecut:
        stackK = sim.recutContextK(killerIndex, targetIndex)
        # BR-native marquee band (table §1b), UPGRADE-ONLY under the
        # one-kill-one-deed law: the kill re-classifies to a marquee deed
        # only when that deed's recut class is STRICTLY higher than the
        # resolved one — the anti-stacking rule keeps one label per kill,
        # and "the more specific, rarer feat" (killDeed's own principle)
        # is read in class order. Precedence inside the band: dLastLight
        # (×4) > dDuoDown (×2) > dClosingTime (×2) — duo-finishing is the
        # more specific fact than time-of-kill at equal class. A marquee
        # fact shadowed by a higher-class kill deed goes unminted
        # (flagged to conformance review, same one-deed law as every
        # other co-satisfied kill).
        if sim.config.brMode and not ctx.friendly:
          var marquee = dNone
          if sim.config.zonePhases.len > 0:
            let zone = sim.recutZonePhase(sim.tickCount - sim.gameStartTick)
            if zone.final: marquee = dLastLight
            elif zone.closing: marquee = dClosingTime
          if marquee != dLastLight:
            # Finish off an enemy duo: this kill leaves no member of the
            # victim's team alive. Under armed downedMode a downed-but-
            # unfinalized partner still reads `alive`, so the duo-down
            # fires at the FINALIZE that truly empties the duo — the same
            # once-at-finalize timing the FF ruling recorded.
            var partnerAlive = false
            for i, p in sim.players:
              if i != targetIndex and p.team == victim.team and p.alive:
                partnerAlive = true
                break
            if not partnerAlive and RecutClassTable[dDuoDown] >=
                RecutClassTable[marquee]:
              marquee = dDuoDown
          if marquee != dNone and
              RecutClassTable[marquee] > RecutClassTable[deed]:
            deed = marquee
      # Glory-toast channel source (GameConfig.allowCosmeticFx): `fxActor`
      # is -1 for a grenade-caused kill regardless of which deed `killDeed`
      # resolved to -- the swap9-era wire never wired the grenade blast-kill
      # site (fragile GV24-hash attribution branch); this keeps the same
      # class of kill silent on the toast wire even now that every weapon
      # funnels through this one chokepoint. See `awardDeed`'s own doc
      # comment on `fxActor` for the full rationale.
      sim.awardDeed(killer.team, deed, victim.x, victim.y,
                    byIndex = killerIndex,
                    fxActor = (if ctx.weaponGrenade: -1 else: killerIndex),
                    stackK = stackK)
      # The taper only latches once the payback ACTUALLY minted: a kill
      # that also satisfies a higher-precedence descriptor (an ace tag, a
      # denial, ...) resolves to that deed instead, same as `avengesKiller`
      # already yields precedence in every other case `killDeed` covers.
      if deed == dRevengeKill and avengesPartner:
        sim.players[killerIndex].avengedPartner = true
      # Achievement counters, keyed off the RESOLVED deed so they can never
      # disagree with what was actually minted.
      if not ctx.friendly:
        if ctx.weaponSpray:
          inc sim.players[killerIndex].sprayKills
          inc sim.players[killerIndex].sprayKillsThisPickup
        elif ctx.weaponGrenade:
          inc sim.players[killerIndex].grenadeKills
        else:
          inc sim.players[killerIndex].gunKills
        # `longshotKills` tracks the raw DISTANCE fact (same as before this
        # version), independent of which deed precedence actually resolved
        # to -- a long-range kill that ALSO satisfies a higher-priority
        # deed (an ace tag, a denial, ...) still counts here, same as it
        # did when this compared against the flat `LongshotPx` constant.
        # Only the THRESHOLD moved (now a fraction of `ctx.gunRange`, see
        # `CtfReferenceGunRange`), never this counter's own semantics.
        if ctx.rangePx >= longshotPxFor(ctx.gunRange):
          inc sim.players[killerIndex].longshotKills
        if ctx.victimLevel >= AceLevel:
          inc sim.players[killerIndex].aceKills
        if ctx.victimCarrying:
          inc sim.players[killerIndex].carrierKills
          sim.players[killerIndex].peelTick = sim.tickCount
          if ctx.nearVictimHome: inc sim.players[killerIndex].denials
        if killer.carryingFlag: inc sim.players[killerIndex].carryKills
        if ctx.escorted:
          inc sim.players[killerIndex].escortKills
        let victimDamager = victim.lastDamagedBy
        if victimDamager >= 0 and victimDamager < sim.players.len and
           victimDamager != killerIndex and
           sim.players[victimDamager].team == killer.team and
           victim.lastDamagedByTick >= 0 and
           sim.tickCount - victim.lastDamagedByTick <= AssistWindowTicks:
          inc sim.players[victimDamager].assists
          # GLORY v12 FOLD (Amendment 3 Option C): the assist is a PRICED
          # deed in CTF now -- same facts, same single-slot/window predicate
          # as the counter line above, credited to the assister (never the
          # killer, who just banked the kill deed at this same site). The
          # BR overlay rides increment 2, hence the mode gate.
          if not sim.config.brMode:
            sim.awardDeed(killer.team, dAssist, victim.x, victim.y,
                          byIndex = victimDamager)
        if victim.menacingTick >= 0 and
           sim.tickCount - victim.menacingTick <= RescueWindowTicks:
          let menaced = victim.menacingVictim
          if menaced >= 0 and menaced < sim.players.len and
             menaced != killerIndex and
             sim.players[menaced].team == killer.team:
            inc sim.players[killerIndex].rescues
            sim.players[menaced].rescuedTick = sim.tickCount
            # GLORY v12 FOLD (Amendment 3 Option C): the rescue is a PRICED
            # deed in CTF now, with ONE deliberate predicate difference
            # from the counter above: the menaced teammate must be ALIVE at
            # mint time -- "the whole point is the partner survived" (spec
            # Part 1). A rescue whose partner already died still counts as
            # engine telemetry, but it is not the celebrated act. BR rides
            # increment 2, hence the mode gate.
            if not sim.config.brMode and sim.players[menaced].alive:
              sim.awardDeed(killer.team, dRescue, victim.x, victim.y,
                            byIndex = killerIndex)
        if killer.rescuedTick >= 0 and
           sim.tickCount - killer.rescuedTick <= SecondWindTicks:
          sim.players[killerIndex].secondWind = true
        sim.recordTeamKillRing(killer.team, killerIndex)
      if not sim.firstBloodDone and not ctx.friendly:
        sim.firstBloodDone = true
        sim.awardDeed(killer.team, dFirstBlood, victim.x, victim.y,
                      byIndex = killerIndex)
      sim.addXp(killerIndex, killXp(ctx))
    sim.players[targetIndex].lastKilledBy = killerIndex
    sim.players[targetIndex].lastKilledByTick = sim.tickCount
    # An environmental death (cause text, no killer) logs its own line; a
    # combat death keeps the classic "killed by" attribution.
    if cause.len > 0:
      sim.logGameEvent(
        playerColorText(sim.players[targetIndex].color) & " " & cause)
    else:
      sim.logGameEvent(
        playerColorText(sim.players[targetIndex].color) &
          " killed by " & sim.playerText(killerIndex)
      )
  # RECUT(v13): a death closes the victim's damage incident — a fresh life
  # starts a fresh dJointAct window (the alliance-vocab spec's own rule).
  # The seq only ever fills while the recut is armed, so this is a no-op on
  # every dark path.
  if targetIndex < sim.recutDamageMarks.len:
    sim.recutDamageMarks[targetIndex] = @[]
  # A dying trigger pull never releases, and a carried grenade is lost.
  sim.players[targetIndex].fireWindup = 0
  sim.players[targetIndex].windupBrads = -1
  sim.players[targetIndex].hasGrenade = false
  sim.players[targetIndex].hasShield = false
  sim.players[targetIndex].shieldHp = 0
  # Under the paintball loadout the can is never lost: a tagged-out cog comes
  # back holding it, because there is nowhere on the map to pick another up.
  sim.players[targetIndex].hasSprayPaint = sim.paintballLoadout()
  sim.players[targetIndex].arcTicksLeft = 0
  sim.players[targetIndex].arcAimBrads = -1
  sim.players[targetIndex].throwCharge = 0
  sim.players[targetIndex].ownPaintTicks = 0
  sim.players[targetIndex].paintUnder = puNone
  sim.players[targetIndex].hasBarrier = false  # carried cardboard is lost too.
  # PERCEPTION(glory-2 §17): the death-drop clear — a looted marker/hopper
  # is lost on a real death (this chokepoint also re-entered from
  # finalizeDowned, so a ghost's eventual bleed-out/splat drops it too;
  # downPlayer itself never reaches here, which is what lets the flags
  # persist through the downed window). Gated on lootStart, never
  # frameLoadoutFlags: this is the engine TRUTH the perception flag only
  # exposes. Dark-inert in every other mode, where hasGun/hasHopper sit at
  # their spawn-armed constant true and this branch never runs — the
  # "classic emits constant true/true" contract stays intact.
  if sim.config.lootStart:
    sim.players[targetIndex].hasGun = false
    sim.players[targetIndex].hasHopper = false
  sim.players[targetIndex].puddleTicks = 0
  for team in sim.teams():
    if sim.flags[team].carrier == targetIndex:
      sim.players[targetIndex].carryingFlag = false
      sim.logGameEvent(teamText(team) & " heart returned home")
      sim.resetFlag(team)
  # Leave a cosmetic splatter at the death spot (never enters gameHash).
  sim.splatters.add SplatterFx(
    x: sim.players[targetIndex].x,
    y: sim.players[targetIndex].y,
    tick: sim.tickCount,
    color: sim.players[targetIndex].color,
    hit: false
  )
  # No permanent stain at the death spot either: the paint that killed this cog
  # landed ON the cog, and the fading splatter above is the record of it. Only
  # paint that MISSED and reached terrain leaves a mark on terrain.
  # A floating "SPLAT" kill marker rises and fades from the death spot — the same
  # mechanism as the "-1" damage pops, so a kill reads at a glance in the
  # spectator/replay view (cosmetic only, never in gameHash).
  sim.damagePops.add DamageFx(
    x: sim.players[targetIndex].x + CollisionW div 2,
    y: sim.players[targetIndex].y + CollisionH div 2,
    tick: sim.tickCount,
    amount: 0,
    color: sim.players[targetIndex].color,
    kill: true
  )
  sim.players[targetIndex].alive = false
  # GLORY: THE ANTI-SNOWBALL RULE -- a cog's whole per-life ladder dies with
  # it. This is the price of granting real power at all, and on BR (one
  # life = the episode) it is what still bounds a levelled cog to one life
  # even though there is only ever one life to bound.
  #
  # GLORY-PORT-TODO: main also leaves a lingering ace glow/star-row at the
  # death spot here (`sim.aceDeathFx.add AceDeathFx(...)`, gated on
  # `level >= AceLevel`, captured before this reset zeroes it) -- that FX
  # type/renderer isn't ported (see this port's report: FX pop RENDERING
  # is out of scope, only the data-producing side is in). The ladder reset
  # itself is unaffected; only the cosmetic lingering glow is missing.
  sim.resetLadder(targetIndex)
  sim.players[targetIndex].grenadeCharges = 0
  sim.players[targetIndex].killsThisLife = 0
  sim.players[targetIndex].healsThisLife = 0
  sim.players[targetIndex].hurtByMask = 0   # the next life starts untouched
  sim.players[targetIndex].velX = 0
  sim.players[targetIndex].velY = 0
  sim.players[targetIndex].carryX = 0
  sim.players[targetIndex].carryY = 0
  # GV35: elimination deaths never touch the deaths stat — the counter (and
  # the killfeed/scrubber markers diffed from it) records combat only.
  if not elimination:
    sim.recordDeath(targetIndex)
  # Death is the victim-side record (source = victim, target = killer); the
  # weapon-attributed Kill is emitted by each weapon's own damage site, where
  # the weapon is known first-hand.
  sim.emitEvent(
    Death, source = targetIndex, target = killerIndex,
    x = float(sim.players[targetIndex].x + CollisionW div 2),
    y = float(sim.players[targetIndex].y + CollisionH div 2),
    targetSlot = killerSlot
  )
  # When this cog died, for the BR timeout tiebreak's "stayed alive longer"
  # rank. Written for every mode (it is one int and costs nothing), read
  # only by brTiebreakWinner.
  sim.players[targetIndex].lastDeathTick = sim.tickCount
  if sim.config.brMode:
    # BR: no respawns, ever — one death is out regardless of the configured
    # `lives`/`respawnTicks`. Reuse eliminateTeam's existing "permanently
    # out" contract (lives = 0) instead of a new sentinel, so every reader
    # that already understands lives == 0 (respawnPlayers, teamHasLivePlayers,
    # teamLivesRemaining, the HUD, gameHash) handles a BR death correctly
    # with no further changes.
    sim.players[targetIndex].lives = 0
  elif sim.players[targetIndex].lives > 0:
    dec sim.players[targetIndex].lives
  sim.players[targetIndex].respawnTimer =
    if sim.players[targetIndex].lives > 0:
      max(1, sim.config.respawnTicks)
    else:
      0
  # LOOT(s2): a real death always clears ghosthood — both finalization and
  # the eliminateTeam fold land here. A no-op on every dark game (both
  # fields already 0/false).
  sim.players[targetIndex].downed = false
  sim.players[targetIndex].reviveProgress = 0
  sim.players[targetIndex].zonePaintBleedBank = 0

proc finalizeDowned(
  sim: var SimServer,
  targetIndex, killerIndex: int,
  cause: string
) =
  ## LOOT(s2): a ghost's PERMANENT death — splat (applyFire), bleed-out or
  ## team-wipe (updateDowned). Routes through killPlayer with the victim
  ## still flagged `downed`, which is exactly what carries it past the
  ## downedMode interception at the top of killPlayer: a ghost dying is the
  ## deferred real death, not a new down. `cause` is the log-line text
  ## (killPlayer's own environmental-death convention); the event stream
  ## reads the cause from the Downed→Death pairing instead.
  if targetIndex < 0 or targetIndex >= sim.players.len:
    return
  if not sim.players[targetIndex].downed:
    return
  sim.killPlayer(targetIndex, killerIndex, cause = cause)

proc absorbDamage*(
  sim: var SimServer,
  targetIndex: int,
  amount: int,
  attackerIndex = -1,
  weapon = ""
): int {.discardable.} =
  ## Applies damage to a player: the shield layer soaks hits before base hp.
  ## Callers keep their own death checks on the base hp that remains. Returns
  ## how many hp the shield layer absorbed (`fromShield`) — first-hand `blocked`
  ## for the tier-2 Damage event; callers that don't need it can ignore it.
  ##
  ## This is the ONE subtraction point, so the achievement analysis counters
  ## live here: the victim's damageTaken always (shield hits included — being
  ## hit at all breaks `spotless`), and, when the caller names an attacker,
  ## that attacker's damageDealt (self-damage excluded) with its grenade
  ## share. Environmental damage (puddles, barrage shells) passes no attacker.
  ## GV47 credits the attacker's reward account from the same spot, split
  ## enemy/teammate — see roster.recordHitDamage.
  ##
  ## `assassin` is judged here too: a gun or grenade hit that drops the
  ## victim from living hp to none, landed by an attacker that had not yet
  ## touched this victim in this life (hurtByMask), is a first-touch kill
  ## shot. Spray never qualifies, and neither does a teammate.
  let hpBefore = sim.players[targetIndex].hp
  inc sim.players[targetIndex].damageTaken, amount
  # LOOT(s2): the bandage calm clock — a bandage self-applies only after
  # BandageApplyTicks without taking damage (updateBandageApplies). Stamped
  # only while the bandage mechanism is armed, so a dark game's field never
  # leaves 0.
  if sim.config.bandagePickups > 0 and amount > 0:
    sim.players[targetIndex].lastDamageTick = sim.tickCount
  # RECUT(v13): the per-victim damager history feeding the Fibonacci
  # stack's k — the dJointAct incident-window machinery (alliance-vocab
  # spec 2026-09-01: per-victim damage incidents, `AssistWindowTicks`=120
  # as the ruled shared merge constant; environmental damage — no
  # attacker — can never open or join a window). Armed-only maintained:
  # a dark game never touches these seqs, and they stay out of gameHash
  # either way (derived state — see the field's own comment).
  if sim.config.gloryMultiplierRecut and attackerIndex >= 0 and
      attackerIndex != targetIndex and amount > 0:
    while sim.recutDamageMarks.len < sim.players.len:
      sim.recutDamageMarks.add newSeq[tuple[attacker: int, tick: int]]()
    var kept = newSeq[tuple[attacker: int, tick: int]]()
    for mark in sim.recutDamageMarks[targetIndex]:
      if sim.tickCount - mark.tick <= AssistWindowTicks:
        kept.add mark
    kept.add (attacker: attackerIndex, tick: sim.tickCount)
    sim.recutDamageMarks[targetIndex] = kept
  var firstTouch = false
  if attackerIndex >= 0 and attackerIndex != targetIndex:
    if attackerIndex < 32:
      let bit = 1'u32 shl attackerIndex
      firstTouch = (sim.players[targetIndex].hurtByMask and bit) == 0
      sim.players[targetIndex].hurtByMask =
        sim.players[targetIndex].hurtByMask or bit
    inc sim.players[attackerIndex].damageDealt, amount
    # GV47: the same hp, mirrored onto the reward account split by team, so
    # shaping can pay for enemy chip damage and charge for friendly fire.
    sim.recordHitDamage(attackerIndex, targetIndex, amount)
    case weapon
    of "grenade": inc sim.players[attackerIndex].grenadeDamageDealt, amount
    of "gun": inc sim.players[attackerIndex].gunDamageDealt, amount
    of "spray": inc sim.players[attackerIndex].sprayDamageDealt, amount
    else: discard
    if sim.playerTrench(attackerIndex) >= 0:
      inc sim.players[attackerIndex].pitDamageDealt, amount
  # Any damage restarts the heal clock: two seconds of UNINTERRUPTED time on
  # your own colour is what buys a hit point back.
  if amount > 0:
    sim.players[targetIndex].ownPaintTicks = 0
  let fromShield = min(sim.players[targetIndex].shieldHp, amount)
  if fromShield > 0:
    # GLORY: `dShieldSoak` -- kept as a fire/audit counter even though
    # `XpPerShieldSoak`/its drama price are zero+tombstoned (v9 LAW E1),
    # same status main gives it.
    sim.awardDeed(sim.players[targetIndex].team, dShieldSoak,
                  sim.players[targetIndex].x, sim.players[targetIndex].y,
                  times = fromShield)
    sim.addXp(targetIndex, XpPerShieldSoak * fromShield)
    sim.players[targetIndex].soakedHp += fromShield
  sim.players[targetIndex].shieldHp -= fromShield
  sim.players[targetIndex].hp -= amount - fromShield
  if firstTouch and hpBefore > 0 and sim.players[targetIndex].hp <= 0 and
      weapon in ["gun", "grenade"] and
      sim.players[attackerIndex].team != sim.players[targetIndex].team:
    inc sim.players[attackerIndex].assassinKills
  if fromShield > 0 and sim.players[targetIndex].shieldHp == 0:
    # A broken shield is GONE: the carry icon, the " shield" label, and the
    # fire slowdown all end with the bubble, and an in-flight slowed cooldown
    # re-clamps so the next shot fires at the normal rate.
    sim.players[targetIndex].hasShield = false
    sim.players[targetIndex].fireCooldown = min(
      sim.players[targetIndex].fireCooldown, sim.config.fireCooldownTicks
    )
  fromShield

proc canFire*(sim: SimServer, shooterIndex: int): bool =
  ## Returns whether one player is able to fire a shot right now.
  ## LOOT(s2): under lootStart the gun additionally needs BOTH looted
  ## halves — the marker (hasGun) and the hopper (hasHopper, the ammo).
  ## The config gate short-circuits first, so a dark game's verdict is the
  ## pre-existing expression bit-for-bit; a ghost (downed) can never fire.
  if shooterIndex < 0 or shooterIndex >= sim.players.len:
    return false
  let shooter = sim.players[shooterIndex]
  shooter.alive and not shooter.downed and
    shooter.fireCooldown <= 0 and not shooter.hasSprayPaint and
    (not sim.config.lootStart or (shooter.hasGun and shooter.hasHopper))

proc canFireArc*(sim: SimServer, attackerIndex: int): bool =
  ## Returns whether one player can fire an immediate spray burst.
  ## LOOT(s2): a ghost (downed) can never spray; the spray can is its own
  ## lootable weapon, so the marker+hopper gate deliberately does not
  ## apply to it.
  if attackerIndex < 0 or attackerIndex >= sim.players.len:
    return false
  let attacker = sim.players[attackerIndex]
  attacker.alive and not attacker.downed and
    attacker.hasSprayPaint and attacker.fireCooldown <= 0

proc selectArcVictims(
  sim: SimServer,
  attackerIndex: int
): seq[int] =
  ## Returns every living player whose BODY overlaps the attacker's forward
  ## spray cone. The cone's ORIGIN is the attacker's CURRENT position (it rides
  ## its owner across the active window), but its DIRECTION is the aim locked at
  ## the fire instant (`arcAimBrads`) — turning the cog mid-spray never sweeps
  ## the cone.
  ##
  ## The victim is a disc of SprayPaintBodyRadius, not the bare point its
  ## 1px collision box would suggest, so the cone covers what the paint
  ## visibly covers. Spraying backwards still hits nobody: the can points
  ## forward, so a cog behind the attacker is out regardless of its body.
  if attackerIndex < 0 or attackerIndex >= sim.players.len:
    return @[]
  let
    attacker = sim.players[attackerIndex]
    ax = attacker.x + CollisionW div 2
    ay = attacker.y + CollisionH div 2
    (ux, uy) = aimVector(attacker.arcAimBrads)
    reach = float(SprayPaintReach)
    # The cone's half-width grows linearly with forward distance, hitting
    # SprayPaintMaxWidth / 2 exactly at the reach cap.
    halfWidthSlope = float(SprayPaintMaxWidth) / (2.0 * reach)
  for i in 0 ..< sim.players.len:
    # LOOT(s2): a ghost (downed) is not a spray victim — the gun is the one
    # splat-confirm channel (applyFire); dark-inert, downed is never true
    # without downedMode.
    if i == attackerIndex or not sim.players[i].alive or
        sim.players[i].downed:
      continue
    let
      vx = float(sim.players[i].x + CollisionW div 2 - ax)
      vy = float(sim.players[i].y + CollisionH div 2 - ay)
      forward = vx * ux + vy * uy
      perpendicular = abs(vx * uy - vy * ux)
    if forward <= 0 or forward > reach + float(SprayPaintBodyRadius):
      continue
    if perpendicular > forward * halfWidthSlope + float(SprayPaintBodyRadius):
      continue
    if not sim.paintPathClear(
      ax,
      ay,
      sim.players[i].x + CollisionW div 2,
      sim.players[i].y + CollisionH div 2
    ):
      continue
    result.add(i)

proc startArcFire*(sim: var SimServer, attackerIndex: int) =
  ## Ignites one player's spray paint cone: it stays on for SprayPaintActiveTicks
  ## and the weapon then needs SprayPaintResetTicks to recharge before the
  ## next firing. Damage is dealt by resolveActiveArcCones each active tick.
  if not sim.canFireArc(attackerIndex):
    return
  sim.players[attackerIndex].fireCooldown =
    SprayPaintActiveTicks + SprayPaintResetTicks
  sim.players[attackerIndex].arcTicksLeft = SprayPaintActiveTicks
  # Lock the aim NOW: the cone keeps this direction for its whole active
  # window, so turning the cog mid-spray no longer sweeps it around. One
  # fire, one direction.
  sim.players[attackerIndex].arcAimBrads = sim.players[attackerIndex].aimBrads
  sim.players[attackerIndex].arcHitMask = 0
  sim.players[attackerIndex].arcKillsThisFire = 0
  inc sim.players[attackerIndex].attacksMade
  sim.logGameEvent(
    playerColorText(sim.players[attackerIndex].color) & " sprayed paint"
  )

proc resolveActiveArcCones*(sim: var SimServer) =
  ## Advances every live spray cone one tick: all cones are resolved
  ## against the same snapshot (no processing-order advantage), each victim
  ## is damaged at most once per activation, and every live cone leaves a
  ## cosmetic flash at its owner's current position and aim. A touch removes
  ## SprayPaintDamage hit points — lethal to a bare cog, survivable once by a
  ## shield carrier. A dead owner's cone shuts off.
  var arcFires: seq[tuple[attacker: int, victims: seq[int]]] = @[]
  for attackerIndex in 0 ..< sim.players.len:
    if sim.players[attackerIndex].arcTicksLeft <= 0:
      continue
    if not sim.players[attackerIndex].alive:
      sim.players[attackerIndex].arcTicksLeft = 0
      continue
    arcFires.add((attackerIndex, sim.selectArcVictims(attackerIndex)))
  for arcFire in arcFires:
    let attacker = sim.players[arcFire.attacker]
    var damages: seq[EventDamage]
    sim.sprayPaintFlashes.add SprayPaintFx(
      x: attacker.x + CollisionW div 2,
      y: attacker.y + CollisionH div 2,
      aimBrads: attacker.arcAimBrads,   ## the locked fire direction, not live aim
      tick: sim.tickCount,
      color: teamColor(attacker.team),
      attacker: arcFire.attacker
    )
    # A can sprayed at the terrain coats it. March the cone's center ray to the
    # first wall inside reach and dry a stain there — so spraying down a
    # corridor leaves the corridor painted, not just the cogs in it. One stain
    # per tick of the cone (its site moves with the owner).
    block sprayStain:
      let
        ax = attacker.x + CollisionW div 2
        ay = attacker.y + CollisionH div 2
        (ux, uy) = aimVector(attacker.arcAimBrads)
      for step in 1 .. SprayPaintReach:
        let
          rx = ax + int(round(ux * float(step)))
          ry = ay + int(round(uy * float(step)))
        if sim.isWall(rx, ry):
          let (sxw, syw) = sim.seatInWall(rx, ry, ux, uy)
          sim.addPaintStain(sxw, syw, teamColor(attacker.team), onWall = true)
          break sprayStain
    # NEW (paintball): the same cone repaints the FLOOR TILES it covers. This
    # is the only thing that paints the floor under the paintball loadout —
    # there is no gun, no grenade and no barrage — so a squad's territory is
    # exactly the ground its cans have swept.
    block paintFloorFromCone:
      let painted = sim.paintConeTiles(arcFire.attacker)
      if painted.tiles > 0:
        sim.emitEvent(
          PaintTiles,
          source = arcFire.attacker,
          weapon = "spray",
          amount = painted.tiles,
          hp = painted.hillTiles,
          x = float(attacker.x + CollisionW div 2),
          y = float(attacker.y + CollisionH div 2)
        )
    for victimIndex in arcFire.victims:
      if victimIndex < 0 or victimIndex >= sim.players.len:
        continue
      if not sim.players[victimIndex].alive:
        continue
      if victimIndex < 32:
        let bit = 1'u32 shl victimIndex
        if (sim.players[arcFire.attacker].arcHitMask and bit) != 0:
          continue
        sim.players[arcFire.attacker].arcHitMask =
          sim.players[arcFire.attacker].arcHitMask or bit
      # A bubble that eats the burst keeps the body clean, exactly as with a
      # paintball (see the gun's damage site).
      let bubbleUp = sim.players[victimIndex].hasShield and
        sim.players[victimIndex].shieldHp > 0
      let sprayDamage = max(1, sim.config.sprayDamage)
      let blocked = sim.absorbDamage(
        victimIndex, sprayDamage, arcFire.attacker, "spray"
      )
      if sim.config.allowShotFeedback:
        # Same private hit-confirm the gun's damage site pushes (applyFire) —
        # area weapons are cheap to cover here since victimIndex/attacker are
        # already resolved above; see GameConfig.allowShotFeedback.
        sim.shotFeedback.add ShotFeedbackFx(
          shooterIndex: arcFire.attacker,
          targetIndex: victimIndex,
          kill: sim.players[victimIndex].hp <= 0,
          friendlyFire: attacker.team == sim.players[victimIndex].team,
          weapon: "spray",
          distance: int(round(hypot(
            float(sim.players[victimIndex].x - attacker.x),
            float(sim.players[victimIndex].y - attacker.y)
          ))),
          # Killcam (sim_types.nim ShotFeedbackFx.shooterX): the sprayer's
          # center this cone tick, same convention as the gun site's sx/sy.
          shooterX: attacker.x + CollisionW div 2,
          shooterY: attacker.y + CollisionH div 2
        )
      if bubbleUp:
        # Blink the bubble toward the sprayer, as the gun's damage site does —
        # otherwise a fully-absorbed burst shows no feedback anywhere.
        sim.bubbleImpacts.add BubbleImpactFx(
          playerIndex: victimIndex,
          tick: sim.tickCount,
          angleBrads: bradsOfVector(
            sim.players[arcFire.attacker].x - sim.players[victimIndex].x,
            sim.players[arcFire.attacker].y - sim.players[victimIndex].y
          )
        )
      else:
        # A can of paint sprayed in the face paints: stamp the visor splat,
        # like the gun and the grenade.
        sim.players[victimIndex].paintHitTick = sim.tickCount
      let
        vx = float(sim.players[victimIndex].x + CollisionW div 2)
        vy = float(sim.players[victimIndex].y + CollisionH div 2)
      sim.emitEvent(
        Damage, source = arcFire.attacker, target = victimIndex,
        weapon = "spray", amount = sprayDamage,
        hp = max(0, sim.players[victimIndex].hp),
        blocked = blocked, x = vx, y = vy
      )
      if sim.collectEvents:
        damages.add sim.eventDamage(
          victimIndex,
          sprayDamage,
          max(0, sim.players[victimIndex].hp),
          blocked
        )
      # Floating damage number for the HP loss (cosmetic, not in gameHash).
      sim.damagePops.add DamageFx(
        x: sim.players[victimIndex].x + CollisionW div 2,
        y: sim.players[victimIndex].y + CollisionH div 2,
        tick: sim.tickCount,
        amount: sprayDamage, color: sim.players[victimIndex].color
      )
      # GLORY: damage is the DENSE half of the ladder -- identical block to
      # the gun's own damage site, see its comment there. Priced from the
      # CONFIGURED sprayDamage (the hp the victim actually lost), not the
      # classic constant: paintball configures 1, and crediting 3 there
      # would advance the ladder three times too fast.
      if arcFire.attacker >= 0 and arcFire.attacker < sim.players.len and
          sim.players[arcFire.attacker].team != sim.players[victimIndex].team:
        sim.addXp(arcFire.attacker, XpPerDamage * sprayDamage)
        if sim.players[victimIndex].hp > 0:
          sim.players[victimIndex].lastDamagedBy = arcFire.attacker
          sim.players[victimIndex].lastDamagedByTick = sim.tickCount
          if sim.players[victimIndex].hp <= ClutchHpThreshold:
            sim.players[arcFire.attacker].menacingTick = sim.tickCount
            sim.players[arcFire.attacker].menacingVictim = victimIndex
      if sim.players[victimIndex].hp <= 0:
        # GLORY: `multi` reflects the PRIOR value of `arcKillsThisFire` --
        # this is the 2nd+ kill of the activation iff it was already >=1
        # before the increment below.
        let
          arcMulti = sim.players[arcFire.attacker].arcKillsThisFire > 0
          teamKill =
            sim.players[victimIndex].team == sim.players[arcFire.attacker].team
        sim.killPlayer(victimIndex, arcFire.attacker, weapon = "spray",
                       multi = arcMulti)
        if victimIndex != arcFire.attacker:
          sim.recordKillCredit(arcFire.attacker, victimIndex)
          sim.emitEvent(
            Kill, source = arcFire.attacker, target = victimIndex,
            weapon = "spray", amount = sprayDamage, x = vx, y = vy
          )
          # Multi-kill accounting per ACTIVATION (not per tick): the second
          # kill of one firing mints a double, the third upgrades it to a
          # triple; a fourth+ stays inside the already-counted triple.
          # Enemy kills only — a sprayed teammate is a backstab, not an honor
          # (GV45 stats rule; also excludes the GLORY sprayMultiKills counter,
          # same reasoning).
          if not teamKill:
            inc sim.players[arcFire.attacker].arcKillsThisFire
            if sim.players[arcFire.attacker].arcKillsThisFire == 2:
              inc sim.players[arcFire.attacker].multiKills2
              inc sim.players[arcFire.attacker].sprayMultiKills
            elif sim.players[arcFire.attacker].arcKillsThisFire == 3:
              dec sim.players[arcFire.attacker].multiKills2
              inc sim.players[arcFire.attacker].multiKills3
    if sim.collectEvents:
      sim.emitEvent(
        SprayUse,
        source = arcFire.attacker,
        weapon = "spray",
        x = float(attacker.x + CollisionW div 2),
        y = float(attacker.y + CollisionH div 2),
        actionId = sim.eventActionId(
          arcFire.attacker,
          SprayAction,
          sim.tickCount - (SprayPaintActiveTicks - attacker.arcTicksLeft)
        ),
        headingBrads = attacker.arcAimBrads,
        damages = damages
      )
    if sim.players[arcFire.attacker].arcTicksLeft > 0:
      dec sim.players[arcFire.attacker].arcTicksLeft
      # The cone just shut off: clear the locked aim so an idle owner carries
      # no stale direction (matches how the gun clears windupBrads on release).
      if sim.players[arcFire.attacker].arcTicksLeft == 0:
        sim.players[arcFire.attacker].arcAimBrads = -1

proc tryFireArc*(sim: var SimServer, attackerIndex: int) =
  ## Fires one spray burst immediately for direct callers and tests: ignites
  ## the cone and resolves its first tick (other live cones also advance).
  if not sim.canFireArc(attackerIndex):
    return
  sim.startArcFire(attackerIndex)
  sim.resolveActiveArcCones()

proc aimJitterSigma(sim: SimServer, perks: PerkSet): float =
  ## The per-shot Gaussian aim-noise sigma, in radians (GV34): calibrated
  ## against the LIVE config.gunRange so that a fully visible body at max
  ## range is hit exactly 80% of the time — see AimJitterCentralZ for the
  ## derivation. PlayerHalf + BulletHalfWidth is the corridor's continuous
  ## acceptance half-window for a centered silhouette. A scope-perked shooter
  ## deviates less: sigma shrinks by perkMods.scopeAim (the scale applies
  ## only when the perk is present, so a perk-free shot's draw is untouched).
  let window = (float(PlayerHalf) + BulletHalfWidth) / float(sim.config.gunRange)
  result = arcsin(min(1.0, window)) / AimJitterCentralZ
  if PerkScope in perks:
    result = result * float(1000 - sim.config.perkMods.scopeAim) / 1000.0

proc jitterDirection(
  sim: var SimServer, headingBrads: int, perks: PerkSet
): tuple[x, y: float] =
  ## The actual unit direction of one released shot: the locked aim rotated
  ## by a Gaussian draw on the deterministic sim RNG (like the trench duck,
  ## it is part of the hashed game, so replays re-roll identically). The
  ## same fuzzed direction drives target selection AND the tracer/stain, so
  ## where the paint lands is where the viewer sees it fly.
  let
    (bx, by) = aimVector(headingBrads)
    jitter = gauss(sim.rng, 0.0, sim.aimJitterSigma(perks))
    cj = cos(jitter)
    sj = sin(jitter)
  # aimVector is (cos a, -sin a) (screen y down), so adding jitter to the
  # angle expands to this rotation of the base vector.
  (bx * cj + by * sj, by * cj - bx * sj)

proc selectFireTarget(
  sim: var SimServer, shooterIndex: int, ux, uy: float
): int =
  ## Returns the player the shot lands on: the bullet travels down the
  ## given unit direction (the locked aim plus the released shot's jitter,
  ## GV34) toward the FIRST body it crosses (friendly fire
  ## on), stopping at walls — or -1 for a miss. A trench occupant crossed
  ## by the ray ducks under TrenchMissPct of the shots fired from outside
  ## their trench (config-gated trenches): the bullet flies straight over them and carries
  ## on down the ray to the next exposed body, exactly as if the occupant
  ## were not there. The duck is rolled per occupant on the deterministic
  ## sim RNG at shot release.
  ##
  ## A target's body is sampled across its silhouette (perpendicular to the
  ## ray, ±PlayerHalf): a sample connects only when the bullet corridor
  ## covers it AND the shooter has line of sight TO THAT SAMPLE. Cover is
  ## therefore partial, not binary — a corner-hugger can only be hit on the
  ## sliver of body it actually shows, and a fully exposed body presents the
  ## same effective width as the old center-only corridor check.
  result = -1
  let
    shooter = sim.players[shooterIndex]
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
    maxRange = float(sim.config.gunRange)
    shooterTrench = sim.playerTrench(shooterIndex)
  # Every body the bullet corridor crosses, at its distance along the ray.
  var crossed: seq[tuple[t: float, index: int]] = @[]
  for i in 0 ..< sim.players.len:
    if i == shooterIndex or not sim.players[i].alive:
      continue
    let
      tx = float(sim.players[i].x + CollisionW div 2)
      ty = float(sim.players[i].y + CollisionH div 2)
    for off in countup(-PlayerHalf, PlayerHalf, ExposureSampleStep):
      let
        px = tx - float(off) * uy      # silhouette sample: the body span
        py = ty + float(off) * ux      # perpendicular to the shot ray
        vx = px - float(sx)
        vy = py - float(sy)
        t = vx * ux + vy * uy          # distance along the ray
      if t <= 0 or t > maxRange:
        continue
      if abs(vx * uy - vy * ux) > BulletHalfWidth:
        continue
      if not sim.paintPathClear(sx, sy, int(round(px)), int(round(py))):
        continue
      crossed.add((t, i))
      break
  # Walk the crossed bodies in ray order (index breaks exact ties, so the
  # walk is deterministic); the first body that does not duck is the hit.
  crossed.sort()
  # A handicapped shooter's aim goes wide on a fraction of the shots that would
  # otherwise connect. Rolled ONCE per shot, only when there is a body to hit
  # AND the team carries a handicap — so an unhandicapped game draws no extra
  # RNG and re-simulates byte-for-byte. On a miss the whole shot flies wide
  # (it does not fall through to a body further down the ray).
  let missPermille = sim.config.missPermilleFor(shooter.team)
  if missPermille > 0 and crossed.len > 0 and sim.rng.rand(999) < missPermille:
    return -1
  for candidate in crossed:
    let targetTrench = sim.playerTrench(candidate.index)
    if targetTrench >= 0 and targetTrench != shooterTrench and
        sim.rng.rand(99) < TrenchMissPct:
      continue
    return candidate.index

type PendingGunShot = object
  shooterIndex: int
  targetIndex: int
  headingBrads: int          ## the INTENDED locked aim (events, animation).
  dirX, dirY: float          ## the fuzzed direction the shot actually flew.
  actionId: int64

proc selectGunShot(sim: var SimServer, shooterIndex: int): PendingGunShot =
  ## Selects a target and snapshots the trigger metadata before any
  ## simultaneous shot can kill and reset another shooter. (`var` because
  ## the shot rolls its aim jitter, then target selection rolls the trench
  ## duck, both on the sim RNG — one fixed draw order per released shot.)
  let
    shooter = sim.players[shooterIndex]
    headingBrads =
      if shooter.windupBrads >= 0: shooter.windupBrads
      else: shooter.aimBrads
    triggerTick =
      if shooter.windupBrads >= 0:
        sim.tickCount - sim.config.fireWindupTicks
      else:
        sim.tickCount
    (ux, uy) = sim.jitterDirection(headingBrads, shooter.perks)
  PendingGunShot(
    shooterIndex: shooterIndex,
    targetIndex: sim.selectFireTarget(shooterIndex, ux, uy),
    headingBrads: headingBrads,
    dirX: ux,
    dirY: uy,
    actionId: sim.eventActionId(shooterIndex, GunAction, triggerTick)
  )

proc applyFire(sim: var SimServer, shot: PendingGunShot) =
  ## Applies one selected shot: cooldown, tracer, and the kill. The target
  ## may already have died to another shot this tick; the shot still lands
  ## (tracer and all) but only an alive target yields a kill.
  let
    shooterIndex = shot.shooterIndex
    targetIndex = shot.targetIndex
    shooter = sim.players[shooterIndex]
    (ux, uy) = (shot.dirX, shot.dirY)  # the fuzzed direction, not the aim.
    sx = shooter.x + CollisionW div 2
    sy = shooter.y + CollisionH div 2
  # GV26: heart carriers fire at CarrierFireSlowdown (same 3x as shields);
  # Trench occupants fire at TrenchFireSlowdown (config-gated). Every slowdown
  # composes by MAX, never the product.
  var cooldownScale = 1
  if shooter.hasShield or shooter.carryingFlag:
    cooldownScale = max(ShieldFireSlowdown, CarrierFireSlowdown)
  if sim.playerTrench(shooterIndex) >= 0:
    cooldownScale = max(cooldownScale, TrenchFireSlowdown)
  sim.players[shooterIndex].fireCooldown =
    sim.config.fireCooldownTicks * cooldownScale
  sim.players[shooterIndex].windupBrads = -1
  # Accuracy bookkeeping (analysis-only, excluded from gameHash): every call
  # here is one released shot; a shot that locked onto a live enemy on the ray
  # (targetIndex >= 0) is on-target, so it counts as a hit even in the rare
  # tick where the victim already died to a simultaneous shot.
  inc sim.players[shooterIndex].shotsFired
  inc sim.players[shooterIndex].attacksMade
  sim.emitEvent(
    Shot,
    source = shooterIndex,
    weapon = "gun",
    x = float(sx),
    y = float(sy),
    actionId = shot.actionId,
    headingBrads = shot.headingBrads
  )
  # Record a cosmetic tracer for the shot (never enters gameHash). It ends at
  # the victim, so a bullet visibly never travels past its first hit.
  var
    ex = sx
    ey = sy
  if targetIndex >= 0:
    inc sim.players[shooterIndex].shotsHit
    ex = sim.players[targetIndex].x + CollisionW div 2
    ey = sim.players[targetIndex].y + CollisionH div 2
    sim.emitEvent(
      Hit, source = shooterIndex, target = targetIndex, weapon = "gun",
      x = float(ex), y = float(ey)
    )
  else:
    # March along the unit aim to the last wall-free pixel or max range
    # (checking each sampled pixel keeps this O(range) at 1050px).
    let maxRange = sim.config.gunRange
    var
      lastClear = 0
      wallX = 0
      wallY = 0
      struckWall = false
      struckBarrier = -1
    for step in 1 .. maxRange:
      let
        rx = sx + int(round(ux * float(step)))
        ry = sy + int(round(uy * float(step)))
      # Cardboard before stone: a standing barrier soaks the paintball (one
      # of its BarrierHp hits) where a wall would merely wear the stain.
      if sim.placedBarriers.len > 0:
        struckBarrier = sim.barrierIndexAt(rx, ry)
        if struckBarrier >= 0:
          wallX = rx
          wallY = ry
          break
      if sim.isWall(rx, ry):
        struckWall = true
        wallX = rx
        wallY = ry
        break
      lastClear = step
    ex = sx + int(round(ux * float(lastClear)))
    ey = sy + int(round(uy * float(lastClear)))
    if struckBarrier >= 0:
      # The tracer visibly ends ON the cardboard, and the hit splat lands
      # there; the paint never reaches the terrain behind it.
      ex = wallX
      ey = wallY
      sim.damageBarrier(struckBarrier, wallX, wallY, shooter.color)
    # Paint that MISSES every cog carries on until it hits geometry, and dries
    # there for the rest of the match. The mark goes on the WALL PIXEL it
    # struck — not the last clear pixel in front of it, which would leave the
    # paint hanging on the floor beside the wall it visibly hit. A shot that
    # simply ran out of range hit nothing and marks nothing.
    if struckWall:
      let (stainX, stainY) = sim.seatInWall(wallX, wallY, ux, uy)
      sim.addPaintStain(stainX, stainY, shooter.color, onWall = true)
  sim.recentShots.add ShotFx(
    x0: sx,
    y0: sy,
    x1: ex,
    y1: ey,
    firedTick: sim.tickCount,
    color: shooter.color,
    hit: targetIndex >= 0
  )
  var impactReported = false
  if targetIndex >= 0 and sim.players[targetIndex].downed:
    # LOOT(s2): the splat confirm (downedMode; dark-inert — downed is never
    # true otherwise). An ENEMY paintball landing on a ghost finalizes the
    # elimination on the spot: no damage accounting, no second Kill credit
    # (the weapon site credited the kill at the DOWN), just the deferred
    # real death. A teammate's stray paint never confirms — the ghost soaks
    # it without effect.
    if shooter.team != sim.players[targetIndex].team:
      sim.finalizeDowned(targetIndex, shooterIndex, "was splatted out")
  elif targetIndex >= 0 and sim.players[targetIndex].alive:
    # A carrier whose shield layer is still up at impact absorbs the hit
    # VISUALS on the bubble: it blinks and dents toward the shooter instead of
    # showing the inner struck-target ring and body paint spark. The "-1" pop
    # still reads the hp loss. (Cosmetic only — the damage itself is
    # unchanged.)
    let bubbleUp = sim.players[targetIndex].hasShield and
      sim.players[targetIndex].shieldHp > 0
    # A lucky shot (luck perk) deals perkMods.luckDamage instead of 1. Rolled once
    # per LANDED hit, only when the shooter carries the perk, so a perk-free
    # game draws no extra RNG and re-simulates byte-for-byte.
    var damage = 1
    if PerkLuck in shooter.perks and
        sim.rng.rand(999) < sim.config.perkMods.luckChance:
      damage = sim.config.perkMods.luckDamage
    let blocked = sim.absorbDamage(targetIndex, damage, shooterIndex, "gun")
    # Paintball paint marks the body only when the shield bubble ISN'T eating it
    # (a bubble dent draws no body paint). Stamp so the EYES-PiP visor splat
    # fires for THIS paint hit — and only for a PAINT hit (gun/grenade). The
    # spray cone stamps it at its own damage site.
    if not bubbleUp:
      sim.players[targetIndex].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = shooterIndex, target = targetIndex, weapon = "gun",
      amount = damage, hp = max(0, sim.players[targetIndex].hp),
      blocked = blocked,
      x = float(sim.players[targetIndex].x + CollisionW div 2),
      y = float(sim.players[targetIndex].y + CollisionH div 2)
    )
    if sim.collectEvents:
      sim.emitEvent(
        ShotImpact,
        source = shooterIndex,
        target = targetIndex,
        weapon = "gun",
        x = float(ex),
        y = float(ey),
        actionId = shot.actionId,
        headingBrads = shot.headingBrads,
        distance = hypot(float(ex - sx), float(ey - sy)),
        damages = @[
          sim.eventDamage(
            targetIndex,
            damage,
            max(0, sim.players[targetIndex].hp),
            blocked
          )
        ]
      )
    impactReported = true
    if sim.config.allowShotFeedback:
      # Private, gate-only hit-confirm for both combat participants: never
      # broadcast, never in gameHash — server.nim's send loop drains and
      # delivers this seq (see SimServer.shotFeedback / GameConfig.
      # allowShotFeedback). hp is read AFTER absorbDamage above, so this
      # already reflects whichever hp<=0 branch the code below takes.
      # distance: the same hypot formula the (conditional, collectEvents-
      # gated) ShotImpact event above uses, off the same ex/ey/sx/sy locals
      # — recomputed here since that event's own computation only runs
      # when collectEvents is on, a separate gate from allowShotFeedback.
      sim.shotFeedback.add ShotFeedbackFx(
        shooterIndex: shooterIndex,
        targetIndex: targetIndex,
        kill: sim.players[targetIndex].hp <= 0,
        friendlyFire: shooter.team == sim.players[targetIndex].team,
        weapon: "gun",
        distance: int(round(hypot(float(ex - sx), float(ey - sy)))),
        # Killcam (sim_types.nim ShotFeedbackFx.shooterX): the shooter's
        # center at release — the same sx/sy this shot's ray was cast from.
        shooterX: sx,
        shooterY: sy
      )
    if bubbleUp:
      sim.bubbleImpacts.add BubbleImpactFx(
        playerIndex: targetIndex,
        tick: sim.tickCount,
        angleBrads: bradsOfVector(sx - ex, sy - ey)
      )
    else:
      # A spectator-view flash rings the struck target the moment the bullet
      # connects, so hits read at a glance (cosmetic only, never in gameHash).
      sim.hitFlashes.add HitFlashFx(
        playerIndex: targetIndex,
        tick: sim.tickCount
      )
    # A floating "-1" rises and fades from the victim so a lost health bar
    # reads at a glance (cosmetic only, never in gameHash).
    sim.damagePops.add DamageFx(
      x: sim.players[targetIndex].x + CollisionW div 2,
      y: sim.players[targetIndex].y + CollisionH div 2,
      tick: sim.tickCount,
      amount: damage,
      color: sim.players[targetIndex].color
    )
    # GLORY: damage is the DENSE half of the ladder (pairs with the sparse
    # deed events above) -- every hit lands XpPerDamage, enemy-only, gun
    # included. Also sets the ASSIST ("who set this kill up") / RESCUE
    # ("who left a teammate at clutch hp alive") plumbing `killPlayer`'s
    # kill-pricing context reads -- identical block at the spray/arc and
    # grenade sites.
    if shooterIndex >= 0 and shooterIndex < sim.players.len and
        sim.players[shooterIndex].team != sim.players[targetIndex].team:
      sim.addXp(shooterIndex, XpPerDamage * 1)
      if sim.players[targetIndex].hp > 0:
        sim.players[targetIndex].lastDamagedBy = shooterIndex
        sim.players[targetIndex].lastDamagedByTick = sim.tickCount
        if sim.players[targetIndex].hp <= ClutchHpThreshold:
          sim.players[shooterIndex].menacingTick = sim.tickCount
          sim.players[shooterIndex].menacingVictim = targetIndex
    if sim.players[targetIndex].hp <= 0:
      sim.killPlayer(targetIndex, shooterIndex, weapon = "gun")
      sim.recordKillCredit(shooterIndex, targetIndex)
      sim.emitEvent(
        Kill, source = shooterIndex, target = targetIndex, weapon = "gun",
        amount = damage,
        x = float(sim.players[targetIndex].x + CollisionW div 2),
        y = float(sim.players[targetIndex].y + CollisionH div 2)
      )
    else:
      if not bubbleUp:
        # A non-fatal hit leaves a small, short-lived paint spark in the
        # shooter's color on the target (cosmetic only, never in gameHash).
        sim.splatters.add SplatterFx(
          x: sim.players[targetIndex].x,
          y: sim.players[targetIndex].y,
          tick: sim.tickCount,
          color: shooter.color,
          hit: true
        )
        # NO terrain stain here: a paintball that connects spends its paint ON
        # THE COG (the splat above). Only shots that MISS reach terrain and
        # mark it — that is the whole fiction, and staining hit sites too made
        # the arena read as painted wherever cogs merely stood.
      sim.logGameEvent(
        playerColorText(sim.players[targetIndex].color) &
          " hit by " & sim.playerText(shooterIndex) &
          " (" & $(sim.players[targetIndex].hp +
            sim.players[targetIndex].shieldHp) & " hp left)"
      )
  if sim.collectEvents and not impactReported:
    sim.emitEvent(
      ShotImpact,
      source = shooterIndex,
      target = targetIndex,
      weapon = "gun",
      x = float(ex),
      y = float(ey),
      actionId = shot.actionId,
      headingBrads = shot.headingBrads,
      distance = hypot(float(ex - sx), float(ey - sy))
    )

proc tryFire*(sim: var SimServer, shooterIndex: int) =
  ## Fires one shot immediately (the single-shooter path).
  if not sim.canFire(shooterIndex):
    return
  sim.applyFire(sim.selectGunShot(shooterIndex))

proc applyAimAssist*(sim: var SimServer, shooterIndex: int) =
  ## Aim assist (`allowAimAssist`). Called at the fire-press edge, BEFORE
  ## `startFireWindup` locks `windupBrads` off `aimBrads` — this is the one
  ## chance to correct the bearing before it freezes for the shot.
  ##
  ## Scans every OTHER live, non-teammate cog, predicts each one
  ## `fireWindupTicks` ticks ahead by simple linear integer extrapolation of
  ## its CURRENT velocity, and turns that predicted position into a bearing
  ## from the shooter's muzzle. Among all of those, the one nearest the
  ## shooter's own current aim wins; if it is within `aimAssistConeBrads` of
  ## that aim, `aimBrads` snaps to it. Otherwise nothing changes. A human
  ## cannot compute the windup lead a bot's policy already does every shot —
  ## this closes exactly that gap, and only for a target the cursor was
  ## already close to; it never turns the turret onto a target the human
  ## was not already tracking.
  ##
  ## Pure function of already-hashed sim state (every candidate's x, y,
  ## velX, velY, team, alive) plus the shooter's own already-recorded aim:
  ## nothing here reads a clock, a float RNG, or anything a replay cannot
  ## re-derive from the recorded input/aim streams, so a replay reaches the
  ## identical intercept and re-locks the identical `windupBrads` for free.
  if shooterIndex < 0 or shooterIndex >= sim.players.len:
    return
  template shooter: untyped = sim.players[shooterIndex]
  if not shooter.alive:
    return
  let
    ticks = max(0, sim.config.fireWindupTicks)
    mx = shooter.x + CollisionW div 2
    my = shooter.y + CollisionH div 2
  var
    bestBrads = -1
    bestDelta = high(int)
  for i in 0 ..< sim.players.len:
    if i == shooterIndex:
      continue
    let candidate = sim.players[i]
    if not candidate.alive or candidate.team == shooter.team:
      continue
    let
      # velX/velY are fixed-point (MotionScale units per tick — the same
      # convention applyMomentumAxis's `carry` accumulates), not raw px/tick;
      # dividing back out is what keeps this "simple" extrapolation in the
      # right units. Ignores walls, collisions and the carry remainder on
      # purpose — an approximate lead, not a re-derivation of movement.
      px = candidate.x + (candidate.velX * ticks) div MotionScale
      py = candidate.y + (candidate.velY * ticks) div MotionScale
      brads = bradsOfVector(px - mx, py - my)
      delta = abs(shortestAimBradsDelta(shooter.aimBrads, brads))
    if delta < bestDelta:
      bestDelta = delta
      bestBrads = brads
  if bestBrads >= 0 and bestDelta <= sim.config.aimAssistConeBrads:
    shooter.aimBrads = bestBrads

proc startFireWindup*(sim: var SimServer, shooterIndex: int) =
  ## Starts a shot: locks the current aim angle and arms the windup.
  ## The shot itself releases fireWindupTicks later (see step).
  if not sim.canFire(shooterIndex):
    return
  if sim.players[shooterIndex].fireWindup > 0:
    return
  let actionId = sim.eventActionId(shooterIndex, GunAction)
  sim.players[shooterIndex].fireWindup = sim.config.fireWindupTicks
  sim.players[shooterIndex].windupBrads = sim.players[shooterIndex].aimBrads
  sim.emitEvent(
    GunTrigger,
    source = shooterIndex,
    weapon = "gun",
    x = float(sim.players[shooterIndex].x + CollisionW div 2),
    y = float(sim.players[shooterIndex].y + CollisionH div 2),
    actionId = actionId,
    headingBrads = sim.players[shooterIndex].aimBrads
  )


proc grenadePosition*(grenade: AirborneGrenade, tick: int): tuple[x, y: int] =
  ## The grenade's map position while airborne (linear flight over walls).
  let t = clamp(tick - grenade.launchTick, 0, grenade.flightTicks)
  (grenade.sx + (grenade.tx - grenade.sx) * t div grenade.flightTicks,
    grenade.sy + (grenade.ty - grenade.sy) * t div grenade.flightTicks)

proc throwTarget*(player: Player, maxRange: int): tuple[x, y: int] =
  ## Where a charging player's throw would currently land, along their aim at
  ## the charge-picked distance. `maxRange` is the seat's resolved full-charge
  ## distance (config.grenadeRangeFor — the grenade perk stretches it). The
  ## render charge-ring caller (global.nim) resolves it the same way
  ## throwGrenade below does, and throwGrenade duplicates this strength
  ## formula inline — keep the two in lockstep so the ring never disagrees
  ## with where the grenade actually goes.
  let
    charge = clamp(player.throwCharge, 0, GrenadeChargeTicks)
    strength = GrenadeMinRange +
      (maxRange - GrenadeMinRange) * charge div GrenadeChargeTicks
    (ux, uy) = aimVector(player.aimBrads)
    sx = player.x + CollisionW div 2
    sy = player.y + CollisionH div 2
  (clamp(sx + int(round(ux * float(strength))),
      ArenaBorder + 2, MapWidth - ArenaBorder - 2),
    clamp(sy + int(round(uy * float(strength))),
      ArenaBorder + 2, MapHeight - ArenaBorder - 2))

proc throwGrenade(sim: var SimServer, playerIndex: int) =
  ## Releases the charged throw along the thrower's current aim. The charge
  ## picks the distance (GrenadeMinRange..GrenadeMaxRange); the grenade
  ## flies over every obstacle and explodes where it lands. Throwing is
  ## deliberately silent: no sound FX is recorded here.
  let
    player = sim.players[playerIndex]
    charge = clamp(player.throwCharge, 0, GrenadeChargeTicks)
    maxRange = sim.config.grenadeRangeFor(GrenadeMaxRange, player.perks)
    strength = GrenadeMinRange +
      (maxRange - GrenadeMinRange) * charge div GrenadeChargeTicks
    (ux, uy) = aimVector(player.aimBrads)
    sx = player.x + CollisionW div 2
    sy = player.y + CollisionH div 2
    tx = clamp(
      sx + int(round(ux * float(strength))),
      ArenaBorder + 2, MapWidth - ArenaBorder - 2
    )
    ty = clamp(
      sy + int(round(uy * float(strength))),
      ArenaBorder + 2, MapHeight - ArenaBorder - 2
    )
    # Fixed fuse: the burst comes exactly GrenadeFlightMultiple shot-windups
    # after release, near or far. The visible arc just moves faster on long
    # throws; the threat window is constant and readable.
    flight = max(1, GrenadeFlightMultiple * sim.config.fireWindupTicks)
    throwDistance = hypot(float(tx - sx), float(ty - sy))
  inc sim.players[playerIndex].attacksMade
  sim.airborneGrenades.add AirborneGrenade(
    sx: sx,
    sy: sy,
    tx: tx,
    ty: ty,
    launchTick: sim.tickCount,
    flightTicks: flight,
    thrower: playerIndex,
    throwerSlot: player.joinOrder,
    throwerAccount: sim.rewardAccountIndexForSlot(player.joinOrder)
  )
  sim.emitEvent(
    GrenadeThrow,
    source = playerIndex,
    weapon = "grenade",
    x = float(sx),
    y = float(sy),
    actionId = sim.eventActionId(playerIndex, GrenadeAction),
    headingBrads = player.aimBrads,
    distance = throwDistance,
    item = "grenade"
  )
  sim.players[playerIndex].hasGrenade = false
  sim.players[playerIndex].throwCharge = 0
  sim.logGameEvent(playerColorText(player.color) & " threw a grenade")

proc placeBarrier(sim: var SimServer, playerIndex: int) =
  ## Unfolds the carried cardboard into a standing half-hex centered on the
  ## placer, flat side across their aim: vertices at aim -90/-30/+30/+90
  ## degrees, BarrierRadius out, snapped to map pixels (every later coverage
  ## test is integer-only). The apothem (~21px) clears the placer's own
  ## 6px-half footprint, so placing never crushes the fresh barrier — walking
  ## forward into it afterwards does.
  const vertAngles = [-PI / 2.0, -PI / 6.0, PI / 6.0, PI / 2.0]
  let
    player = sim.players[playerIndex]
    cx = player.x + CollisionW div 2
    cy = player.y + CollisionH div 2
    (ux, uy) = aimVector(player.aimBrads)
  var barrier = PlacedBarrier(
    x: cx,
    y: cy,
    facingBrads: player.aimBrads,
    hp: BarrierHp,
    team: player.team,
    placedTick: sim.tickCount
  )
  for k in 0 .. 3:
    let
      c = cos(vertAngles[k])
      s = sin(vertAngles[k])
    barrier.verts[k] = (
      cx + int(round(float(BarrierRadius) * (ux * c - uy * s))),
      cy + int(round(float(BarrierRadius) * (ux * s + uy * c)))
    )
  barrier.minX = barrier.verts[0].x
  barrier.maxX = barrier.verts[0].x
  barrier.minY = barrier.verts[0].y
  barrier.maxY = barrier.verts[0].y
  for k in 1 .. 3:
    barrier.minX = min(barrier.minX, barrier.verts[k].x)
    barrier.maxX = max(barrier.maxX, barrier.verts[k].x)
    barrier.minY = min(barrier.minY, barrier.verts[k].y)
    barrier.maxY = max(barrier.maxY, barrier.verts[k].y)
  barrier.minX -= BarrierHalfThick + 1
  barrier.minY -= BarrierHalfThick + 1
  barrier.maxX += BarrierHalfThick + 1
  barrier.maxY += BarrierHalfThick + 1
  # The pool is bounded (it sizes the render id block): past the cap the
  # OLDEST standing barrier folds so the new one can stand.
  if sim.placedBarriers.len >= MaxBarriersPlaced:
    sim.placedBarriers.delete(0)
  sim.placedBarriers.add(barrier)
  sim.players[playerIndex].hasBarrier = false
  sim.logGameEvent(
    playerColorText(player.color) & " placed a cardboard barrier")

proc applyBarrierInput(
  sim: var SimServer,
  playerIndex: int,
  input, prev: InputState
) =
  ## Press C to unfold a carried barrier where you stand — instant, no
  ## charge. C is the grenade button too, but a cog never holds both
  ## (pickups are mutually exclusive), so the press is unambiguous.
  if not sim.players[playerIndex].alive or
      sim.players[playerIndex].downed or
      not sim.players[playerIndex].hasBarrier:
    return
  if input.c and not prev.c:
    sim.placeBarrier(playerIndex)

proc applyGrenadeInput(
  sim: var SimServer,
  playerIndex: int,
  input, prev: InputState
) =
  ## Hold C to charge a throw, release to let it fly.
  if not sim.players[playerIndex].alive or
      sim.players[playerIndex].downed or
      not sim.players[playerIndex].hasGrenade:
    sim.players[playerIndex].throwCharge = 0
    return
  if input.c:
    sim.players[playerIndex].throwCharge = min(
      sim.players[playerIndex].throwCharge + 1, GrenadeChargeTicks
    )
  elif prev.c and sim.players[playerIndex].throwCharge > 0:
    sim.throwGrenade(playerIndex)
  else:
    sim.players[playerIndex].throwCharge = 0

proc explodeGrenade(sim: var SimServer, grenade: AirborneGrenade) =
  ## Applies one landing: a cosmetic blast flash (which views also use for
  ## the audible landing's sound ring) plus blast damage to EVERYONE inside
  ## the radius — teammates and the thrower included. A trench changes the
  ## damage, not the radius: GrenadeTrenchDamage for a victim sharing the
  ## landing trench, GrenadeTrenchSplashDamage for a victim in any other
  ## trench, GrenadeDamage for anyone in the open.
  # Color the splat by the thrower's TEAM (not their individual slot color), so
  # a landing reads as that team's paint-bomb — and the sprite id stays within
  # the two team-color slots, never colliding with the tracer pool.
  let
    throwerSlot = sim.grenadeThrowerSlot(grenade)
    throwerIndex = sim.playerIndexForSlot(throwerSlot)
    # An environment shell (grenade barrage, throwerSlot -1) has no owning
    # team: its splat cycles the ACTIVE team colors by launch tick, staying
    # inside the same team-keyed blast sprite pool a player lob uses.
    # (teamForSlot(-1) would index Team(-1) — never call it for a shell.)
    throwerColor =
      if throwerSlot < 0:
        teamColor(Team(grenade.launchTick mod sim.gameMap.teamCount()))
      else:
        teamColor(sim.teamForSlot(throwerSlot))
    landingTrench = trenchIndexAt(grenade.tx, grenade.ty)
  sim.recentBlasts.add BlastFx(
    x: grenade.tx, y: grenade.ty, tick: sim.tickCount, color: throwerColor,
    trenchLanding: landingTrench >= 0
  )
  # A paint bomb repaints the ground it lands on permanently: a cluster of
  # dried stains across the blast footprint, so a contested chokepoint that
  # eats grenades ends the match visibly coated. Offsets are fixed (and each
  # stain re-hashes its own site) so a replay rebuilds the identical cluster.
  # A trench-trapped blast keeps its stains inside the pit: offsets that
  # would land outside the landing trench's own square are simply skipped.
  const stainRing = [(0, 0), (-26, -14), (24, -20), (30, 12),
                     (-18, 24), (6, 32), (-32, 4), (14, -32)]
  for (ox, oy) in stainRing:
    let
      bx = grenade.tx + ox
      by = grenade.ty + oy
    if bx < 0 or by < 0 or bx >= MapWidth or by >= MapHeight:
      continue
    if landingTrench >= 0 and not inShape(bx, by, ArenaTrenches[landingTrench]):
      continue
    sim.addPaintStain(bx, by, throwerColor)
  sim.logGameEvent("grenade landed")
  let radiusSq = GrenadeBlastRadius * GrenadeBlastRadius
  var
    blastKills = 0
    damages: seq[EventDamage]
  for i in 0 ..< sim.players.len:
    # LOOT(s2): a ghost (downed) is not a blast victim — the gun is the one
    # splat-confirm channel (applyFire). Dark-inert.
    if not sim.players[i].alive or sim.players[i].downed:
      continue
    let
      px = sim.players[i].x + CollisionW div 2
      py = sim.players[i].y + CollisionH div 2
      # GV30: the blast tests the SOLID BODY BOX (±PlayerHalf), not the bare
      # position point — a cog whose footprint touches the circle is caught,
      # the same rule the gun's bullet corridor already uses (BulletHalfWidth
      # sampled across ±PlayerHalf). Circle-vs-box is the distance from the
      # burst to the NEAREST point of the box, so on-axis reach becomes
      # GrenadeBlastRadius + PlayerHalf.
      nearX = max(0, abs(px - grenade.tx) - PlayerHalf)
      nearY = max(0, abs(py - grenade.ty) - PlayerHalf)
    if nearX * nearX + nearY * nearY > radiusSq:
      continue
    # A trench traps or shields a blast: a victim caught in the SAME trench
    # the grenade landed in takes amplified damage (nowhere to duck), a
    # victim in any OTHER trench takes reduced splash, and a victim outside
    # every trench takes the ordinary open-field amount.
    let
      victimTrench = trenchIndexAt(px, py)
      dmg =
        if victimTrench < 0: GrenadeDamage
        elif victimTrench == landingTrench: GrenadeTrenchDamage
        else: GrenadeTrenchSplashDamage
      # Read the bubble BEFORE absorbDamage drains shieldHp: a bubble that eats
      # the blast keeps the body clean, exactly as with a paintball (see the
      # gun's damage site).
      bubbleUp = sim.players[i].hasShield and sim.players[i].shieldHp > 0
      blocked = sim.absorbDamage(i, dmg, throwerIndex, "grenade")
    if sim.config.allowShotFeedback and throwerIndex >= 0 and i != throwerIndex:
      # Same private hit-confirm the gun's damage site pushes (applyFire) —
      # area weapons are cheap to cover here too. Excludes self-splash
      # (i == throwerIndex, same guard the kill-crediting code below already
      # uses) and an environment shell (throwerIndex < 0, no seat to notify).
      sim.shotFeedback.add ShotFeedbackFx(
        shooterIndex: throwerIndex,
        targetIndex: i,
        kill: sim.players[i].hp <= 0,
        friendlyFire: sim.players[throwerIndex].team == sim.players[i].team,
        weapon: "grenade",
        distance: int(round(hypot(float(px - grenade.tx), float(py - grenade.ty)))),
        # Killcam (sim_types.nim ShotFeedbackFx.shooterX): the THROWER's
        # center at blast resolution — where they stand when it bursts, the
        # spot a camera should find them at, not the launch point.
        shooterX: sim.players[throwerIndex].x + CollisionW div 2,
        shooterY: sim.players[throwerIndex].y + CollisionH div 2
      )
    if sim.players[i].hp > 0:
      inc sim.players[i].blastsSurvived    # `lucky`: caught, not killed
    if bubbleUp:
      # The bubble itself blinks and dents toward the burst, so an absorbed
      # blast reads as absorbed instead of leaving no feedback at all.
      sim.bubbleImpacts.add BubbleImpactFx(
        playerIndex: i,
        tick: sim.tickCount,
        angleBrads: bradsOfVector(grenade.tx - px, grenade.ty - py)
      )
    else:
      # A paint-bomb blast marks everyone caught in it — stamp so the EYES-PiP
      # visor splat fires for this paint hit (gun/grenade; spray stamps its own).
      sim.players[i].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = throwerIndex, target = i, weapon = "grenade",
      amount = dmg, hp = max(0, sim.players[i].hp),
      blocked = blocked,
      x = float(px), y = float(py), sourceSlot = throwerSlot
    )
    if sim.collectEvents:
      damages.add sim.eventDamage(
        i,
        dmg,
        max(0, sim.players[i].hp),
        blocked
      )
    # Floating damage number for the blast's HP loss (cosmetic, not in gameHash).
    sim.damagePops.add DamageFx(
      x: px, y: py, tick: sim.tickCount,
      amount: dmg, color: sim.players[i].color
    )
    # GLORY: damage is the DENSE half of the ladder -- identical block to
    # the gun's own damage site, see its comment there. Uses `throwerIndex`
    # (this loop's own current-frame identity, already reconciled against
    # GV24 compaction below) rather than `grenade.thrower` directly.
    if throwerIndex >= 0 and throwerIndex < sim.players.len and
        sim.players[throwerIndex].team != sim.players[i].team:
      sim.addXp(throwerIndex, XpPerDamage * dmg)
      if sim.players[i].hp > 0:
        sim.players[i].lastDamagedBy = throwerIndex
        sim.players[i].lastDamagedByTick = sim.tickCount
        if sim.players[i].hp <= ClutchHpThreshold:
          sim.players[throwerIndex].menacingTick = sim.tickCount
          sim.players[throwerIndex].menacingVictim = i
    if sim.players[i].hp <= 0:
      # GLORY: `multi` reflects the PRIOR value of `blastKills` -- this is
      # the 2nd+ kill of the blast iff a valid, non-self kill already
      # landed from it before this one.
      let grenadeMulti = blastKills > 0
      # An environment shell logs its own death line instead of the combat
      # "killed by" attribution (there is nobody to credit).
      sim.killPlayer(
        i, throwerIndex, throwerSlot,
        cause = (if throwerSlot < 0: "shelled by the grenade barrage" else: ""),
        weapon = "grenade", multi = grenadeMulti
      )
      if throwerSlot >= 0 and throwerSlot != sim.eventSlot(i):
        # GV45: the credit routes by team — an enemy kill to `kills`, a
        # blasted teammate to `teamKills`. The account is credited via the
        # immutable thrower identity (the thrower may have left the game);
        # the live counters ride the current index when the thrower is still
        # seated, mirroring recordKillCredit without double-crediting the
        # account. (The GV24 legacy-index hash quirk retires with the bump.)
        let
          throwerTeam =
            if throwerIndex >= 0: sim.players[throwerIndex].team
            else: sim.teamForSlot(throwerSlot)
          teamKill = throwerTeam == sim.players[i].team
        if grenade.throwerAccount >= 0 and
            grenade.throwerAccount < sim.rewardAccounts.len:
          if teamKill:
            inc sim.rewardAccounts[grenade.throwerAccount].teamKills
          else:
            inc sim.rewardAccounts[grenade.throwerAccount].kills
        if throwerIndex >= 0 and throwerIndex != i:
          if teamKill:
            inc sim.players[throwerIndex].teamKills
          else:
            inc sim.players[throwerIndex].kills
            sim.noteLifeKill(throwerIndex)
        sim.emitEvent(
          Kill, source = throwerIndex, target = i, weapon = "grenade",
          amount = dmg, x = float(px), y = float(py),
          sourceSlot = throwerSlot
        )
        # Cluster (multi-kill) honors count enemy kills only.
        if throwerIndex >= 0 and throwerIndex != i and not teamKill:
          inc blastKills
          if blastKills == 2:
            inc sim.players[throwerIndex].grenadeMultiKills
  if sim.collectEvents:
    sim.emitEvent(
      GrenadeImpact,
      source = throwerIndex,
      weapon = "grenade",
      x = float(grenade.tx),
      y = float(grenade.ty),
      actionId = sim.eventActionIdForSlot(
        throwerSlot,
        GrenadeAction,
        grenade.launchTick
      ),
      headingBrads = bradsOfVector(
        grenade.tx - grenade.sx,
        grenade.ty - grenade.sy
      ),
      distance = hypot(
        float(grenade.tx - grenade.sx),
        float(grenade.ty - grenade.sy)
      ),
      item = "grenade",
      damages = damages,
      sourceSlot = throwerSlot
    )
  # Multi-kill accounting per BLAST: one landing that kills 2 mints a double,
  # 3+ a triple (a self-kill in the blast never counts toward either).
  if throwerIndex >= 0:
    if blastKills >= 3:
      inc sim.players[throwerIndex].multiKills3
    elif blastKills == 2:
      inc sim.players[throwerIndex].multiKills2

proc updateGrenades(sim: var SimServer) =
  ## Refills corner pickups whose timer elapsed and lands due grenades.
  for spawn in sim.grenadeSpawns.mitems:
    if not spawn.present and sim.tickCount >= spawn.respawnAt:
      spawn.present = true
  var
    landing: seq[AirborneGrenade] = @[]
    kept: seq[AirborneGrenade] = @[]
  for grenade in sim.airborneGrenades:
    if sim.tickCount - grenade.launchTick >= grenade.flightTicks:
      landing.add grenade
    else:
      kept.add grenade
  sim.airborneGrenades = kept
  for grenade in landing:
    sim.explodeGrenade(grenade)

template pickupByTouch(
  sim: var SimServer,
  playerIndex: int,
  spawnsField: untyped,
  pickupRange, respawnTicks: int,
  taken: untyped
) =
  ## Shared touch-pickup skeleton for the four pickup families: scans present
  ## spawns within pickupRange of the player's center, and on the first hit
  ## marks it taken, arms its respawn timer, runs `taken` (with `spawn`, `px`,
  ## `py` injected — grant + events + log, in each family's original order),
  ## and stops. Callers keep their own eligibility gates.
  let
    px {.inject.} = sim.players[playerIndex].x + CollisionW div 2
    py {.inject.} = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = pickupRange * pickupRange
  for spawn {.inject.} in sim.spawnsField.mitems:
    if spawn.present and distSq(px, py, spawn.x, spawn.y) <= rangeSq:
      spawn.present = false
      spawn.respawnAt = sim.tickCount + respawnTicks
      taken
      return

template refillElapsedPickups(sim: var SimServer, spawnsField: untyped) =
  ## Refills spawns whose respawn timer elapsed.
  for spawn in sim.spawnsField.mitems:
    if not spawn.present and sim.tickCount >= spawn.respawnAt:
      spawn.present = true

proc tryPickupGrenades*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up a corner grenade by touch (one carried
  ## grenade max; either team may take either side's pickups). A cog carrying
  ## a cardboard barrier walks over the pickup untouched — grenade and
  ## barrier share button C, so a cog holds one or the other, never both.
  if not sim.players[playerIndex].alive or
      sim.players[playerIndex].downed or
      sim.players[playerIndex].hasGrenade or
      sim.players[playerIndex].hasBarrier:
    return
  sim.pickupByTouch(playerIndex, grenadeSpawns, GrenadePickupRange,
      GrenadeRespawnTicks):
    sim.players[playerIndex].hasGrenade = true
    sim.emitPickup(playerIndex, "grenade", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a grenade"
    )

proc updateMedKits*(sim: var SimServer) =
  ## Refills center med kits whose respawn timer elapsed.
  sim.refillElapsedPickups(medKitSpawns)

proc updateSprayPaints*(sim: var SimServer) =
  ## Refills side-center spray can pickups whose respawn timer elapsed.
  sim.refillElapsedPickups(sprayPaintSpawns)

proc tryPickupMedKits*(sim: var SimServer, playerIndex: int) =
  ## Lets a hurt living player pick up a center med kit by touch, restoring
  ## hit points back to full. A healthy player walks over it untouched, so a
  ## kit is never wasted; a taken kit refills after MedKitRespawnTicks.
  ## LOOT(s2): a ghost parked on the spawn must not drink it (downed guard).
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed:
    return
  let maxHp = sim.config.maxHpFor(
    sim.players[playerIndex].team, sim.players[playerIndex].perks)
  if sim.players[playerIndex].hp >= maxHp:
    return
  # GLORY: read BEFORE the pickup heals, like the kill site reads its
  # context before mutation -- "at/near clutch hp" only means anything
  # measured against the PRE-heal hp.
  let onOneHp = sim.players[playerIndex].hp <= ClutchHpThreshold
  sim.pickupByTouch(playerIndex, medKitSpawns, MedKitPickupRange,
      MedKitRespawnTicks):
    if onOneHp:
      sim.awardDeed(sim.players[playerIndex].team, dClutchHeal,
                    sim.players[playerIndex].x, sim.players[playerIndex].y)
      sim.addXp(playerIndex, XpPerClutchHeal)
      inc sim.players[playerIndex].clutchHeals
      sim.players[playerIndex].clutchHealTick = sim.tickCount
      if sim.players[playerIndex].carryingFlag:
        inc sim.players[playerIndex].clutchCarryHeals
    let healed = maxHp - sim.players[playerIndex].hp
    sim.players[playerIndex].hp = maxHp
    # GLORY: the general pickup+heal mint. `XpPerPickup`/`XpPerHeal` are
    # both zero+tombstoned (v9 LAW E1, self-heal no longer pays) -- this
    # call site stays wired anyway so a future re-price needs no new
    # plumbing, same discipline `dShieldSoak` above holds.
    sim.addXp(playerIndex, XpPerPickup + XpPerHeal * healed)
    sim.noteLifeHeal(playerIndex)
    sim.emitPickup(playerIndex, "med_kit", spawn.x, spawn.y)
    sim.emitEvent(
      Heal, source = playerIndex, amount = healed,
      hp = sim.players[playerIndex].hp, x = float(px), y = float(py)
    )
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a med kit"
    )

proc updateBandages*(sim: var SimServer) =
  ## LOOT(s2): refills taken bandage pickups whose respawn timer elapsed —
  ## the med-kit cadence. A no-op on a dark game (empty family).
  sim.refillElapsedPickups(bandageSpawns)

proc tryPickupBandages*(sim: var SimServer, playerIndex: int) =
  ## LOOT(s2): lets a living cog pocket a bandage by touch, up to
  ## BandageCarryCap. A full pocket walks over the spawn untouched (the
  ## med-kit "never wasted" rule); a taken bandage refills after
  ## MedKitRespawnTicks. The pocket is the inventory: the heal itself is
  ## deferred to updateBandageApplies' calm-window rule.
  if sim.config.bandagePickups <= 0:
    return
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed:
    return
  if sim.players[playerIndex].bandages >= BandageCarryCap:
    return
  sim.pickupByTouch(playerIndex, bandageSpawns, BandagePickupRange,
      MedKitRespawnTicks):
    inc sim.players[playerIndex].bandages
    sim.emitPickup(playerIndex, "bandage", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " pocketed a bandage"
    )

proc updateBandageApplies*(sim: var SimServer) =
  ## LOOT(s2): one tick of bandage self-application: a hurt, upright cog
  ## carrying a bandage that has gone BandageApplyTicks without taking any
  ## damage applies one (+1 hp, capped at the seat's max) — and the calm
  ## clock restarts, so a stack applies one bandage per calm window, never
  ## all at once. Tick-based and RNG-free; a no-op unless bandagePickups
  ## armed.
  if sim.config.bandagePickups <= 0 or sim.phase != Playing:
    return
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive or sim.players[i].downed:
      continue
    if sim.players[i].bandages <= 0:
      continue
    let maxHp = sim.config.maxHpFor(sim.players[i].team, sim.players[i].perks)
    if sim.players[i].hp >= maxHp:
      continue
    if sim.tickCount - sim.players[i].lastDamageTick < BandageApplyTicks:
      continue
    dec sim.players[i].bandages
    inc sim.players[i].hp
    # Restart the calm window: the NEXT bandage needs its own quiet spell.
    sim.players[i].lastDamageTick = sim.tickCount
    sim.emitEvent(
      Heal, source = i, weapon = "bandage", amount = 1,
      hp = sim.players[i].hp,
      x = float(sim.players[i].x + CollisionW div 2),
      y = float(sim.players[i].y + CollisionH div 2)
    )
    sim.logGameEvent(
      playerColorText(sim.players[i].color) & " applied a bandage"
    )

proc tryPickupWeapons*(sim: var SimServer, playerIndex: int) =
  ## LOOT(s2): lets an unarmed living cog loot a marker (gun) crate by
  ## touch. A cog already holding the marker walks over the crate untouched
  ## — a crate arms exactly one cog per game (the family is never
  ## refilled; see resetLootCrates).
  if not sim.config.lootStart:
    return
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed:
    return
  if sim.players[playerIndex].hasGun:
    return
  # respawnTicks 0 is inert: no refill call exists for this family.
  sim.pickupByTouch(playerIndex, weaponSpawns, WeaponPickupRange, 0):
    sim.players[playerIndex].hasGun = true
    sim.emitPickup(playerIndex, "gun", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " looted a marker"
    )

proc tryPickupHoppers*(sim: var SimServer, playerIndex: int) =
  ## LOOT(s2): lets a living cog loot a hopper (the marker's ammo) crate by
  ## touch — the other half of the BOTH-to-shoot gate (canFire). Same
  ## one-crate-one-cog rule as tryPickupWeapons.
  if not sim.config.lootStart:
    return
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed:
    return
  if sim.players[playerIndex].hasHopper:
    return
  # respawnTicks 0 is inert: no refill call exists for this family.
  sim.pickupByTouch(playerIndex, hopperSpawns, WeaponPickupRange, 0):
    sim.players[playerIndex].hasHopper = true
    sim.emitPickup(playerIndex, "hopper", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " looted a hopper"
    )

proc updateShields*(sim: var SimServer) =
  ## Refills endzone shields whose respawn timer elapsed.
  sim.refillElapsedPickups(shieldSpawns)

proc tryPickupShields*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up an endzone shield by touch (either team may
  ## take either endzone's shield). A pickup grants the shield and refills the
  ## ShieldLayerHp-strong shield layer that damage depletes before base hp —
  ## it never heals base damage (that is the med kits' job), so a worn carrier
  ## may take another shield to restore the layer, while a carrier whose layer
  ## is intact leaves the spawn untouched for a teammate. Carrying a shield
  ## slows fire ShieldFireSlowdown times; a taken shield refills after
  ## ShieldRespawnTicks.
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed:
    return
  if sim.players[playerIndex].shieldHp >= ShieldLayerHp:
    return
  sim.pickupByTouch(playerIndex, shieldSpawns, ShieldPickupRange,
      ShieldRespawnTicks):
    sim.players[playerIndex].hasShield = true
    sim.players[playerIndex].shieldHp = ShieldLayerHp
    sim.emitPickup(playerIndex, "shield", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a shield"
    )

proc tryPickupSprayPaints*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up one side-center spray can by touch.
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed or
      sim.players[playerIndex].hasSprayPaint:
    return
  sim.pickupByTouch(playerIndex, sprayPaintSpawns, SprayPaintPickupRange,
      SprayPaintRespawnTicks):
    sim.players[playerIndex].hasSprayPaint = true
    sim.players[playerIndex].fireWindup = 0
    sim.players[playerIndex].windupBrads = -1
    sim.emitPickup(playerIndex, "spray_can", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a spray can"
    )

proc tryPickupBarriers*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player pick up one folded cardboard barrier by touch. The
  ## grenade shares button C, so carrying either blocks picking up the other
  ## (the grenade side of the gate lives in tryPickupGrenades).
  if not sim.players[playerIndex].alive or
      sim.players[playerIndex].downed or
      sim.players[playerIndex].hasBarrier or
      sim.players[playerIndex].hasGrenade:
    return
  sim.pickupByTouch(playerIndex, barrierSpawns, BarrierPickupRange,
      BarrierRespawnTicks):
    sim.players[playerIndex].hasBarrier = true
    sim.emitPickup(playerIndex, "barrier", spawn.x, spawn.y)
    sim.logGameEvent(
      playerColorText(sim.players[playerIndex].color) &
        " picked up a cardboard barrier"
    )

proc updateBarriers*(sim: var SimServer) =
  ## Refills barrier pickups whose respawn timer elapsed, then flattens any
  ## standing barrier a cog drove into this tick — cardboard stops paint,
  ## not a rolling bot. Runs after movement, so the crush lands the same
  ## tick as the contact.
  sim.refillElapsedPickups(barrierSpawns)
  if sim.placedBarriers.len == 0:
    return
  var index = 0
  while index < sim.placedBarriers.len:
    var crusher = -1
    for playerIndex in 0 ..< sim.players.len:
      if sim.players[playerIndex].alive and
          sim.playerTouchesBarrier(playerIndex, index):
        crusher = playerIndex
        break
    if crusher >= 0:
      sim.flattenBarrier(
        index, sim.players[crusher].color, "flattened a cardboard barrier")
    else:
      inc index

proc sanitizeShout*(text: string): string =
  ## Reduces raw chat text to a legal shout: printable ASCII only, at most
  ## ShoutMaxChars characters, no leading or trailing spaces.
  for c in text:
    if c >= ' ' and c <= '~':
      result.add(c)
    if result.len == ShoutMaxChars:
      break
  result = result.strip()

proc parseCallout*(
  text: string
): tuple[isCallout: bool, id: int, cell: string] =
  ## Parses an already-sanitized shout as the standard ping vocabulary
  ## (callout-spec.md §5): `!<id>[ <cell>]`, where `<id>` is a single digit
  ## 1-6 and `<cell>` — when present — is one space-free token (the wheel's
  ## chessCell grid string, e.g. "F9"). Anything else — a bare "!", a
  ## multi-digit id, an out-of-range digit, or a second space — is NOT a
  ## callout and returns `(false, 0, "")`, so the caller falls through and
  ## treats the message as ordinary chat. Only ever consulted when
  ## `config.allowCallouts` is on (see `applyShout`); this proc itself has
  ## no config dependency, so it stays trivially unit-testable.
  result = (false, 0, "")
  if text.len < 2 or text[0] != '!':
    return
  if text[1] < '1' or text[1] > '6':
    return
  if text.len == 2:
    return (true, ord(text[1]) - ord('0'), "")
  if text[2] != ' ':
    return                       # e.g. "!12" — id must be exactly one digit.
  let cell = text[3 .. ^1]
  if cell.len == 0 or ' ' in cell:
    return
  return (true, ord(text[1]) - ord('0'), cell)

proc applyShout*(sim: var SimServer, playerIndex: int, text: string): bool {.discardable.} =
  ## Applies one player chat message as a shout: a short message audible to
  ## anyone within ShoutRange of the shouter. Living players only, at most
  ## one shout per second, and one live bubble per player (a new shout
  ## replaces the old one). Returns whether the shout was applied.
  if sim.phase != Playing:
    return false
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed:
    return false
  let shoutText = sanitizeShout(text)
  if shoutText.len == 0:
    return false
  let last = sim.players[playerIndex].lastShoutTick
  if last >= 0 and sim.tickCount - last < ShoutCooldownTicks:
    return false
  sim.players[playerIndex].lastShoutTick = sim.tickCount
  let address = sim.players[playerIndex].address
  var kept: seq[Shout] = @[]
  for shout in sim.recentShouts:
    if shout.address != address:
      kept.add shout
  var shout = Shout(
    address: address,
    team: sim.players[playerIndex].team,
    text: shoutText,
    tick: sim.tickCount,
    x: sim.players[playerIndex].x + CollisionW div 2,
    y: sim.players[playerIndex].y + CollisionH div 2
  )
  # Config-gated: off, this block never runs, so isCallout/calloutId/
  # calloutCell stay at their zero value on every shout — see gameHash
  # (sim_state.nim) for why that is what keeps a gate-off replay
  # byte-identical to a build that never added these fields.
  if sim.config.allowCallouts:
    let parsed = parseCallout(shoutText)
    shout.isCallout = parsed.isCallout
    shout.calloutId = parsed.id
    shout.calloutCell = parsed.cell
  kept.add shout
  sim.recentShouts = kept
  sim.emitEvent(
    ShoutEvent,
    source = playerIndex,
    x = float(shout.x),
    y = float(shout.y),
    content = shoutText
  )
  true

proc shoutAudibleTo*(sim: SimServer, viewerIndex: int, shout: Shout): bool =
  ## Whether one viewer can hear a shout: within ShoutRange of where it was
  ## made. Shouts carry through walls and fog like gunfire, but dead viewers
  ## observe nothing.
  if viewerIndex < 0 or viewerIndex >= sim.players.len:
    return false
  if not sim.players[viewerIndex].alive:
    return false
  let
    vx = sim.players[viewerIndex].x + CollisionW div 2
    vy = sim.players[viewerIndex].y + CollisionH div 2
  distSq(vx, vy, shout.x, shout.y) <= ShoutRange * ShoutRange

proc resolveSimultaneousFire*(sim: var SimServer, shooters: openArray[int]) =
  ## Resolves every shot released this tick at once: all targets are chosen
  ## against the same snapshot before any kill is applied, so a mutual duel
  ## kills both shooters and neither team gains an input-processing-order
  ## advantage.
  var shots: seq[PendingGunShot] = @[]
  for shooterIndex in shooters:
    if sim.canFire(shooterIndex):
      shots.add(sim.selectGunShot(shooterIndex))
  for shot in shots:
    sim.applyFire(shot)

proc tryPickupFlags*(sim: var SimServer, playerIndex: int) =
  ## Lets a living player steal ANY enemy team's flag off its pedestal by
  ## touch. A player's own flag cannot be interacted with by their own team.
  ## Ties (two pedestals in touch range at once — impossible on real maps)
  ## resolve in enum order, deterministically.
  ##
  ## GV42: `FlagPickupRange` covers the DRAWN heart, so standing on the
  ## pedestal is the whole interaction — there is no pinpoint to find and no
  ## grab button. See the constant for the art-derived derivation.
  ##
  ## BR N-point spawn subsystem: a flagless map arms no flag at all — refuse
  ## pickup outright rather than relying on carrier/captured defaults. This
  ## is the ONLY gate flagless needs on the interaction side: with pickup
  ## refused, carrier never leaves -1, so checkWinCondition's capture branch
  ## can never fire and needs no separate flagless check of its own.
  if sim.gameMap.flagless:
    return
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed or
      sim.players[playerIndex].carryingFlag:
    return
  let
    px = sim.players[playerIndex].x + CollisionW div 2
    py = sim.players[playerIndex].y + CollisionH div 2
    rangeSq = FlagPickupRange * FlagPickupRange
  for flagTeam in sim.teams():
    if flagTeam == sim.players[playerIndex].team:
      continue
    if sim.flags[flagTeam].carrier >= 0 or sim.flags[flagTeam].captured:
      continue
    if distSq(px, py, sim.flags[flagTeam].x, sim.flags[flagTeam].y) <= rangeSq:
      # GLORY: read BEFORE the steal mutates anything, same discipline the
      # kill site's context read uses. GLORY-PORT-TODO: source also called
      # `sim.floorGameClock()` here (a steal keeps at least
      # ActionClockFloorTicks on the clock) -- GV41 (this file's own
      # GameVersion history, sim_types.nim) already removed the "action
      # floor"/overtimeTicks clock model that fed, so the call is dropped
      # outright rather than ported onto a mechanism that no longer exists.
      let contested = sim.stealIsContested(playerIndex)
      sim.flags[flagTeam].carrier = playerIndex
      sim.players[playerIndex].carryingFlag = true
      sim.awardDeed(sim.players[playerIndex].team, dFlagSteal,
                    sim.players[playerIndex].x, sim.players[playerIndex].y)
      sim.addXp(playerIndex, XpPerSteal)
      if contested:
        inc sim.players[playerIndex].contestedSteals
      inc sim.players[playerIndex].steals
      sim.players[playerIndex].stealTickThisLife = sim.tickCount
      sim.emitEvent(
        FlagSteal, source = playerIndex,
        x = float(sim.flags[flagTeam].x), y = float(sim.flags[flagTeam].y)
      )
      sim.logGameEvent(
        teamText(sim.players[playerIndex].team) & " stole the " &
          teamText(flagTeam) & " heart"
      )
      return

proc updateFlags(sim: var SimServer) =
  ## Keeps each carried flag glued to its carrier; a carrier that stops
  ## carrying for any reason other than capture sends the flag straight back
  ## to its own pedestal.
  ##
  ## BR N-point spawn subsystem: already provably inert on a flagless map
  ## (carrier is permanently -1, so the loop below always `continue`s
  ## immediately) — this explicit return is defense-in-depth, not load-
  ## bearing, so a future change to that invariant fails loudly here rather
  ## than resurrecting a stale flag position on-screen.
  if sim.gameMap.flagless:
    return
  for team in sim.teams():
    let carrier = sim.flags[team].carrier
    if carrier < 0:
      continue
    if carrier < sim.players.len and sim.players[carrier].alive:
      sim.flags[team].x = sim.players[carrier].x + CollisionW div 2
      sim.flags[team].y = sim.players[carrier].y + CollisionH div 2
    else:
      # Carrier vanished; the flag goes straight back home.
      sim.logGameEvent(teamText(team) & " heart returned home")
      sim.resetFlag(team)

proc applyDirectAim*(sim: var SimServer, playerIndex: int, brads: int) =
  ## Points one cog's turret at an absolute bearing, this tick, with no
  ## `aimTurnRate` traverse. This is the HUMAN aim channel and only ever runs
  ## for a seat a human has taken over on a config that arms `allowDirectAim`;
  ## a policy has no way to reach it, so no policy's turret tuning moves.
  ##
  ## Called immediately BEFORE `applyInput` for the same tick, by BOTH the live
  ## server and replay playback, so the two orderings are the same ordering:
  ## write the bearing, then run the tick that reads it (fire direction, FOV
  ## cone, sprite flip). `applyInput`'s own B/Select traverse still runs after
  ## this write, which is why the human client unbinds those while pointing.
  ##
  ## Dead cogs are skipped on purpose: aim resets to `spawnAimBrads` at every
  ## respawn, and letting a cursor write aim through a death would desync the
  ## client's re-seed on the self-marker edge.
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  # LOOT(s2): a ghost's aim is frozen with the rest of it (downed guard).
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed:
    return
  sim.players[playerIndex].aimBrads =
    ((brads mod AimBradsTurn) + AimBradsTurn) mod AimBradsTurn
  # Marks this cog as human-pointed FOR THIS TICK ONLY: `step` reads and
  # clears it (the aim-assist gate). Live and replay both call this proc at
  # the same point, from the same recorded stream (see `stepReplay`), so the
  # flag comes back identically either way — no new replay record needed.
  sim.players[playerIndex].directAimActive = true

proc directAimBrads*(player: Player, mapX, mapY: int): int =
  ## Converts a cursor position in MAP PIXELS to the bearing that points the
  ## turret at it. The player POV ships the map layer at scale 1 with origin
  ## (0, 0) (buildSpritePlayerSnapshot's viewport is the map's own size), so
  ## the x,y the client already puts on the wire ARE map pixels — no transform.
  ##
  ## The origin is the muzzle point every weapon fires from
  ## (`x + CollisionW div 2`), written the same way throwTarget writes it, so
  ## "the turret points at the cursor" and "the shot goes at the cursor" cannot
  ## drift apart.
  bradsOfVector(
    mapX - (player.x + CollisionW div 2),
    mapY - (player.y + CollisionH div 2)
  )

proc applyInput*(
  sim: var SimServer,
  playerIndex: int,
  input: InputState
) {.measure.} =
  ## Applies one player's movement input. Firing is resolved separately and
  ## simultaneously for all players (resolveSimultaneousFire).
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return
  template player: untyped = sim.players[playerIndex]
  # LOOT(s2): a ghost (downed) is frozen — no locomotion, no aim traverse.
  # Dark-inert: downed is never true without downedMode.
  if not player.alive or player.downed:
    return

  var
    inputX = 0
    inputY = 0
  if input.left:
    inputX -= 1
  if input.right:
    inputX += 1
  if input.up:
    inputY -= 1
  if input.down:
    inputY += 1

  # Aim rotation is decoupled from locomotion: holding B turns the aim
  # counter-clockwise, holding Select clockwise; holding both cancels out,
  # and the d-pad never changes the aim.
  if input.b != input.select:
    let turn =
      if input.b: sim.config.aimTurnRate else: -sim.config.aimTurnRate
    player.aimBrads =
      ((player.aimBrads + turn) mod AimBradsTurn + AimBradsTurn) mod AimBradsTurn
  # The sprite flip follows the aim: flipped while aiming left-ish.
  player.flipH =
    player.aimBrads > AimBradsTurn div 4 and
    player.aimBrads < AimBradsTurn * 3 div 4

  let
    speedScale =
      if player.carryingFlag: sim.config.carrierSpeedPct else: 100
    # The floor-paint buff composes MULTIPLICATIVELY AFTER the carrier scale
    # and BEFORE the trench divisor, in exactly this integer order so both
    # ends of the map round identically. paintPct is 100 whenever the buff is
    # gated off, which makes the gate-off path byte-identical.
    paintPct = sim.paintSpeedPct(playerIndex)
    maxSpeed =
      (sim.config.maxSpeedFor(player.team, player.perks) * speedScale div 100) *
        paintPct div 100
    accel = (sim.config.accel * speedScale div 100) * paintPct div 100
    # CLIMBING OUT of a trench is slow; dropping in and moving around it
    # are not. While the center is inside a pit, each axis whose motion
    # points AWAY from the pit's center — up that wall — is capped at 1/5
    # speed and accel, and outward momentum is shed to the cap. Motion
    # into, across, and around the pit runs at full speed.
    trench = sim.playerTrench(playerIndex)
    slowSpeed = maxSpeed div TrenchSpeedDivisor
    slowAccel = max(1, accel div TrenchSpeedDivisor)
  var
    posBoundX = maxSpeed
    negBoundX = -maxSpeed
    posBoundY = maxSpeed
    negBoundY = -maxSpeed
  if trench >= 0:
    let
      pit = shapeAsRect(ArenaTrenches[trench])
      relX = (player.x + CollisionW div 2) - (pit.x + pit.w div 2)
      relY = (player.y + CollisionH div 2) - (pit.y + pit.h div 2)
    if relX > 0: posBoundX = slowSpeed
    elif relX < 0: negBoundX = -slowSpeed
    if relY > 0: posBoundY = slowSpeed
    elif relY < 0: negBoundY = -slowSpeed
    player.velX = clamp(player.velX, negBoundX, posBoundX)
    player.velY = clamp(player.velY, negBoundY, posBoundY)

  if inputX != 0:
    let accelX =
      if trench >= 0 and
          ((inputX > 0 and posBoundX == slowSpeed) or
           (inputX < 0 and negBoundX == -slowSpeed)):
        slowAccel
      else:
        accel
    player.velX = clamp(
      player.velX + inputX * accelX,
      negBoundX,
      posBoundX
    )
  else:
    player.velX =
      (player.velX * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velX) < sim.config.stopThreshold:
      player.velX = 0

  if inputY != 0:
    let accelY =
      if trench >= 0 and
          ((inputY > 0 and posBoundY == slowSpeed) or
           (inputY < 0 and negBoundY == -slowSpeed)):
        slowAccel
      else:
        accel
    player.velY = clamp(
      player.velY + inputY * accelY,
      negBoundY,
      posBoundY
    )
  else:
    player.velY =
      (player.velY * sim.config.frictionNum) div sim.config.frictionDen
    if abs(player.velY) < sim.config.stopThreshold:
      player.velY = 0

  let
    preferredSlideY =
      if inputY != 0:
        inputY
      else:
        signOf(player.velY)
    preferredSlideX =
      if inputX != 0:
        inputX
      else:
        signOf(player.velX)
  sim.applyMomentumAxis(playerIndex, preferredSlideY, true)
  sim.applyMomentumAxis(playerIndex, preferredSlideX, false)

proc fovCellIndex*(cx, cy: int): int {.inline.} =
  ## Returns the flat index of one fog-of-war grid cell.
  cy * FovGridW + cx

proc fovCellAt*(x, y: int): tuple[cx, cy: int] {.inline.} =
  ## Returns the fog-of-war grid cell containing one map point.
  (clamp(x div FovCellSize, 0, FovGridW - 1),
   clamp(y div FovCellSize, 0, FovGridH - 1))

proc fovCellCenter*(cx, cy: int): tuple[x, y: int] {.inline.} =
  ## Returns the map-pixel center of one fog-of-war grid cell.
  (cx * FovCellSize + FovCellSize div 2, cy * FovCellSize + FovCellSize div 2)

proc buildFovBlocked*(wallMask: seq[bool]): seq[bool] =
  ## Downsamples the pixel wall mask into the fog-of-war occlusion grid: a
  ## cell is opaque when at least half of its pixels are wall.
  result = newSeq[bool](FovCellCount)
  for cy in 0 ..< FovGridH:
    for cx in 0 ..< FovGridW:
      var
        walls = 0
        pixels = 0
      for py in cy * FovCellSize ..< min((cy + 1) * FovCellSize, MapHeight):
        for px in cx * FovCellSize ..< min((cx + 1) * FovCellSize, MapWidth):
          inc pixels
          if wallMask[mapIndex(px, py)]:
            inc walls
      result[fovCellIndex(cx, cy)] = walls * 2 >= pixels

proc castFovOctant(
  blocked: openArray[bool],
  visible: var seq[bool],
  originCx, originCy, row: int,
  startSlope, endSlope: float,
  xx, xy, yx, yy: int
) =
  ## Recursive shadowcasting over one octant of the fog-of-war grid
  ## (Bergstrom-style). Row distance is unbounded; scanning stops at the grid
  ## edge, so THIS pass is limited only by walls — the caller's cone/range
  ## filter applies the visionRange cutoff (GV34) afterwards.
  if startSlope < endSlope:
    return
  var
    start = startSlope
    rowBlocked = false
    newStart = 0.0
  let maxDist = FovGridW + FovGridH
  for dist in row .. maxDist:
    if rowBlocked:
      break
    var anyInside = false
    for dx in -dist .. 0:
      let
        dy = -dist
        lSlope = (float(dx) - 0.5) / (float(dy) + 0.5)
        rSlope = (float(dx) + 0.5) / (float(dy) - 0.5)
      if start < rSlope:
        continue
      if endSlope > lSlope:
        break
      let
        cx = originCx + dx * xx + dy * xy
        cy = originCy + dx * yx + dy * yy
      if cx < 0 or cy < 0 or cx >= FovGridW or cy >= FovGridH:
        continue
      anyInside = true
      let index = fovCellIndex(cx, cy)
      visible[index] = true
      if rowBlocked:
        if blocked[index]:
          newStart = rSlope
        else:
          rowBlocked = false
          start = newStart
      elif blocked[index]:
        rowBlocked = true
        castFovOctant(
          blocked,
          visible,
          originCx,
          originCy,
          dist + 1,
          start,
          lSlope,
          xx, xy, yx, yy
        )
        newStart = rSlope
    if not anyInside and dist > row:
      break

proc visionRange*(sim: SimServer): int =
  ## How far the vision CONE reaches, in px (GV34): 1.5x the live
  ## config.gunRange (1575 at the stock 1050), so sight always outranges
  ## paint by half again — you can see fights you cannot yet join — and both
  ## scale together under a config override. The close-quarters bubble
  ## (visionBubble) is never shrunk by this cap.
  sim.config.gunRange * 3 div 2

proc computeFovShadowcast*(
  sim: SimServer,
  originCx, originCy: int,
  visible: var seq[bool]
) {.measure.} =
  ## The aim-independent half of fog-of-war: recursive shadowcasting from
  ## the viewer's cell (walls block, unbounded by range). Cacheable per
  ## cell — this is the expensive pass.
  if visible.len != FovCellCount:
    visible.setLen(FovCellCount)
  zeroMem(addr visible[0], visible.len * sizeof(bool))
  visible[fovCellIndex(originCx, originCy)] = true
  const Octants = [
    (1, 0, 0, 1), (0, 1, 1, 0), (0, -1, 1, 0), (-1, 0, 0, 1),
    (-1, 0, 0, -1), (0, -1, -1, 0), (0, 1, -1, 0), (1, 0, 0, -1)
  ]
  for (xx, xy, yx, yy) in Octants:
    castFovOctant(
      sim.fovBlocked,
      visible,
      originCx,
      originCy,
      1,
      1.0,
      0.0,
      xx, xy, yx, yy
    )

proc applyFovCone*(
  sim: SimServer,
  originCx, originCy, aimBrads: int,
  shadowcast: seq[bool],
  visible: var seq[bool]
) {.measure.} =
  ## The aim-dependent half of fog-of-war: intersects a cached shadowcast
  ## with the forward vision cone (half-angle visionConeDeg around the aim
  ## angle, reaching visionRange px — 1.5x the gun range, GV34) plus the
  ## omnidirectional vision bubble (visionBubble px, exempt from the range
  ## cap).
  if visible.len != FovCellCount:
    visible.setLen(FovCellCount)
  copyMem(addr visible[0], unsafeAddr shadowcast[0],
    FovCellCount * sizeof(bool))
  let
    (ox, oy) = fovCellCenter(originCx, originCy)
    (ax, ay) = aimVector(aimBrads)
    coneCos = cos(float(sim.config.visionConeDeg) * PI / 180.0)
    bubbleSq = float(sim.config.visionBubble * sim.config.visionBubble)
    rangeSq = float(sim.visionRange() * sim.visionRange())
  for cy in 0 ..< FovGridH:
    for cx in 0 ..< FovGridW:
      let index = fovCellIndex(cx, cy)
      if not visible[index]:
        continue
      let
        (px, py) = fovCellCenter(cx, cy)
        vx = float(px - ox)
        vy = float(py - oy)
        d2 = vx * vx + vy * vy
      if d2 <= bubbleSq:
        continue
      if d2 > rangeSq:
        visible[index] = false
        continue
      let dot = vx * ax + vy * ay
      if dot < coneCos * sqrt(d2):
        visible[index] = false

proc computeFovVisible*(
  sim: SimServer,
  originCx, originCy, aimBrads: int,
  visible: var seq[bool]
) {.measure.} =
  ## Computes one viewer's full fog-of-war cell visibility in one shot:
  ## shadowcast, then cone/range filter. Uncached path, kept for tools and
  ## probes; the server loop goes through refreshPlayerFov's two-level
  ## cache instead.
  var shadowcast = newSeq[bool](FovCellCount)
  sim.computeFovShadowcast(originCx, originCy, shadowcast)
  sim.applyFovCone(originCx, originCy, aimBrads, shadowcast, visible)

proc ensureFovCacheSlots(sim: var SimServer) =
  ## Keeps player-indexed fog-of-war cache storage aligned with players.
  while sim.fovCaches.len < sim.players.len:
    sim.fovCaches.add PlayerFov(
      valid: false,
      visible: newSeq[bool](FovCellCount)
    )
  if sim.fovCaches.len > sim.players.len:
    sim.fovCaches.setLen(sim.players.len)

proc refreshPlayerFov*(sim: var SimServer, playerIndex: int): bool {.measure.} =
  ## Refreshes one player's cached fog-of-war grid and returns true when it
  ## was recomputed (the viewer moved to a new cell or turned).
  sim.ensureFovCacheSlots()
  let
    player = sim.players[playerIndex]
    (cx, cy) = fovCellAt(
      player.x + CollisionW div 2,
      player.y + CollisionH div 2
    )
  template cache: untyped = sim.fovCaches[playerIndex]
  if cache.valid and
      cache.originCx == cx and
      cache.originCy == cy and
      cache.aimBrads == player.aimBrads:
    return false
  # Two-level refresh: the shadowcast only depends on the viewer's cell, so
  # a viewer who merely turned (bots rotate aim nearly every tick) reuses it
  # and pays only the cone filter.
  if not (cache.cellValid and cache.cellCx == cx and cache.cellCy == cy):
    sim.computeFovShadowcast(cx, cy, cache.cellVisible)
    cache.cellValid = true
    cache.cellCx = cx
    cache.cellCy = cy
  sim.applyFovCone(cx, cy, player.aimBrads, cache.cellVisible, cache.visible)
  cache.valid = true
  cache.originCx = cx
  cache.originCy = cy
  cache.aimBrads = player.aimBrads
  true

proc playerFov*(sim: SimServer, playerIndex: int): lent PlayerFov =
  ## Returns one player's cached fog-of-war grid (refreshPlayerFov first).
  sim.fovCaches[playerIndex]

proc fovVisibleAt*(sim: SimServer, playerIndex, x, y: int): bool =
  ## Returns whether one map point is inside a viewer's vision. Dead viewers
  ## have no eyes: everything is fogged until they respawn -- EXCEPT their
  ## own last position, so the fatal hit's own "SPLAT" kill pop (added at
  ## sim.players[targetIndex].x/y by killPlayer, THREE LINES before it sets
  ## alive=false) is not fogged from the one viewer it exists to tell. A dead
  ## cog's x/y never moves again until respawn (respawnPlayers.placePlayer
  ## repositions it and flips alive=true in the same statement, so there is
  ## no tick where x/y already reads the new spawn while alive still reads
  ## false) -- so this narrowly hands back exactly one point, the viewer's
  ## own body, never any other dead-viewer intel. Call refreshPlayerFov
  ## first.
  if not sim.players[playerIndex].alive:
    let self = sim.players[playerIndex]
    return x >= self.x and x < self.x + CollisionW and
      y >= self.y and y < self.y + CollisionH
  if playerIndex >= sim.fovCaches.len or not sim.fovCaches[playerIndex].valid:
    return true
  let (cx, cy) = fovCellAt(x, y)
  sim.fovCaches[playerIndex].visible[fovCellIndex(cx, cy)]

proc playerVisibleTo*(sim: SimServer, viewerIndex, targetIndex: int): bool =
  ## Returns whether one player is observable by a viewer: only yourself is
  ## always visible; everyone else — teammates included — only inside your
  ## vision. There is no team radio.
  if viewerIndex == targetIndex:
    return true
  sim.fovVisibleAt(
    viewerIndex,
    sim.players[targetIndex].x + CollisionW div 2,
    sim.players[targetIndex].y + CollisionH div 2
  )

proc refreshSeatFov*(sim: var SimServer, viewerIndex: int) =
  ## Refreshes one viewer's fog AND, in a squad game, ORs in the fog of every
  ## other cog the same SEAT commands under the current regime.
  ##
  ## The seat is the observer, not the cog: a `resident` seat legitimately
  ## sees through all four of its cogs, while a `visitor` seat sees only
  ## through alpha — which is exactly what makes the visitor half a genuinely
  ## narrower view and the resident/visitor comparison worth measuring. Doing
  ## it by OR-ing into the viewing cog's cached grid means every downstream
  ## consumer (the frame builder, the first-person inset, entity culling)
  ## picks the union up with no further change.
  discard sim.refreshPlayerFov(viewerIndex)
  if not sim.config.squadModeConfigured():
    return
  let seat = sim.cogSeat(viewerIndex)
  if not sim.seatCommands(seat, viewerIndex):
    return
  for other in sim.commandedCogs(seat):
    if other == viewerIndex or not sim.players[other].alive:
      continue
    discard sim.refreshPlayerFov(other)
    if sim.fovCaches[other].visible.len != sim.fovCaches[viewerIndex].visible.len:
      continue
    for cell in 0 ..< sim.fovCaches[viewerIndex].visible.len:
      if sim.fovCaches[other].visible[cell]:
        sim.fovCaches[viewerIndex].visible[cell] = true
  # The union is a per-FRAME derivation, so it must not be mistaken for a
  # valid single-cog cache on the next tick.
  sim.fovCaches[viewerIndex].valid = false

proc flagVisibleTo*(sim: SimServer, viewerIndex: int, team: Team): bool =
  ## Returns whether one team's flag is observable by a viewer: always on its
  ## pedestal; riding a carrier it is exactly as visible as the carrier.
  let carrier = sim.flags[team].carrier
  if carrier < 0:
    return true
  sim.playerVisibleTo(viewerIndex, carrier)


proc focusCog(
  sim: SimServer,
  winner: Team,
  score: proc(p: Player): int
): int =
  ## The winning team's cog with the top `score`, damage dealt as the
  ## tiebreak (achievement focus -- see finishGame). -1 if the team is empty.
  result = -1
  var best = low(int)
  for i in 0 ..< sim.players.len:
    if sim.players[i].team != winner:
      continue
    let v = score(sim.players[i]) * 1000 + sim.players[i].damageDealt
    if result < 0 or v > best:
      best = v
      result = i

proc brRankedTeams(sim: SimServer): seq[Team] =
  ## Every seated team (sim.teams()), BEST TO WORST, by BR's one
  ## pre-registered total order (docs/designs/BR_MAPGEN.md §1):
  ##   1. most LIVING cogs — the mode's own currency.
  ##   2. latest LAST DEATH — of two teams equally reduced, the one that
  ##      held its cogs longer was winning for longer. A team that never
  ##      died at all ranks best (sentinel below), which matters because
  ##      -1 would otherwise rank it WORST.
  ##   3. most KILLS — took the fight to somebody.
  ##   4. most DAMAGE DEALT — was winning fights it did not finish.
  ##   5. lowest SLOT INDEX — arbitrary, and deliberately so: it exists
  ##      only to guarantee totality, so no timeout (or elimination-order
  ##      tie) can leave two teams unranked against each other.
  ##
  ## Pure function of already-hashed per-tick state (alive, lastDeathTick,
  ## kills, damageDealt) plus the static seat index — brTiebreakWinner's
  ## winner pick and finishGame's BR placement reward both read this, and
  ## neither adds anything to gameHash (rewardAccounts, and this ranking
  ## with it, is deliberately excluded — see brPlacements).
  ##
  ## Generic over sim.teams(), so it is unchanged at 2, 4 or 16 teams.
  var
    living, kills, damage: array[Team, int]
    lastDeath: array[Team, int]
    deaths: array[Team, int]
    seat: array[Team, int]
  for team in Team:
    lastDeath[team] = -1
    seat[team] = int.high
  for i, p in sim.players:
    # LOOT(s2): a ghost (downed) is not LIVING for the BR ranking — it is
    # a pending elimination, not a standing cog. Dark-inert.
    if p.alive and not p.downed:
      inc living[p.team]
    kills[p.team] += p.kills
    damage[p.team] += p.damageDealt
    if p.lastDeathTick >= 0:
      inc deaths[p.team]
      lastDeath[p.team] = max(lastDeath[p.team], p.lastDeathTick)
    seat[p.team] = min(seat[p.team], i)
  ## A team that never lost anybody outranks every team that did.
  for team in sim.teams():
    if deaths[team] == 0:
      lastDeath[team] = int.high

  result = @[]
  for team in sim.teams():
    result.add team
  result.sort(proc(a, b: Team): int =
    ## Lexicographic compare on the five ranks, in order; `a` before `b`
    ## (negative) when `a` ranks BETTER.
    if living[a] != living[b]: return cmp(living[b], living[a])
    if lastDeath[a] != lastDeath[b]: return cmp(lastDeath[b], lastDeath[a])
    if kills[a] != kills[b]: return cmp(kills[b], kills[a])
    if damage[a] != damage[b]: return cmp(damage[b], damage[a])
    cmp(seat[a], seat[b])
  )
  ## Never a tie: seat index is unique per team among seated teams, so the
  ## comparison above is a strict total order and this sort is a strict
  ## ranking with no ties left over.

proc brTiebreakWinner(sim: SimServer): tuple[winner: Team, isDraw: bool] =
  ## BR maxTicks tiebreak: the best-ranked team from brRankedTeams. A
  ## STRICT TOTAL ORDER: a timeout can never be a draw.
  ##
  ## Draw-free is the point, not a detail. A draw at the clock breeds
  ## PASSIVE DOUBLE-DEATH play: if both sides survive to the timeout and
  ## split the result, the dominant strategy is to avoid the fight, and a
  ## battle royale whose optimal line is "do not engage" has lost its
  ## thesis. The failure is observable rather than theoretical — weakly
  ## priced endgames let a share of episodes reach the clock and be won by
  ## survival farming instead of by fighting.
  (sim.brRankedTeams()[0], false)

proc brPlacements*(sim: SimServer): array[Team, int] =
  ## 1-based placement (1..16) for every seated team, from the exact same
  ## total order brTiebreakWinner picks its winner from — rank 1 is the
  ## team that IS (or would be) crowned, rank N the team ranked worst
  ## (ordinarily the team eliminated first). Unseated teams (past
  ## sim.teams()) are left at the array's zero-value default.
  ##
  ## Read by finishGame's BR placement reward (§7.3: any survival-derived
  ## term must be a bounded, monotone function of already-hashed state,
  ## never a fresh draw or raw ticks-alive). This is exactly that: a rank
  ## in 1..16 BY CONSTRUCTION, derived from brRankedTeams above, which is
  ## itself a pure function of already-hashed per-tick fields. Nothing
  ## here enters gameHash — rewardAccounts (and the placements/rewards
  ## derived from it) is deliberately excluded from it, same as every
  ## other derived-bookkeeping field.
  for idx, team in sim.brRankedTeams():
    result[team] = idx + 1

proc finishGame*(sim: var SimServer, winner: Team, isDraw = false, timeLimitReached = false) =
  ## Moves to game over and awards all winning players.
  if sim.phase == GameOver:
    return
  if isDraw:
    sim.logGameEvent("draw")
  else:
    sim.logGameEvent(teamText(winner) & " win")
  sim.emitPhaseChange(GameOver)
  sim.phase = GameOver
  sim.winner = winner
  sim.isDraw = isDraw
  sim.gameOverTimer = sim.config.gameOverTicks
  sim.timeLimitReached = timeLimitReached
  # GLORY v12: the structural conclusion sweep (contract §4) -- one full
  # achievement pass over the exact state the game ended on, before any of
  # the reward/placement bookkeeping below and before the `isDraw` early
  # return, so it fires on every conclusion (draw or decisive, capture or
  # wipe or time limit). This is where a game-ENDING act's tiers mint
  # (Delivered, Victory Lap, the final kill's thresholds) and where Clean
  # Sheet -- a full-game requirement no Playing-phase read can satisfy --
  # keeps its "the whole game, however it ended" scope, now via
  # `satisfiedAchievements`' `atConclusion` read instead of a special case.
  #
  # ── MULTIPLIER RECUT (v13, armed) ── `dVictory` (table §1b): "the game
  # is over, you won" as a BR-native ×8, minted at the winner's own
  # pedestal (the same pricing site achievements use — home ground, so the
  # territory shift is a structural no-op) BEFORE the conclusion sweep, so
  # the sweep's deed counters already include it. brMode-only (CTF's
  # game-over deed is the capture/wipe that ended it), decisive games only
  # (a draw crowns nobody). Dark-inert: the flag gates the mint entirely.
  if sim.config.gloryMultiplierRecut and sim.config.brMode and not isDraw:
    let home = sim.gameMap.flagHome(winner)
    sim.awardDeed(winner, dVictory, home.x, home.y)
  sim.evalAchievementsAtConclusion()
  if isDraw:
    if timeLimitReached:
      # A time-limit draw is a lose-lose: every player on both teams takes
      # TimeoutReward so running out the clock is never better than losing.
      # A mutual-wipe draw stays 0/0 — both sides at least fought to the end.
      var penalizedAccounts = newSeq[bool](sim.rewardAccounts.len)
      for i in 0 ..< sim.players.len:
        let accountIndex = sim.rewardAccountForPlayer(i)
        if penalizedAccounts.len < sim.rewardAccounts.len:
          penalizedAccounts.setLen(sim.rewardAccounts.len)
        if accountIndex >= 0 and accountIndex < penalizedAccounts.len:
          penalizedAccounts[accountIndex] = true
        sim.addReward(i, TimeoutReward)
      for i in 0 ..< sim.rewardAccounts.len:
        if i < penalizedAccounts.len and penalizedAccounts[i]:
          continue
        if not sim.rewardAccounts[i].hasTeam:
          continue
        sim.rewardAccounts[i].reward += TimeoutReward
    return
  # classic: zero-sum by construction — the winning team scores +1 per losing
  # team, each losing team -1. Classic 2-team play is +1/-1; a 4-team ffa win
  # pays the winner +3 and each loser -1.
  # pot: every team antes one point, so the pot is the team count and the
  # winning team takes all of it; the losing teams split the forfeit evenly
  # (integer division, so a 4-team pot of 4 costs each of the three losers 1).
  # 2 teams pay +2/-2, 4 teams pay +4/-1/-1/-1.
  let loserTeams = sim.gameMap.teamCount() - 1
  let winReward =
    if sim.config.scoring == PotScoring:
      sim.gameMap.teamCount()
    else:
      WinReward * loserTeams
  let lossReward =
    if sim.config.scoring == PotScoring:
      -(sim.gameMap.teamCount() div loserTeams)
    else:
      LossReward
  # BR placement (§7.3): every losing team's reward is keyed on placement
  # RANK instead of a flat lossReward, GATED on engagement evidence — a
  # team earns placement credit only if it made an attack or dealt damage
  # (attacksMade/damageDealt, summed over its cogs); with no engagement its
  # reward collapses to the plain loss floor. teamReward[t] is exactly
  # lossReward for every t != winner outside brMode (the loop below never
  # runs), so this is a no-op — byte-identical to the pre-BR reward path —
  # for every classic/non-BR game.
  var teamReward: array[Team, int]
  for t in Team:
    teamReward[t] = lossReward
  teamReward[winner] = winReward
  if sim.config.brMode:
    var teamAttacks, teamDealt: array[Team, int]
    for p in sim.players:
      teamAttacks[p.team] += p.attacksMade
      teamDealt[p.team] += p.damageDealt
    let placement = sim.brPlacements()
    for t in sim.teams():
      if t == winner:
        continue
      if teamAttacks[t] == 0 and teamDealt[t] == 0:
        continue  # no engagement evidence: stays at the loss floor.
      # placement[t] is 2..16 for every real call site: both BR endings
      # (checkWinCondition's wipe, whose `winner` is the one team with
      # living players, and checkMaxTicks's brTiebreakWinner, whose
      # `winner` IS brPlacements()[0] by construction) always pass a
      # `winner` that agrees with this same ranking's rank 1, and the
      # ranking is a strict total order, so no OTHER team can also read
      # rank 1 here. `max(2, ...)` is defense-in-depth only, for a
      # hypothetical future caller that passes a `winner` disagreeing with
      # this ranking — never crash on that, just floor its rank at 2nd.
      let rank = max(2, placement[t])
      teamReward[t] = min(lossReward + BrPlacementBonus[rank], winReward - 1)
  var awardedAccounts = newSeq[bool](sim.rewardAccounts.len)
  for i in 0 ..< sim.players.len:
    let accountIndex = sim.rewardAccountForPlayer(i)
    if awardedAccounts.len < sim.rewardAccounts.len:
      awardedAccounts.setLen(sim.rewardAccounts.len)
    if accountIndex >= 0 and accountIndex < awardedAccounts.len:
      awardedAccounts[accountIndex] = true
    sim.addReward(i, teamReward[sim.players[i].team])
    if sim.players[i].team == winner:
      sim.recordGameWin(i)
  for i in 0 ..< sim.rewardAccounts.len:
    if i < awardedAccounts.len and awardedAccounts[i]:
      continue
    if not sim.rewardAccounts[i].hasTeam:
      continue
    sim.rewardAccounts[i].reward += teamReward[sim.rewardAccounts[i].team]
    if sim.rewardAccounts[i].team == winner:
      sim.rewardAccounts[i].won = true
      inc sim.rewardAccounts[i].wins[sim.rewardAccounts[i].team]
  # Achievements: evaluated once per finished (non-draw) game, for the
  # winning team only, from the analysis counters this game reset at
  # startGame. Earned ids accumulate on the address accounts (deduplicated),
  # so a maxGames > 1 episode reports the union in results.json.
  #
  # Every badge is TEAM-level: the counters are summed (or maxed) over all of
  # the winning team's cogs, whichever policies seat them, and every cog on
  # the team records the badge — the platform dedupes per player. Judging
  # cogs one at a time handed pacifist/spotless to any seat whose heart-guard
  # never fired or never got hit, i.e. to nearly every winner.
  #
  # `almost` counts the team's whole remaining LIFE BUDGET: living hp plus
  # every respawn still owed (a cog respawns at full hp while it has lives
  # left). Counting living hp alone made a winner whose last cog was
  # respawning when the final enemy fell — the barrage endgame's normal
  # finish — a "cliffhanger" in one game out of eight.
  var winnerLife = 0
  for p in sim.players:
    if p.team != winner:
      continue
    let fullHp = sim.config.maxHpFor(p.team, p.perks)
    if p.alive:
      # An alive cog with N lives dies N times in total, so it still has
      # N - 1 respawns owed; a dead cog waiting on its timer has `lives`.
      winnerLife += max(0, p.hp) + max(0, p.lives - 1) * fullHp
    else:
      winnerLife += p.lives * fullHp
  let almost = winnerLife < AlmostTeamHp
  # `heist`: the game ended on THIS tick's heart capture by the winner — the
  # capture eliminated the last standing rival — so the win was the carry,
  # not the wipe.
  let heistWin = sim.lastCaptureTick == sim.tickCount and
    sim.lastCaptureTeam == winner
  var
    attacks, taken, dealt, grenade, gun, spray, pit, kills = 0
    bestKills, bestHeals, bestAssassin, bestLucky = 0
    packOk = true
    silent = true
  for p in sim.players:
    if p.team != winner:
      continue
    attacks += p.attacksMade
    taken += p.damageTaken
    dealt += p.damageDealt
    grenade += p.grenadeDamageDealt
    gun += p.gunDamageDealt
    spray += p.sprayDamageDealt
    pit += p.pitDamageDealt
    kills += p.kills
    bestKills = max(bestKills, p.bestKillsInLife)
    bestHeals = max(bestHeals, p.bestHealsInLife)
    bestAssassin = max(bestAssassin, p.assassinKills)
    bestLucky = max(bestLucky, p.blastsSurvived)
    # `silent`: lastShoutTick is reset to -1 at startGame and only set by
    # an APPLIED shout, so any value >= 0 means this cog spoke this game.
    if p.lastShoutTick >= 0:
      silent = false
    # `pack` is an EVERY-cog condition: one straggler fails the team.
    if p.aliveTicks == 0 or p.packTicks * 100 < p.aliveTicks * PackPct:
      packOk = false
  # BR (§7.3): Pacifist/Spotless must not pay ON TOP of a win earned WITHOUT
  # engagement — a team that never fired a shot and was never fired upon
  # either is exactly the "pure-hiding winner" the doctrine caps. brMode
  # gates both on the SAME engagement evidence the placement reward above
  # uses (attacks>0 or dealt>0, already summed team-wide just above).
  # Pacifist's own definition (attacks == 0 for the whole team) means this
  # gate is not a special case for it: every damage-dealing hit is
  # attributed to an attacker who by construction already has
  # attacksMade >= 1 (the fire site increments it before any hit can
  # land), so dealt > 0 implies attacks > 0 — a Pacifist-eligible team
  # (attacks == 0) always has dealt == 0 too, so the gate always fails and
  # Pacifist is simply unearnable in brMode. Spotless keeps its own
  # meaning (never touched) but now additionally requires the team to have
  # actually fought — "we never got hit while dealing/attempting damage"
  # instead of "we were never involved." Classic (non-BR) games are
  # untouched: brEngaged is unconditionally true when brMode is off, so
  # both badges stay byte-identical there.
  let brEngaged = not sim.config.brMode or attacks > 0 or dealt > 0
  var earned: seq[string]
  if attacks == 0 and brEngaged:
    earned.add AchievementPacifist
  if taken == 0 and brEngaged:
    earned.add AchievementSpotless
  if almost:
    earned.add AchievementAlmost
  # Percent thresholds compare by integer cross-multiply (no floats in the sim).
  if dealt > 0 and grenade * 100 >= dealt * GrenadierPct:
    earned.add AchievementGrenadier
  if bestKills >= RamboKills:
    earned.add AchievementRambo
  if bestHeals >= MedicHeals:
    earned.add AchievementMedic
  if dealt > 0 and gun == dealt:
    earned.add AchievementSniper
  if dealt > 0 and spray * 100 >= dealt * BanksyPct:
    earned.add AchievementBanksy
  if packOk:
    earned.add AchievementPack
  if dealt > 0 and pit * 100 >= dealt * PitMasterPct:
    earned.add AchievementPitMaster
  if heistWin and kills == 0:
    earned.add AchievementHeist
  if silent:
    earned.add AchievementSilent
  if bestAssassin >= AssassinKills:
    earned.add AchievementAssassin
  if bestLucky >= LuckyBlasts:
    earned.add AchievementLucky
  for i in 0 ..< sim.players.len:
    if sim.players[i].team != winner:
      continue
    for id in earned:
      sim.recordAchievement(i, id)
  # The focus cog per earned badge — who the badge is ABOUT — so a replay
  # opened from a badge's watch link can select the receiving cog. Per-cog
  # badges name their streaker/survivor; aggregate badges name the top
  # contributor; heist names the capturer; the team-wide badges (pacifist,
  # spotless, silent, pack, almost) fall back to the team's most active cog
  # (kills, then damage dealt) — every teammate "received" those, so the
  # camera follows the one with the most story.
  sim.achievementFocus = @[]
  for id in earned:
    let focus =
      case id
      of AchievementRambo:
        focusCog(sim, winner, proc(p: Player): int = p.bestKillsInLife)
      of AchievementMedic:
        focusCog(sim, winner, proc(p: Player): int = p.bestHealsInLife)
      of AchievementAssassin:
        focusCog(sim, winner, proc(p: Player): int = p.assassinKills)
      of AchievementLucky:
        focusCog(sim, winner, proc(p: Player): int = p.blastsSurvived)
      of AchievementGrenadier:
        focusCog(sim, winner, proc(p: Player): int = p.grenadeDamageDealt)
      of AchievementSniper:
        focusCog(sim, winner, proc(p: Player): int = p.gunDamageDealt)
      of AchievementBanksy:
        focusCog(sim, winner, proc(p: Player): int = p.sprayDamageDealt)
      of AchievementPitMaster:
        focusCog(sim, winner, proc(p: Player): int = p.pitDamageDealt)
      of AchievementAlmost:
        # The cliffhanger's face is whoever is still standing.
        focusCog(sim, winner,
          proc(p: Player): int = (if p.alive: 1000 + p.hp else: 0))
      of AchievementHeist:
        if sim.lastCaptureIndex >= 0: sim.lastCaptureIndex
        else: focusCog(sim, winner, proc(p: Player): int = p.captures)
      else: focusCog(sim, winner, proc(p: Player): int = p.kills)
    if focus >= 0:
      sim.achievementFocus.add(
        AchievementFocus(id: id, playerIndex: focus))

proc maxTicksReached(sim: SimServer): bool =
  ## Whether the scheduled draw ceiling ends the game this tick. A game
  ## with the grenade barrage configured has NO draw ceiling: past the
  ## deadline the clock reads 0:00 and the full-intensity bombardment
  ## grinds on until at most one team stands (GV41) — a draw then needs
  ## the last players of two teams to die on the same tick.
  sim.config.barrageMaxPerSec <= 0 and
    sim.config.maxTicks > 0 and sim.phase == Playing and
    sim.gameTicksElapsed() >= sim.effectiveMaxTicks()

proc teamLivesRemaining*(sim: SimServer, team: Team): int =
  ## Returns total lives remaining (alive players count their current life).
  ## Kept for the broadcast scorebug + momentum series (upstream dropped it as
  ## unused; the replay chrome still reads it).
  for p in sim.players:
    if p.team != team:
      continue
    result += p.lives
    if p.alive:
      inc result

proc flagCarryProgress*(sim: SimServer, flagTeam: Team): int =
  ## Returns how far one team's STOLEN flag has been advanced from its
  ## pedestal toward its carrier's home; 0 while it sits home. (0.7.0
  ## relabels the flag a "heart" in art/copy, but the carry-to-home
  ## mechanic is unchanged.) Sides maps keep the classic x-displacement
  ## measure; corner and plus layouts use straight-line displacement.
  let flag = sim.flags[flagTeam]
  if flag.carrier < 0:
    return 0
  let
    carrierTeam = sim.players[flag.carrier].team
    home = sim.gameMap.flagHome(flagTeam)
  let progress =
    case sim.gameMap.layout
    of layoutSides:
      if carrierTeam == Red:
        home.x - flag.x
      else:
        flag.x - home.x
    of layoutCorners, layoutPlus:
      let
        anchor = sim.gameMap.teamAnchor(carrierTeam)
        d0 = sqrt(float(distSq(home.x, home.y, anchor.x, anchor.y)))
        d = sqrt(float(distSq(flag.x, flag.y, anchor.x, anchor.y)))
      int(d0 - d)
  max(0, progress)

proc teamFlagProgress*(sim: SimServer, team: Team): int =
  ## Returns how far this team has advanced a stolen enemy flag toward its
  ## own home; 0 when no enemy flag is on one of its players' backs.
  for flagTeam in sim.teams():
    if flagTeam == team:
      continue
    let flag = sim.flags[flagTeam]
    if flag.carrier < 0 or sim.players[flag.carrier].team != team:
      continue
    result = max(result, sim.flagCarryProgress(flagTeam))

proc teamHasLivePlayers(sim: SimServer, team: Team): bool =
  ## Returns true when a team still has a player who can act this round.
  for p in sim.players:
    if p.team == team and (p.alive or p.lives > 0):
      return true
  false

proc shouldAbortFiniteMatch*(sim: SimServer): bool =
  ## Returns true when a finite match cannot continue after roster loss.
  if sim.config.maxGames <= 0:
    return false
  if sim.phase == Lobby:
    return sim.startWaitTimer > 0 and sim.players.len < sim.config.minPlayers
  sim.phase == Playing and sim.players.len == 0

proc lobbyJoinTimedOut*(sim: SimServer): bool =
  ## Returns true when a finite match waited out its lobby-join budget with
  ## the roster still short of minPlayers. Joins are strictly slot-sequential
  ## (`nextPlayerSlot`), so at timeout the stuck seat is exactly
  ## `sim.nextPlayerSlot()` — the caller declares that seat's failure to the
  ## platform (player_failure.json) so the no-show is charged to the policy
  ## that never joined instead of poisoning the episode unattributed.
  sim.config.maxGames > 0 and
    sim.config.lobbyJoinTimeoutTicks > 0 and
    sim.phase == Lobby and
    sim.players.len < sim.config.minPlayers and
    sim.lobbyWaitTimer >= sim.config.lobbyJoinTimeoutTicks

proc eliminateTeam(sim: var SimServer, team: Team, killerIndex: int) =
  ## GV32: removes a team from play after its heart is captured — every
  ## player dies with no respawn. A heart an eliminated player was carrying
  ## goes home via the normal killPlayer flag return; the eliminated team's
  ## own heart is retired by the capture site, not here. GV35: these are
  ## `elimination` deaths — the team lost, nobody was killed — so the
  ## deaths stat stays untouched and the endscreen stats stay combat-only.
  sim.logGameEvent(teamText(team) & " eliminated")
  for i in 0 ..< sim.players.len:
    if sim.players[i].team != team:
      continue
    sim.players[i].lives = 0
    sim.players[i].respawnTimer = 0
    if sim.players[i].alive:
      sim.killPlayer(i, killerIndex, elimination = true)

proc updatePuddles*(sim: var SimServer) =
  ## One tick of the paint-puddle hazard: every full second (PuddleRollTicks
  ## ticks) a cog's center spends CONTINUOUSLY inside a puddle rolls a
  ## puddleDamagePct chance of 1 damage — through the shield layer first,
  ## like every weapon. Dipping out (or dying) restarts the second. The RNG
  ## draws ONLY on a completed second of occupancy, so the puddle-free path
  ## stays byte-identical across builds (changing the DEFAULT pct still
  ## bumps GV — spec-pinned puddle replays echo no pct key; see GV43).
  if ArenaPuddles.len == 0 or sim.phase != Playing:
    return
  for i in 0 ..< sim.players.len:
    # LOOT(s2): a ghost (downed) is past hurting — environmental damage
    # never confirms an elimination; only an enemy paintball (splat) or the
    # bleed-out clock does. Dark-inert.
    if not sim.players[i].alive or sim.players[i].downed:
      sim.players[i].puddleTicks = 0
      continue
    if sim.playerPuddle(i) < 0:
      sim.players[i].puddleTicks = 0
      continue
    inc sim.players[i].puddleTicks
    if sim.players[i].puddleTicks < PuddleRollTicks:
      continue
    sim.players[i].puddleTicks = 0
    if sim.rng.rand(99) >= sim.config.puddleDamagePct:
      continue
    let
      px = sim.players[i].x + CollisionW div 2
      py = sim.players[i].y + CollisionH div 2
      bubbleUp = sim.players[i].hasShield and sim.players[i].shieldHp > 0
      blocked = sim.absorbDamage(i, 1)
    # Puddle paint marks the body the same way weapon paint does — unless
    # the shield bubble ate the hit (a bubble dent draws no body paint).
    if not bubbleUp:
      sim.players[i].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = -1, target = i, weapon = "puddle",
      amount = 1, hp = max(0, sim.players[i].hp),
      blocked = blocked,
      x = float(px), y = float(py)
    )
    # A floating "-1" rises from the victim so the hazard's bite reads at a
    # glance (cosmetic only, never in gameHash).
    sim.damagePops.add DamageFx(
      x: px, y: py,
      tick: sim.tickCount,
      amount: 1,
      color: sim.players[i].color
    )
    if sim.players[i].hp <= 0:
      sim.killPlayer(i, -1, cause = "dissolved in a paint puddle")


proc updateZone*(sim: var SimServer) =
  ## One tick of the battle-royale shrink-zone hazard (§4.3): a player whose
  ## center has stood OUTSIDE the current zone rect for a full second
  ## (ZoneDamageRollTicks — the same per-second cadence updatePuddles uses)
  ## takes the active phase's `dps` hit points, exactly — no RNG roll, since
  ## dps is an authored RATE rather than a chance (unlike puddleDamagePct).
  ## Dipping back inside (or dying) restarts the second, exactly like
  ## puddleTicks. A no-op — no RNG draw, no state read beyond the config
  ## length check — when zonePhases is empty, so an unconfigured game is
  ## untouched.
  if sim.config.zonePhases.len == 0 or sim.phase != Playing:
    return
  let (rect, _, dps) = sim.zoneRectAndDps(sim.tickCount - sim.gameStartTick)
  for i in 0 ..< sim.players.len:
    # LOOT(s2): ghosts are zone-immune — the bleed-out clock is already
    # running; see updatePuddles' same guard. Dark-inert.
    if not sim.players[i].alive or sim.players[i].downed:
      sim.players[i].zoneOutsideTicks = 0
      continue
    let
      px = sim.players[i].x + CollisionW div 2
      py = sim.players[i].y + CollisionH div 2
    var inside = px >= rect.x and px <= rect.x + rect.w - 1 and
      py >= rect.y and py <= rect.y + rect.h - 1
    # ZONEPAINT (owner order 2026-09-03): when armed, the damage test IS the
    # painted test — "being on the pink paint is what does damage, not an
    # invisible rectangle." Same cadence, same dps, same source=-1
    # environment attribution, same kill cause below: ONLY the membership
    # verdict changes, from rect geometry to the shared arrival field
    # (zone_field.nim, the exact surface the viewer draws). Wall/off-grid
    # cells (onField=false) keep the rect verdict — the flow field is
    # undefined there and no pixel may read as immortal ground. Dark
    # (default): this branch never runs and the rect path above is
    # byte-identical to the pre-flag build.
    if sim.config.zoneDamageByPaint:
      let q = sim.zonePaintedForDamageAt(
        px, py, sim.tickCount - sim.gameStartTick)
      if q.onField:
        inside = not q.painted
    if inside:
      sim.players[i].zoneOutsideTicks = 0
      continue
    inc sim.players[i].zoneOutsideTicks
    if sim.players[i].zoneOutsideTicks < ZoneDamageRollTicks:
      continue
    sim.players[i].zoneOutsideTicks = 0
    if dps <= 0:
      continue
    let
      bubbleUp = sim.players[i].hasShield and sim.players[i].shieldHp > 0
      blocked = sim.absorbDamage(i, dps)
    # Zone paint marks the body the same way puddle/weapon paint does —
    # unless the shield bubble ate the hit.
    if not bubbleUp:
      sim.players[i].paintHitTick = sim.tickCount
    sim.emitEvent(
      Damage, source = -1, target = i, weapon = "zone",
      amount = dps, hp = max(0, sim.players[i].hp),
      blocked = blocked,
      x = float(px), y = float(py)
    )
    # A floating "-N" rises from the victim so the hazard's bite reads at a
    # glance (cosmetic only, never in gameHash) — same idiom as the puddle
    # roll above.
    sim.damagePops.add DamageFx(
      x: px, y: py,
      tick: sim.tickCount,
      amount: dps,
      color: sim.players[i].color
    )
    if sim.players[i].hp <= 0:
      sim.killPlayer(i, -1, cause = "caught outside the zone")

proc launchBarrageShell(sim: var SimServer) =
  ## Launches one environment grenade: the landing point is drawn from the
  ## deterministic sim RNG inside the current target band (within
  ## barrageDepth of some map edge), and the shell arcs in from the nearest
  ## point of that edge with the same fixed fuse a player lob has. Thrower
  ## -1 marks it environmental: no kill credit, no rewards, no multi-kills.
  let
    depth = max(1, sim.barrageDepth())
    side = sim.rng.rand(3)
    inset = sim.rng.rand(depth - 1)
  var tx, ty, sx, sy: int
  case side
  of 0:                                  # north edge, raining downward.
    tx = sim.rng.rand(MapWidth - 1)
    ty = inset
    sx = tx
    sy = 0
  of 1:                                  # south edge.
    tx = sim.rng.rand(MapWidth - 1)
    ty = MapHeight - 1 - inset
    sx = tx
    sy = MapHeight - 1
  of 2:                                  # west edge.
    ty = sim.rng.rand(MapHeight - 1)
    tx = inset
    sx = 0
    sy = ty
  else:                                  # east edge.
    ty = sim.rng.rand(MapHeight - 1)
    tx = MapWidth - 1 - inset
    sx = MapWidth - 1
    sy = ty
  tx = clamp(tx, ArenaBorder + 2, MapWidth - ArenaBorder - 2)
  ty = clamp(ty, ArenaBorder + 2, MapHeight - ArenaBorder - 2)
  sim.airborneGrenades.add AirborneGrenade(
    sx: sx,
    sy: sy,
    tx: tx,
    ty: ty,
    launchTick: sim.tickCount,
    flightTicks: max(1, GrenadeFlightMultiple * sim.config.fireWindupTicks),
    thrower: -1,
    throwerSlot: -1,
    throwerAccount: -1
  )

proc updateBarrage*(sim: var SimServer) =
  ## One tick of the grenade-barrage endgame: latch when the game clock
  ## drops to barrageStartSec remaining, then rain environment grenades —
  ## barrageStartPerSec along the map edges at first, ramping linearly to
  ## barrageMaxPerSec across the whole board as the escalation completes
  ## (barrageProgressPermille). The shells land through the ordinary
  ## grenade pipeline, so blast kills bank action-floor overtime; the
  ## latched barrage only ever escalates through the extension, so a timed
  ## game ends on a wipe or capture instead of a timeout draw.
  if sim.config.barrageMaxPerSec <= 0 or sim.config.maxTicks <= 0:
    return
  if sim.phase != Playing:
    return
  if sim.barrageStartTick < 0:
    let remaining = sim.effectiveMaxTicks() - sim.gameTicksElapsed()
    if remaining <= sim.config.barrageStartSec * TargetFps:
      sim.barrageStartTick = sim.tickCount
      sim.barrageAccum = 0
      sim.logGameEvent("grenade barrage incoming")
    return
  # Fractional launch pacing: the rate is permille grenades/second, one
  # grenade costs TargetFps*1000 accumulator units, so any integer rate
  # spreads its launches evenly with zero drift.
  const UnitsPerGrenade = TargetFps * 1000
  sim.barrageAccum += sim.barrageRatePermille()
  while sim.barrageAccum >= UnitsPerGrenade:
    sim.barrageAccum -= UnitsPerGrenade
    # The drawn-orb pool holds MaxPlayers in-flight grenades; at the config
    # ceiling (BarrageAbsMaxPerSec x the ~10-tick fuse) the barrage stays
    # well inside it, so this cap is a belt-and-suspenders skip, and the
    # accumulator still drains so a capped stretch never banks a burst.
    if sim.airborneGrenades.len < MaxPlayers:
      sim.launchBarrageShell()

proc awardWipe(sim: var SimServer, winner, loser: Team) =
  ## Mints `dWipe` at the exact in-sim site of the deciding kill: the
  ## losing team's last player to fall THIS tick, paid out over their
  ## killer. `checkWinCondition`'s draw branch never calls this, so a
  ## mutual wipe can never pay two windfalls.
  ##
  ## GLORY PORT (increment 2/3): ported as a 2-argument (winner, loser) proc, same
  ## as main -- `checkWinCondition` below generalizes the CALLER to find
  ## which team(s) to call it for on an N-team board (main's own version
  ## could assume exactly one `loser` because it only ever ran on 2-team
  ## play); this proc's own body needed no N-team change at all.
  ##
  ## GLORY v11 (BR increment 3): DISABLED outright in `brMode` -- CTF is
  ## untouched (2-team play still mints the classic wipe). In a 16-team
  ## single-elimination BR board this fires on essentially every episode
  ## that isn't a mutual draw, always paying out to whichever team happens
  ## to be the sole survivor -- a near-fixed win bonus, not a dominance
  ## signal. MEASURED (re-simulating the GV47 `episode-s830` reference
  ## recording, PR #313, and its five 31337-seeded siblings, 2026-08-30):
  ## winner glory converged to 626-627g across every one of them despite
  ## different seeds and different match shapes -- exactly the
  ## "structural constant dominating the ledger" this cut removes. On
  ## s830 specifically (886g total, 16/16 teams nonzero), disabling this
  ## one mint (re-simulated against the SAME recorded inputs, so the
  ## match itself replays identically) dropped the winner from 626g to
  ## 26g and the episode total from 886g to 286g -- a single deed mint
  ## was 95.8% of the eventual winner's WHOLE episode glory. (The mint
  ## priced above its own 400g base here because the site gradient's
  ## `groundOwner` was still degenerate at record time -- see the E7
  ## `slotAnchor` fix, same wave -- so it is not a pure measure of
  ## `dWipe`'s base price alone; the STRUCTURAL point, that one mint ate
  ## nearly the whole ledger, holds regardless.)
  if sim.config.brMode:
    return
  var
    siteX, siteY: int
    killerIndex = -1
    found = false
  for i in 0 ..< sim.players.len:
    if sim.players[i].team != loser:
      continue
    if sim.players[i].lastKilledByTick == sim.tickCount:
      siteX = sim.players[i].x
      siteY = sim.players[i].y
      let by = sim.players[i].lastKilledBy
      if by >= 0 and by < sim.players.len and sim.players[by].team == winner:
        killerIndex = by
      found = true
      break
  if not found:
    for i in 0 ..< sim.players.len:
      if sim.players[i].team == loser:
        siteX = sim.players[i].x
        siteY = sim.players[i].y
        found = true
        break
  if not found:
    return
  sim.awardDeed(winner, dWipe, siteX, siteY, byIndex = killerIndex)

proc updatePaintBuff*(sim: var SimServer) =
  ## NEW (paintball): the once-per-tick "what am I standing on" evaluation.
  ##
  ## Runs at the END of tick t; the speed multiplier it records is consumed by
  ## `applyInput` on tick t+1, so there is exactly ONE evaluation per cog per
  ## tick and both halves of the buff read the SAME snapshot.
  ##
  ## The heal counter is reset by stepping off own paint for even one tick, by
  ## taking any damage (absorbDamage), by dying (killPlayer) and at the start
  ## of each game (startGame).
  if not sim.config.floorPaint:
    return
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      sim.players[i].paintUnder = puNone
      sim.players[i].ownPaintTicks = 0
      continue
    let under = sim.paintUnderFor(i)
    sim.players[i].paintUnder = under
    if not sim.config.paintBuff:
      continue
    if under != puOwn:
      sim.players[i].ownPaintTicks = 0
      continue
    inc sim.players[i].ownPaintTicks
    if sim.players[i].ownPaintTicks < max(1, sim.config.paintHealTicks):
      continue
    sim.players[i].ownPaintTicks = 0
    let maxHp = sim.config.maxHpFor(sim.players[i].team, sim.players[i].perks)
    if sim.players[i].hp >= maxHp:
      continue
    inc sim.players[i].hp
    sim.emitEvent(
      Heal, source = i, amount = 1, hp = sim.players[i].hp,
      x = float(sim.players[i].x + CollisionW div 2),
      y = float(sim.players[i].y + CollisionH div 2)
    )

proc updateHill*(sim: var SimServer) =
  ## NEW (paintball): recompute hill ownership from the incremental tile
  ## counts and bank one point per owned tick. An ownership CHANGE emits a
  ## `hillflip` analysis event, throttled to at most one per
  ## HillFlipThrottleTicks so a contested rim cannot flood the feed.
  if not sim.config.hill:
    return
  var
    owner = Red
    owned = false
  for team in sim.teams():
    if sim.hillOwnsFor(team):
      owner = team
      owned = true
      break
  if owned != sim.hillOwned or (owned and owner != sim.hillOwner):
    sim.hillOwned = owned
    sim.hillOwner = owner
    if sim.tickCount - sim.lastHillFlipTick >= HillFlipThrottleTicks:
      sim.lastHillFlipTick = sim.tickCount
      if owned:
        sim.logGameEvent(
          teamText(owner) & " takes the hill (" &
            $sim.hillCoveragePct(owner) & "%)")
      else:
        sim.logGameEvent("the hill is contested")
      sim.emitEvent(
        HillFlip,
        weapon = (if owned: teamText(owner) else: "none"),
        amount = (if owned: sim.hillCoveragePct(owner) else: 0)
      )
  if sim.hillOwned:
    inc sim.hillTicks[sim.hillOwner]
    if sim.hillTicks[sim.hillOwner] mod TargetFps == 0:
      sim.emitEvent(
        HillHold,
        weapon = teamText(sim.hillOwner),
        amount = sim.hillTicks[sim.hillOwner] div TargetFps
      )

proc hillLeader*(sim: SimServer): tuple[team: Team, draw: bool] =
  ## The team with more banked hill ticks this game, and whether it is level.
  if sim.hillTicks[Red] > sim.hillTicks[Blue]: (Red, false)
  elif sim.hillTicks[Blue] > sim.hillTicks[Red]: (Blue, false)
  else: (Red, true)

proc checkWinCondition*(sim: var SimServer) {.measure.} =
  ## Resolves capture and wipe win conditions.
  if sim.phase != Playing or sim.players.len == 0:
    return
  # Capture: a living carrier bringing an enemy flag into their own home
  # capture zone (deliberately no own-flag-must-be-home precondition).
  # GV32: a capture ELIMINATES the captured team instead of ending the game
  # outright — the heart leaves play where it was captured and every player
  # on the captured team dies for good. The game then ends below when at
  # most one team still stands, so a 4-team winner either captures every
  # rival heart or outlives the field; classic 2-team play still ends on
  # the first capture (eliminating the only rival leaves one team).
  #
  # BR INTEGRATION: two lanes each disarmed this branch, for DIFFERENT and
  # independently-true reasons, so the merged guard is their union:
  #   * brMode (elim lane) — a BR episode is decided by elimination only. A
  #     capture must not eliminate a team or end the game even on a map whose
  #     flags CAN be carried, which is precisely what test_br_elim's "flags
  #     never end or score a BR game" exercises (it picks a heart up first).
  #   * flagless (spawn lane) — a flagless map's flags are permanently
  #     `captured` with carrier -1 (resetFlags), so the loop below is already
  #     provably inert; the guard is defense-in-depth.
  # Note the SECOND loop (heart retirement) is guarded by flagless alone, not
  # by this union — see its own comment.
  if not sim.config.brMode and not sim.gameMap.flagless:
    for flagTeam in sim.teams():
      let carrierIndex = sim.flags[flagTeam].carrier
      if carrierIndex < 0 or carrierIndex >= sim.players.len or
          not sim.players[carrierIndex].alive:
        continue
      let
        carrier = sim.players[carrierIndex]
        zone = sim.captureZone(carrier.team)
        cx = carrier.x + CollisionW div 2
        cy = carrier.y + CollisionH div 2
      if zone.inCaptureZone(cx, cy):
        sim.recordCapture(carrierIndex)
        # GLORY: capture deed/xp + the "Uphill"/"Fast Break" pins (v12:
        # endcard DISTINCTIONS now, not ladder gates -- contract §3 keeps
        # this pin path unchanged; `over.distinctions` in broadcast.nim
        # reads them at conclusion) -- kept at this call site (not inside `recordCapture`
        # itself) because `roster.nim` cannot see `awardDeed`/`addXp`/
        # `teamAliveCount` (import direction; see `recordCapture`'s own
        # comment). Read/pinned BEFORE the flag-reset mutations a few
        # lines down, same "context before mutation" discipline the kill
        # site uses. `flagTeam` (this loop's own var) is the N-team-safe
        # replacement for main's hardcoded `if team == Red: Blue else: Red`
        # -- the SPECIFIC team whose heart this was, more correct than
        # main's own "the one other team" even in the 2-team case main was
        # written for.
        if sim.teamAliveCount(carrier.team) < sim.teamAliveCount(flagTeam):
          sim.players[carrierIndex].capturedOutnumbered = true
        if sim.players[carrierIndex].stealTickThisLife >= 0 and
           sim.tickCount - sim.players[carrierIndex].stealTickThisLife <=
               FastBreakTicks:
          sim.players[carrierIndex].capturedFastBreak = true
        # Glory-toast channel source (GameConfig.allowCosmeticFx): `fxActor`
        # is the carrier -- see `awardDeed`'s own doc comment on `fxActor`.
        # Dead code under the brMode guard above (BR disarms captures
        # entirely), kept for the non-BR configs this channel also serves.
        sim.awardDeed(carrier.team, dCapture, carrier.x, carrier.y,
                      fxActor = carrierIndex)
        sim.addXp(carrierIndex, XpPerCapture)
        sim.emitEvent(
          Capture, source = carrierIndex,
          x = float(cx), y = float(cy)
        )
        sim.logGameEvent(
          teamText(carrier.team) & " captured the " & teamText(flagTeam) & " heart"
        )
        sim.flags[flagTeam].captured = true
        sim.flags[flagTeam].carrier = -1
        sim.players[carrierIndex].carryingFlag = false
        sim.lastCaptureTeam = carrier.team
        sim.lastCaptureTick = sim.tickCount
        sim.lastCaptureIndex = carrierIndex
        sim.eliminateTeam(flagTeam, carrierIndex)
  # GV33: a completely killed team's heart leaves play with it. A wiped
  # team can never recover its heart, so it retires the moment the team is
  # gone — even off the back of an enemy carrier, who drops it (recovering
  # full speed and fire rate) rather than lugging an objective that can no
  # longer score. Capture-eliminated teams take the branch above; hearts
  # the wiped team itself was carrying already went home via killPlayer.
  #
  # BR INTEGRATION: the elim lane deliberately DEDENTED this loop out of its
  # brMode guard — a brMode episode on a flagged map still retires the hearts
  # of wiped teams — while the spawn lane kept it inside the flagless guard,
  # to suppress a "heart retired" log line on a map that never had a heart.
  # Both hold at once, so it keeps the flagless guard and NOT the brMode one.
  # (On a flagless map the loop is inert regardless: every flag is already
  # `captured`, so the `continue` fires for every team.)
  if not sim.gameMap.flagless:
    for team in sim.teams():
      if sim.flags[team].captured or sim.teamHasLivePlayers(team):
        continue
      let carrier = sim.flags[team].carrier
      if carrier >= 0:
        sim.players[carrier].carryingFlag = false
        sim.flags[team].carrier = -1
      sim.flags[team].captured = true
      sim.logGameEvent(teamText(team) & " heart retired")
  # Wipe: the game ends when at most one team still has live players — the
  # survivor wins, and a mutual wipe is a draw. A 4-team game continues
  # while two or more teams stand; a wiped team just stays out. Classic
  # 2-team behavior is the two-team case of the same rule.
  var
    aliveCount = 0
    lastAlive = Red
  for team in sim.teams():
    if sim.teamHasLivePlayers(team):
      inc aliveCount
      lastAlive = team
  if aliveCount == 1:
    # GLORY: `dWipe` -- fire only for a team that crossed from alive to
    # dead on THIS exact tick, never for one eliminated earlier in the
    # match. On a 2-team board this is always exactly the loser (main's
    # own case). On an N-team board, `checkWinCondition`'s wipe branch
    # only runs when `aliveCount` reaches 1 at all -- so a team eliminated
    # several ticks earlier is already dead by the time this fires, and
    # must NOT re-mint a stale wipe using its corpse's current (meaningless)
    # position. `justDied` is the guard `awardWipe`'s own defensive
    # fallback (built for a "should not happen" 2-team case) can't provide
    # by itself on N teams -- checked HERE so that fallback never masks a
    # stale re-fire.
    for loserTeam in sim.teams():
      if loserTeam == lastAlive or sim.teamHasLivePlayers(loserTeam):
        continue
      var justDied = false
      for player in sim.players:
        if player.team == loserTeam and player.lastKilledByTick == sim.tickCount:
          justDied = true
          break
      if justDied:
        sim.awardWipe(lastAlive, loserTeam)
    sim.finishGame(lastAlive)
  elif aliveCount == 0:
    # GLORY: a mutual wipe is a draw -- never mint dWipe here, matching
    # main's own rule (no windfall for a game nobody won).
    sim.finishGame(Red, isDraw = true)

proc checkMaxTicks(sim: var SimServer) =
  ## A game that hits the time limit before a capture or a wipe is a
  ## scoreless draw for both sides: no tiebreak, no rewards.
  ## brMode: pre-registered tiebreak instead (see brTiebreakWinner) — a
  ## clock-out still needs to crown a last-team-standing winner if the field
  ## is ahead on any measured axis, since a BR episode has no captures to
  ## fall back on.
  if not sim.maxTicksReached():
    return
  if sim.config.brMode:
    let (winner, isDraw) = sim.brTiebreakWinner()
    sim.finishGame(winner, isDraw = isDraw, timeLimitReached = true)
    return
  sim.finishGame(Red, isDraw = true, timeLimitReached = true)

proc checkKothEnd*(sim: var SimServer) =
  ## NEW (paintball): replaces checkWinCondition + checkMaxTicks while
  ## `hill` is on, evaluated in exactly this order.
  ##
  ## 1. WIPE — a team with no cog alive and no lives left loses on the spot,
  ##    and the SURVIVOR is credited every remaining tick. Crediting the
  ##    remainder is what stops a wipe from being worth less than playing the
  ##    clock out.
  ## 2. MERCY — the lead exceeds the ticks remaining, so the result can no
  ##    longer change.
  ## 3. FULL TIME — the clock ran out; equal hill ticks is a draw.
  if sim.phase != Playing or sim.players.len == 0:
    return
  let
    elapsed = sim.gameTicksElapsed()
    limit = sim.config.maxTicks
    remaining = (if limit > 0: max(0, limit - elapsed) else: high(int) div 4)
  var
    standing = 0
    survivor = Red
  for team in sim.teams():
    if sim.teamHasLivePlayers(team):
      inc standing
      survivor = team
  if standing <= 1:
    if standing == 1:
      sim.hillTicks[survivor] += (if limit > 0: remaining else: 0)
      sim.endRule = EndRuleWipe
      sim.finishGame(survivor)
    else:
      sim.endRule = EndRuleWipe
      sim.finishGame(Red, isDraw = true)
    return
  if limit > 0 and abs(sim.hillTicks[Red] - sim.hillTicks[Blue]) > remaining:
    let leader = sim.hillLeader()
    sim.endRule = EndRuleMercy
    sim.finishGame(leader.team, isDraw = leader.draw)
    return
  if limit > 0 and elapsed >= limit:
    let leader = sim.hillLeader()
    sim.endRule = EndRuleFullTime
    sim.finishGame(leader.team, isDraw = leader.draw, timeLimitReached = true)

proc decodeGridFont(image: Image, cellW, cellH, cols: int,
    spacing = 1): PixelFont =
  ## Decodes a fixed-cell monospace ASCII sheet (ascii.png: cellW x cellH cells
  ## laid out `cols` per row, starting at ASCII 32) into a PixelFont. Unlike
  ## decodePixelFont there is no yellow marker row: each glyph is the cell's
  ## white ink, trimmed to its own ink width so the font stays proportional.
  ## Used only for shout bubbles, which want a chunkier, taller face than the
  ## 6px tiny5 HUD font so the text reads at full desktop size.
  result.height = cellH
  result.spacing = spacing
  proc ink(x, y: int): bool =
    if x < 0 or y < 0 or x >= image.width or y >= image.height:
      return false
    let p = image[x, y]
    p.a > 20'u8 and p.r >= 120'u8 and p.g >= 120'u8 and p.b >= 120'u8
  for code in FirstPrintableAscii .. LastPrintableAscii:
    let
      idx = code - FirstPrintableAscii
      cx = (idx mod cols) * cellW
      cy = (idx div cols) * cellH
    var minX = cellW
    var maxX = -1
    for gx in 0 ..< cellW:
      for gy in 0 ..< cellH:
        if ink(cx + gx, cy + gy):
          minX = min(minX, gx)
          maxX = max(maxX, gx)
          break
    # A blank cell (e.g. the space) gets a fixed narrow advance.
    let width = if maxX < 0: max(1, cellW div 2) else: maxX - minX + 1
    let start = if maxX < 0: 0 else: minX
    var glyph = PixelGlyph(ch: char(code), width: width, height: cellH)
    glyph.pixels = newSeq[bool](width * cellH)
    if maxX >= 0:
      for gy in 0 ..< cellH:
        for gx in 0 ..< width:
          glyph.pixels[gy * width + gx] = ink(cx + start + gx, cy + gy)
    result.glyphs.add(glyph)

proc loadShoutFont(): PixelFont =
  ## Loads the chunky 7x9 grid font used for shout bubbles.
  decodeGridFont(readImage(gameDir() / "data" / "ascii.png"), 7, 9, 18)

## ---------------------------------------------------------------------------
## Spinning center diamonds — LIVE geometry (GV28).
## The art turns them, so the sim turns them too: what a player sees is what
## blocks their feet, their bullets, and their eyes. Only the sixteen frames of
## a quarter turn exist (a diamond is 4-fold symmetric), and only the pixels
## inside each diamond's circumscribed square can ever change, so a frame
## advance restamps ~8 small boxes — not the map.
## ---------------------------------------------------------------------------

proc initDiamondPatches(sim: var SimServer) =
  ## Snapshots the diamond-free collision masks around each spinning diamond.
  ## loadMapLayers already baked them WITHOUT the diamonds, so this captures
  ## the neighbours (a stub, the border) that must survive every restamp.
  sim.diamondPatches = @[]
  for spot in AnimatedDiamonds:
    let
      pad = spot.radius + 1
      x0 = max(0, spot.cx - pad)
      y0 = max(0, spot.cy - pad)
      x1 = min(MapWidth, spot.cx + pad + 1)
      y1 = min(MapHeight, spot.cy + pad + 1)
    var patch = DiamondPatch(
      x0: x0, y0: y0, w: x1 - x0, h: y1 - y0,
      frame: -1                       # nothing stamped yet.
    )
    patch.baseWall = newSeq[bool](patch.w * patch.h)
    for py in 0 ..< patch.h:
      for px in 0 ..< patch.w:
        let index = mapIndex(patch.x0 + px, patch.y0 + py)
        patch.baseWall[py * patch.w + px] = sim.wallMask[index]
    sim.diamondPatches.add patch
  ## Pair up overlapping windows. Without this a restamp of one diamond would
  ## write `base or its own stone` over a pixel its neighbour also occupies,
  ## erasing the neighbour's stone until the neighbour happened to restamp —
  ## and applyDiamondGeometry skips a diamond whose frame has not advanced, so
  ## "the neighbour restamps too" is not guaranteed.
  for i in 0 ..< sim.diamondPatches.len:
    for j in 0 ..< sim.diamondPatches.len:
      let a = sim.diamondPatches[i]
      let b = sim.diamondPatches[j]
      if a.x0 < b.x0 + b.w and b.x0 < a.x0 + a.w and
          a.y0 < b.y0 + b.h and b.y0 < a.y0 + a.h:
        sim.diamondPatches[i].neighbours.add j

proc refreshFovCells(sim: var SimServer, x0, y0, x1, y1: int) =
  ## Rebuilds the fog occlusion cells covering one map box from the live wall
  ## mask, on the same rule as buildFovBlocked (opaque when at least half the
  ## cell is wall) and with the same window exemption — glass never occludes.
  ##
  ## The glass test reads the precomputed windowMask rather than calling
  ## isArenaWindowPixel: that proc scans all ~70 ArenaObstacles twice per
  ## pixel, and this runs over ~41k pixels every time the spin advances. Doing
  ## it live cost ~5.4 ms per frame advance — more than three whole ticks —
  ## for a fact that never changes after the bake.
  let
    gx0 = clamp(x0 div FovCellSize, 0, FovGridW - 1)
    gx1 = clamp((x1 - 1) div FovCellSize, 0, FovGridW - 1)
    gy0 = clamp(y0 div FovCellSize, 0, FovGridH - 1)
    gy1 = clamp((y1 - 1) div FovCellSize, 0, FovGridH - 1)
  for gy in gy0 .. gy1:
    for gx in gx0 .. gx1:
      var
        walls = 0
        pixels = 0
      for py in gy * FovCellSize ..< min((gy + 1) * FovCellSize, MapHeight):
        for px in gx * FovCellSize ..< min((gx + 1) * FovCellSize, MapWidth):
          let index = mapIndex(px, py)
          inc pixels
          if sim.wallMask[index] and not sim.windowMask[index]:
            inc walls
      sim.fovBlocked[fovCellIndex(gx, gy)] = walls * 2 >= pixels

proc stampDiamondPatch(sim: var SimServer, index, frame: int) =
  ## Writes one diamond's rotated footprint into the movement, bullet, and
  ## vision masks: base OR stone, never a differential against the previous
  ## frame, so a restamp can neither leak old stone nor erase a neighbour.
  ## The OR runs over every diamond sharing this window, each at ITS OWN
  ## current frame, so the write is idempotent and order-independent.
  sim.diamondPatches[index].frame = frame
  let
    x0 = sim.diamondPatches[index].x0
    y0 = sim.diamondPatches[index].y0
    w = sim.diamondPatches[index].w
    h = sim.diamondPatches[index].h
  ## This runs ~4k pixels per window per frame advance, so the lone-diamond
  ## case — every window on both authored arenas — gets a loop with the shape
  ## in locals and no allocation. Resolving it out of a seq instead costs
  ## roughly a quarter of a tick.
  template stampLoop(covers: untyped) =
    for py in 0 ..< h:
      for px in 0 ..< w:
        let
          x {.inject.} = x0 + px
          y {.inject.} = y0 + py
          mapAt = mapIndex(x, y)
        var stone = sim.diamondPatches[index].baseWall[py * w + px]
        if not stone:
          stone = covers
        sim.wallMask[mapAt] = stone
        sim.walkMask[mapAt] = not stone

  if sim.diamondPatches[index].neighbours.len == 1:
    let spot = AnimatedDiamonds[index]
    stampLoop(animatedDiamondCovers(spot, frame, x, y))
  else:
    var live: seq[tuple[spot: tuple[cx, cy, radius: int], frame: int]]
    for other in sim.diamondPatches[index].neighbours:
      live.add((AnimatedDiamonds[other], sim.diamondPatches[other].frame))
    stampLoop(block:
      var hit = false
      for d in live:
        if animatedDiamondCovers(d.spot, d.frame, x, y):
          hit = true
          break
      hit)
  sim.refreshFovCells(x0, y0, x0 + w, y0 + h)

proc applyDiamondGeometry*(sim: var SimServer, tick: int): bool
    {.discardable.} =
  ## Brings every spinning diamond's geometry to the frame `tick` shows.
  ## Returns true when any of them turned. The frame comes from
  ## diamondSpinFrame — the same call the renderer makes — so geometry and art
  ## are the same shape by construction, and a replay re-derives both.
  ##
  ## The bool is not decoration: it is the only signal that someone may now be
  ## standing inside stone. Production code should go through
  ## updateAnimatedDiamonds, which acts on it. The two callers that discard it
  ## (initSimServer, resetToLobby) may only do so because the roster is empty
  ## at that point — any new caller under a live roster owes a push-out.
  ##
  ## Every frame is published BEFORE anything is stamped: a window ORs the
  ## neighbours it overlaps at THEIR current frames, so stamping mid-update
  ## would write a shared pixel against a stale angle.
  ## No allocation on either pass: this runs every tick, and three ticks in
  ## four nothing has moved.
  for index in 0 ..< sim.diamondPatches.len:
    let frame = diamondSpinFrame(
      AnimatedDiamonds[index].cx, AnimatedDiamonds[index].cy, tick)
    if frame == sim.diamondPatches[index].frame:
      continue
    sim.diamondPatches[index].frame = frame
    sim.diamondPatches[index].dirty = true
    result = true
  if not result:
    return
  for index in 0 ..< sim.diamondPatches.len:
    if not sim.diamondPatches[index].dirty:
      continue
    sim.diamondPatches[index].dirty = false
    sim.stampDiamondPatch(index, sim.diamondPatches[index].frame)
  if result:
    ## Vision was computed against the old stone; every viewer re-casts.
    for i in 0 ..< sim.fovCaches.len:
      sim.fovCaches[i].valid = false

proc restampDiamondGeometry*(sim: var SimServer) =
  ## Rewrites every spinning diamond's footprint into the collision and
  ## vision masks at the frame the patches already hold. Exists for keyframe
  ## restores (deserializeReplaySim): the walk/wall/fov masks arrive from a
  ## donor sim whose stamps are at the DONOR tick's spin frame, while the
  ## restored diamondPatches carry the keyframe tick's frames — and
  ## applyDiamondGeometry skips a diamond whose frame "has not changed", so
  ## the donor's stale stone would otherwise survive any seek whose target
  ## sits inside the restored keyframe's spin frame — fewer than
  ## DiamondSpinTicksPerFrame ticks stepped after the restore, so no stepped
  ## tick advances the spin and nothing restamps. Each stamp writes base OR
  ## stone over the whole window, so this cleans any foreign footprint the
  ## donor left behind.
  ##
  ## fovCaches are deliberately NOT invalidated: on the keyframe path the
  ## restored caches were recorded against the very masks this restamp
  ## reproduces, so they are valid by construction. A future caller whose
  ## caches were built against OTHER masks must invalidate them itself.
  for index in 0 ..< sim.diamondPatches.len:
    if sim.diamondPatches[index].frame < 0:
      continue                          # nothing stamped yet.
    sim.stampDiamondPatch(index, sim.diamondPatches[index].frame)

proc nearestFreeBody(
  sim: SimServer, playerIndex, x, y: int
): tuple[x, y: int, found: bool] =
  ## The nearest cell where player `playerIndex` can stand without overlapping
  ## any OTHER live body, via the same deterministic expanding ring search as
  ## nearestWalkable. Unlike that one it reports failure instead of handing
  ## back the blocked point it was asked to escape.
  for r in 0 .. max(MapWidth, MapHeight):
    for dy in -r .. r:
      for dx in -r .. r:
        if r > 0 and abs(dx) != r and abs(dy) != r:
          continue
        let
          nx = x + dx
          ny = y + dy
        if not sim.canOccupy(nx, ny):
          continue
        var clear = true
        for j in 0 ..< sim.players.len:
          if j == playerIndex or not sim.players[j].alive:
            continue
          if max(abs(sim.players[j].x - nx), abs(sim.players[j].y - ny)) <=
              PlayerSolidSpan:
            clear = false
            break
        if clear:
          return (nx, ny, true)
  (x, y, false)

proc sweptByDiamond(sim: SimServer, px, py: int): bool =
  ## True when any pixel of the player box at (px, py) is inside a spinning
  ## diamond's CURRENT footprint — i.e. the stone moved onto them, rather than
  ## their being unable to stand for some unrelated reason.
  for spot in AnimatedDiamonds:
    let frame = diamondSpinFrame(spot.cx, spot.cy, sim.tickCount)
    for dy in -PlayerHalf .. PlayerHalf:
      for dx in -PlayerHalf .. PlayerHalf:
        if animatedDiamondCovers(spot, frame, px + dx, py + dy):
          return true
  false

proc pushPlayersOutOfDiamonds(sim: var SimServer) =
  ## A turning diamond can sweep over someone hugging its edge. Standing
  ## inside stone would make a player unshootable from one side and unable to
  ## walk out, so the sweep displaces them to the nearest free floor. The ring
  ## search is deterministic, so replays and clients agree.
  ##
  ## Players are displaced in index order and each lands clear of every other
  ## live body, so two players caught by the same sweep cannot be handed the
  ## same pixel — overlapping bodies are a state the rest of the game does not
  ## allow (tests/test_player_collision.nim).
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    let
      px = sim.players[i].x
      py = sim.players[i].y
    if sim.canOccupy(px, py):
      continue
    if not sim.sweptByDiamond(px, py):
      continue
    let free = sim.nearestFreeBody(i, px, py)
    if free.found:
      sim.placePlayer(i, free.x, free.y)
    else:
      ## No standable floor anywhere on the map. Unreachable on every shipped
      ## map (measured: the whole sweep displaces by at most 2 px), but
      ## leaving someone embedded in stone is a silent, self-perpetuating
      ## trap — send them to their protected home pocket, and say so.
      sim.logGameEvent(
        "diamond sweep found no free floor for player " & $i & "; sent home")
      sim.resetPlayerToHome(i)

proc updateAnimatedDiamonds*(sim: var SimServer) =
  ## One tick of diamond rotation: geometry first, then anyone it engulfed.
  if sim.applyDiamondGeometry(sim.tickCount):
    sim.pushPlayersOutOfDiamonds()

proc buildMapBakes*(sim: var SimServer) =
  ## (Re)derives every static per-map bake from `sim.gameMap`: the render
  ## pixels, the walk/wall collision masks, the glass-aware fog occlusion
  ## grid. Exactly the fields replays.nim's ReplayStaticBakes strips from
  ## keyframes (minus the map-independent darkBgPixels), factored out of
  ## initSimServer so the MAP VOTE's winner install (applyVoteWinnerMap
  ## below) and a cross-map keyframe restore can rebuild them for a map
  ## that changed mid-episode.
  let (mapImage, walkImage, wallImage) = loadMapLayers(sim.gameMap)
  sim.mapPixels = newSeq[uint8](MapWidth * MapHeight)
  sim.mapRgba = newSeq[uint8](MapWidth * MapHeight * 4)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let
        pixel = mapImage[x, y]
        index = mapIndex(x, y)
        offset = index * 4
      sim.mapPixels[index] = nearestPaletteIndex(pixel)
      sim.mapRgba[offset] = pixel.r
      sim.mapRgba[offset + 1] = pixel.g
      sim.mapRgba[offset + 2] = pixel.b
      sim.mapRgba[offset + 3] = pixel.a

  sim.walkMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = walkImage[x, y]
      sim.walkMask[mapIndex(x, y)] = pixel.a > 0

  sim.wallMask = newSeq[bool](MapWidth * MapHeight)
  for y in 0 ..< MapHeight:
    for x in 0 ..< MapWidth:
      let pixel = wallImage[x, y]
      sim.wallMask[mapIndex(x, y)] = pixel.a > 0

  ## The fog occlusion grid builds from the OPAQUE walls only: glass window
  ## pixels stay in wallMask (movement/bullets/spray cones) but drop out here, so
  ## shadowcasting sees straight through every window.
  ##
  ## Which pixels are glass is fixed by the bake and never moves, so it is
  ## resolved ONCE here into windowMask. refreshFovCells re-derives occlusion
  ## for the boxes a turning diamond touches and reads that mask instead of
  ## re-running the O(obstacles) predicate per pixel. (Glass is never part of
  ## a spinning diamond — windows are stub shapes out on column 1 — so a live
  ## diamond can add wall over a window pixel but can never create or destroy
  ## one.)
  sim.windowMask = newSeq[bool](MapWidth * MapHeight)
  var opaqueMask = sim.wallMask
  block:
    let
      cx = sim.gameMap.center.x
      cy = sim.gameMap.center.y
    ## Only a window shape's own footprint can hold glass, so the sweep runs
    ## over those few boxes instead of asking isArenaWindowPixel (a full
    ## obstacle scan) at every map pixel.
    for shape in ArenaObstacles:
      if not shape.window:
        continue
      let
        bounds = shapeBounds(shape)
        x0 = max(bounds.x0, 0)
        y0 = max(bounds.y0, 0)
        x1 = min(bounds.x1, MapWidth - 1)
        y1 = min(bounds.y1, MapHeight - 1)
      for y in y0 .. y1:
        for x in x0 .. x1:
          if inShape(x, y, shape) and isArenaWall(x, y, cx, cy):
            let index = mapIndex(x, y)
            sim.windowMask[index] = true
            opaqueMask[index] = false
  sim.fovBlocked = buildFovBlocked(opaqueMask)

proc installEpisodeMap(sim: var SimServer, map: CtfMap) =
  ## Installs one map as THE episode map: the def, its bakes, the diamond
  ## snapshot and the paint grid — the exact per-map block initSimServer
  ## has always run, factored so the MAP VOTE's winner (applyVoteWinnerMap)
  ## installs through the identical path. Callers with a live roster or
  ## placed pickups own re-seating them afterwards.
  sim.gameMap = map
  sim.rooms = map.rooms
  sim.buildMapBakes()
  ## The bake left the spinning diamonds OUT of every collision layer; snapshot
  ## that diamond-free ground truth, then stamp tick 0's rotation over it. From
  ## here the masks track the art (updateAnimatedDiamonds, every step).
  sim.initDiamondPatches()
  discard sim.applyDiamondGeometry(0)   # roster, if any, is re-seated by caller.
  ## The paint grid's PAINTABLE mask is computed here, against the wall mask
  ## with the diamonds at spin frame 0 — the one state the native server and
  ## the wasm viewer are both guaranteed to be in at map install.
  sim.initPaintGrid()

proc initSimServer*(config: GameConfig): SimServer =
  result.config = config
  result.rng = initRand(config.seed)
  loadPalette(clientDataDir() / "pallete.png")
  result.asciiSprites = readTiny5Font()
  result.shoutFont = loadShoutFont()

  let sheet = loadSpriteSheet()
  result.crewSprites = loadCrewSprites()
  # Reuse the former task-icon cell as the flag sprite.
  result.flagSprite = spriteFromImage(
    sheet.subImage(SpriteSize * 4, 0, SpriteSize, SpriteSize)
  )

  result.darkBgPixels = loadDarkBgPixels()
  result.installEpisodeMap(loadCtfMap(config))
  result.regime =
    if result.config.regimes.len > 0: result.config.regimes[0]
    else: regimeResident
  result.gameIndex = 0
  result.gameHill = @[]
  result.gameRegimes = @[]
  result.endReason = ReasonComplete
  result.endRule = EndRuleFullTime
  result.fovCaches = @[]
  result.players = @[]
  result.nextJoinOrder = 0
  result.gameStartTick = -1
  result.startWaitTimer = 0
  result.lobbyWaitTimer = 0
  result.barrageStartTick = -1
  result.barrageAccum = 0
  result.gameEventLoggingEnabled = true
  result.resetFlags()
  result.resetGrenades()
  result.resetMedKits()
  result.resetShields()
  result.resetSprayPaints()
  result.resetBarriers()
  # LOOT(s2): no-ops (empty families) on a dark config; after grenades/
  # sprays for the crate-fallback points.
  result.resetBandages()
  result.resetLootCrates()
  result.lastLobbyPlayersLogged = -1
  result.lastLobbyNeededLogged = -1
  result.lastLobbySecondsLogged = -1

proc resetToLobby*(sim: var SimServer) =
  if sim.phase != Lobby:
    sim.emitPhaseChange(Lobby)
  sim.phase = Lobby
  sim.players = @[]
  sim.fovCaches = @[]
  ## Rewind the spin BEFORE anything snaps to walkable floor. The pickup
  ## resets below all nudge their spawns through nearestWalkable, which reads
  ## the live walk mask — if the diamonds were still stamped at the frame the
  ## last game ended on, a pickup could be nudged clear of stone that is about
  ## to move and land inside the stone the new game starts with. (Safe to run
  ## with the roster already emptied above: no one is left to be engulfed, so
  ## the displacement pass this returns true for has nothing to do.)
  if sim.config.numAgents > 0:
    ## A paintball EPISODE is two games, and the replay codec stops parsing at
    ## the first non-increasing tick hash (ReplaySpec.hashOrder = rhoStop). So
    ## the tick clock must stay MONOTONIC across the games: rewinding it here
    ## truncated the recording at game one and threw the whole visitor half —
    ## half the league score — away. The diamonds are still rewound to spin
    ## frame 0 for the reason above; the very next updateAnimatedDiamonds
    ## re-stamps whatever frame the running clock implies, so the geometry
    ## stays a pure function of the tick either way.
    discard sim.applyDiamondGeometry(0)
  else:
    sim.tickCount = 0
    discard sim.applyDiamondGeometry(0)
  sim.resetGrenades()
  sim.resetMedKits()
  sim.resetShields()
  sim.resetSprayPaints()
  sim.resetBarriers()
  # LOOT(s2): no-ops (empty families) on a dark config; after grenades/
  # sprays for the crate-fallback points.
  sim.resetBandages()
  sim.resetLootCrates()
  sim.recentBlasts = @[]
  sim.sprayPaintFlashes = @[]
  sim.recentShouts = @[]
  sim.recentShots = @[]
  sim.hitFlashes = @[]
  sim.bubbleImpacts = @[]
  sim.splatters = @[]
  sim.paintStains = @[]
  sim.diamondStains = @[]
  sim.damagePops = @[]
  sim.clearPaintGrid()
  sim.feedDirectives = @[]
  sim.shotFeedback = @[]
  sim.gloryDeeds = @[]
  sim.nextJoinOrder = 0
  sim.gameStartTick = -1
  sim.startWaitTimer = 0
  sim.lobbyWaitTimer = 0
  sim.lobbyChatActive = false
  sim.lobbyChatTicksLeft = 0
  sim.lobbyChatDone = false
  sim.lobbyChatOrdinal = 0
  sim.votingActive = false
  sim.votingTicksLeft = 0
  sim.votingDone = false
  sim.voteOrdinal = 0
  sim.voteSeats = default(array[MaxPlayers, VoteSeatState])
  sim.voteResolved = false
  sim.voteCategory = 0
  sim.voteTieBreakDrawn = false
  sim.voteFinalOption = 0
  sim.voteResolutionTick = 0
  sim.timeLimitReached = false
  sim.barrageStartTick = -1
  sim.barrageAccum = 0
  sim.isDraw = false
  sim.needsReregister = true
  sim.resetFlags()
  sim.lastLobbyPlayersLogged = -1
  sim.lastLobbyNeededLogged = -1
  sim.lastLobbySecondsLogged = -1
  for account in sim.rewardAccounts.mitems:
    account.hasTeam = false
    account.won = false
    account.abandoned = false

proc inLobbyChat*(sim: SimServer): bool =
  ## True while the §9.2 `chatting` substate is actively running: the ONLY
  ## window a `LobbyChat` (0xA3) send is admitted in (applyLobbyChat below).
  sim.phase == Lobby and sim.lobbyChatActive

proc inVoting*(sim: SimServer): bool =
  ## True while the pre-match vote phase's `voting` substate (docs/designs/
  ## prematch-vote-phase-2026-08-31.md §2, prematch-vote-wire-2026-08-31.md
  ## §1) is actively running: the ONLY window a `BallotCast` (0xA4) send is
  ## admitted in (applyBallotCast below). Mirrors inLobbyChat exactly.
  sim.phase == Lobby and sim.votingActive

proc voteSlotForSeat(sim: SimServer, seatIndex: int): int =
  ## THE REKEY (sentinel-wedge class fix): `sim.voteSeats` is keyed by the
  ## seat's STABLE configured slot (`Player.joinOrder`) — never by its
  ## position in `sim.players`, which is a COMPACTING array
  ## (roster.removePlayerAt `delete`s the row and shifts every later player
  ## down one). Keying accepted casts positionally meant one mid-vote
  ## disconnect re-attributed every later seat's ballot to the wrong
  ## player and orphaned/duplicated the removed seat's own accepted cast.
  ## This proc maps a caller-facing `sim.players` index (the shape the
  ## socket layer and applyLobbyChat already speak) to that stable key,
  ## or -1 when the index names no joined player or an out-of-range slot.
  if seatIndex < 0 or seatIndex >= sim.players.len:
    return -1
  let slot = sim.players[seatIndex].joinOrder
  if slot < 0 or slot >= MaxPlayers:
    return -1
  slot

proc allConfiguredPlaySeatsCast(sim: SimServer): bool =
  ## §6/J1's early-resolution predicate: every configured "play" slot
  ## (§5.1) has an accepted cast on record. Walks `config.slots` and reads
  ## `voteSeats` BY SLOT (the rekey above): a configured play seat that is
  ## not currently bound to a live player — never joined yet, or removed
  ## by a disconnect — still blocks early resolution while it has no
  ## accepted cast on record (J1: "that seat is absent, not resolved");
  ## only `voteTicks` can close the phase around it. A seat that CAST and
  ## then disconnected no longer blocks: its accepted ballot is already on
  ## the record (and in the replay stream) and survives the roster
  ## compaction — exactly the property the positional keying broke.
  for slotIndex in 0 ..< sim.config.slots.len:
    if sim.config.slots[slotIndex].control != scPlay:
      continue
    if slotIndex >= MaxPlayers or not sim.voteSeats[slotIndex].hasCastVote:
      return false
  true

proc setVoteSeatTombstoned*(sim: var SimServer, slotIndex: int, tombstoned: bool) =
  ## The seam a presence-aware caller (the shell's `pssLost` tracking, once
  ## wired) drives — see VoteSeatState.tombstoned's own comment for why
  ## this does not, on its own, change `allConfiguredPlaySeatsCast`'s
  ## outcome. Keyed by CONFIGURED SLOT, like every voteSeats access after
  ## the rekey (voteSlotForSeat above). Exported mainly so tests and a
  ## future caller have one named entry point rather than reaching into
  ## `sim.voteSeats` directly.
  if slotIndex >= 0 and slotIndex < MaxPlayers:
    sim.voteSeats[slotIndex].tombstoned = tombstoned

proc voteDraw(seed: int, tag: uint32, n: int): int =
  ## A fresh, tag-separated deterministic draw from the episode's own seed
  ## (prematch-vote-wire-2026-08-31.md §5 point 4) — NOT `sim.rng`, whose
  ## mutable position depends on unrelated gameplay draws elsewhere in the
  ## tick, which would make resolution a function of "how much else
  ## happened first," not just seed+votes. Two calls with different tags
  ## (the plurality tie-break and D's own delegated draw, below) never
  ## correlate by construction. Pure in its arguments, so a replaying
  ## client recomputes the identical draw from record 0x17's transcript and
  ## the launch-config seed alone (§4's reconstruction requirement) — the
  ## whole reason the seed itself never rides the wire.
  var mixed = 14695981039346656037'u64
  mixed = mixed xor cast[uint64](int64(seed))
  mixed *= 1099511628211'u64
  mixed = mixed xor uint64(tag)
  mixed *= 1099511628211'u64
  var r = initRand(cast[int64](mixed))
  r.rand(n - 1)

const
  VoteTieBreakDrawTag = 1'u32
  VoteDelegationDrawTag = 2'u32
    ## Domain-separates section 5's two draws (the plurality tie-break
    ## among leaders, and D's own delegated draw over A/B/C) so they never
    ## correlate — ballot.nim's own candidate-generation draw uses a
    ## THIRD, visibly distinct tag for the same reason.

proc isMapVote*(sim: SimServer): bool =
  ## True when this episode's ballot is a MAP ballot: 4 candidate map
  ## specs were pinned into the config at parse (sim_config.update — a
  ## brpool episode with voteTicks armed). Empty = the v1 mode-bundle
  ## ballot semantics, untouched.
  sim.config.voteMapSpecs.len > 0

proc voteMapCandidateName*(sim: SimServer, option: int): string =
  ## The pinned candidate's own "name" field ("br-gen-<seed>"), or "" for
  ## an out-of-range option / a non-map ballot. Parsed on demand — the
  ## specs are config-pinned strings, never cached sim state.
  if option < 0 or option >= sim.config.voteMapSpecs.len:
    return ""
  try:
    let node = parseJson(sim.config.voteMapSpecs[option])
    result = node["name"].getStr("")
  except CatchableError:
    result = ""

proc applyVoteWinnerMap(sim: var SimServer) =
  ## MAP VOTE: installs the resolved winner as THE episode map, at the
  ## instant `voting` closes (still Lobby, before huddle/countdown/
  ## startGame). Runs identically on the live server and on replay
  ## playback — a pure function of (config.voteMapSpecs, voteFinalOption)
  ## — so the recorded hash chain reproduces. Candidate 0 is already the
  ## installed map (sim_config pinned it as mapSpec at parse), so an A win
  ## or a no-show fallback touches nothing and stays byte-identical.
  if not sim.isMapVote():
    return
  let index = int(sim.voteFinalOption)
  if index <= 0 or index >= sim.config.voteMapSpecs.len:
    return
  let spec = sim.config.voteMapSpecs[index]
  sim.config.mapSpec = spec
  sim.installEpisodeMap(mapFromSpecJson(spec))
  ## Every map-anchored placement re-seats on the winner's geometry — the
  ## same reset family initSimServer runs after its own install (all are
  ## lobby-safe: no game is running yet).
  sim.resetFlags()
  sim.resetGrenades()
  sim.resetMedKits()
  sim.resetShields()
  sim.resetSprayPaints()
  sim.resetBarriers()
  sim.resetBandages()
  sim.resetLootCrates()
  ## Players joined onto the OLD map's floor; nudge anyone the new walls
  ## swallowed onto walkable ground (startGame's arrangeHomePositions
  ## re-places every seat at match start regardless), and drop every fog
  ## cache built against the old occlusion grid.
  for i in 0 ..< sim.players.len:
    let spot = sim.nearestWalkable(sim.players[i].x, sim.players[i].y)
    sim.players[i].x = spot.x
    sim.players[i].y = spot.y
  for i in 0 ..< sim.fovCaches.len:
    sim.fovCaches[i].valid = false
  sim.logGameEvent("map vote: " & sim.gameMap.name & " wins")

proc resolveVote(sim: var SimServer) =
  ## prematch-vote-wire-2026-08-31.md §5's tally + resolution, run exactly
  ## once when `voting` exits (either clock). A PURE function of (every
  ## configured play seat's latest accepted cast, sim.config.seed) — no
  ## sim.rng, no new wire entropy — so a replaying client recomputes the
  ## identical category/tieBreakDrawn/finalOption from record 0x17's
  ## transcript alone (§4 point 3).
  ##
  ## TWO BALLOT SEMANTICS, keyed on isMapVote():
  ## - v1 mode-bundle ballot (voteMapSpecs empty): §5 verbatim — abstention
  ##   is an implicit D, and a D category delegates to a second draw over
  ##   A/B/C. Unchanged.
  ## - MAP ballot (voteMapSpecs pinned): every option is a REAL map, so
  ##   there is no delegation and no implicit-D: only EXPLICIT casts count,
  ##   zero casts fall back to option 0 (candidate A — the exact member
  ##   the gate-off #355 path would have played), and a tie takes the same
  ##   seed-deterministic draw. The winner is installed immediately
  ##   (applyVoteWinnerMap above).
  var counts: array[4, int]
  var explicitCasts = 0
  let optionLimit =
    if sim.isMapVote(): sim.config.voteMapSpecs.len else: 4
  for slotIndex in 0 ..< sim.config.slots.len:
    if sim.config.slots[slotIndex].control != scPlay:
      continue
    if slotIndex < MaxPlayers and sim.voteSeats[slotIndex].hasCastVote and
        int(sim.voteSeats[slotIndex].option) < optionLimit:
      inc counts[int(sim.voteSeats[slotIndex].option)]
      inc explicitCasts
    elif not sim.isMapVote():
      inc counts[3]   # implicit D: abstention (§5 point 1)
  var
    category: uint8
    tieBreakDrawn = false
  if sim.isMapVote() and explicitCasts == 0:
    category = 0'u8   # no votes at all: the deterministic default, A.
  else:
    var
      best = -1
      leaders: seq[uint8] = @[]
    for bucket in 0 ..< optionLimit:
      if counts[bucket] > best:
        best = counts[bucket]
        leaders = @[uint8(bucket)]
      elif counts[bucket] == best:
        leaders.add uint8(bucket)
    if leaders.len == 1:
      category = leaders[0]
    else:
      tieBreakDrawn = true
      category =
        leaders[voteDraw(sim.config.seed, VoteTieBreakDrawTag, leaders.len)]
  let finalOption =
    if not sim.isMapVote() and category == 3'u8:
      uint8(voteDraw(sim.config.seed, VoteDelegationDrawTag, 3))
    else:
      category
  sim.voteCategory = category
  sim.voteTieBreakDrawn = tieBreakDrawn
  sim.voteFinalOption = finalOption
  sim.voteResolved = true
  sim.voteResolutionTick = sim.tickCount
  sim.applyVoteWinnerMap()

proc ballotCandidatesForEpisode*(sim: SimServer): array[3, BallotCandidate] =
  ## THIS episode's pre-match vote A/B/C (docs/designs/prematch-vote-phase-
  ## 2026-08-31.md §3): deterministic from the episode seed via
  ## ballot.nim's `defaultBallotCandidates`, recomputed on demand rather
  ## than cached on SimServer — cheap, pure, and keeps ballot generation
  ## entirely out of the flatty-serialized/gameHash surface. v1 does not
  ## yet ACT on the result (no PlayContext/map-switch wiring — darkness
  ## discipline, see the module doc at the top of this file's vote-phase
  ## section); once `sim.voteResolved`, `sim.voteFinalOption` indexes into
  ## this array to name which bundle the vote picked.
  defaultBallotCandidates(sim.config.seed)

proc applyBallotCast*(
  sim: var SimServer,
  seatIndex: int,
  castId: uint64,
  option: uint8
): BallotCastResult {.discardable.} =
  ## Admits one prematch-vote-wire-2026-08-31.md §2 `BallotCast` (0xA4)
  ## send. Mirrors applyLobbyChat's shape and check order (closed -> bad
  ## seat -> structural validity -> dedup/stale/conflict -> rate cap ->
  ## spacing); no play-seat-only admission restriction, same generality
  ## applyLobbyChat has (any joined seat may send — only CONFIGURED PLAY
  ## seats are counted in the tally, resolveVote above).
  if not sim.inVoting():
    return BallotCastResult(ok: false, reason: bcrClosed)
  let slot = sim.voteSlotForSeat(seatIndex)
  if slot < 0:
    return BallotCastResult(ok: false, reason: bcrBadSeat)
  if option > 3'u8 or
      (sim.isMapVote() and int(option) >= sim.config.voteMapSpecs.len):
    return BallotCastResult(ok: false, reason: bcrBadOption)
  var seat = sim.voteSeats[slot]
  if seat.hasCastVote and castId == seat.lastCastId:
    if option == seat.option:
      # Silent no-op resend (§2): the original outcome, unchanged state, no
      # new ordinal, no broadcast, no rate charge.
      return BallotCastResult(
        ok: true, ordinal: seat.lastOrdinal, reason: bcrOk, fresh: false)
    return BallotCastResult(ok: false, reason: bcrCastIdConflict)
  if seat.hasCastVote and castId < seat.lastCastId:
    return BallotCastResult(ok: false, reason: bcrCastIdStale)
  if seat.castCount >= BallotCastMaxPerSeatPerPhase:
    return BallotCastResult(ok: false, reason: bcrRateLimited)
  if seat.hasCastVote and
      sim.tickCount - seat.lastCastTick < BallotCastMinSpacingTicks:
    return BallotCastResult(ok: false, reason: bcrTooSoon)
  inc sim.voteOrdinal
  seat.hasCastVote = true
  seat.lastCastId = castId
  seat.option = option
  seat.lastOrdinal = sim.voteOrdinal
  seat.lastCastTick = sim.tickCount
  inc seat.castCount
  sim.voteSeats[slot] = seat
  BallotCastResult(ok: true, ordinal: sim.voteOrdinal, reason: bcrOk, fresh: true)

proc applyReplayBallotCast*(
  sim: var SimServer, slotIndex: int, option: uint8, ordinal: uint64
) =
  ## Replay playback's re-application of one RECORDED (already-admitted)
  ## `0x17` kind-0 cast, keyed by the record's own stable `seat` field
  ## (the configured slot — exactly the rekey key). Deliberately NOT
  ## applyBallotCast: admission (window, castId dedup, rate, spacing)
  ## already happened on the live server and the record is its accepted
  ## truth — re-adjudicating could diverge. Writes only what resolveVote
  ## and allConfiguredPlaySeatsCast read, so the recorded vote reproduces:
  ## the same seats hold the same options when `voting` closes, on the
  ## same tick (early resolution included).
  if slotIndex < 0 or slotIndex >= MaxPlayers:
    return
  var seat = sim.voteSeats[slotIndex]
  seat.hasCastVote = true
  seat.option = option
  seat.lastOrdinal = ordinal
  seat.lastCastTick = sim.tickCount
  inc seat.castCount
  sim.voteSeats[slotIndex] = seat
  if ordinal > sim.voteOrdinal:
    sim.voteOrdinal = ordinal

proc stepLobby(sim: var SimServer) {.measure.} =
  ## Advances the lobby: `joining` (roster fill, unchanged) -> `voting`
  ## (once, held countdown, prematch-vote-wire-2026-08-31.md §1) ->
  ## `chatting` (once, held countdown, §9.2) -> `countdown` (today's
  ## startWaitTicks logic, unchanged in shape). Voting precedes chatting so
  ## that chat, once it starts, can refer to the resolved bundle rather
  ## than negotiating blind (prematch-vote-wire-2026-08-31.md §1). Both
  ## substates exist ONLY for a play-seat episode with their own ticks field
  ## > 0 — `hasPlaySeat` is the gate-blind roster check in sim_config.nim;
  ## server/shell boundaries use the conjunctive `isPlaySeatEpisode`. "Nothing below
  ## changes a configuration with no play seat" (§9.2) is enforced HERE,
  ## not by either field's own default value, so an ordinary input-only
  ## lobby follows the direct-input path regardless of
  ## either field's configured value. `voteTicks` additionally defaults to
  ## 0 REGARDLESS of hasPlaySeat (VoteTicksDefault's own comment,
  ## sim_types.nim) — the v1/huddle-v1 divergence.
  if sim.votingActive:
    # Held exactly like lobbyChatActive below: the roster-sufficiency check
    # never runs while voting is open, and an input seat leaving does not
    # end it — checked BEFORE, and independent of, that check.
    dec sim.votingTicksLeft
    if sim.votingTicksLeft <= 0 or sim.allConfiguredPlaySeatsCast():
      sim.resolveVote()
      sim.votingActive = false
      sim.votingDone = true
    return
  if sim.lobbyChatActive:
    # Held: startWaitTimer does not run, and an input seat leaving does not
    # end chat (§9.2) — so this branch is checked BEFORE, and independent
    # of, the roster-sufficiency check below.
    dec sim.lobbyChatTicksLeft
    if sim.lobbyChatTicksLeft <= 0:
      sim.lobbyChatActive = false
      sim.lobbyChatDone = true
    return
  if sim.players.len < sim.config.minPlayers:
    sim.startWaitTimer = 0
    if sim.config.maxGames > 0 and sim.config.lobbyJoinTimeoutTicks > 0:
      # Join-budget clock: only finite (league-shaped) matches, only while the
      # roster is actually short, and only on lobby ticks — bake/setup time
      # before the loop starts stepping never counts against the budget.
      inc sim.lobbyWaitTimer
    sim.logLobbyWaiting()
    return
  if not sim.votingDone:
    if sim.config.voteTicks <= 0 or not sim.config.hasPlaySeat():
      sim.votingDone = true
    else:
      sim.votingActive = true
      sim.votingTicksLeft = sim.config.voteTicks
      return
  if not sim.lobbyChatDone:
    if sim.config.lobbyChatTicks <= 0 or not sim.config.hasPlaySeat():
      sim.lobbyChatDone = true
    else:
      sim.lobbyChatActive = true
      sim.lobbyChatTicksLeft = sim.config.lobbyChatTicks
      return
  if sim.config.startWaitTicks <= 0:
    sim.startGame()
    return
  if sim.startWaitTimer <= 0:
    sim.startWaitTimer = sim.config.startWaitTicks
  dec sim.startWaitTimer
  if sim.startWaitTimer <= 0:
    sim.startGame()
  else:
    sim.logLobbyCountdown()

proc lobbyChatContentReason(text: string): LobbyChatRejectReason =
  ## Structural + content admission checks for lobby chat text, decoded in
  ## one pass: well-formed UTF-8 (no overlong encoding, no surrogate
  ## scalar, no scalar past U+10FFFF), then the C0/C1 control ranges (LF
  ## excepted) and U+2028/U+2029, then the ASCII-only blank predicate
  ## ("non-ASCII space is content", §9.2). Assumes the caller already
  ## checked the LobbyChatMaxBytes length cap.
  var i = 0
  let n = text.len
  var allBlank = true
  while i < n:
    let b0 = uint8(text[i])
    var cp: uint32
    var width: int
    if b0 <= 0x7f'u8:
      cp = uint32(b0)
      width = 1
    elif b0 shr 5 == 0b110'u8:
      if b0 < 0xc2'u8 or i + 1 >= n or uint8(text[i + 1]) shr 6 != 0b10'u8:
        return lcrInvalidUtf8
      cp = (uint32(b0 and 0x1f'u8) shl 6) or
        uint32(uint8(text[i + 1]) and 0x3f'u8)
      width = 2
    elif b0 shr 4 == 0b1110'u8:
      if i + 2 >= n or uint8(text[i + 1]) shr 6 != 0b10'u8 or
          uint8(text[i + 2]) shr 6 != 0b10'u8:
        return lcrInvalidUtf8
      cp = (uint32(b0 and 0x0f'u8) shl 12) or
        (uint32(uint8(text[i + 1]) and 0x3f'u8) shl 6) or
        uint32(uint8(text[i + 2]) and 0x3f'u8)
      if cp < 0x800'u32 or (cp >= 0xd800'u32 and cp <= 0xdfff'u32):
        return lcrInvalidUtf8
      width = 3
    elif b0 shr 3 == 0b11110'u8:
      if i + 3 >= n or uint8(text[i + 1]) shr 6 != 0b10'u8 or
          uint8(text[i + 2]) shr 6 != 0b10'u8 or
          uint8(text[i + 3]) shr 6 != 0b10'u8:
        return lcrInvalidUtf8
      cp = (uint32(b0 and 0x07'u8) shl 18) or
        (uint32(uint8(text[i + 1]) and 0x3f'u8) shl 12) or
        (uint32(uint8(text[i + 2]) and 0x3f'u8) shl 6) or
        uint32(uint8(text[i + 3]) and 0x3f'u8)
      if cp < 0x10000'u32 or cp > 0x10ffff'u32:
        return lcrInvalidUtf8
      width = 4
    else:
      return lcrInvalidUtf8
    if cp == 0x0a'u32:
      discard   # the one allowed line break; counts as blank below.
    elif cp <= 0x1f'u32 or (cp >= 0x7f'u32 and cp <= 0x9f'u32) or
        cp == 0x2028'u32 or cp == 0x2029'u32:
      return lcrControlChar
    if cp != 0x20'u32 and cp != 0x0a'u32:
      allBlank = false
    i += width
  if allBlank:
    return lcrEmpty
  lcrOk

proc applyLobbyChat*(
  sim: var SimServer,
  seatIndex: int,
  text: string
): LobbyChatResult {.discardable.} =
  ## Admits one §9.2 lobby chat send. `sim.applyShout` stays Playing-only
  ## and untouched (this is its own path, not a shout variant, per the
  ## design's ruling) — this is the whole of the lobby chat one.
  if not sim.inLobbyChat():
    return LobbyChatResult(ok: false, reason: lcrClosed)
  if seatIndex < 0 or seatIndex >= sim.players.len:
    return LobbyChatResult(ok: false, reason: lcrBadSeat)
  if text.len > LobbyChatMaxBytes:
    return LobbyChatResult(ok: false, reason: lcrTooLong)
  let contentReason = lobbyChatContentReason(text)
  if contentReason != lcrOk:
    return LobbyChatResult(ok: false, reason: contentReason)
  if sim.players[seatIndex].lobbyChatSentCount >= LobbyChatMaxMessagesPerSeat:
    return LobbyChatResult(ok: false, reason: lcrRateLimited)
  let last = sim.players[seatIndex].lastLobbyChatTick
  if last >= 0 and sim.tickCount - last < LobbyChatMinSpacingTicks:
    return LobbyChatResult(ok: false, reason: lcrTooSoon)
  inc sim.lobbyChatOrdinal
  sim.players[seatIndex].lastLobbyChatTick = sim.tickCount
  inc sim.players[seatIndex].lobbyChatSentCount
  LobbyChatResult(ok: true, ordinal: sim.lobbyChatOrdinal, reason: lcrOk)

proc packRadiusSq*(sim: SimServer): int =
  ## `pack`: the squared radius of a circle covering PackAreaPct of the map's
  ## area (r² = area / π, integer: area * 100 / 314).
  var w = sim.gameMap.width
  var h = sim.gameMap.height
  if w <= 0: w = MapWidth
  if h <= 0: h = MapHeight
  (PackAreaPct * w * h) div 314

proc updatePackTicks*(sim: var SimServer) =
  ## Analysis-only (`pack`): one alive tick per living cog, and a pack tick
  ## when at least PackMates living teammates stand within the pack radius.
  ## Nothing here enters gameHash.
  if sim.phase != Playing:
    return
  let radiusSq = sim.packRadiusSq()
  for i in 0 ..< sim.players.len:
    if not sim.players[i].alive:
      continue
    inc sim.players[i].aliveTicks
    var mates = 0
    for j in 0 ..< sim.players.len:
      if j == i or not sim.players[j].alive or
          sim.players[j].team != sim.players[i].team:
        continue
      let dx = sim.players[j].x - sim.players[i].x
      let dy = sim.players[j].y - sim.players[i].y
      if dx * dx + dy * dy <= radiusSq:
        inc mates
        if mates >= PackMates:
          break
    if mates >= PackMates:
      inc sim.players[i].packTicks

proc respawnPlayers(sim: var SimServer) =
  ## Ticks respawn timers and brings dead players back at a random spot in
  ## their endzone, so a fixed respawn point can't be camped.
  let groupOffset = sim.spawnGroupOffset()
    ## Pure function of the config seed, same value all game — see the
    ## identical hoist in resetPlayers/startGame.
  for i in 0 ..< sim.players.len:
    if sim.players[i].alive:
      continue
    if sim.players[i].lives <= 0:
      continue
    if sim.players[i].respawnTimer > 0:
      dec sim.players[i].respawnTimer
      if sim.players[i].respawnTimer <= 0:
        let spawn = sim.randomEndzonePosition(sim.players[i].team)
        sim.placePlayer(i, spawn.x, spawn.y)
        sim.players[i].alive = true
        sim.players[i].hp =
          sim.config.maxHpFor(sim.players[i].team, sim.players[i].perks)
        sim.players[i].aimBrads =
          sim.gameMap.spawnAimBrads(sim.players[i].team, groupOffset)
        sim.players[i].flipH =
          sim.gameMap.spawnFlipH(sim.players[i].team, groupOffset)
        sim.emitEvent(
          Respawn, source = i,
          x = float(sim.players[i].x + CollisionW div 2),
          y = float(sim.players[i].y + CollisionH div 2)
        )

proc downedBleedOutWindow(sim: SimServer, downedCount: int): int =
  ## LOOT(s2): the bleed-out window for a ghost's Nth down: the configured
  ## base, halved per successive down when downedEscalation is on (the
  ## ruled shape — pressure escalates, no hard down-cap), floored at
  ## DownedMinBleedOutTicks so a many-times-downed cog still gets a real
  ## rescue window.
  result = sim.config.downedBleedOutTicks
  if sim.config.downedEscalation:
    for _ in 1 ..< max(1, downedCount):
      result = result div 2
  result = max(result, DownedMinBleedOutTicks)

proc updateDowned(sim: var SimServer) =
  ## LOOT(s2): one tick of the downed-state machine, per ghost and in this
  ## order:
  ##   1. TEAM-WIPE finalize — a team with no upright cog left has nobody
  ##      who could ever tag anyone back, so its ghosts fade at once and
  ##      the same tick's checkWinCondition sees a real elimination (this
  ##      is also what keeps teamHasLivePlayers honest without touching it:
  ##      ghosts only ever exist on teams that still stand).
  ##   2. BLEED-OUT expiry (downedBleedOutWindow).
  ##   3. REVIVE progress — any upright teammate inside DownedTagRange
  ##      advances the channel one tick (the first such teammate by index
  ##      is the tagger, a deterministic pick); the channel resets the tick
  ##      the tag breaks; at downedReviveTicks the ghost stands back up at
  ##      1 hp. The reviver's vulnerability IS the adjacency: DownedTagRange
  ##      sits far inside gun range and the channel costs real ticks.
  ## Tick-based throughout, RNG-free; a no-op unless downedMode armed.
  if not sim.config.downedMode or sim.phase != Playing:
    return
  # Upright census per team, taken BEFORE any finalization this tick
  # mutates it — a duo downed on the same tick reads the same census.
  var upright: array[Team, int]
  for p in sim.players:
    if p.alive and not p.downed:
      inc upright[p.team]
  for i in 0 ..< sim.players.len:
    if not sim.players[i].downed:
      continue
    if upright[sim.players[i].team] == 0:
      sim.finalizeDowned(i, sim.players[i].downedBy,
        "faded out with their team")
      continue
    # ZONEPAINT (glory-2 amendment 1): paint on a ghost's cell ACCELERATES
    # the bleed clock — it NEVER finalizes directly, and it never touches
    # the revive channel below (a revive under closing paint stays possible
    # by construction; Last Light's premium moment). Each painted tick
    # banks (permille - 1000) extra clock permille; whole extra ticks are
    # applied by pulling downedTick further into the past, so the ONLY
    # death gate is still this proc's own windowed expiry check, floored by
    # DownedMinBleedOutTicks on the escalated path and bounded by the
    # config ceiling (ZonePaintDownedBleedPermilleMax) at load. Stacks with
    # downedEscalation: the window halves per prior down AND the clock runs
    # faster under paint — two independent multipliers on the same check.
    # Dark (default): the branch never runs, byte-identical.
    if sim.config.zoneDamageByPaint and
        sim.config.zonePaintDownedBleedPermille > 1000 and
        sim.config.zonePhases.len > 0:
      let
        zx = sim.players[i].x + CollisionW div 2
        zy = sim.players[i].y + CollisionH div 2
        q = sim.zonePaintedForDamageAt(
          zx, zy, sim.tickCount - sim.gameStartTick)
      if q.onField and q.painted:
        sim.players[i].zonePaintBleedBank +=
          sim.config.zonePaintDownedBleedPermille - 1000
        while sim.players[i].zonePaintBleedBank >= 1000:
          sim.players[i].zonePaintBleedBank -= 1000
          dec sim.players[i].downedTick
    if sim.tickCount - sim.players[i].downedTick >=
        sim.downedBleedOutWindow(sim.players[i].downedCount):
      sim.finalizeDowned(i, sim.players[i].downedBy, "bled out")
      continue
    var tagger = -1
    let
      gx = sim.players[i].x + CollisionW div 2
      gy = sim.players[i].y + CollisionH div 2
    for j in 0 ..< sim.players.len:
      if j == i or sim.players[j].team != sim.players[i].team:
        continue
      if not sim.players[j].alive or sim.players[j].downed:
        continue
      let
        tx = sim.players[j].x + CollisionW div 2
        ty = sim.players[j].y + CollisionH div 2
      if distSq(gx, gy, tx, ty) <= DownedTagRange * DownedTagRange:
        tagger = j
        break
    if tagger < 0:
      sim.players[i].reviveProgress = 0
      continue
    inc sim.players[i].reviveProgress
    if sim.players[i].reviveProgress >= sim.config.downedReviveTicks:
      sim.players[i].downed = false
      sim.players[i].reviveProgress = 0
      # ZONEPAINT: a stood-up cog starts its next down (if any) with a
      # clean acceleration bank. Writing 0 over 0 when dark — unhashed
      # either way (sim_types.nim's field note).
      sim.players[i].zonePaintBleedBank = 0
      sim.players[i].hp = 1
      sim.emitEvent(
        Revived, source = tagger, target = i,
        amount = sim.config.downedReviveTicks, hp = 1,
        x = float(gx), y = float(gy)
      )
      sim.logGameEvent(
        playerColorText(sim.players[i].color) & " tagged back in by " &
          sim.playerText(tagger)
      )

proc duoPartnerIndex*(sim: SimServer, playerIndex: int): int =
  ## GIVE(s2): the seat's duo partner — the one OTHER member of its team
  ## (BR seats duos two to a team; deterministic lowest-index pick if a
  ## variant ever seats more). -1 = no partner has joined.
  result = -1
  for j in 0 ..< sim.players.len:
    if j != playerIndex and
        sim.players[j].team == sim.players[playerIndex].team:
      return j

proc declareHandoff*(
  sim: var SimServer, playerIndex: int, item: string
): bool {.discardable.} =
  ## GIVE(s2): declares — or, with item = "", clears — a HANDOFF play for
  ## one seat: "give my `item` to my duo partner". The declaration is the
  ## CONSENT record: without one the channel below never advances and no
  ## item ever moves (owner ruling 2026-09-02 — proximity can never imply
  ## consent, so there is no auto-share path to be gated). Target is not a
  ## parameter: it is always THE duo partner, resolved at execution time.
  ##
  ## This proc is the engine seam for the play-calling shell's HANDOFF
  ## play (the 0x10-recorded play call is the matching intent record).
  ## NOTHING in the engine calls it yet — the shell-side Intent vocabulary
  ## and the replay-side declaration record are the arming lane's work
  ## (see the PR's activation section). Returns true when the declaration
  ## was accepted. Re-declaring a different item restarts the channel.
  if not sim.config.giveItem or sim.phase != Playing:
    return false
  if playerIndex < 0 or playerIndex >= sim.players.len:
    return false
  if not sim.players[playerIndex].alive or sim.players[playerIndex].downed:
    return false
  if item.len == 0:
    sim.players[playerIndex].giveDeclItem = ""
    sim.players[playerIndex].giveProgress = 0
    return true
  if item != "gun" and item != "hopper" and item != "bandage":
    return false
  if sim.duoPartnerIndex(playerIndex) < 0:
    return false
  if sim.players[playerIndex].giveDeclItem != item:
    sim.players[playerIndex].giveProgress = 0
  sim.players[playerIndex].giveDeclItem = item
  true

proc updateGiveChannel(sim: var SimServer) =
  ## GIVE(s2): one tick of the play-called handoff channel, per declared
  ## giver. The channel advances only while EVERY condition holds this
  ## tick — giver upright and still holding the declared item, partner
  ## upright and able to receive it (marker/hopper are binary; bandages
  ## cap at BandageCarryCap), and both inside GiveItemRange — and resets
  ## to zero the tick any of them breaks (interruptible by construction,
  ## the revive channel's own shape). At GiveChannelTicks the declared
  ## item transfers, the declaration clears, and the ItemGive row is
  ## emitted — the ONLY transfer path in the game besides death-drops
  ## (owner ruling 2026-09-02: guns, hoppers and bandages alike move by
  ## play or not at all).
  ## Tick-based, RNG-free; a no-op unless giveItem is armed.
  if not sim.config.giveItem or sim.phase != Playing:
    return
  for i in 0 ..< sim.players.len:
    if sim.players[i].giveDeclItem.len == 0:
      continue
    # A dead or downed giver's declaration dies with the life that made it.
    if not sim.players[i].alive or sim.players[i].downed:
      sim.players[i].giveDeclItem = ""
      sim.players[i].giveProgress = 0
      continue
    let
      item = sim.players[i].giveDeclItem
      partner = sim.duoPartnerIndex(i)
    var holds = partner >= 0 and sim.players[partner].alive and
      not sim.players[partner].downed
    if holds:
      holds =
        case item
        of "gun":
          sim.players[i].hasGun and not sim.players[partner].hasGun
        of "hopper":
          sim.players[i].hasHopper and not sim.players[partner].hasHopper
        else:
          sim.players[i].bandages > 0 and
            sim.players[partner].bandages < BandageCarryCap
    if holds:
      let
        gx = sim.players[i].x + CollisionW div 2
        gy = sim.players[i].y + CollisionH div 2
        px = sim.players[partner].x + CollisionW div 2
        py = sim.players[partner].y + CollisionH div 2
      holds = distSq(gx, gy, px, py) <= GiveItemRange * GiveItemRange
    if not holds:
      sim.players[i].giveProgress = 0
      continue
    inc sim.players[i].giveProgress
    if sim.players[i].giveProgress < GiveChannelTicks:
      continue
    case item
    of "gun":
      sim.players[i].hasGun = false
      sim.players[partner].hasGun = true
    of "hopper":
      sim.players[i].hasHopper = false
      sim.players[partner].hasHopper = true
    else:
      dec sim.players[i].bandages
      inc sim.players[partner].bandages
    sim.players[i].giveDeclItem = ""
    sim.players[i].giveProgress = 0
    inc sim.players[i].handoffs
    sim.emitEvent(
      ItemGive, source = i, target = partner, item = item,
      amount = GiveChannelTicks,
      x = float(sim.players[i].x + CollisionW div 2),
      y = float(sim.players[i].y + CollisionH div 2)
    )
    sim.logGameEvent(
      playerColorText(sim.players[i].color) & " handed a " &
        (if item == "gun": "marker" else: item) & " to " &
        sim.playerText(partner)
    )

template pruneAgedFx(sim: var SimServer, fxField, tickField: untyped,
    life: untyped) =
  ## Keeps the entries of one aged FX/state seq that are younger than `life`
  ## ticks (the entry is in scope as `fx` inside the `life` expression, for
  ## per-entry lifetimes). Same copy-filter shape every pruned seq used.
  var kept: typeof(sim.fxField) = @[]
  for fx {.inject.} in sim.fxField:
    if sim.tickCount - fx.tickField < life:
      kept.add fx
  sim.fxField = kept


proc step*(
  sim: var SimServer,
  inputs: openArray[InputState],
  prevInputs: openArray[InputState]
) {.measure.} =
  inc sim.tickCount

  # GLORY: the heat ladder cools on a stalled streak -- called unconditionally
  # every tick (same as main), same reasoning as evalAchievementsAllTeams
  # below: cheap, and a no-op whenever heatEmbers is already 0 (Lobby/GameOver).
  sim.heatCool()

  # GLORY: the per-tick achievement pass -- judges every team's satisfied
  # tiers before any claim mints, so a same-tick multi-team completion is a
  # genuine tie (its own internal `if sim.phase != Playing: return` makes
  # this safe to call unconditionally, same as main's own placement ahead
  # of the Lobby/GameOver early-returns below).
  sim.evalAchievementsAllTeams()

  # The center diamonds turn BEFORE anything moves or fires this tick, so
  # movement, bullets, and vision all resolve against the geometry the tick
  # renders — never against last tick's stone.
  sim.updateAnimatedDiamonds()

  # Roster-driven transitions belong inside the deterministic step: leaves
  # are recorded and re-applied, so replays re-derive these exactly. (They
  # used to run live-only in the server loop, which made every replay with a
  # mid-match disconnect-out diverge from its recorded hashes.)
  if sim.players.len == 0 and sim.phase == Playing and sim.config.maxGames > 0:
    sim.finishGame(Red, isDraw = true, timeLimitReached = true)
  elif sim.players.len == 0 and sim.phase != Lobby:
    sim.resetToLobby()

  if sim.phase == Lobby:
    sim.stepLobby()
    return

  if sim.phase == GameOver:
    dec sim.gameOverTimer
    if sim.gameOverTimer <= 0:
      sim.resetToLobby()
    return

  # Playing: move everyone first, then resolve every shot that releases this
  # tick at once against the post-movement snapshot (no processing-order
  # advantage). A fresh trigger pull arms a windup with the aim locked at the
  # pull; the bullet leaves fireWindupTicks later from the shooter's current
  # position, so a target that ducks back behind cover survives the shot.
  var
    firing: seq[int] = @[]
    arcFiring: seq[int] = @[]
  for playerIndex in 0 ..< sim.players.len:
    if sim.players[playerIndex].fireCooldown > 0:
      dec sim.players[playerIndex].fireCooldown
    if sim.players[playerIndex].fireWindup > 0:
      dec sim.players[playerIndex].fireWindup
      if sim.players[playerIndex].fireWindup == 0:
        firing.add(playerIndex)
    let input =
      if playerIndex < inputs.len: inputs[playerIndex]
      else: InputState()
    let prev =
      if playerIndex < prevInputs.len: prevInputs[playerIndex]
      else: InputState()
    sim.applyInput(playerIndex, input)
    sim.applyGrenadeInput(playerIndex, input, prev)
    sim.applyBarrierInput(playerIndex, input, prev)
    # `directAimActive` is this tick's ONLY signal that a human, not a
    # policy, is pointing this cog (see the field doc) — read it once, then
    # clear it so it can never leak into next tick's decision.
    let assistEligible = sim.players[playerIndex].directAimActive
    sim.players[playerIndex].directAimActive = false
    # LOOT(s2): a ghost's trigger is frozen with the rest of it — without
    # this guard the windup branch below would arm a shot canFire only
    # rejects at release. Dark-inert.
    if input.attack and not prev.attack and
        not sim.players[playerIndex].downed:
      if sim.players[playerIndex].hasSprayPaint:
        if sim.canFireArc(playerIndex):
          arcFiring.add(playerIndex)
      else:
        if sim.config.allowAimAssist and assistEligible:
          sim.applyAimAssist(playerIndex)
        if sim.config.fireWindupTicks <= 0:
          if sim.canFire(playerIndex) and sim.players[playerIndex].fireWindup == 0:
            sim.startFireWindup(playerIndex)
            firing.add(playerIndex)
        else:
          sim.startFireWindup(playerIndex)
  sim.resolveSimultaneousFire(firing)
  for playerIndex in arcFiring:
    sim.startArcFire(playerIndex)
  sim.resolveActiveArcCones()
  # Pickups and the heart objective are skipped ENTIRELY under the paintball
  # loadout, because nothing is placed: no grenades, med kits, shields, spray
  # cans, cardboard or hearts exist on the board to update or to touch.
  if not sim.paintballLoadout():
    sim.updateGrenades()
    sim.updateMedKits()
    sim.updateShields()
    sim.updateSprayPaints()
    sim.updateBarriers()
    # LOOT(s2): bandage refill — a no-op (empty family) on a dark config.
    sim.updateBandages()

    for playerIndex in 0 ..< sim.players.len:
      sim.tryPickupFlags(playerIndex)
      sim.tryPickupGrenades(playerIndex)
      sim.tryPickupMedKits(playerIndex)
      sim.tryPickupShields(playerIndex)
      sim.tryPickupSprayPaints(playerIndex)
      sim.tryPickupBarriers(playerIndex)
      # LOOT(s2): config-gated at each proc's own head; no-ops when dark.
      sim.tryPickupBandages(playerIndex)
      sim.tryPickupWeapons(playerIndex)
      sim.tryPickupHoppers(playerIndex)
    sim.updateFlags()
    # LOOT(s2): bandage self-application, after pickups so a bandage
    # pocketed this tick still waits out its own calm window. Config-gated
    # at the proc head; a no-op when dark.
    sim.updateBandageApplies()
  sim.respawnPlayers()
  # LOOT(s2): the downed-state machine — revive tags, bleed-outs and
  # team-wipe finalizations — resolves BEFORE the hazards and the win
  # check, so a ghost finalized this tick feeds the same tick's wipe
  # resolution exactly as a direct kill would. Config-gated at the proc
  # head; a no-op when dark.
  sim.updateDowned()
  # GIVE(s2): the play-called handoff channel, after the downed machine so
  # a partner revived this tick can hold the channel and a giver downed
  # this tick cannot. Config-gated at the proc head; a no-op when dark.
  sim.updateGiveChannel()
  sim.armSprayCans()          ## a respawned cog comes back holding its can.
  sim.updatePackTicks()
  # Puddle damage resolves after movement and pickups, before the win check,
  # so a lethal roll feeds the same tick's wipe resolution. The shrink zone
  # (config-gated, empty by default) resolves right alongside it, for the
  # same reason.
  sim.updatePuddles()
  sim.updateZone()
  sim.updateBarrage()

  # NEW (paintball), in the design note's order: the buff snapshot, then the
  # hill, then the KotH end conditions IN PLACE OF the capture/wipe checks.
  sim.updatePaintBuff()
  if sim.config.floorPaint or sim.config.hill:
    ## The sim guard: the incremental paint/hill counters and the cog
    ## positions every score is derived from, checked before a game is ended
    ## on them. A trip raises SimGuardError, which the server's tick loop
    ## turns into `fault` / `sim_fault` (design §End conditions row 5).
    sim.checkPaintInvariants()
  sim.updateHill()
  if sim.config.hill:
    sim.checkKothEnd()
  else:
    sim.checkWinCondition()
    sim.checkMaxTicks()

  # Prune expired shot tracers and splatters (cosmetic only; excluded from
  # gameHash).
  sim.pruneAgedFx(recentShots, firedTick, ShotFxTicks)
  sim.pruneAgedFx(hitFlashes, tick, HitFlashTicks)
  sim.pruneAgedFx(bubbleImpacts, tick, BubbleImpactTicks)
  sim.pruneAgedFx(recentBlasts, tick, BlastFxTicks)
  sim.pruneAgedFx(sprayPaintFlashes, tick, SprayPaintFxTicks)

  # Expire old shouts. Unlike the cosmetic effects above, shouts are
  # observable gameplay state (bots hear them), so expiry is part of the
  # deterministic sim and the hash.
  sim.pruneAgedFx(recentShouts, tick, ShoutTicks)
  sim.pruneAgedFx(splatters, tick,
    (if fx.hit: HitFxTicks else: SplatterFxTicks))
  sim.pruneAgedFx(damagePops, tick,
    (if fx.kill: KillFxTicks else: DamageFxTicks))
  # GLORY: cosmetic pop expiry (never gameHash) -- a named claim lives the
  # longer AchievementFxTicks, a bare deed/rank-up pop the shorter
  # GloryFxTicks (RANK UP deliberately uses this short life: it fires
  # ~40x/episode and would pile up under the longer claim duration).
  sim.pruneAgedFx(gloryPops, tick,
    (if fx.label.len > 0: AchievementFxTicks else: GloryFxTicks))

## Glory: paintbot's own score. Every kill, save, steal and clean play mints
## GLORY to a team's ledger; a streak of it lights HEAT, a rung of rampage
## multiplier that only pays while you keep playing. Separately, each cog
## climbs a five-rung PER-LIFE ladder by doing real work -- damage landed,
## kits converted, flag play -- and each rung buys a real, playable buff.
## Achievements are the third leg: an eight-tree, five-tier curriculum of
## named feats a team can chase without needing to win outright. Read
## docs/designs/GLORY.md for the full, paintbot-native tour (score fiction,
## deeds, heat, achievements, xp/stars, the supply drop, versioning) -- nothing
## here requires knowing any OTHER game to make sense. (Lineage note, a
## secondary aside: the shape -- priced deeds, a heat ladder, a supply drop
## that can't be farmed -- began as a port from an internal research sim's own
## reward economy, `glory_spec.py` + `patronage.py`; paintbot re-fit every
## number to its own field and inverted at least one of that source's core
## rulings on purpose, noted inline below where it matters.)
##
## **This module is the SINGLE SOURCE OF TRUTH for every glory number.** The
## sim mints through `deedGlory`/`deedDrama`, the achievement tracker prices
## through `tierGlory`, and the ladder reads `LevelThresholds`. Muster's
## lockstep principle: one accessor, so a table can never drift from its
## consumer. An unknown deed prices at zero rather than a stray value.
##
## **Three things here are causal, not analysis.** Unlike the tier-2 SimEvent
## channel, glory changes gameplay: XP drives levels, levels grant buffs, and
## buffs change hit points, fire timing and grenade capacity. So every number
## below is INTEGER (no float drift across platforms), the ledger enters
## `gameHash`, and nothing here may be gated on `collectEvents`.
##
## **The anti-snowball rule is that levels are PER LIFE.** A cog's XP resets
## to zero on death and its buffs go with it. A runaway cog is therefore also
## a fat bounty (`dAceTag`), and the counter-play to a snowball is the same
## as the counter-play to everything else: tag it out. This is a DELIBERATE
## inversion of Muster's ruling that stars must only ever REPORT strength
## (`soldier_roles.STAR_BUFFS` is 60 buffs with zero consumers, and Muster
## keeps it that way on purpose). Paintbot wants the power fantasy; the
## per-life reset is the price that keeps it from compounding across an
## episode.
##
## **This module must keep ZERO imports**, for the same reason `labels.nim`
## does: `players/baseline/` compiles against it, and that image ships no
## `data/` directory. Any import risks dragging the renderer's asset cone into
## a binary that cannot satisfy it.

type
  Deed* = enum
    ## Every priced act. Each is minted at the exact in-sim site where the
    ## fact is known first-hand (attacker, weapon, positions) — never
    ## reconstructed by counter-diffing after the tick.
    dNone

    # ── Combat ───────────────────────────────────────────────────────────
    dFirstBlood        ## the episode's first kill.
    dHonorableKill     ## a plain gun kill: a real fight, priced as the floor.
    dSprayKill         ## a kill by the spray cone.
    dGrenadeKill       ## a kill by a paint-bomb blast.
    dPointBlankKill    ## a kill inside PointBlankPx — the duel won at arm's
                       ## length. Re-cut in v2: at 150px this was the MEDIAN
                       ## kill, not a rare one.
    dLongshotKill      ## a kill past LongshotPx. Zero of 35,335 field shots
                       ## damaged anyone past 832px, so this is genuinely rare.
    dSplashMultiKill   ## one blast or cone activation that killed 2+.
    dRevengeKill       ## killing the cog that killed you, inside RevengeTicks.
    dRunDown           ## killing a target that is moving away from you: the
                       ## chase, on camera.
    dAceTag            ## killing an AceLevel+ cog — a named character
                       ## goes down. This is what makes a leveller a bounty.
    dTeamKill          ## NEGATIVE. Friendly fire cost us up to 63% of the
                       ## death gap before v59; pricing it keeps it closed.

    # ── Objective ────────────────────────────────────────────────────────
    #
    # 🚨 RETIRED (2026-08-24, LEDGER audit C2): `dFlagReturn` (was priced 35g)
    # used to sit here, between `dFlagSteal` and `dCapture`, and never had a
    # mint site. Traced every path that can move `sim.flags[team].carrier`
    # back to -1 (`resetFlag`'s four call sites, sim.nim): (1) the carrier
    # dies -- priced ALREADY, as `dCarrierKill`/`dDenial` at the kill site;
    # `killXp`'s own comment says it outright ("the heart returns home when
    # its carrier dies, so in THIS game the peel IS the return"), so wiring a
    # second deed here would DOUBLE-PAY one act. (2) the carrier disconnects
    # (`removePlayerAt`) or its index goes stale (`updateFlags`'s "vanished"
    # branch) -- neither is a player ACT: nobody did anything, so there is no
    # honest `byIndex` to credit, the same bystander-credit problem that
    # already killed the `returns` counter and the old "Eyes Back"
    # achievement (see `resetFlag`'s comment). This engine has no third path
    # -- no dropped-flag-lies-on-the-ground-until-touched mechanic exists; a
    # flag is always either on its pedestal or glued to a live carrier. So
    # there is no act left for `dFlagReturn` to price. Deleted from the enum,
    # `DeedGloryTable`, `DeedDramaTable` and `deedName` rather than left as
    # inert dead weight.
    dFlagSteal         ## the heart left its pedestal on your back.
    dCapture           ## you scored the enemy heart.
    dCarrierKill       ## THE PEEL: killing the enemy carrier. Invisible in
                       ## every readout we own today, and the highest-value
                       ## defensive act in the game.
    dDenial            ## killing a carrier inside DenialPx of their home —
                       ## the capture stopped on the doorstep.
    dEscortKill        ## a kill landed while a TEAMMATE carries -- not the
                       ## killer, who gets `dCarrierKill`'s own carry
                       ## multiplier for that. This is covering the runner:
                       ## a kill that happens because your own attack is live
                       ## is still a distinct act from the carry itself, so it
                       ## does not double-pay the steal or the eventual
                       ## capture. Wired via `KillContext.escorted`.

    # ── Alliance vocabulary (v12 FOLD -- Amendment 3 Option C, Maxwell's
    # 2026-08-31 ruling, alliance-vocab deed specs Part 1). CTF-ONLY mints:
    # both sites are gated on `not sim.config.brMode`; the BR overlay rides
    # increment 2. Both promote an already-instrumented engine fact into a
    # priced deed -- the deed reads the SAME facts at the kill site that
    # the counter reads, and the wire (`GloryDeed` events) is the proven
    # reconstruction source the offline ledger rebuilds from. dPartnerPeel
    # and dJointAct are NOT in this fold (spec: parked / increment 2). ────
    dAssist            ## the other half of a finished kill: the victim's
                       ## most recent enemy damager (single slot,
                       ## `lastDamagedBy`, inside `AssistWindowTicks`) was a
                       ## TEAMMATE of the killer, not the killer -- credited
                       ## to the assister B, never the killer A, who already
                       ## banks the kill deed. One mint per kill (one slot,
                       ## no multi-assist chains), same shape as the
                       ## `assists` counter beside it. Priced at
                       ## `dEscortKill` parity (spec option B): promoting a
                       ## real, already-instrumented fact deserves the same
                       ## footing as the deed it structurally resembles.
    dRescue            ## killed the attacker whose window-damage left a
                       ## TEAMMATE at clutch hp -- and that teammate is
                       ## STILL ALIVE (the whole point is the partner
                       ## survived; the `rescues` counter does not check
                       ## aliveness, the deed does -- the one predicate
                       ## difference, deliberate). Credited to the rescuer
                       ## at the kill site. Priced at `dRevengeKill` parity
                       ## (spec option A -- under the `dAceTag` ceiling; the
                       ## 56g life-value derivation breaches it and is
                       ## parked as an owner feel-check item, NOT taken).

    # ── Survival and support ─────────────────────────────────────────────
    #
    # 🚨 ZERO+TOMBSTONE (2026-08-26, GLORYVERSION 9, LAW AUDIT E1): `dClutchHeal`
    # priced (25g/30 drama, popping "SAVE", climbing heat) the act of healing
    # YOURSELF at 1 hp. Ground truth: no mechanic in this engine heals or arms
    # another player, so a self-heal is never above-and-beyond -- it is the
    # cog buying its own life back, the textbook self-benefiting act the law
    # bans from anything CELEBRATED. Kept in the enum rather than deleted
    # outright (unlike `dFlagReturn`'s full removal, above) because the mint
    # SITE still fires structurally at the exact spot the save used to be
    # priced -- `tryPickupMedKits` still calls `awardDeed(..., dClutchHeal,
    # ...)` -- so the §8 audit's "every deed fires or it is dead code" rule
    # stays honest about WHY this one fires for nothing: it is INTENTIONALLY
    # inert, not silently unwired. `DeedGloryTable`/`DeedDramaTable` both go
    # to 0 (see their own rows), and `popsScore` now excludes it explicitly
    # (the "SAVE" pop dies with it, same as the law asks). The underlying
    # `clutchHeals` counter on `Player` survives as ANALYSIS-ONLY telemetry
    # (still incremented at the real heal site, still in `gameHash` for
    # replay determinism) -- useful for measuring the heal-rate gap the old
    # deed was aimed at, but it gates no achievement any more (`treeMedKit`
    # is re-founded as The Provider, E2; `treeShield`'s re-gated Second Wind
    # reads `rescuedTick`, never `clutchHealTick`, E3) -- see `tests/
    # test_glory.nim`'s new golden-law test, which asserts exactly that.
    dClutchHeal        ## RETIRED (self-heal, zero+tombstone): see the block
                       ## comment above. Fires at the real heal site, prices
                       ## at 0g/0 drama, never pops, gates nothing.
    # `dShieldSoak` KEPT AS-IS (4g, 0 drama): the law-audit choice offered
    # "keep as a 0-drama analysis counter or retire" -- kept, because unlike
    # `dClutchHeal` it was NEVER celebrated in the first place (0 drama since
    # v1, already excluded from `popsScore`, already excluded from
    # `paysHeat`) -- unretired only in the sense that it still mints a small
    # background glory trickle, same as `dLevelUp`. The LAW VIOLATION here was
    # never the deed, it was the achievement layer built on top of it: the
    # old `treeShield` tree gated five tiers on `soakedHp`, and its own
    # "STANDING DECISION" comment argued soaking "funds the team" -- which the
    # ground truth in this wave's brief refutes directly ("the shield
    # protects ONLY its wearer"). That comment and the tree it defended are
    # gone (E3, `treeShield` re-founded as the teamwork tree); `soakedHp`
    # keeps existing purely as an analysis counter, read by no gate.
    dShieldSoak        ## per hit point your shield absorbed for the team.
                       ## Self-benefiting by mechanics (the ground truth: a
                       ## shield protects only its wearer) -- kept as a
                       ## 0-drama background mint, gates no achievement.
    dWipe              ## the enemy team eliminated.

    # ── Progression ──────────────────────────────────────────────────────
    #
    # 🚨 ZERO+TOMBSTONE (2026-08-26, GLORYVERSION 10, Maxwell's ruling): the
    # leveling tree "shouldn't earn Glory for each action, they simply get
    # stronger as a unit." Leveling's reward IS the power -- the buff ladder
    # (`levelWindupTicks`/`levelGunRange`/`levelMaxHp`/... below), ace status
    # at `AceLevel`, and the supply drop it unlocks -- not the scoreboard.
    # Field fact that forced the call: `dLevelUp` was ~30% of ALL deed glory
    # mass, the single largest deed in the table, so a cog got paid twice for
    # the same climb -- once in raw combat power, again in team glory for
    # merely reaching a rung that nothing above-and-beyond required. Same
    # pattern as `dClutchHeal`'s v9 tombstone, just above: `DeedGloryTable`/
    # `DeedDramaTable` both go to 0 (see their own rows) rather than deleting
    # the enum member -- `addXp` (sim.nim) still calls `awardDeed(...,
    # dLevelUp, ...)` at the exact tick a cog crosses a threshold, so the §8
    # audit still sees the deed FIRE, just for nothing, and `deedCounts`/
    # `deedGloryMass` keep tracking the real cadence for analysis. Zero drama
    # also means it never climbs heat any more (`paysHeat` reads `isDrama`,
    # now false for this deed) -- the xp-earns-a-level -> heat-ember arrow
    # closes. `popsScore` now excludes it too (see that accessor's own
    # comment): the generic "+Ng" pop path stays silent for a deed with
    # nothing to pay, but the RANK UP moment itself is not deleted -- `addXp`
    # mints it directly, the same direct-`addGloryPop`-with-a-label pattern
    # `claimAchievement` already uses for its own named claims, carrying the
    # new star count instead of a payout.
    dLevelUp           ## RETIRED AS GLORY (power stays, scoreboard doesn't):
                       ## see the block comment above. Fires at the real
                       ## level-crossing site, prices at 0g/0 drama, pops as
                       ## a star-count moment with no payout, gates nothing,
                       ## never climbs heat.
    dAchievement       ## an achievement tier claimed; priced by tier, not
                       ## here. Never climbs heat (see `paysHeat`).

    # ── BR-native marquee band (MULTIPLIER RECUT v13, table §1b) ─────────
    #
    # APPENDED members (never inserted -- every existing deed keeps its
    # ordinal, so `deedCounts`/`DeedGloryTable` indexing and the `$deed`
    # wire strings of the pre-v13 world are untouched). All four mint ONLY
    # when `GameConfig.gloryMultiplierRecut` is armed AND `brMode` is on --
    # a dark or classic ledger never sees them, which is what keeps the
    # committed fixtures byte-identical with the flag off. Their
    # `DeedGloryTable` rows are 0 on purpose: in the armed world they are
    # priced by `RecutClassTable` (the additive column is dead there), and
    # in the dark world they never fire at all -- belt and braces.
    dDuoDown           ## finished off an enemy DUO: this kill left the
                       ## victim's whole team dead (BR teams seat exactly
                       ## two). Recut class x2 -- deliberately the
                       ## ESCORT/CHASE tier, not marquee (table §1b:
                       ## 14.12 duo-eliminations/ep at the LOBBY level;
                       ## pricing it higher re-explodes the same way
                       ## common kills would).
    dClosingTime       ## a kill during the zone's CLOSING phase (the
                       ## shrink is actively running). Recut class x2.
    dLastLight         ## a kill in the zone's FINAL phase (at or past the
                       ## last authored `zonePhases` entry). Recut class
                       ## x4 -- the rarest signal in the table (measured
                       ## 0.0% under the shipped 7-phase pacing; a supply
                       ## problem, priced for when supply exists).
    dVictory           ## you won the BR match. Recut class x8 -- ties
                       ## CAPTURE/WIPEOUT as "the game is over, you won".

const
  GloryVersion* = 13
    ## Bumped on any pricing change, so a ledger can be attributed to the
    ## table that produced it. A cross-version comparison is invalid.
    ##
    ## v13 (2026-09-02, MULTIPLIER RECUT -- built VERBATIM from the frozen
    ## contract `~/.ctf/handoff/2026-09-02-multiplier-recut-table.md` +
    ## `...-multiplier-recut-directive.md`; glory-2 lead holds conformance
    ## review): the pure-multiplier economy, DARK behind
    ## `GameConfig.gloryMultiplierRecut` (default false everywhere -- with
    ## the flag off every number in this file prices exactly as v12 and the
    ## committed fixtures replay byte-identical; the batched fixture
    ## re-record rides a later coordinated pass, deliberately NOT this
    ## increment).
    ##   - NO BASE POINTS (directive §2): armed episode score = RecutSeed(1)
    ##     x PRODUCT(per-event integer factors) / 2^(FF halvings). Every
    ##     deed/achievement maps to an integer CLASS (`RecutClassTable` /
    ##     `RecutTierClass`, table §1): x1 commons carry no score weight at
    ##     all (§5.8 -- they still mint, pop, count); x2+ classes fold, per
    ##     event, class x heat (`HeatLadder`, unchanged cadence) x carry
    ##     (x2) x ally-stack (`RecutStackLadder`, Fibonacci §2), with the
    ##     territory rung shift (+1 on enemy ground, above-x1 only, §3)
    ##     applied to the class before the live-state factors.
    ##   - FF PENALTY = DIVISION, PER MODE (§4): BR /2 per `dTeamKill`
    ##     incident, CTF /2 per TWO incidents, both compounding, both
    ##     uncapped. Canonical state is the integer pair (product,
    ##     halvings); the int ledger reports the floor division (the
    ##     table's accepted non-integer tail, e.g. 1.125, floors on the int
    ##     wire -- flagged to conformance, not hidden).
    ##   - BR-NATIVE MARQUEE BAND (§1b): new deeds `dDuoDown` (x2),
    ##     `dClosingTime` (x2), `dLastLight` (x4), `dVictory` (x8) -- ALL
    ##     four mint ONLY when the recut is armed (brMode + flag), so the
    ##     dark ledger never sees them.
    ##   - PER-DUO, NOT PER-SEAT (§7a): the product lives on the TEAM key
    ##     (`awardDeed` is the single mint, called once per shared fact);
    ##     both seats of a duo read the SAME product; nothing is evaluated
    ##     twice through the mirrored per-seat display ledger.
    ##   - Drama column deliberately UNTOUCHED (§5.7 -- open owner call).
    ##
    ## v12 (2026-08-31, HEART RECUT + CONCLUSION SWEEP -- the ruled
    ## 2026-08-31 recut contract plus its Amendment 1, implemented verbatim):
    ##   - STRUCTURAL CONCLUSION SWEEP: `finishGame` (sim.nim) now runs ONE
    ##     full achievement pass over every team and every tree at the moment
    ##     a game concludes (capture, wipe, mutual-wipe draw, time limit --
    ##     every path through `finishGame`; an aborted game still sweeps
    ##     nothing), under the same read-all-before-any-mint first-claim tie
    ##     law the per-tick pass applies. This closes the terminal-tick hole
    ##     the decisive claimability experiment proved (branch
    ##     maxwell/heart-claimability-test): a fact created by the capture or
    ##     kill that ENDS the game could never mint, because the per-tick
    ##     sweep runs before the win check and both eval procs are
    ##     Playing-gated. In Season 2's modes (2-team 8v8 CTF, 16-duo BR)
    ##     EVERY episode ends on a terminal tick, so conclusion-time
    ##     evaluation is the MAIN mint path there, not an edge. Clean Sheet's
    ##     dedicated conclusion mint (`evalCleanSheetAtConclusion`) folds
    ##     into the general sweep -- same "never reported while Playing,
    ##     evaluated once at conclusion" semantics, one mechanism instead of
    ##     a special case.
    ##   - THE HEART (treeCarrier) RECUT, per the contract table: I "Hands
    ##     On" (contestedSteals >= 1, unchanged), II "Fighting Carry"
    ##     (carryKills >= 1, was III), III "Double Steal" (NEW,
    ##     contestedSteals >= 2 -- mirrors The Peel's "Double Peel" naming
    ##     and shape), IV "Hard Carry" (NEW, contestedSteals >= 2 and
    ##     carryKills >= 1 -- the strict superset of II+III: kept taking it
    ##     AND kept fighting), V "Delivered" (captures >= 1, was II; the
    ##     single terminal tier, claimable via the conclusion sweep). II/III
    ##     ordering is PROVISIONAL (contract ordering caveat): re-measure
    ##     both rates on real episodes EXCLUDING game-ending captures (the
    ##     subset the offline scorer over-credited -- Amendment 1's C4-swap
    ##     revisit) and swap then if the field says so.
    ##   - "Uphill" and "Fast Break" leave the ladder for the ENDCARD (see
    ##     `CaptureDistinction` below): the engine keeps pinning
    ##     `capturedOutnumbered`/`capturedFastBreak` at the capture site
    ##     (unchanged code path), the game-over frame ships the pins as
    ##     display-only distinction lines -- no glory, no claim, no heat.
    ##   - VICTORY LAP (treeSquad V) amended gate (Amendment 1):
    ##     `kits >= KitLegsImplemented and anyCapture` -- every kit leg this
    ##     port implements, converted, plus a capture. The old `kits >= 4`
    ##     could never hold (`teamConvertedKits` hard-caps at 3: the med leg
    ##     reads `supplyShared`, absent on this port), so the tier was dead
    ##     for a reason UPSTREAM of sweep timing. Restoring it to 4 when the
    ##     med leg lands is a one-constant change. "Full Kit" (treeSquad
    ##     III, 4 of 4 kits) is TOMBSTONED zero-claim until then -- a
    ##     3-value counter cannot carry three thresholds, so I/II are NOT
    ##     re-spaced.
    ##   - `XpPerCapture` 30 -> 0, tombstoned in place (contract §5) -- see
    ##     its own comment for the ruling.
    ##   - ALLIANCE-VOCAB FOLD (Amendment 3 Option C, Maxwell's 2026-08-31
    ##     ruling; alliance-vocab deed specs Part 1): `dAssist` (14g/15
    ##     drama, dEscortKill parity) and `dRescue` (18g/30 drama,
    ##     dRevengeKill parity) promoted as CTF deeds, minted at the kill
    ##     site in sim.nim from the same engine facts their counters read
    ##     -- gated `not brMode` (the BR overlay rides increment 2). The
    ##     rescue deed additionally requires the menaced teammate be ALIVE
    ##     at mint time (spec: "the partner survived"), which the
    ##     `rescues` counter never checked. `dPartnerPeel`/`dJointAct`
    ##     deliberately NOT added (parked / increment 2 per the spec).
    ##
    ## v11 (2026-08-30, BR increment 3, the glory-inc3 wave): makes the BR
    ## ledger honest against real measured numbers, gated everywhere on
    ## `sim.config.brMode` so a classic 2-/4-team ledger is unaffected.
    ##   - `PointBlankPx`/`LongshotPx`/`DenialPx` are now priced as a
    ##     FRACTION of the live map's `gunRange` (`pointBlankPxFor`/
    ##     `longshotPxFor`/`denialPxFor`, `CtfReferenceGunRange`), not an
    ##     absolute px figure -- unscaled, BR's 331px gunRange
    ##     (`br-golden-map.json`) inflated `PointBlankPx` from a rare
    ##     duel-range bonus (10.5% of CTF's reference range) into 33% of
    ##     BR's whole range, the modal kill; `LongshotPx` (700px) exceeded
    ##     BR's gunRange outright, structurally dead and taking gun-tree
    ##     tier V with it. See `CtfReferenceGunRange`'s own comment.
    ##   - `LevelThresholds` gains a BR-only multiplier
    ##     (`BrLevelThresholdMultPct`) via `levelForXp`'s new `brMode`
    ##     param: BR's xp is damage-only (no heal/pickup/shield xp, per the
    ##     v9 self-care law) at `XpPerDamage=3` and the gun deals 1 hp, so
    ##     one tag was exactly L1 and ~5.3 tags capped a cog at L5
    ##     permanently for the rest of the one-life episode -- `resetLadder`
    ##     (the anti-snowball rule) cannot fire in BR, since the reset
    ##     always lands on a death that is ALSO the cog's permanent
    ##     elimination. See `BrLevelThresholdMultPct`'s own comment for the
    ##     `episode-s830` measurement this was tuned against.
    ##   - `dRevengeKill` ("PAYBACK") gains a second, BR-only gate:
    ##     avenging a DEAD PARTNER's killer (`avengesPartner`, via
    ##     `partner.lastKilledBy`), not just avenging your OWN killer
    ##     (`avengesKiller`, structurally unreachable in BR -- a killer who
    ##     had ever died is already permanently eliminated). Tapered to at
    ##     most one mint per cog per episode (`avengedPartner`).
    ##   - `awardWipe` (`dWipe`) is disabled outright in `brMode` -- see its
    ##     own comment in sim.nim.
    ##   - `slotAnchor`'s `layoutSides` branch (arena.nim) no longer
    ##     collapses every non-Red team onto the SAME anchor point when a
    ##     BR map's `spawnPoints` are authored -- each team gets its own
    ##     point, so `groundOwner`'s nearest-pedestal search (the site
    ##     gradient, §3) can actually tell 16 BR duos' ground apart instead
    ##     of resolving every non-Red deed at the flat `SiteMultEnemyPct`.
    ##   - The whole ledger (team glory, heat, per-player xp/level/counters,
    ##     achievement claims) enters `gameHash` for the first time (was
    ##     GLORY PORT increment 2/3, is now increment 3/3) -- `GameVersion`
    ##     bumps 47->48 alongside this, in the same commit that re-records
    ##     every `.bitreplay` fixture.
    ##
    ## v10 (2026-08-26, GLORYVERSION 10 WAVE, Maxwell's ruling verbatim: the
    ## leveling tree "shouldn't earn Glory for each action, they simply get
    ## stronger as a unit"). `dLevelUp` zero+tombstoned -- `DeedGloryTable`
    ## 6->0, `DeedDramaTable` 5->0 -- so leveling's reward is the POWER (the
    ## buff ladder, ace status, the supply drop) and nothing pays the
    ## scoreboard for reaching a rung any more; see the tombstone on `Deed.
    ## dLevelUp` for the full mechanics writeup. `popsScore` now excludes the
    ## deed too (its generic "+NG" path would otherwise draw an empty "+0G"
    ## toast); the RANK UP moment survives as a direct, star-count pop minted
    ## by `addXp` itself (sim.nim), the same labelled `addGloryPop` path
    ## `claimAchievement` already uses for its own named claims.
    ##
    ## Field fact that forced the call: `dLevelUp` was ~30% of ALL deed glory
    ## mass, the single largest deed in the table. The downstream effect ran
    ## well past that direct share, because zero drama also means level-ups
    ## (39.4 fires/episode -- the single most frequent drama deed in the
    ## game, more often than every combat deed combined) stop feeding heat
    ## embers, so every OTHER drama deed's own heat multiplier collapsed
    ## with it. RE-MEASURED, tools/ladder/gloryscore.py, same 120-episode
    ## `--min-version 0.7.200` cache, run against the fully v10-synced
    ## mirror (2026-08-26): heat occupancy x1 72%->91%, x2 12%->7%,
    ## x4 11%->0%, x8 3%->0%; wipe-corrected median WINNER episode glory
    ## 2287G->1038G; wipe-corrected combined (both teams) per-episode glory
    ## p20 2450->1321, p40 3058->1477, p60 3724->1635, p80 4387->1873
    ## (median 3246->1553, n=112 decided of 120 scored). Three constants
    ## re-tuned off these numbers this wave: `AchievementSweepBudgetPct`
    ## 27->58 (see its own comment -- the STRICT test constraint,
    ## `sum(TierGlory) * AchievementTrees < dCapture + dWipe`, did NOT move,
    ## since neither `dCapture` nor `dWipe` changed); and, in
    ## `client/replay_broadcast.html`, `GLORY_TIERS`' four endcard cuts
    ## (2500/3000/3700/4400 -> 1300/1500/1600/1900) and the leader-pulse
    ## margin (130G -> 60G, still ~8% of a typical per-team total) -- see
    ## each constant's own provenance comment for the full readout.
    ##
    ## v9 (2026-08-26, GLORYVERSION 9 WAVE / LAW AUDIT, Maxwell's re-affirmed
    ## law: "achievements and glory reward play ABOVE AND BEYOND normal --
    ## never self-benefiting acts"). A whole violating tree was caught this
    ## pass: ground truths already proven and cited rather than re-derived --
    ## a shield protects ONLY its wearer (all three damage sites absorb on
    ## the hit index), NO mechanic heals or arms another player, and the
    ## supply drop is the ONE team-benefit loop this engine has (any
    ## teammate may consume a drop). Every item below is classified by
    ## MECHANICS, never by name.
    ##   - E1: self-care stops paying anything CELEBRATED. `dClutchHeal`
    ##     zero+tombstoned (see its own comment on `Deed`) -- the "SAVE" pop
    ##     and its heat/drama are gone, the mint site stays wired at 0g/0
    ##     drama so the §8 audit still sees it FIRE, just for nothing.
    ##     `XpPerHeal`, `XpPerClutchHeal`, `XpPerShieldSoak` and the
    ##     heal-gated `XpPerPickup` all go to 0 -- self-care buys no levels.
    ##     `dShieldSoak` KEPT (never celebrated to begin with; see its own
    ##     comment). `LevelThresholds` [9,19,27,40,55] -> [9,15,24,33,48],
    ##     RE-FIT against the mirror re-measured with those four constants
    ##     zeroed (tools/ladder/gloryscore.py, same 120-episode
    ##     `--min-version 0.7.200` cache, 2026-08-26): xp peaks p25:6 p50:9
    ##     p75:15 p90:21 p95:27 p98:39 p99:45 (4804/6870 active lives) --
    ##     visibly compressed vs the v7 fit's p90:25/p99:52 (heal xp was a
    ##     real chunk of the old pool; removing it shrinks the whole
    ##     distribution, as it should once self-care no longer levels). Same
    ##     design anchors as v7: L1 just above p50 (value 9, sits at the p50
    ##     mark itself: 56.7% of active lives clear it), L3 ≈ p90 (24, lands
    ##     at p93.1 -- 6.9% clear), L5 just past p99 (48, p99.3 -- 0.7%
    ##     clear); L2 (15) and L4 (33) interpolate on the same curve.
    ##     VERIFIED cadence: L3+ lives/team-ep mean 1.93 (target ~2), L5
    ##     lives/ep mean 0.38 (target ~0.3), P(L1+ | killed or stole) 0.91
    ##     (target ~0.9) -- all close to the design targets despite the
    ##     shrunk pool, because damage xp (the workhorse, untouched) still
    ##     dominates. Sanity (unchanged design facts):
    ##     `levelForXp(XpPerSteal)` == 1 (12 sits in [9,15)),
    ##     `levelForXp(XpPerCapture)` == 3 (30 sits in [24,33)).
    ##   - E2: `treeMedKit` re-founded as THE PROVIDER (see `AchievementNames`'
    ##     own comment) -- gated on `supplyShared`/`supplySaves`, new
    ##     per-player counters pinned in `tryPickupSupplyDrops` (sim.nim) the
    ##     instant a TEAMMATE (not the dropper) consumes a supply-dropped
    ##     pickup, crediting the DROPPER. `SupplyDropPickup` gained
    ##     `droppedBy`. `teamConvertedKits`'s "med" boolean now reads
    ##     `supplyShared >= 1` instead of `clutchHeals >= 1`.
    ##   - E3: `treeShield` re-founded as THE TEAMWORK tree -- gated on four
    ##     new counters (`assists`, `escortKills`, `rescues`,
    ##     re-gated `secondWind`) plus a team-wide `squadVolleyDone` pin, all
    ##     set ONCE at their causal sites in `killPlayer`/the three damage
    ##     sites, the same discipline `secondWind`/`capturedOutnumbered`/
    ##     `capturedFastBreak` already hold themselves to -- see sim.nim's
    ##     own comments at `lastDamagedBy`/`menacingTick`/`rescuedTick` for
    ##     the plumbing. "Second Wind" keeps its name but is RE-GATED: the
    ##     comeback beat is now "get rescued, then land a tag within
    ##     `SecondWindTicks`" instead of "heal yourself, then land a tag" --
    ##     the self-heal gate is gone, the comeback fiction survives.
    ##     `teamConvertedKits`'s "shield" boolean now reads `assists >= 1`
    ##     instead of `soakedHp >= 3`.
    ##   - E4: the FIRST race (the marker AND the 300% pioneer bonus) is now
    ##     restricted to TIER V of each tree -- 8 of 40 possible claims
    ##     (20%), under Maxwell's "no more than a quarter of all possible
    ##     achievements should be firsts" ceiling. Tiers I-IV claim for every
    ##     team at the same base price, no race, ever; enforced once, inside
    ##     `claimAchievement` itself (sim.nim), so no caller can bypass it.
    ##   - E5: `TierGlory` [2,4,8,16,32] -> [9,11,14,18,23] -- the "+2
    ##     problem": tier I used to pay 2g next to a 10g floor kill, an order
    ##     of magnitude under "a solid deed." Re-anchored so tier I (9g) sits
    ##     just under `dHonorableKill` (10g) and tier V (23g, 69g first-
    ##     claimed) sits in the `dAceTag`(40)/`dCarrierKill`(90) neighborhood
    ##     -- a real event, not a footnote. `tests/test_glory.nim`'s law-3
    ##     sweep-budget test is the hard constraint this was solved against:
    ##     `sum(TierGlory) * AchievementTrees < dCapture + dWipe` --
    ##     75 * 8 = 600 < 650, unchanged `dCapture`/`dWipe`. See
    ##     `AchievementSweepBudgetPct`'s own comment for the re-measured
    ##     share of a median winner's episode glory this ladder now costs.
    ##   - E6: `AchievementDescriptions` -- one truthful, kid-readable
    ##     sentence per (tree, tier), shipped once per HUD viewer
    ##     (`broadcast.nim`'s `curriculumJson`) and read as native `title=`
    ##     tooltips on the achievement panel and the two team dropdowns
    ##     (`client/replay_broadcast.html`).
    ##   - E7: a GOLDEN LAW test drives the REAL `evalAchievements` path and
    ##     asserts `clutchHeals`/`soakedHp` (self-care), pumped to an absurd
    ##     value, satisfy NOTHING -- neither any individual tier nor the
    ##     team-wide `teamConvertedKits` booleans -- the violation class this
    ##     whole wave exists to end now fails the suite loudly, forever,
    ##     instead of waiting for a human audit to catch the next one. Lives
    ##     in `tests/test_glory_sim.nim` (not `test_glory.nim`) on purpose:
    ##     verifying gates is a SIM-behavioral question, and that file
    ##     already owns "glory wired into the sim."
    ## Every item above changes WHETHER, HOW MUCH, or WHO an achievement or
    ## deed pays, and the xp/threshold refit changes which level a cog's xp
    ## buys -- so a v8 ledger's achievement claims, glory totals and levels
    ## are NOT comparable to a v9 one.
    ##
    ## v8 (2026-08-25, FAST BREAK wave): treeCarrier tier V "Full Run" retired
    ## and replaced with "Fast Break" -- see GLORY C3c's own ⚠️⚠️ disclosure
    ## (now deleted from the tree comment below, its job done) for the proof
    ## that "Full Run" was REDUNDANT with "Delivered" (II) in this engine, not
    ## merely correlated: every capture this engine can ever produce already
    ## satisfies the old requirement, so the tier never tested anything
    ## Delivered did not already cover (n=45 field claims, identical claim-tick
    ## distributions). "Fast Break" tests a real, DIFFERENT act instead: steal
    ## the heart and capture it within `FastBreakTicks` = 240 (10s) of the
    ## steal, in the SAME life. Field-fit on 103 real steal->capture deltas
    ## (2026-08-25): p10=210, p25=244, p50=358 -- 240t sits just inside the
    ## first quartile, qualifying 22.3% of real captures, a genuine tier-V
    ## speed-run band (rare enough to chase, not a floor every capture clears).
    ## Engine side: `capturedFastBreak` is PINNED once in `recordCapture`, the
    ## same event-pin pattern `capturedOutnumbered`/`secondWind` already use,
    ## instead of re-deriving `captures >= 1 and stealTickThisLife >= 0` (the
    ## old check, trivially true for EVERY capture and thus the actual source
    ## of the redundancy) on every poll. Causal (gates a claim), so it rides
    ## the hash. This changes WHICH acts can claim tier V, so a v7 ledger's
    ## carrier-tree claims are not comparable to a v8 one.
    ##
    ## v7 (2026-08-25, /proof FIX WAVE E, measurement-first): E1/E2 were
    ## MEASUREMENT-ONLY (see their own comments on `DenialPx`/`SiteMultHomePct`)
    ## and moved no number a v6 ledger would price differently. Three items
    ## did move pricing/claims, bundled into this one version so nothing
    ## hash-moving ships piecemeal:
    ##   - E3: `LevelThresholds` [10,18,24,36,50] -> [10,19,27,40,55],
    ##     re-fit on the first mirror measurement that can actually see heal
    ##     xp (GLORY C10 had fixed the mirror's dead `item_pickup` detection
    ##     branch, but every threshold fit before this one -- including the
    ##     2026-08-25 GLORY C1 "byte-identical" re-check -- ran BEFORE that
    ##     fix landed, so all of them were blind to `XpPerHeal`/
    ##     `XpPerClutchHeal` xp without knowing it). Changes which XP total
    ##     buys which level, so it changes buffs. See its own comment for the
    ##     full percentile/cadence fit.
    ##   - E4: "Blast Radius" (treeGrenade III) and "Double Blast" (IV) used
    ##     to gate on the SAME condition (`grenadeMultiKills >= 1`, a GLORY
    ##     C3a side effect) and claimed in lockstep, n=7 field, every claim
    ##     same-tick as its pair. IV now needs `grenadeMultiKills >= 2` --
    ##     literally two multi-kill blasts. Changes WHETHER IV claims.
    ##   - E5: treeMedKit reordered on its first-ever field claim rates (n=240
    ##     team-eps, the first data point since GLORY C10 fixed heal
    ##     detection): Patch Job<->Second Wind (II/III) and Miracle
    ##     Worker<->Lifeline (IV/V) swap slots, same requirements. Changes
    ##     HOW MUCH each act pays (`TierGlory` is tier-indexed), not whether
    ##     it can claim.
    ## Also landed this wave, NEITHER of which moves a v6 ledger: a real bug
    ## fix in tools/ladder/gloryscore.py (the MEASUREMENT MIRROR, not the
    ## source of truth) that hardcodes the two home pedestals as map
    ## constants instead of recovering them per-episode -- see `DenialPx`'s
    ## own v7 note; and a second mirror fix widening its spray multi-kill
    ## grouping from same-tick-only to a 4-tick window -- see "Double
    ## Splash"'s own comment. Both are measurement-instrument fixes with zero
    ## sim.nim/glory.nim pricing changes attached.
    ##
    ## v6 (2026-08-25, /proof fix cycle C1-C6): six changes, each moving
    ## WHETHER or HOW MUCH something mints or levels, so a v5 ledger's xp,
    ## achievement claims and per-kill deed pricing are not comparable to a
    ## v6 one.
    ##   - C1: `XpPerPickup` no longer pays on a BARE-TOUCH grenade, shield
    ##     or spray-can pickup (six sim.nim sites zeroed) -- only the
    ##     work-gated med-kit path still pays it. `LevelThresholds` was
    ##     re-measured against the real field with the cut applied and came
    ##     back unchanged (the sample it was fit from never had pickup xp to
    ##     begin with; see its own comment).
    ##   - C2: `LevelGunRangePct`'s +15% rung (L2+) retired -- geometrically
    ##     dead, past the default arena's own diagonal, so it never gated a
    ##     shot at any level. L2 now carries only its spray-reset -40%.
    ##   - C3a: "Blast Radius" (treeGrenade) gates on `grenadeMultiKills`
    ##     alone now, dropping the `sprayMultiKills` alternative (a SPRAY
    ##     multi-kill could complete a GRENADE tier) and the redundant
    ##     `grenadeKills >= 1` term.
    ##   - C3b: "Uphill" (treeCarrier) reads a fact PINNED at the capture
    ##     instant (`capturedOutnumbered`, set once in `recordCapture`)
    ##     instead of re-reading live team-alive-counts on every
    ##     achievement poll -- closes a backdating bug where a capture made
    ##     EVEN could claim Uphill the instant a teammate died afterwards.
    ##   - C4: three trees reordered on measured field claim rates (n=240
    ##     team-eps) -- treeGun Longshot(IV)<->Sharpshooter(V);
    ##     treeGrenade "The Bombardier" II->V (the tree's actual hardest,
    ##     moved off III), Blast Radius/Double Blast shift to III/IV;
    ##     treeCarrier Delivered(III)->II, Fighting Carry(II)->III. Same
    ##     requirements, different `TierGlory`/`TierDrama` price per slot.
    ##   - C5: `DenialPx` 220 -> 600, field-fit ("Doorstep" claimed 0.0% of
    ##     240 team-episodes at the old value; see its own comment for the
    ##     measurement). This ALSO reprices many real carrier kills: any
    ##     kill 220-600px from the victim's own pedestal now resolves as
    ##     `dDenial` (120g) instead of `dCarrierKill` (90g) in `killDeed`,
    ##     not just an achievement-side change.
    ## (C6, the achievement display-name renames, mints nothing differently
    ## and is not part of this changelog's WHETHER/HOW-MUCH scope --
    ## `achievementKey` is ordinal-derived, never name-derived.)
    ##
    ## v5 (2026-08-25, heat persistence): `HeatThresholds` [1,4,10] ->
    ## [2,5,10], `HeatEmberDecay` 4 -> 2, `HeatEmberCap` 12 -> 11. Measured
    ## on 3 real hosted episodes (change-point-exact gloryLine census):
    ## flames lit ~12x/team/episode with a 2.5s MEAN lit spell -- one deed
    ## lit x2 (threshold 1) and one ~1.9s quiet window erased a whole rung
    ## (decay 4). Maxwell: "they earn it then it disappears." Now a lone
    ## deed never lights (flames = a live STREAK), and cooling is a visible
    ## descent through the rungs (~11s cap-to-dark) instead of a light
    ## switch. The cap rides down 12 -> 11 so one quiet window still
    ## demotes the top rung (11-2=9 < 10); at cap 12, decay 2 would have
    ## let a maxed team hold x8 through a full quiet window. Every deed's
    ## multiplier can differ under the new ladder, so a v4 ledger is not
    ## comparable to a v5 one.
    ##
    ## v4 (2026-08-24, /proof fix cycle): `dFlagReturn` retired (dead, zero
    ## mint sites, would double-pay the carrier's death -- see the tombstone
    ## on `Deed`); `dEscortKill` wired via `KillContext.escorted`; treeCarrier
    ## tier I/II re-cut off possession ("Hands On" -> a CONTESTED steal,
    ## "Breakaway" -> "Fighting Carry", a kill while carrying); "Blast Radius"
    ## moved off the friendly-fire-contaminated `multiKills` onto the clean
    ## per-activation counters (that field is deleted, having lost its only
    ## reader); "Second Wind" now requires the kill to land AFTER the heal,
    ## inside the window, instead of comparing two independent tick fields at
    ## poll time. Every one of these changes WHETHER or HOW MUCH a claim
    ## mints, so a v3 ledger's achievement claims are not comparable to a v4
    ## one.
    ##
    ## v3 (2026-08-24): the achievement curriculum rewrite that bans every
    ## pickup/possession/arrival requirement from the tree (law 2b's ruling,
    ## below) and moves Clean Sheet (`treeSquad` tier IV) from a per-tick
    ## tick>=600 poll to a FULL-GAME conclusion-only mint. Both change WHEN
    ## and WHETHER a claim mints, which moves `teamGlory` -- so a v2 ledger's
    ## achievement claims are not comparable to a v3 one, even though
    ## `TierGlory` itself did not move a single number.
    ##
    ## v2 (2026-08-21): `PointBlankPx` 150 -> 110 and `dPointBlankKill`
    ## 16 -> 12, after the deed was measured firing on HALF of all kills.
    ## Any v1 ledger is priced against a point-blank deed that was the
    ## DEFAULT kill; do not pool the two.

  # ───────────────────────────────────────────────────────────────────────
  # §1  DEED PRICING — glory magnitude, and drama weight
  # ───────────────────────────────────────────────────────────────────────
  #
  # Two numbers per deed, exactly as Muster carries them:
  #
  #   glory  — the MAGNITUDE minted to the team ledger (integer).
  #   drama  — the SPECTATOR's pricing of the deed, in TENTHS so it stays
  #            integer. Drama does three jobs: it decides whether a deed
  #            climbs the heat ladder (drama > 0), it is what the replay feed
  #            ranks moments by, and it is the weight any future gradient
  #            would filter through.
  #
  # A deed can be worth glory and worth ZERO drama (an economy act funds you
  # without being a show). Muster's live telemetry had passive deeds at
  # 93-100% of all glory; pricing them at 0 drama is what stops that mass
  # from leaking into the watched game as correlated noise.
  #
  # ⚠️ These magnitudes are the OPENING pre-registration, fit to the deed's
  # measured worth in OUR field data, not copied from Muster. The two games
  # price differently: a paintbot kill is only ~16% banked, one life saved is
  # worth 5.6 kills made, and a death costs 3.4x a kill. So the objective and
  # survival lines outprice the combat line here, where in Muster combat
  # dominates. Do not re-fit these against our own gap after seeing it —
  # that is selection on outcome.

  DeedGloryTable: array[Deed, int] = [
    0,      # dNone
    # combat
    12,     # dFirstBlood
    10,     # dHonorableKill
    12,     # dSprayKill
    12,     # dGrenadeKill
    12,     # dPointBlankKill  (v2: was 16, which outpaid the floor on
            #                  the MEDIAN kill -- see PointBlankPx)
    30,     # dLongshotKill
    35,     # dSplashMultiKill
    18,     # dRevengeKill
    16,     # dRunDown
    40,     # dAceTag
    -60,    # dTeamKill  (NEGATIVE: a teammate's life at full price)
    # objective
    40,     # dFlagSteal
    250,    # dCapture
    90,     # dCarrierKill
    120,    # dDenial
    14,     # dEscortKill
    # alliance vocabulary (v12 fold: CTF-only mint sites)
    14,     # dAssist  (dEscortKill parity -- spec Part 1, option B)
    18,     # dRescue  (dRevengeKill parity -- spec Part 1, option A;
            #          NOT the 56g life-value derivation, which breaches
            #          the dAceTag-40 ordinal ceiling and went to the
            #          owner as a feel-check item)
    # survival and support
    0,      # dClutchHeal (v9 GLORY LAW E1: zero+tombstoned -- self-heal is
            #             never above-and-beyond; see the Deed enum comment)
    4,      # dShieldSoak (per hit point; kept -- see the Deed enum comment)
    400,    # dWipe
    # progression
    0,      # dLevelUp (v10 GLORY LAW, Maxwell's ruling: zero+tombstoned --
            #          leveling pays POWER, not the scoreboard; see the
            #          Deed enum comment. Was 6, ~30% of ALL deed glory mass.)
    0,      # dAchievement (priced by tier — see TierGlory)
    # BR-native marquee band (v13): additive prices are 0 BY DESIGN -- these
    # four exist only in the armed multiplier world (`RecutClassTable`) and
    # never mint dark. See the Deed enum block comment.
    0,      # dDuoDown
    0,      # dClosingTime
    0,      # dLastLight
    0,      # dVictory
  ]

  DeedDramaTable: array[Deed, int] = [
    0,      # dNone
    # combat
    20,     # dFirstBlood
    10,     # dHonorableKill — the floor: a plain, real fight
    30,     # dSprayKill
    30,     # dGrenadeKill
    35,     # dPointBlankKill
    40,     # dLongshotKill
    40,     # dSplashMultiKill
    30,     # dRevengeKill
    20,     # dRunDown
    30,     # dAceTag — a named cog dies
    0,      # dTeamKill — anti-drama; it costs glory but must never light heat
    # objective
    25,     # dFlagSteal
    70,     # dCapture
    35,     # dCarrierKill
    45,     # dDenial
    15,     # dEscortKill
    # alliance vocabulary (v12 fold)
    15,     # dAssist  (dEscortKill parity, with its glory)
    30,     # dRescue  (dRevengeKill parity, with its glory)
    # survival and support
    0,      # dClutchHeal (v9 GLORY LAW E1: the "SAVE" pop and its heat dies
            #             with it -- see the Deed enum comment)
    0,      # dShieldSoak — ambient soak, funds you, is not a moment
    400,    # dWipe
    # progression
    0,      # dLevelUp (v10: zero+tombstoned with its glory, above -- zero
            #          drama also means it never climbs heat any more,
            #          `paysHeat` reads `isDrama`. Was 5.)
    0,      # dAchievement — tier-priced (TierDrama)
    # BR-native marquee band (v13). dDuoDown/dVictory carry the drama the
    # alliance-vocab spec (2026-09-01, increment-2 §4) already derived for
    # them (35/70). dClosingTime/dLastLight have NO specced drama anywhere
    # -- held at 0 (they neither climb heat nor rank the replay feed) and
    # FLAGGED to the glory-2 conformance review as an open drama-column
    # item rather than invented here (§5.7: the drama column is explicitly
    # untouched by the recut contract). Armed-only mints either way.
    35,     # dDuoDown  (alliance-vocab spec increment-2 §4 parity)
    0,      # dClosingTime (OPEN: no specced drama -- see block comment)
    0,      # dLastLight   (OPEN: no specced drama -- see block comment)
    70,     # dVictory  (alliance-vocab spec increment-2 §4 parity)
  ]

  # ───────────────────────────────────────────────────────────────────────
  # §2  HEAT — the rampage multiplier ladder
  # ───────────────────────────────────────────────────────────────────────
  #
  # Ported from Muster patronage.py `_rung_for_embers`. Flames are earned by
  # a STREAK, not one kill per rung: a drama deed adds an ember, and each rung
  # costs more embers than the last. Muster's scar: +1 rung per deed pinned
  # the whole server at max flames (measured heat_sum 14.7 = everyone maxed)
  # because three kills bought x8.
  #
  # Muster's cadence is re-fit here, not copied. Muster cools 4 embers per 20
  # ticks on a 1000+ tick match; a paintbot episode is decided inside ~40
  # seconds, so the window is tighter and the cool-off is faster in absolute
  # ticks. The pinball law holds either way: a lit multiplier pays only when
  # you shoot.
  #
  # 🎖 THE FICTION DECISION (GLORY C8, 2026-08-25): flames stay. A streak
  # mechanic needs SOME visual metaphor for "building heat," and "on fire"
  # was the one already shipping (the flame chip on the scorebug/board, the
  # rung-crossing callouts) before this audit ever asked the question.
  # Considered and rejected two paint-native alternatives:
  #   - PAINT-PRESSURE GAUGE (a tank/canister filling as the streak
  #     builds): more literally paint-native, but a gauge reads as a
  #     RESOURCE ("how much do I have left"), which is backwards -- heat is
  #     the OPPOSITE of a depleting resource, it is a reward for spending
  #     attention on offense. A gauge FILLING as you succeed also fights the
  #     established videogame grammar where gauges drain with use.
  #   - OVERSPRAY (a paint-cloud/haze effect that thickens with the streak):
  #     reads as an accident or a mess, not an achievement -- the connotation
  #     runs the wrong direction for a REWARD state, and it is a much harder
  #     read at a glance than a flame (haze density vs. a flame's already-
  #     legible rung count).
  # "On fire" wins because it is an INSTANTLY legible, near-universal idiom
  # for a hot streak (sports broadcasts, other games, playground language a
  # kid already has) that needs zero paintball-specific translation to read
  # -- and the flame chip already ships, so keeping it costs nothing while a
  # switch would cost a full asset + HUD rework for a fiction change with no
  # gameplay upside. STANDING unless Maxwell overrules; flagged explicitly
  # in the /proof report per NATIVE C3's own instruction to write the
  # decision down rather than let it sit as an unstated default.

  HeatLadder* = [1, 2, 4, 8]
    ## Multiplier by rung. x2 is a solo kill, x4 is a few back-to-back, x8 is
    ## a genuine rampage.
    ## ⚠️ UNCALIBRATED STEP SIZE (GLORY C7): the doubling PATTERN is ported
    ## from Muster; `HeatThresholds`/`HeatEmberCap`/`HeatEmberDecay` (the
    ## CADENCE -- how fast you climb and fall the ladder) are the pieces v5
    ## actually re-fit from 3 real hosted episodes (see `GloryVersion`'s own
    ## changelog). The multiplier MAGNITUDES themselves (1/2/4/8, as opposed
    ## to e.g. 1/2/3/5) were never independently measured against how much a
    ## rampage should actually be worth -- only how OFTEN a team should
    ## reach one.
  HeatThresholds* = [2, 5, 10]
    ## Cumulative embers to reach each rung above x1. The first rung costs
    ## TWO embers (v5): one deed is an incident, not a streak -- at
    ## threshold 1 the field showed ~12 lightings/team/episode with a 2.5s
    ## mean lit spell, pure flicker.
  HeatEmberCap* = 11
    ## Just above the x8 floor: a tear maxes the ladder, but no streak can
    ## HOARD heat that survives going quiet. Sized so ONE quiet window
    ## always demotes the top rung (cap - decay < x8 floor: 11-2=9 < 10).
  HeatEmberDecay* = 2
    ## Embers shed per quiet window (v5: was 4 -- a whole rung per window,
    ## which read as a light switch). At 2, a maxed streak cools through
    ## the rungs over ~6 windows (~11s): a visible descent with a story,
    ## still nowhere near Muster's pinned-at-max scar.
  HeatDecayTicks* = 45
    ## Ticks of no drama before a window closes. ~1.9s at 24fps: react within
    ## a decision and a half.

  # ───────────────────────────────────────────────────────────────────────
  # §3  THE SITE GRADIENT — where the deed happened
  # ───────────────────────────────────────────────────────────────────────
  #
  # Muster's within-arena gradient, and the reason it is worth porting: the
  # primitive is TILE OWNERSHIP AT THE DEED SITE, explicitly NOT
  # distance-from-spawn. Ownership is live, arena-local, and needs no
  # home-base anchor.
  #
  # 🚨 That is also the fix for a bug we own. Our `homeSign` is an x-sign
  # against a midline four bases do not have, and every spawn address in the
  # engine is a 2-team formula — so a home/away multiplier built the obvious
  # way would be silently wrong on ffa4, which is half of Elite. Ownership
  # here means NEAREST HOME PEDESTAL (a Voronoi cell over the real pedestal
  # positions), which is correct for 2 and 4 teams by construction and needs
  # no midline at all.
  #
  # Percent, applied as `glory * pct div 100`. Modest by design: Muster's
  # combo table taught it what a layer monopoly costs.

  SiteMultHomePct* = 100      ## your own ground: defending your keep is table stakes.
                              ## ⚠️ UNCALIBRATED (GLORY C7). Ported at
                              ## Muster's own ratio, not fit against a
                              ## paintbot deed-site distribution. 100/150 is
                              ## a directionally-safe design choice (initiative
                              ## into defended ground should never be cheaper
                              ## than sitting on your own pedestal) rather
                              ## than a measured one.
                              ##
                              ## MEASURED (GLORY /proof E2, 2026-08-25): the
                              ## MAGNITUDE is still uncalibrated -- this
                              ## measurement only answers whether the
                              ## home/enemy split has enough spread in the
                              ## field to be worth pricing at all, not what
                              ## the right ratio is. tools/ladder/gloryscore.py
                              ## (post the E1 `FIXED_PEDESTAL` fix, so every
                              ## positioned deed classifies from tick 0, none
                              ## defaulting neutral for lack of an early
                              ## flag_steal) over the same 120-episode cache:
                              ## 5,371 positioned, glory-bearing deed mints
                              ## split 45.4% home (2,436) / 54.6% enemy
                              ## (2,935) -- NOT inert, and not close to the
                              ## >90%-in-one-zone bar that would call the
                              ## gradient dead. Per-deed the split moves with
                              ## the deed's own fiction (`flag_steal` 100%
                              ## enemy -- the theft happens AT the enemy
                              ## pedestal; `carrier_kill`/`capture` 100% home
                              ## -- a non-denial peel lands on the killer's
                              ## own side, a capture completes on the
                              ## scorer's own pedestal; combat deeds split
                              ## close to 40-60 either way). Two deed types,
                              ## `dLevelUp` and `dShieldSoak`, are EXCLUDED
                              ## from this measurement -- both mint with a
                              ## real live x,y in sim.nim's own `awardDeed`
                              ## calls, but gloryscore.py's offline
                              ## re-derivation infers them off-tick (an XP
                              ## threshold crossing, a `blocked` sub-field on
                              ## a damage row) and never threads a position
                              ## through, so they always price neutral
                              ## OFFLINE -- a MIRROR gap, not evidence those
                              ## two deeds are unsited in the real engine.
                              ## Not retuned this wave (measurement only, per
                              ## instruction) -- the 100/150 ratio itself
                              ## remains a design choice.
  SiteMultEnemyPct* = 150     ## initiative into DEFENDED ground.
                              ## ⚠️ UNCALIBRATED, same as `SiteMultHomePct`.
                              ## See its own comment for the E2 field
                              ## measurement (54.6% of positioned deeds land
                              ## here) -- the gradient discriminates, the
                              ## ratio is still a guess.
  SiteMultNeutralPct* = 120   ## the open field.
                              ## 🚨 DEAD IN THIS ENGINE, not merely
                              ## uncalibrated (GLORY C7 audit finding).
                              ## `deedSitePct` is the ONLY caller of
                              ## `siteMultPct` and it hardcodes
                              ## `ownerIsNone = false` unconditionally --
                              ## `groundOwner` is a strict nearest-pedestal
                              ## argmin over `Team` (a 2-value enum today),
                              ## which always resolves to SOME team, never
                              ## "none." No deed can ever price at this
                              ## multiplier; ANY value assigned here is
                              ## unfalsifiable by construction, the same
                              ## unfired-reward-layer class the module
                              ## header's §8 audit exists to catch, just on
                              ## a multiplier branch instead of a deed. Not
                              ## fixed in this wave (C7 is provenance, not a
                              ## behavior change) -- flagged for Maxwell in
                              ## the /proof report; a real "neutral ground"
                              ## concept (e.g. a distance floor past which
                              ## NEITHER pedestal is close) would need to
                              ## exist before this constant can ever fire.

  CarrierHoldMultPct* = 200
    ## Muster's baton, our heart. Holding the enemy heart pays NOTHING per
    ## tick — that is farmable, and the `trophy_held` lesson is that a
    ## per-tick reward always gets farmed. Instead possession LIGHTS A
    ## MULTIPLIER on the carrying team's drama deeds. A passive carrier earns
    ## zero; a carrying team that fights earns double. This also converts the
    ## carry from a pure liability (carrierSpeedPct slows you) into a reason
    ## the whole team wants the heart up.

  # ───────────────────────────────────────────────────────────────────────
  # §4  THE PER-LIFE LADDER — XP, levels, and what a level BUYS
  # ───────────────────────────────────────────────────────────────────────

  MaxLevel* = 5

  LevelThresholds* = [9, 15, 24, 33, 48]
    ## Cumulative XP for levels 1..5, within ONE life. CTF only -- BR reads
    ## these through `BrLevelThresholdMultPct` (below) via `levelForXp`'s
    ## `brMode` param, never bare.
    ##
    ## v9 (GLORY LAW E1, 2026-08-26): RE-FIT -- `XpPerHeal`, `XpPerClutchHeal`,
    ## `XpPerShieldSoak` and the heal-gated `XpPerPickup` all go to 0 this
    ## version (self-care buys no levels), so the xp pool this ladder is fit
    ## against SHRINKS for real, not from a measurement bug like v7's fix.
    ## See `GloryVersion`'s own v9 changelog for the full percentile table,
    ## cadence verification and design-consistency checks (levelForXp(
    ## XpPerSteal)==1, levelForXp(XpPerCapture)==3) -- both still hold.
    ##
    ## v7 (GLORY /proof E3, 2026-08-25): RE-FIT -- every earlier fit at this
    ## constant (2026-08-21's original, and the "byte-identical" 2026-08-25
    ## GLORY C1 re-check below) was measured on a mirror with a THEN-UNKNOWN
    ## bug: gloryscore.py detected med-kit heals off the dead `item_pickup`
    ## branch (0 rows on the wire, at any version -- see GLORY C10's own
    ## commit), so it silently scored ZERO `XpPerHeal`/`XpPerClutchHeal` xp
    ## on every one of the 4,820-4,831 active lives in every prior
    ## measurement -- ALL heal xp was invisible, not merely the pickup xp C1
    ## believed it was isolating. C10 repointed detection at the `heal`
    ## event sim.nim actually emits; this is the first fit run against a
    ## mirror that can see it.
    ##
    ## MEASURED (tools/ladder/gloryscore.py, same 120-episode
    ## `--min-version 0.7.200` selection, post-C10, 2026-08-25): xp peaks
    ## p25:6 p50:9 p75:15 p90:25 p95:34 p98:45 p99:52 (4831/6870 active
    ## lives) -- close to the old blind-to-heal reading (p90 was 24-25
    ## either way) because clutch heals are still rare relative to damage
    ## xp in this field (0.62 kits/Ep vs winners' 1.84-2.60, the gap this
    ## whole mechanic exists to close), not because the bug didn't matter.
    ##
    ## REFIT to the documented design anchors: L1 just above p50 (9) ->
    ## unchanged at 10 (p56.4); L3 ≈ p90 (25) -> 27, which lands AT p90.0
    ## exactly (10.00% of active lives clear it); L5 just past p99 (52) ->
    ## 55 (p99.2). L2 (19, p81.8) and L4 (40, p96.7) interpolate between
    ## their neighbors on the same curve, same as the original fit's shape.
    ## VERIFIED cadence against the design targets: L3+ lives per
    ## team-episode 2.01 mean (target ~2, was 2.62 under the shipped
    ## [10,18,24,36,50] -- measurably too easy once heal xp actually counts),
    ## L5 lives per episode 0.33 mean (target ~0.3, was 0.50). Sanity
    ## (unchanged design facts): `levelForXp(XpPerSteal)` == 1,
    ## `levelForXp(XpPerCapture)` == 3 -- both still hold at 12 and 30
    ## against L1=10/L2=19 and L3=27/L4=40 respectively.
    ##
    ## The shape is Muster's rolestreak ladder (per life, reset on death),
    ## NOT its veterancy ladder (career, never resets). Paintbot has no
    ## career, so we get to ship ONE ladder and skip the scar Muster carries:
    ## its two 5-star ladders sit ~4x apart, and any analysis joining them
    ## joins on a false key. The earlier [12,30,60,100,160] was guessed
    ## against kill-based xp and made L5 a never-an-episode legend (0 in 120
    ## real episodes) -- superseded by the 2026-08-21 work-based fit, itself
    ## now superseded by this one.

  BrLevelThresholdMultPct* = 200
    ## GLORY v11 (BR increment 3): `LevelThresholds` scaled by this percent
    ## for a `brMode` episode ONLY (`levelForXp`'s `brMode` param) -- CTF
    ## reads the bare table, unaffected.
    ##
    ## BR's xp pool is a fraction of CTF's by construction: it is
    ## damage-only (every heal/pickup/shield xp source is zeroed by the v9
    ## self-care law, and BR ships no flag play to draw `XpPerSteal`/
    ## `XpPerCapture` from -- flagless, per `glory.nim`'s header). With the
    ## default 3 hp per cog and `XpPerDamage=3`, ONE FULL KILL ("a tag")
    ## lands 9xp -- exactly the unscaled L1 threshold, so a single kill
    ## insta-levels, and the unscaled L5 (48xp) needs only ~5.3 solo kills
    ## to cap a cog's buffs for the rest of the one-life episode --
    ## `resetLadder` (the anti-snowball rule) cannot rescue this the way it
    ## does in CTF, because in BR the death that triggers it is ALSO the
    ## cog's permanent elimination; there is no next life to reset FOR.
    ##
    ## Design target (Maxwell's ruling): the median episode WINNER should
    ## reach L3-L4 by endgame, with L5 exceptional, not the default
    ## outcome. Re-simulated two fresh 16-duo BR episodes end to end
    ## (`dump_glory_from_replay`'s multiplier-sweep table, 2026-08-30:
    ## `tests/fixtures/br-golden-16team.bitreplay` and a fresh recording
    ## at the SAME map/seed the stale, unloadable `rt_episode/
    ## episode-s830.bitreplay` fixture (pre-GameVersion-bump, refuses to
    ## even parse) was named for) -- both, played by the plain baseline
    ## policy on every one of the 32 seats, topped out at only 18-21 FINAL
    ## xp for the most active cog in the whole match (2-3 kills' worth),
    ## nowhere near even the UNSCALED L3 (24xp): the simple baseline bot
    ## measurably under-plays the aggressive, diverse-policy field the
    ## 5.3-tag capping problem above was measured against, so neither
    ## local re-sim can pin an exact real-field percentile. What both DO
    ## confirm: the unscaled table's own arithmetic problem (a solo kill
    ## insta-leveling) and that doubling every rung directly fixes it
    ## without over-correcting into unreachable -- the same "an unreached
    ## gate is the same failure as a mistuned one" law this project
    ## already holds every other threshold to. 200% moves what WAS the
    ## L5 floor (48xp, ~5.3 kills) to the NEW L3 (48xp again, now the
    ## midpoint of the ladder instead of its ceiling) and pushes L5 to
    ## 96xp (~10.7 solo kills) -- a genuinely exceptional single-life
    ## haul, while L1 (18xp, 2 kills) no longer insta-levels off one tag.
    ## Re-derive this against a real, diverse-policy BR corpus once one is
    ## available; a flat, unreasoned 4x (400%, L5 = 192xp ≈ 21.3 solo
    ## kills in one life) was considered and rejected for pushing L5 from
    ## "exceptional" into "practically unreachable" -- the same
    ## unfired-gate failure class this project's own memory of unreachable
    ## gates (§7's layer-monopoly sibling) already warns against.

  # ── What levels a cog: WORK, not kills (Maxwell's ruling, 2026-08-21) ──
  #
  # TWO CURRENCIES, TWO QUESTIONS -- keep them split:
  #
  #   XP     (this block)  per-COG. Pays the PROCESS: damage landed, healing
  #                        taken, tools picked up, flag play. Drives the
  #                        ladder and therefore the buffs. Kills pay ZERO.
  #   GLORY  (DeedGlory)   per-TEAM. Pays OUTCOMES and DRAMA: kills,
  #                        multikills, ace tags, the peel, first blood --
  #                        all still priced in full, through heat and the
  #                        site gradient. Glory is the show; xp is the work.
  #
  # A kill is an OUTCOME -- the last-hit lottery on damage mostly dealt by
  # someone. So it belongs to the glory ledger, not the ladder. This is also
  # Muster's own hardest-won reward law ("reward the EFFECT that lands,
  # never completion") applied to the ladder: every xp source below is
  # either effect-landed (damage, soak) or naturally rate-limited by the map
  # (pickups respawn on 30s timers), so no source can be farmed by repeating
  # a free action. A future re-tune that makes a kill grant xp, or a deed
  # price depend on the killer's level, is crossing the streams -- don't.
  XpPerDamage* = 3            ## per hit point landed on an enemy, ANY weapon
                              ## -- the workhorse, and the reason gun, spray
                              ## and grenade use all level a cog exactly in
                              ## proportion to what the tool actually did.
  XpPerHeal* = 0              ## v9 (GLORY LAW E1): was 3/hit point restored.
                              ## Self-care buys no levels -- healing YOURSELF
                              ## is not above-and-beyond, it is the cog buying
                              ## its own life back (ground truth: no mechanic
                              ## heals another player, so every heal xp mint
                              ## this constant ever fed was self-benefiting by
                              ## construction). The mint sites
                              ## (`tryPickupMedKits`/`tryPickupSupplyDrops`,
                              ## sim.nim) stay wired -- `XpPerPickup +
                              ## XpPerHeal * healed` now always contributes 0,
                              ## structurally inert rather than deleted, the
                              ## same "keep the fire counter honest" choice
                              ## `dClutchHeal` makes.
  XpPerClutchHeal* = 0        ## v9 (GLORY LAW E1): was 6, the save-at-1-hp
                              ## bonus ON TOP of the restore -- same self-care
                              ## reasoning as `XpPerHeal`, doubly so (this was
                              ## the MORE celebrated half of a self-heal).
  XpPerPickup* = 0            ## v9 (GLORY LAW E1): was 4. Its only remaining
                              ## payer was the med-kit heal path (every other
                              ## pickup site already zeroed this in v6, GLORY
                              ## C1) -- a self-heal, so it goes to 0 with
                              ## `XpPerHeal`/`XpPerClutchHeal` rather than
                              ## surviving as an orphaned "just for touching a
                              ## kit" xp source (which the v6 ruling had
                              ## already banned everywhere else). The mint
                              ## sites stay wired, same discipline as above.
  XpPerShieldSoak* = 0        ## v9 (GLORY LAW E1): was 2/hit point absorbed.
                              ## Ground truth: a shield protects ONLY its
                              ## wearer, so soaking is self-preservation, not
                              ## team funding -- the same self-care class as
                              ## the heal constants above, just on the
                              ## survival side of the ladder instead of the
                              ## support side. `dShieldSoak` itself (the GLORY
                              ## mint, distinct from this XP grant) is KEPT --
                              ## see its own comment on `Deed` for why that is
                              ## not a contradiction (it was never celebrated
                              ## to begin with).
  XpPerSteal* = 12            ## flag actions are the objective spine.
                              ## DESIGN-CONSISTENCY CHECK (GLORY C7, not a
                              ## field-fit): with `LevelThresholds`
                              ## [9,15,24,33,48] (v9), `levelForXp(XpPerSteal)`
                              ## resolves to exactly L1 -- a steal alone
                              ## promotes a fresh life to L1 and no further.
                              ## `tests/test_glory.nim`'s "thresholds make
                              ## L5 rare and L1 reachable" asserts the
                              ## `>= 1` half of that (a steal reaches AT
                              ## LEAST L1). Intentional: the objective
                              ## spine should always read as SOME progress.
  XpPerCapture* = 0
    ## v12 TOMBSTONE (was 30; contract §5, Maxwell's 2026-08-31 ruling): the
    ## payment lands on a game that is already over -- per-life buffs and
    ## supply credit can never matter -- so a capture no longer pays xp.
    ## Constant stays (orphaned-consts-are-tombstones convention), the
    ## `addXp(carrierIndex, XpPerCapture)` mint site in `checkWinCondition`
    ## (sim.nim) stays wired, and the deed/counter cadence
    ## (`dCapture`/`deedCounts`) keeps tracking exactly as before -- the §8
    ## audit still sees the site FIRE, just for nothing.
    ##
    ## (The old DESIGN-CONSISTENCY CHECK here -- `levelForXp(30) == 3`, "a
    ## capture is an instant power spike" -- died with the value; the
    ## capture's reward is the win itself.)
  XpPerReturn* = 12
    ## The heart returns home when its carrier dies, so in THIS game the peel
    ## IS the return: killXp prices the carrier kill as this FLAG ACTION, not
    ## as a kill. (This constant shipped dead once -- declared, zero
    ## consumers -- the third instance of the dead-layer class in this
    ## project. The mirror tool gloryscore.py greps would have caught it;
    ## now the wire is killXp itself.)
    ## ⚠️ UNCALIBRATED (GLORY C7): set equal to `XpPerSteal` on the
    ## reasoning that both are flag-spine actions of comparable weight, not
    ## measured independently.
  XpTeamKill* = -20
    ## Friendly fire actively DE-LEVELS you. The one place the ladder bites
    ## back, and it is aimed at the loss that was once 0.81 lives/Ep.

  AceLevel* = 3
    ## Killing a cog at this level or above pays `dAceTag`. This is the
    ## mechanic that makes a levelled enemy a walking bounty and your own
    ## veteran worth escorting — the reason the power fantasy does not run
    ## away with an episode. It is also the level the crowd can SEE: at
    ## AceLevel a cog wears the ember plume (`LabelVeteranMark`) and its
    ## team's heart starts producing kit (the supply drop, below).

  # ── THE SUPPLY DROP: a 3-star cog makes their own heart produce kit ─────
  #
  # Maxwell's rule: at 3 stars a cog gets a particle effect and items start
  # spitting out of their team's heart. The fantasy is the point — a
  # levelled cog visibly PAYS THE TEAM, so the crowd watches the veteran and
  # the team plays around it.
  #
  # 🚨 The obvious implementation is the exact shape of a failure Muster
  # already paid for. Its bomber reward was `cluster_value x proximity x
  # readiness`, which paid 1-3 per tick forever once the bomber was armed and
  # in position — "a rational agent farms the shaping by hovering." The rule
  # banked from it: *for any commit-to-an-action design the potential MUST
  # FLATLINE once the preconditions are met; real reward comes only from the
  # terminal action.* A heart that drips kit for every tick a 3-star cog is
  # ALIVE pays for being-in-a-state, and the optimal play becomes: hit 3
  # stars, then go hide behind a wall and collect.
  #
  # So the tap is fed by EARNING, not by STANDING. Every SupplyDropXp points of
  # NEW xp scored at AceLevel or above drops one pickup at the team's
  # own heart. A veteran that keeps fighting keeps the kit coming; a veteran
  # that hides produces exactly nothing, because xp only moves on landed
  # effect. This is Muster's own fix for the same bug — v12 made the combo
  # bonus MULTIPLY the damage and kills the combo actually landed, and the
  # reward layers flipped back the same day ("can't farm combos without
  # dealing damage").
  #
  # Both caps below are anti-farm bounds, not flavour. Muster's glory law 8
  # is that glory must be FINITE per game, and its ember cap exists so no
  # streak can hoard a multiplier it stopped earning.

  SupplyDropXp* = 20
    ## New xp per pickup produced. At XpPerDamage 3 that is roughly a
    ## pickup every 7 hit points landed once the plume is lit.
  SupplyDropCooldownTicks* = 90
    ## Minimum ticks between two pickups from one heart, so a single
    ## multi-kill burst cannot dump the whole allowance at once.
  SupplyDropMaxPerLife* = 4
    ## Hard ceiling per cog per LIFE. With the per-life reset this bounds the
    ## whole mechanic: a team's kit income is capped by how many veterans it
    ## can keep alive, and every one of them is a `dAceTag` bounty.

  # ── The kit cycle a supply drop rotates through ─────────────────────────
  # Fixed rotation rather than a roll: the sim's RNG draws are load-bearing
  # for replay determinism, and a rotation needs none. Medkit leads because
  # our heal rate is the measured gap (0.62/Ep against winners' 1.84-2.60).
  SupplyDropCycle* = ["med kit", "grenade", "spray can", "shield"]

  # ── What each level BUYS ────────────────────────────────────────────────
  #
  # Muster grants no mechanical power at all: a 5-star champion has the same
  # speed, damage, hp and vision as the recruit beside it, and the ruling in
  # `unit_skill_trees.py` is explicit that this is deliberate — "a unit's
  # strength CAUSES its star count, not the reverse. This is pure
  # measurement." We are inverting that on purpose.
  #
  # The ladder is built so that every rung grants a distinct CAPABILITY
  # rather than a bigger number, so a levelled cog plays differently instead
  # of just harder. Values are cumulative and applied at five integer sites
  # in `sim.nim`; all arithmetic stays integer.
  #
  #   L1 Tagger     windup -1 tick        the lead we measured at +70pp
  #   L2 Marksman   spray reset -40%     the spray finally recycles
  #   L3 Ironhide   +1 max hp             now a real threat -- and a bounty
  #   L4 Quickdraw  fire cooldown -25%,   rate of fire, and two nade charges
  #                 grenade holds 2
  #   L5 Legend     windup -1, carry     the once-an-episode legend (hp
  #                 penalty waived        ceiling stops climbing at L3 --
  #                                       capped by the ~2x power bound)
  #
  # ⚠️ A raised max hp does NOT heal the cog. Levelling grants HEADROOM only;
  # the hit points must still be earned back from a med kit. Otherwise a
  # level-up is a free full heal at the exact moment you are winning a
  # fight, which is the snowball we are trying to bound.

  LevelWindupDelta*: array[0 .. MaxLevel, int] = [0, -1, -1, -1, -1, -2]
    ## Ticks off the trigger windup (FireWindupTicks 5 -> 4 at L1, -> 3 at L5).
  LevelGunRangePct*: array[0 .. MaxLevel, int] = [100, 100, 100, 100, 100, 100]
    ## v6 (GLORY C2): the +15% range rung ("Marksman", L2+) is RETIRED --
    ## geometrically dead on arrival. The default arena is 1235x659px, a
    ## 1399.8px diagonal; `GunRange` (sim.nim) already ships at 1300, ~93% of
    ## that diagonal. +15% pushes the levelled range to 1495px, PAST the
    ## longest line of sight the map can ever draw -- no shot at any level
    ## can be range-gated by a buff that only extends reach beyond the
    ## farthest two points on the board are ever apart. It never fired, on
    ## any map, for any cog: an unreachable number is the same dead-lever
    ## class the module header's §8 audit exists to catch, just geometric
    ## instead of behavioural. L2 keeps ONLY its spray-reset -40% now; see
    ## `tests/test_glory.nim`'s power-cap and ladder-monotonicity checks,
    ## which still pass at 100% flat (the ladder's L1->L2 step is now a tie
    ## on this component and carried entirely by the spray-reset).
  LevelBonusHp*: array[0 .. MaxLevel, int] = [0, 0, 0, 1, 1, 1]
    ## Hit points added to the base ceiling. Capped at +1 TOTAL (reached at
    ## L3): the original +2-at-L5 measured 2.69x effective power against the
    ## ~2x balance bound and was cut. A L4 cog at 4 hp also stays clear of
    ## the shield carrier's 6, the band policies already read.
  LevelFireCooldownPct*: array[0 .. MaxLevel, int] = [100, 100, 100, 100, 75, 75]
    ## Ticks between shots, as a percentage of the configured cooldown.
  LevelSprayResetPct*: array[0 .. MaxLevel, int] = [100, 100, 60, 60, 60, 60]
    ## Spray-can recharge, as a percentage of PlasmaArcResetTicks. The spray
    ## is 28.5% of all kills and we historically left 87% of cones unfired.
  LevelGrenadeCharges*: array[0 .. MaxLevel, int] = [1, 1, 1, 1, 2, 2]
    ## Throws a single pickup yields.
  LevelCarrierSpeedWaived*: array[0 .. MaxLevel, bool] =
    [false, false, false, false, false, true]
    ## At L5 the heart no longer slows you.

  LevelNames*: array[0 .. MaxLevel, string] = [
    "recruit", "tagger", "marksman", "ironhide", "quickdraw", "legend"
  ]
    ## What the feed and the replay pip call each rung.

  # ── Deed detection geometry ─────────────────────────────────────────────
  PointBlankPx* = 110
    ## The duel won at arm's length — and a number that has already been
    ## wrong once.
    ##
    ## 🚨 At 150 this deed was not a rare-skill bonus, it was the DEFAULT
    ## KILL. Re-simulated league episodes minted `dPointBlankKill` 19.5x per
    ## episode against `dHonorableKill`'s 18.4: the floor was outpaid on the
    ## median kill. That is precisely the layer-monopoly failure §7 is written
    ## about — a deed does not need to be mispriced to bury the table, it only
    ## needs to be EASY TO CO-SATISFY.
    ##
    ## Re-cut from the shooter-to-victim distance of every kill in the scout
    ## cache: 7,758 live 2-team episodes, coworld 0.7.229-231, 2026-08-13..20,
    ## 306,506 kills. Distance is read from `shot_impact.distance`, which the
    ## engine itself computes at the impact site, cross-checked against a
    ## rebuild from the killer's own last position at |diff| = 0.0px on 12,381
    ## paired kills. The live field kills at p10=92, p15=123, p25=168,
    ## p50=209px, with a hard standoff spike at 180-219px that holds 26% of
    ## all kills and appears in EVERY policy in the league. So 110px catches
    ## 12.8% of kills — the intended 10-15% band — where 150px caught 20.2%.
    ##
    ## ⚠️ The old 150 came from a SHOT statistic (accuracy 0.517 inside 150px
    ## against a field ~0.72) and was then used to price KILLS. Shots cluster
    ## much closer than the kills they produce; that mismatch is how a
    ## rare-skill deed ended up on the median kill.
    ##
    ## ⚠️ Two live scars are baked into this number.
    ##   1. ENGINE CHURN EXPIRES A MEASUREMENT. The identical query over the
    ##      July `Default` era (coworld 0.7.91-0.7.174) reports p50=141px and
    ##      53% of kills inside 150px — the field has since learned to fight
    ##      at a standoff. Same arena (1235x659), so this is behaviour, not
    ##      scale. Re-derive this constant on an engine bump; never inherit it.
    ##   2. ONE PIXEL RADIUS CANNOT BE RARE IN BOTH MODES. On the same engine,
    ##      ffa4 kills at p50=152px (four teams share one arena), so 110px
    ##      fires on 32% of ffa4 kills against 12.8% of 2-team kills. That
    ##      split is irreducible with a single constant, and it is WHY the
    ##      price came down to 12 as well: at a +20% premium over the
    ##      `dHonorableKill` floor of 10, a radius that mis-fires on a mode
    ##      costs the ledger a rounding error instead of re-rating every kill.
    ##      A radius alone would have left ffa4 paying 16 on a third of kills.
  LongshotPx* = 700           ## no field shot has ever damaged past 832px.
  DenialPx* = 600             ## a carrier killed this close to their own
                              ## pedestal died on the doorstep.
                              ##
                              ## v6 (GLORY C5): field-fit, replacing the
                              ## uncalibrated 220. "Doorstep" (`treeDefender`
                              ## II) claimed 0.0% in the field at 220 (n=240
                              ## team-episodes) -- the value was reasoned
                              ## from combat-band intuition ("close range"),
                              ## never measured against where a carrier
                              ## actually dies.
                              ##
                              ## OPERATIONALIZATION: this arena's two home
                              ## pedestals are FIXED, not per-episode/seed
                              ## (measured directly: (186,329) and
                              ## (1049,329) across every recovered
                              ## flag_steal in the cache, stdev 0.0 on both
                              ## axes -- 863px apart). So every carrier kill
                              ## in the 120-episode sample can be scored
                              ## against its victim's OWN team's true
                              ## pedestal directly (no per-episode recovery
                              ## needed, unlike the site gradient's own
                              ## flag_steal-coordinate approximation) --
                              ## dist(kill site, victim's own pedestal),
                              ## same event ordering fix the module
                              ## docstring's own "kills sort BEFORE same-tick
                              ## flag_return" note requires.
                              ##
                              ## MEASURED (157 carrier kills, matching the
                              ## DEEDS report's 1.31/ep x 120 exactly):
                              ## p5=343 p10=401 p15=436 p20=483 p25=536
                              ## p30=561 p40=638 p50=776 p75=859 p90=867px.
                              ## HALF of all carrier kills land PAST 776px --
                              ## a carrier is caught mid-field or near the
                              ## STEAL site far more often than near
                              ## completing the run, which is why 220 (a
                              ## PointBlankPx-scale number) could never fire.
                              ## 100/240 team-episodes (41.7%, matching "The
                              ## Peel"'s own T1 rate exactly) have ANY
                              ## carrier kill at all -- the hard ceiling any
                              ## DenialPx can reach.
                              ##
                              ## 600px lands Doorstep's team-episode claim
                              ## rate at 17.5% (42/240) -- inside the 10-30%
                              ## tier-II band, comfortably clear of both the
                              ## 41.7% ceiling and zero. (For reference:
                              ## 470-480px -> 10.0%, 700px -> 20.8%.)
                              ##
                              ## v7 (GLORY /proof E1, 2026-08-25):
                              ## RECONCILED three disagreeing Doorstep reads
                              ## -- 4.6%, 17.5% (this comment, above), 34%.
                              ## Root cause traced to tools/ladder/gloryscore.py:
                              ## its mirror used to RECOVER these same-fixed
                              ## coordinates per episode from `flag_steal`
                              ## events instead of hardcoding them, which
                              ## needs team(t)'s OWN flag to have ALSO been
                              ## independently stolen (by the enemy, an
                              ## unrelated act) SOMEWHERE EARLIER in that
                              ## same episode before it can resolve a denial
                              ## at all. Traced directly: 44 of 56 true
                              ## denials (78.6%) were invisible to that
                              ## mirror for exactly this reason, landing it
                              ## at 4.6% (11/240) instead of 17.5%. (The 34%
                              ## read: `denials / carrier_kills` = 56/157 =
                              ## 35.7%, a PER-KILL rate mistaken for the
                              ## achievement's own PER-TEAM-EPISODE claim
                              ## unit -- a team only needs ONE denial to
                              ## claim, so the two units diverge once a team
                              ## banks more than one.) Fixed in gloryscore.py
                              ## (`FIXED_PEDESTAL`, seeded from tick 0 --
                              ## these coordinates need no event to learn
                              ## them, they are a map constant); re-run
                              ## confirms 17.5% (42/240) EXACTLY, so this is
                              ## the correct operationalization and `DenialPx`
                              ## needs no further move.

  CtfReferenceGunRange* = 1050
    ## The map `gunRange` (sim_types.nim's stock `GunRange`, what every
    ## classic CTF map ships with, arena.nim: "fixed, never scaled with the
    ## field") that `PointBlankPx`/`LongshotPx`/`DenialPx` above were each
    ## fit against. GLORY v11 (2026-08-30, BR increment 3 measurement):
    ## these three were absolute pixel constants, silently assuming every
    ## map shares CTF's own gunRange. BR does not -- `br-golden-map.json`
    ## ships `gunRange: 331`, less than a third of the reference. Priced
    ## unscaled, `PointBlankPx` (110px, 10.5% of 1050) becomes 33.2% of
    ## BR's 331 -- inflated from a rare duel-range bonus into the MODAL
    ## kill, the exact layer-monopoly failure `PointBlankPx`'s own v2 cut
    ## already fixed once for CTF. `LongshotPx` (700px) EXCEEDS BR's whole
    ## gunRange outright -- structurally dead, taking gun-tree tier V
    ## ("Sharpshooter") down with it. `pointBlankPxFor`/`longshotPxFor`/
    ## `denialPxFor` below re-derive each as the SAME fraction of
    ## whichever map's gunRange is actually live, so a non-standard
    ## gunRange reprices proportionally instead of silently drifting the
    ## deed's real-world rarity. Every classic CTF map ships gunRange ==
    ## this constant (arena.nim never scales it with the field), so the
    ## three accessors return their unscaled reference constants there --
    ## byte-identical pricing to before this version for every 2- and
    ## 4-team fixture in the suite; only a non-reference gunRange (BR
    ## today) sees a different number.
  PointBlankPermille* = 105   ## round(110 * 1000 / 1050).
  LongshotPermille* = 667     ## round(700 * 1000 / 1050).
  DenialPermille* = 571       ## round(600 * 1000 / 1050).

  RevengeTicks* = 240         ## ~10s to answer your killer.
                              ## ⚠️ UNCALIBRATED (GLORY C7): a round
                              ## 10-second design choice (matching
                              ## `HeatDecayTicks`'s own ~1.9s-per-window
                              ## register of "seconds a crowd can track"),
                              ## not fit against a measured
                              ## time-to-respawn-and-re-engage distribution.
                              ## Same constant gates both `dRevengeKill` and
                              ## the "Turnaround" achievement (peel then
                              ## steal within the window) -- a real field
                              ## measurement of typical respawn-to-re-engage
                              ## latency would calibrate both at once.
  ContestedStealPx* = 300     ## a live enemy within this radius at the
                              ## moment the heart leaves its pedestal makes
                              ## the steal CONTESTED, not a walk-in -- the
                              ## `Hands On` gate (law 2b's ruling below: an
                              ## uncontested pickup is not an achievement).
                              ## ⚠️ UNCALIBRATED, same honesty as
                              ## `AchievementSweepBudgetPct`: reasoned from
                              ## the existing combat bands (wider than
                              ## `PointBlankPx`'s duel range, tighter than a
                              ## gun's full reach) rather than fit from a
                              ## measured contest rate. Re-derive once a
                              ## field query for "enemy proximity at steal
                              ## time" exists.
  KitLegsImplemented* = 3     ## v12 (Amendment 1): how many kit-conversion
                              ## legs `teamConvertedKits` (sim.nim) can
                              ## actually count on this port -- nade, spray,
                              ## shield; the med leg reads `supplyShared`,
                              ## which does not exist here (GLORY-PORT-TODO
                              ## on `teamConvertedKits` itself). "Victory
                              ## Lap" gates on `kits >= KitLegsImplemented
                              ## and anyCapture` so the tier means "every
                              ## kit this engine can field, converted, plus
                              ## a capture" instead of being structurally
                              ## dead. When the med leg lands, restore the
                              ## design gate by setting this to 4 -- ONE
                              ## constant, no gate rewrite ("Full Kit"'s
                              ## tombstone in `satisfiedAchievements` lifts
                              ## with the same landing).
  FastBreakTicks* = 240       ## the `Fast Break` gate (v8, GLORY C3c
                              ## replacement): steal the heart and capture it
                              ## within this many ticks of the steal, same
                              ## life. FIELD-FIT (2026-08-25, n=103 real
                              ## steal->capture deltas): p10=210, p25=244,
                              ## p50=358 -- 240t sits just inside the first
                              ## quartile and qualifies 22.3% of real
                              ## captures, a genuine tier-V speed-run band
                              ## (rare enough to chase, not a floor every
                              ## capture already clears the way the old "Full
                              ## Run" requirement did). Coincidentally the
                              ## same magnitude as `RevengeTicks` (~10s), but
                              ## fit independently off its own distribution,
                              ## not copied from it.

  ClutchHpThreshold* = 1      ## v9 (GLORY LAW E1/E3): "at/near clutch hp" --
                              ## the same "1 hp" line `tryPickupMedKits`'
                              ## `onOneHp` already used inline, now named so
                              ## E3's damage-site "menacing" pin (sim.nim: a
                              ## hit that leaves an ENEMY at or below this
                              ## reads as putting them in mortal danger) and
                              ## E2's supply-drop "save" pin (a teammate
                              ## consumed my drop while at or below this)
                              ## share ONE definition of clutch instead of
                              ## two independently-chosen numbers.
  AssistWindowTicks* = 120    ## v9 (GLORY E3, new): the victim's last enemy-
                              ## inflicted damage counts toward an ASSIST for
                              ## its dealer only if the eventual kill lands
                              ## within this many ticks. ⚠️ UNCALIBRATED (no
                              ## field data exists for this counter yet) --
                              ## reuses the pre-v9 Second Wind window's own
                              ## magnitude (120t, ~5s) as the design register
                              ## for "recently," not an independent fit.
  RescueWindowTicks* = 120    ## v9 (GLORY E3, new): a RESCUE credits the
                              ## killer only if the victim's own `menacingTick`
                              ## (sim.nim: the last time THAT cog put one of
                              ## the killer's teammates at/near clutch hp) sits
                              ## inside this window. ⚠️ UNCALIBRATED, same
                              ## honesty as `AssistWindowTicks`.
  SecondWindTicks* = 120      ## v9 (GLORY E3): RE-GATED, not re-measured --
                              ## this is the exact 120-tick magnitude the
                              ## pre-v9 self-heal Second Wind used inline
                              ## (`killPlayer`'s old `clutchHealTick` check),
                              ## now named and re-pointed at `rescuedTick`
                              ## instead. The comeback beat's TIMING is
                              ## unchanged; only WHAT arms it moved (rescued,
                              ## not self-healed).
  SquadVolleyWindowTicks* = 90 ## v9 (GLORY E3, new): the team kill-ring
                              ## window for `Squad Volley` -- 3+ DISTINCT
                              ## teammates each landing a kill inside this
                              ## span. ⚠️ UNCALIBRATED. Deliberately TIGHTER
                              ## than the 120t windows above (~3.75s vs ~5s):
                              ## a "volley" should read as one coordinated
                              ## burst, not three separate fights strung
                              ## together by a generous clock.
  SquadVolleyMinDistinct* = 3 ## how many DIFFERENT teammates must each land
                              ## a kill inside the window -- the whole point
                              ## is that no single cog can trigger this alone.
  SquadVolleyRingCap* = 8     ## hard cap on the per-team recent-kill ring
                              ## (killerIndex, tick) sim.nim keeps -- "a
                              ## small ring," bounded so a long quiet-then-
                              ## bursty episode cannot grow it forever.

  # ───────────────────────────────────────────────────────────────────────
  # §5  THE ACHIEVEMENT CURRICULUM
  # ───────────────────────────────────────────────────────────────────────
  #
  # Muster runs 18 trees keyed on UNIT TYPE. Paintbot has one cog, so the
  # tree axis is the KIT — which is the better axis here anyway, because our
  # measured defect is conversion, not access: we hold the best kit access in
  # the league and heal 5.9x worse, hold cans 35% longer and fire them half
  # as often, and walk past uncontested shields. A curriculum keyed on kit
  # CONVERSION is aimed at exactly that.
  #
  # THE FOUR LAWS, each a scar carried over intact:
  #   1. One-shot per team per episode, NEVER per tick. Per-tick rewards get
  #      farmed (Muster's `trophy_held`).
  #   2. Every team can earn every tier; the FIRST team in the episode to
  #      complete one claims at AchievementFirstMultPct. A first-only reward
  #      teaches the other three teams nothing.
  #
  #      🚨 v9 (GLORY LAW E4, Maxwell: "no more than a quarter of all
  #      possible achievements should be firsts"): the race itself -- the
  #      "FIRST!" marker AND the AchievementFirstMultPct bonus -- is now
  #      restricted to TIER V of each tree. Tiers I-IV are NEVER first-
  #      raced: every team that clears one banks the same base price,
  #      always, whether it got there first or last. 8 of the 40 possible
  #      claims (one tier V per tree, 8 trees) can ever be a FIRST -- 20%,
  #      under the 25% ceiling. Enforced ONCE, inside `claimAchievement`
  #      itself (sim.nim), so no caller can accidentally pass a tier-I claim
  #      through as a race.
  #   2b. No achievement ever pays for travel, arrival or departure. Movement
  #      is how you reach plays; it is not a play.
  #
  #      🚨 RULING (Maxwell, 2026-08-24), extending 2b for the v3 curriculum
  #      rewrite: "these are things where the player goes above and beyond
  #      normal gameplay, not rewarding them for just normal gameplay." An
  #      act that already carries its own benefit -- a pickup heals you or
  #      arms you, arrival anywhere pays for itself mechanically -- is NOT an
  #      achievement; the game already paid you once for doing it. So NO
  #      pickup/possession/arrival requirement may exist ANYWHERE in the
  #      curriculum. v3 deletes "Shake It" (pick up a spray can), "Pull the
  #      Pin" (pick up a grenade), "Suit Up" (pick up a shield), "Field
  #      Dressing" (take a med kit) and "Eyes Back" (a heart return -- which
  #      also happened to retire the corrupt `returns` counter; see
  #      `resetFlag`'s bystander-credit note in sim.nim) outright, and
  #      replaces every kit tree's tier I with the CONVERTED act the pickup
  #      was only ever a precondition for.
  #
  #      🚨 v3.1 (2026-08-24, CURRICULUM audit C1/C8): the SAME rewrite
  #      missed `treeCarrier` tier I/II ("Hands On"/"Breakaway"), which read
  #      `steals >= 1` (an uncontested pickup) and live `carryingFlag` plus a
  #      hold timer (pure possession-plus-duration) -- exempted only by a
  #      comment ASSERTING "stealing, holding and scoring the enemy heart are
  #      all already above ordinary play," which directly contradicts this
  #      ruling's own text two paragraphs up. Re-cut to the same standard:
  #      tier I now needs a CONTESTED steal (a live enemy within
  #      `ContestedStealPx`), tier II a kill made WHILE CARRYING (not mere
  #      possession). See the tree's own comment below for the counters.
  #   3. Big enough to chase, too small to win on: a full sweep must stay
  #      under AchievementSweepBudgetPct of a median winner's episode glory.
  #      `tests/test_glory.nim` sums the table and asserts it.
  #   4. Achievements NEVER climb the heat ladder — only combat drama does.
  #      `paysHeat` is the enforcement.

  AchievementTrees* = 8
  AchievementTiers* = 5

  TierGlory*: array[AchievementTiers, int] = [9, 11, 14, 18, 23]
    ## v9 (GLORY LAW E5, "the +2 problem"): RE-ANCHORED off [2, 4, 8, 16, 32]
    ## -- a clean power-of-2 ladder whose tier I paid 2g next to
    ## `dHonorableKill`'s 10g floor, an order of magnitude under "a solid
    ## deed," and whose tier V (32g) barely read as an event next to
    ## `dAceTag` (40g). Re-anchored so tier I (9g) sits just under a plain
    ## kill and tier V (23g, 69g first-claimed at tier V's own
    ## `AchievementFirstMultPct`) sits in the `dAceTag`(40)/`dCarrierKill`(90)
    ## neighborhood -- a real event, not a footnote. Escalation is now
    ## +2/+3/+4/+5 rather than a flat doubling, a deliberately ACCELERATING
    ## curve (the gap between neighbors grows, so the top of the ladder feels
    ## like it is pulling away, not just repeating the same multiplier).
    ##
    ## Solved directly against the hard constraint: `tests/test_glory.nim`'s
    ## "law 3 -- big enough to chase, too small to win on" asserts
    ## `sum(TierGlory) * AchievementTrees < dCapture + dWipe` (unchanged this
    ## wave: 250 + 400 = 650) -- 75 * 8 = 600, clearing it with room (50g,
    ## ~8%) rather than shaving the ceiling to the last integer. `tierGlory(4)`
    ## = 23 stays well under `dCapture` (250), so no single tier rivals the
    ## win condition it sits beside, first-claimed or not.
    ##
    ## The BASE magnitude is still a design choice, not a field-fit (no
    ## measured "what should a first tag be worth" number exists for
    ## paintbot) -- what changed is the ANCHOR it is designed against (the
    ## deed table's own floor and mid-tier, not an arbitrary "2"). See
    ## `AchievementSweepBudgetPct`'s own comment for the re-measured share of
    ## a median winner's episode glory this new ladder actually costs in the
    ## field.
  TierDrama*: array[AchievementTiers, int] = [5, 5, 15, 15, 30]  ## tenths
    ## ⚠️ UNCALIBRATED (GLORY C7): law 4 (achievements never climb heat) is
    ## enforced regardless of this table's values -- `paysHeat` excludes
    ## `dAchievement` outright -- so these tenths only feed the replay feed's
    ## own moment-ranking, never the ledger's rampage state. No field
    ## measurement backs the specific step shape (flat T1-T2, flat T3-T4,
    ## jump at T5); it mirrors `TierGlory`'s doubling by eye.
  AchievementFirstMultPct* = 300
    ## The first team in the episode to complete a tier claims at x3.
    ##
    ## 🚨 v9 (GLORY LAW E4): only reaches tier V now (`AchievementTiers - 1`)
    ## -- see law 2's own comment above for the 25%-of-40 ceiling this
    ## restriction is sized against. Tiers I-IV never read this constant at
    ## all any more; every team that clears one banks flat `tierGlory(tier)`,
    ## no race, no marker, regardless of who got there first. The pre-v9
    ## claim-split reasoning below (first=0.50-0.86 on common tiers vs 1.00 on
    ## rare ones) is what MOTIVATED narrowing the race to the rare end in the
    ## first place -- a "first" on a tier 86% of claims already win is not a
    ## pioneer bonus, it is a coin flip with a badge.
    ##
    ## 🚨 REFRAMED (VOCABULARY wave): this is a PIONEER bonus, not a race
    ## bonus. It pays for being first-on-the-board, full stop -- whether or
    ## not the other team ever shows up to contest the tier at all. The
    ## measured claim split makes the distinction concrete: common tiers
    ## (the T1-T2 "touched the kit" ones) see first=0.50-0.86, real
    ## competition where most claims are NOT the first (both teams typically
    ## get there), while rare tiers see first=1.00 -- essentially every claim
    ## IS the first claim, because usually only one team ever reaches them in
    ## a given episode. At that end there is no "race" to win; the bonus
    ## simply crowns whichever team pioneered the feat. (Measured against the
    ## pre-v9 curriculum, where every tier could race -- the SHAPE of the
    ## claim split by tier difficulty is what v9's E4 acts on, even though the
    ## specific tier indices it was measured at have since been repriced.)
    ## ⚠️ UNCALIBRATED (GLORY C7): a round "triple" -- big enough to be worth
    ## chasing, per law 2's own stated intent ("a first-only reward teaches
    ## the other teams nothing" argues AGAINST going higher, since a bigger
    ## multiplier makes the other three teams' later claims feel more like
    ## consolation prizes) -- but not fit against a measured
    ## first-to-claim distribution.
  AchievementSweepBudgetPct* = 58
    ## Law 3 as Muster states it: a full sweep must stay under this share of a
    ## MEDIAN WINNER's episode glory.
    ##
    ## v10 (GLORYVERSION 10 WAVE, 2026-08-26): RE-MEASURED after `dLevelUp`
    ## zero+tombstoned (Maxwell's ruling: leveling pays POWER, not the
    ## scoreboard -- see the tombstone on `Deed.dLevelUp`).
    ## tools/ladder/gloryscore.py, same 120-episode `--min-version 0.7.200`
    ## cache, run against the fully v10-synced mirror (`level_up` 6G/5 drama
    ## -> 0G/0 drama in DEED_GLORY/DEED_DRAMA): full-sweep base UNCHANGED at
    ## 600 (`TierGlory`/`AchievementTrees` neither moved this wave), but
    ## wipe-corrected median winner glory collapsed 2287G -> 1038G -- NOT
    ## merely `dLevelUp`'s own ~30%-of-deed-mass direct share. Zero drama
    ## also means level-ups (39.4 fires/episode, the single most frequent
    ## drama deed in the game, more often than every combat deed combined)
    ## stop feeding heat embers, so every OTHER drama deed's OWN heat
    ## multiplier collapses with it -- measured heat occupancy over the same
    ## sample: x1 72% -> 91%, x2 12% -> 7%, x4 11% -> 0%, x8 3% -> 0% (the
    ## xp-earns-a-level -> heat-ember arrow this wave closes, per Maxwell's
    ## brief). Achievement share of winner glory (untouched by this wave)
    ## rose 7.3% -> 15.5% of a now much smaller pie. Recommended value:
    ## ceil(600 / 1038 * 100) = 58 (was 27). Still the SOFT number:
    ## `tests/test_glory.nim` continues to assert only the DERIVED,
    ## denominator-free form (`sum(TierGlory) * AchievementTrees <
    ## dCapture + dWipe` = 600 < 650) -- neither `dCapture` nor `dWipe`
    ## moved this wave, so that hard gate is unaffected and still passes.
    ##
    ## v9 (GLORY LAW E5): RE-MEASURED after the TierGlory re-anchor (was 15,
    ## a placeholder; the field-measured RECOMMENDED value under the v8
    ## curriculum was 28 -- see v8's own gloryscore.py sweep-budget dump).
    ## tools/ladder/gloryscore.py, same 120-episode `--min-version 0.7.200`
    ## cache (2026-08-26, run against the FULLY v9-synced mirror -- new
    ## TierGlory, the FIRST-tier-V-only cap, and the E2/E3 gate rewrites all
    ## landed): full-sweep base moved 496 -> 600 (the new `TierGlory` sum),
    ## wipe-corrected median winner glory 1826 -> 2287 (the richer
    ## achievement ledger AND the new E2/E3 deed/xp mix both lift winner
    ## totals), giving a RECOMMENDED value of 27 (was 28) -- essentially
    ## unchanged despite the price table growing +21%, because winner glory
    ## grew by a similar proportion. (An earlier mid-wave reading of 31 was
    ## taken against a partially-synced mirror -- TierGlory only, before the
    ## FIRST-cap and E2/E3 gate rewrites landed in gloryscore.py -- and is
    ## superseded by this one.) Still the SOFT number: `tests/test_glory.nim`
    ## continues to assert only the DERIVED, denominator-free form
    ## (`sum(TierGlory) * AchievementTrees < dCapture + dWipe`), which this
    ## constant does not gate -- see that test's own comment for why a
    ## guessed denominator is worse than none.
    ##
    ## ⚠️ Pre-v9 UNCALIBRATED note, retained for provenance. We have no measured median for paintbot yet, and a
    ## gate whose denominator is invented is the exact mistake Muster banked
    ## as "ship-gate thresholds asserted from guesses": a threshold pulled
    ## from intuition can be too easy (everything passes) or too hard
    ## (nothing does) and you cannot tell which without a known-answer
    ## reference. So `tests/test_glory.nim` does NOT assert this constant. It
    ## asserts the DERIVED form of the same law instead -- a full sweep must
    ## be worth less than winning the game outright (`dCapture` + `dWipe`) --
    ## which needs no denominator we had to guess. Calibrate this number from
    ## a real episode's ledger, then turn the strict gate on.

type
  Tree* = enum
    ## One curriculum tree per kit, plus the two team trees. Ordered; the
    ## ordinal is the achievement key's high half, so DO NOT REORDER.
    treeGun         ## the weapon every cog spawns with.
    treeSpray       ## the spray can: 28.5% of all kills in the field.
    treeGrenade     ## the corner paint-bomb.
    treeShield      ## v9: re-founded as the TEAMWORK tree (assists, escort
                    ## duty, rescues, the re-gated Second Wind, squad
                    ## volley) -- was the endzone armor's soak ladder, GONE
                    ## (self-benefiting; see `AchievementNames`' own comment).
    treeMedKit      ## v9: re-founded as THE PROVIDER (a teammate consuming
                    ## kit your own supply drop produced) -- was the
                    ## self-heal ladder, GONE (same reason).
    treeCarrier     ## steal, run, score.
    treeDefender    ## peel, deny, turn the tables.
    treeSquad       ## TEAM: the full kit fielded at once.

const
  AchievementNames*: array[Tree, array[AchievementTiers, string]] = [
    # treeGun — "The Sidearm". v3: "Trigger Discipline" (any landed hit) is
    # GONE -- landing a hit is normal gunplay, not an achievement (law 2b's
    # ruling). Every tier below is a KILL or a rank now.
    ["First Tag",           ## I    a gun kill
     "Marksman",            ## II   3 gun kills in one game
     "Bounty",              ## III  killed a level>=AceLevel enemy
     "Sharpshooter",        ## IV   a cog reaches max rank (L5) (v6, GLORY
                            ##      C4: was V -- field claim rate 15.4% vs
                            ##      "Longshot"'s 8.3% (n=240 team-eps) means
                            ##      THIS is the easier act; swapped.
     "Longshot"],           ## V    a kill past LongshotPx (v6, GLORY C4:
                            ##      was IV -- the rarer act, moved up.
                            ##      GLORY C6: EVALUATED, kept -- already
                            ##      neutral paintball/marksmanship
                            ##      vocabulary, names no outside game.)
    # treeSpray — "The Can". v3: "Shake It" (pick up a can) is GONE.
    ["First Coat",          ## I    a spray kill
     "Full Coverage",       ## II   2 spray kills in one game
     "Repainted",           ## III  2 spray kills on one pickup
     "The Muralist",        ## IV   3 spray kills on a single pickup
     "Double Splash"],      ## V    one cone activation kills 2+ enemies
                            ##
                            ## ⚠️ ZERO-CLAIMS-AT-n=240 (GLORY /proof E6,
                            ## 2026-08-25), and the near-miss chase found the
                            ## culprit was the MEASUREMENT, not this
                            ## requirement: `player.sprayMultiKills` in
                            ## sim.nim already tracks the real per-activation
                            ## window correctly (`arcKillsThisFire`, live
                            ## across all `PlasmaArcActiveTicks`=5 ticks a
                            ## cone stays lit) -- it was
                            ## tools/ladder/gloryscore.py's OFFLINE
                            ## reconstruction that grouped kills by exact
                            ## SAME TICK only (the wire carries no
                            ## "activation id"), an instrument too coarse to
                            ## see a real multi-kill spread across ticks.
                            ## Traced directly over the 120-episode cache: of
                            ## 32 same-cog spray-kill pairs closer together
                            ## than a full recharge cycle, ONE sat 2 ticks
                            ## apart (inside one activation) with every other
                            ## pair 29+ ticks apart (a fresh activation needs
                            ## `PlasmaArcResetTicks`=20 recharge +
                            ## `PlasmaArcActiveTicks`=5, so nothing under
                            ## ~25 ticks can be a SEPARATE one) -- exactly the
                            ## false-null-from-instrument-resolution pattern:
                            ## a real claim was there, the ruler just
                            ## couldn't read it. Widened the mirror's spray
                            ## grouping to a 4-tick window (v7, GLORY /proof
                            ## E6; grenade's own grouping stays same-tick,
                            ## which IS exact -- one blast, one step); the
                            ## true in-engine claim rate for this tier is
                            ## still UNMEASURED beyond that single case (n=1
                            ## is not a rate) -- this requirement is NOT
                            ## retuned, only the mirror that was under-
                            ## reading it.
    # treeGrenade — "The Bomb". v3: "Pull the Pin" (pick up a nade) is GONE.
    ["Delivery",            ## I    a grenade kill
     "Splatterbomb",        ## II   2 grenade kills in one game (v6, GLORY
                            ##      C6: was "Fireball" -- a nade throws
                            ##      PAINT, not fire; kept "Delivery" as-is,
                            ##      already paint-native register)
     "Blast Radius",        ## III  a grenade blast that caught 2+ enemies:
                            ##      `grenadeMultiKills >= 1` (v6, GLORY C3a:
                            ##      gates on `grenadeMultiKills` alone now --
                            ##      the old form also accepted a SPRAY
                            ##      multi-kill. GLORY C4: was IV -- see "The
                            ##      Bombardier" below for why it shifted up.)
     "Double Blast",        ## IV   TWO multi-kill blasts in one game:
                            ##      `grenadeMultiKills >= 2` (v7, GLORY
                            ##      /proof E4: III and IV both used to gate
                            ##      on `>= 1` -- the C3a fix left them
                            ##      identical, n=7 field claims and EVERY
                            ##      ONE at the same tick as its pair, so IV
                            ##      never tested anything III hadn't already.
                            ##      "Double" now means what it says -- no new
                            ##      counter, `grenadeMultiKills` already
                            ##      accumulates across the whole episode.
                            ##      v6, GLORY C4: was V, shifted up one)
     "The Bombardier"],     ## V    3 grenade kills in one game (v6, GLORY
                            ##      C4: was III -- field claim rate 2.1%,
                            ##      the LOWEST of the tree's five (n=240
                            ##      team-eps), below even "Blast Radius"
                            ##      (2.9%) and "Double Blast" (2.9%) -- the
                            ##      tree's actual hardest tier, moved to V.
    # treeShield — RE-FOUNDED v9 (GLORY LAW E3) as "The Backup": the teamwork
    # tree. The old "The Wall" (soak thresholds: Suit of Paint/Blockade/Paint
    # Wall/The Bunker/The Backstop) is GONE outright, not merely renamed --
    # its own "STANDING DECISION" comment argued soaking "funds the team,"
    # which this wave's ground truth refutes directly: a shield protects
    # ONLY its wearer (all three damage sites absorb on the hit index), so
    # every one of those five tiers was gating on a SELF-benefiting act, the
    # exact violation class this whole law audit exists to end. Replaced
    # with four counters that are genuinely about a TEAMMATE, pinned ONCE at
    # their causal sites (sim.nim: three damage sites for
    # `lastDamagedBy`/`menacingTick`, `killPlayer` for the rest) rather than
    # re-derived at poll time -- the same discipline `secondWind`/
    # `capturedOutnumbered`/`capturedFastBreak` already hold themselves to.
    # ⚠️ UNCALIBRATED / no field data (GLORY LAW E3): every counter here is
    # BRAND NEW this version, so both the requirements AND their tier order
    # are a first-pass design guess, not a field-fit -- re-measure once a
    # cache with v9 claims exists.
    ["Cover Fire",          ## I    land an ASSIST: your damage put the
                            ##      victim in the fight a teammate finished
                            ##      within `AssistWindowTicks` (`assists >= 1`).
     "Escort Duty",         ## II   land a kill while a TEAMMATE runs the
                            ##      enemy heart (`escortKills >= 1` --
                            ##      `KillContext.escorted`'s own counter,
                            ##      which `dEscortKill` already prices but
                            ##      never used to feed an achievement gate).
     "The Save",            ## III  a RESCUE: kill a cog that recently put one
                            ##      of your teammates at/near clutch hp
                            ##      (`rescues >= 1`) -- the menace is pinned
                            ##      at the DAMAGE site on the attacker, so
                            ##      this reads as "you answered the threat,"
                            ##      not "you happened to kill someone hurt."
     "Second Wind",         ## IV   RE-GATED (was treeMedKit's self-heal
                            ##      version): get rescued (see "The Save"),
                            ##      THEN land a kill of your own within
                            ##      `SecondWindTicks` -- the comeback beat
                            ##      survives, the self-heal gate that used to
                            ##      arm it does not. Detected at the kill
                            ##      site off `rescuedTick`, never
                            ##      `clutchHealTick`.
     "Squad Volley"],       ## V    TEAM-WIDE: 3+ DISTINCT teammates each land
                            ##      a kill inside `SquadVolleyWindowTicks` of
                            ##      one another (`squadVolleyDone`, pinned
                            ##      once off the team's own small recent-kill
                            ##      ring) -- no single cog can trigger this
                            ##      alone, by construction.
    # treeMedKit — RE-FOUNDED v9 (GLORY LAW E2) as "The Provider": every tier
    # of the old "The Patch" (The Catch/Second Wind/Patch Job/Lifeline/
    # Miracle Worker) gated on HEALING YOURSELF -- self-care, banned. The
    # supply drop is the ONE team-benefit loop this engine actually has (any
    # teammate may consume a drop a 3-star cog's heart produced), so this
    # tree now reads THAT: `SupplyDropPickup` gained `droppedBy`, and
    # `tryPickupSupplyDrops` (sim.nim) credits the DROPPER, never the
    # consumer, the instant a TEAMMATE (not the dropper themself) takes the
    # kit. "Second Wind" (the one name worth keeping from the old tree)
    # migrated to `treeShield`'s re-founded teamwork tree above, re-gated
    # onto being rescued rather than self-healing.
    # ⚠️ UNCALIBRATED / no field data (GLORY LAW E2), same honesty as
    # `treeShield` above -- `supplyShared`/`supplySaves` are both new this
    # version.
    ["First Delivery",      ## I    a teammate consumes YOUR supply drop for
                            ##      the first time (`supplyShared >= 1`).
     "Clutch Delivery",     ## II   a teammate consumed your drop while
                            ##      at/near clutch hp (`ClutchHpThreshold`) at
                            ##      the pickup moment -- their hp is readable
                            ##      right at the site (`supplySaves >= 1`).
     "Regular Route",       ## III  3 shared drops in one episode
                            ##      (`supplyShared >= 3`).
     "Emergency Route",     ## IV   2 clutch saves in one episode
                            ##      (`supplySaves >= 2`).
     "Supply Chain"],       ## V    6 shared drops in one episode -- a
                            ##      veteran that keeps the whole team fed
                            ##      (`supplyShared >= 6`).
    # treeCarrier — "The Heart". v3.1 (CURRICULUM audit C1/C8): tier I/II used
    # to read `steals >= 1` (an uncontested pickup, satisfiable by walking
    # into an empty base) and live `carryingFlag` plus a hold timer (pure
    # possession-plus-duration) -- both law-2b violations no different from
    # the pickup tiers v3 already deleted everywhere else, exempted only by a
    # comment's ASSERTION that carrier play is special. It is not: re-cut to
    # the same standard as every other tree -- a CONVERTED, contested act.
    # v12 (HEART RECUT, the 2026-08-31 contract table verbatim): one terminal
    # tier ("Delivered") instead of three capture-gated ones, and a ladder
    # that CLIMBS -- every rung below V is accumulable mid-game and sweeps
    # live. "Uphill"/"Fast Break" moved to the endcard as display-only
    # distinctions on the capture itself (see `CaptureDistinction` below).
    # II/III ordering is PROVISIONAL (see the v12 changelog entry): re-measure
    # excluding game-ending captures before trusting the old field rates.
    ["Hands On",            ## I    a steal landed while a LIVE enemy stood
                            ##      within ContestedStealPx -- an uncontested
                            ##      walk-in no longer counts.
     "Fighting Carry",      ## II   an enemy kill landed WHILE CARRYING the
                            ##      heart -- live possession alone (the old
                            ##      "hold for 120+ ticks") no longer counts.
                            ##      (v12: was III; the 11.7% team-episode
                            ##      rate (n=240) is the one carrier figure
                            ##      the offline scorer measured honestly,
                            ##      since its counter accumulates mid-game.)
     "Double Steal",        ## III  2 contested steals in one game
                            ##      (`contestedSteals >= 2` -- v12, NEW:
                            ##      mirrors The Peel's "Double Peel"
                            ##      (`carrierKills >= 2`) naming and shape.
                            ##      Deliberately NOT `escortKills` -- that
                            ##      counter already gates "Escort Duty" (The
                            ##      Backup II), and one counter must never
                            ##      be recognized by two trees.)
     "Hard Carry",          ## IV   2 contested steals AND a carry kill in
                            ##      one game (`contestedSteals >= 2 and
                            ##      carryKills >= 1` -- v12, NEW: the strict
                            ##      superset of II+III, kept taking it AND
                            ##      kept fighting).
     "Delivered"],          ## V    score the enemy heart (`captures >= 1` --
                            ##      v12: was II; THE terminal tier. On a
                            ##      game-ending capture (every S2 2-team
                            ##      capture, the last capture of an N-team
                            ##      game) it mints in `finishGame`'s
                            ##      conclusion sweep, at the ending tick.
    # treeDefender — "The Peel". v3: "Eyes Back" (a heart return) is GONE --
    # `resetFlag` credits `returns` to every LIVING teammate when a heart
    # comes home, not to whoever caused it, so it was bystander credit, not
    # an individual act (see the comment at `resetFlag` in sim.nim).
    ["The Peel",            ## I    kill the enemy carrier
     "Doorstep",            ## II   a denial inside DenialPx
     "Double Peel",         ## III  2 carrier kills in one game
     "Turnaround",          ## IV   peel then steal within RevengeTicks
                            ##
                            ## ⚠️ ZERO-CLAIMS-AT-n=240 (GLORY /proof E6,
                            ## 2026-08-25) -- near-miss data does NOT clearly
                            ## support a window retune, so `RevengeTicks`
                            ## (240) is UNCHANGED. Traced over the 120-
                            ## episode cache: 135 cogs land >=1 peel; only 12
                            ## (8.9%) EVER chain a later steal in the same
                            ## episode at all, at any gap -- the achievement
                            ## is gated by a rare ROLE SWITCH (a defender who
                            ## becomes an attacker), not narrowly by the
                            ## window. Of those 12, the closest gap is 260
                            ## ticks -- 20 ticks (0.83s) past the 240-tick
                            ## window, genuinely close, but a single case:
                            ## widening to 360 (+50%) only pulls in 3/12, 480
                            ## only 4/12; most of the 12 sit 425-2062 ticks
                            ## out, far beyond any defensible "immediate
                            ## turnaround" window. One near-boundary miss is
                            ## not a distribution -- see the "Double Splash"
                            ## comment above for what a wave that WAS
                            ## clearly supported by its near-miss data looks
                            ## like.
     "Lockdown"],           ## V    2 denials in one episode
    # treeSquad — "The Squad" (TEAM tree). Kit tiers now read CONVERSION
    # (`teamConvertedKits`) -- a teammate landed the kit's signature act --
    # never live possession, which was arrival wearing a team hat.
    ["Kitted",              ## I    2 of 4 kits CONVERTED, team-wide
     "Full Loadout",        ## II   3 of 4 kits converted (v6, GLORY C6: was
                            ##      "Combined Arms" -- real-world military
                            ##      jargon, replaced with a gaming-neutral
                            ##      term)
     "Full Kit",            ## III  4 of 4 kits converted. v12 TOMBSTONE
                            ##      (Amendment 1): zero-claim on this port --
                            ##      `teamConvertedKits` hard-caps at
                            ##      `KitLegsImplemented` (3, no med leg), and
                            ##      a 3-value counter cannot carry three
                            ##      thresholds, so I/II are NOT re-spaced.
                            ##      Lifts when the med leg lands (see
                            ##      `KitLegsImplemented`'s own comment).
     "Clean Sheet",         ## IV   FULL-GAME zero team kills (conclusion-only:
                            ##      reported exclusively by the conclusion
                            ##      sweep's `atConclusion` read, v12)
     "Victory Lap"],        ## V    every implemented kit converted AND a
                            ##      capture this game (v12, Amendment 1:
                            ##      `kits >= KitLegsImplemented and
                            ##      anyCapture` -- was `>= 4`, structurally
                            ##      dead on this port; see the constant's
                            ##      own comment. v6, GLORY C6: was "The
                            ##      Parade" -- "victory lap" is the
                            ##      paintball-league idiom for a dominant,
                            ##      capped-off win)
  ]

  AchievementDescriptions*: array[Tree, array[AchievementTiers, string]] = [
    ## v9 (GLORY LAW E6): one kid-readable sentence per (tree, tier), stating
    ## the requirement TRUTHFULLY -- mechanics, not fiction, so a tooltip can
    ## never promise something the gate does not actually check. Shipped once
    ## per HUD viewer (`broadcast.nim`'s `curriculumJson`) and read by the
    ## client as native `title=` tooltips on the achievement panel rows and
    ## the two team dropdowns (`client/replay_broadcast.html`) -- never
    ## re-typed client-side, the same "one accessor" rule every other number
    ## in this module already holds itself to. Re-read every name against its
    ## gate after E1-E3's renames before trusting an OLD description: two
    ## whole trees (`treeShield`, `treeMedKit`) changed what they measure
    ## this version even though `treeShield`'s tree-level identity endures.
    ["Get a kill with your gun.",
     "Get 3 gun kills in one game.",
     "Take down an enemy who has leveled up to Ace rank or higher.",
     "Reach max rank in one life.",
     "Land a kill from way out past the longshot range."],
    ["Get a kill with the spray can.",
     "Get 2 spray kills in one game.",
     "Get 2 spray kills with the same can.",
     "Get 3 spray kills with the same can.",
     "Hit 2 or more enemies with one spray blast."],
    ["Get a kill with a grenade.",
     "Get 2 grenade kills in one game.",
     "Catch 2 or more enemies in one grenade blast.",
     "Catch 2 or more enemies in a blast, twice in one game.",
     "Get 3 grenade kills in one game."],
    # treeShield -> the teamwork tree (E3). Every sentence names a TEAMMATE,
    # truthfully -- none of these can be satisfied alone.
    ["Damage an enemy that a teammate finishes off soon after.",
     "Get a kill while a teammate is running the enemy's heart.",
     "Take down an enemy who just hurt one of your teammates badly.",
     "Get rescued by a teammate, then land a kill of your own soon after.",
     "Have 3 or more different teammates each land a kill in one quick burst."],
    # treeMedKit -> The Provider (E2). Every sentence names the CONSUMER as a
    # teammate, never the earner -- the tree is about paying the squad.
    ["Have a teammate pick up kit from your team's supply drop.",
     "Have a teammate grab your supply drop while they're badly hurt.",
     "Share 3 supply drops with your team in one game.",
     "Save a badly hurt teammate with your supply drop, twice in one game.",
     "Share 6 supply drops with your team in one game."],
    # v12: II-V rewritten with the recut table (contract §8 tooltip row).
    ["Steal the enemy's heart while a live enemy is close enough to contest it.",
     "Get a kill while you're carrying the enemy's heart.",
     "Steal the enemy's heart twice in one game, both times against contest.",
     "Steal against contest twice AND get a kill while carrying, all in one game.",
     "Carry the enemy's heart all the way home for a capture."],
    ["Kill the enemy who is carrying your team's heart.",
     "Stop a carrier right at your own team's doorstep.",
     "Kill an enemy carrier twice in one game.",
     "Peel a carrier off your heart, then steal the enemy's yourself soon after.",
     "Stop carriers at the doorstep twice in one game."],
    ["Your team gets real use out of 2 of the 4 kits in one game.",
     "Your team gets real use out of 3 of the 4 kits in one game.",
     "Your team gets real use out of all 4 kits in one game.",
     "Finish the whole game without a single teammate shooting a teammate.",
     # v12 (Amendment 1): "every kit", not "all 4" -- the gate reads
     # `KitLegsImplemented`, truthful at 3 today and at 4 after the med leg.
     "Use every kit AND capture the enemy's heart in the same game."],
  ]

type
  CaptureDistinction* = enum
    ## v12 (contract §3): "Uphill" and "Fast Break" moved OFF the Heart
    ## ladder and onto the ENDCARD, as distinctions on the capture itself.
    ## The engine keeps pinning `capturedOutnumbered`/`capturedFastBreak` at
    ## the capture site in `checkWinCondition` (unchanged code path); the
    ## game-over frame (`broadcast.nim`'s `over.distinctions`) reads the
    ## pins and ships one entry per pinned player. Display only: no glory
    ## minted, no claim, no heat -- which is why these are NOT `Tree` tiers
    ## and have no `TierGlory` price.
    cdUphill      ## the capture landed while the carrier's team had fewer
                  ## players alive than the captured team (`capturedOutnumbered`)
    cdFastBreak   ## steal -> capture within `FastBreakTicks`, same life
                  ## (`capturedFastBreak`)

const
  CaptureDistinctionNames*: array[CaptureDistinction, string] = [
    ## The names carry over from the retired ladder tiers verbatim.
    "Uphill",
    "Fast Break",
  ]

  CaptureDistinctionDescriptions*: array[CaptureDistinction, string] = [
    ## The kid-register descriptions carry over from
    ## `AchievementDescriptions`' retired treeCarrier IV/V rows verbatim.
    "Score a capture while your team has fewer players alive than the enemy.",
    "Steal the heart and capture it again in one fast run.",
  ]

# ───────────────────────────────────────────────────────────────────────────
# §6  ACCESSORS — the only way to read a price
# ───────────────────────────────────────────────────────────────────────────

func deedGlory*(deed: Deed): int {.inline.} =
  ## Glory magnitude for a deed. Negative for penalties (the caller adds, so
  ## a penalty subtracts naturally). Zero for an unknown deed, so a mistake
  ## cannot silently award a stray value.
  DeedGloryTable[deed]

func deedDrama*(deed: Deed): int {.inline.} =
  ## Drama weight in TENTHS. Integer so it never drifts across platforms.
  DeedDramaTable[deed]

func isDrama*(deed: Deed): bool {.inline.} =
  ## A deed the crowd came to see. Only these climb the heat ladder and only
  ## these take the carry multiplier.
  DeedDramaTable[deed] > 0

func paysHeat*(deed: Deed): bool {.inline.} =
  ## Law 4: achievements mint through the ledger (feed, heralds and the site
  ## gradient all apply) but NEVER climb heat. Only combat drama does.
  deed != dAchievement and isDrama(deed)

func popsScore*(deed: Deed): bool {.inline.} =
  ## Whether a minted deed floats a "+Ng" score pop at its site (the FPS
  ## hitmarker). Lives here rather than in the renderer for the same reason
  ## every other rule does: one accessor, so the FX layer can never hardcode a
  ## deed name and drift from the economy it is reporting.
  ##
  ## `dShieldSoak` is excluded because it is ambient per-hit-point income, not
  ## a moment — the table already prices it at ZERO drama for exactly that
  ## reason. It also fires every 9-12 ticks per attacker under focus fire, and
  ## the draw pool is a fixed 16: left in, ambient soak STARVES the rare deeds
  ## the pop exists to celebrate, so a capture could mint and never be drawn.
  ##
  ## `dClutchHeal` is excluded as of v9 (GLORY LAW E1): zero+tombstoned, see
  ## the Deed enum's own comment -- "the SAVE pop dies with it" is enforced
  ## HERE, not by amount alone (a 0g mint would otherwise still draw an empty
  ## "+0g SAVE" toast, since `awardDeed` has no amount>0 guard).
  ##
  ## `dAchievement` is excluded because a claim pops through `claimAchievement`'s
  ## LABELLED path instead, carrying the name it just earned. Popping it here
  ## too would price one moment twice on screen.
  ##
  ## `dLevelUp` is excluded as of v10 (Maxwell's ruling: leveling pays POWER,
  ## not the scoreboard -- see the Deed enum's own comment): zero+tombstoned
  ## exactly like `dClutchHeal` above, same "not by amount alone" reasoning --
  ## a 0g mint would otherwise still draw an empty "+0g RANK UP" toast, since
  ## `awardDeed` has no amount>0 guard. The RANK UP moment is NOT deleted
  ## though: `addXp` (sim.nim) mints it directly through `addGloryPop`'s own
  ## LABELLED path, the same one `claimAchievement` uses, carrying the new
  ## star count where a claim would carry its name -- so it survives the
  ## zero-amount guard and reads as a named moment, never a bare payout.
  ##
  ## A PENALTY still pops. `dTeamKill` is 0-drama (anti-drama: it must never
  ## light heat) but friendly fire is the largest single loss we have measured,
  ## so "-60g" over the body is one of the most valuable things on this HUD.
  ## That is why this is NOT `isDrama`, which would silently swallow it.
  deed != dShieldSoak and deed != dClutchHeal and deed != dAchievement and
    deed != dLevelUp

func tierGlory*(tier: int): int {.inline.} =
  ## Base glory for an achievement tier index 0..4.
  if tier < 0 or tier >= AchievementTiers: 0 else: TierGlory[tier]

func tierDrama*(tier: int): int {.inline.} =
  ## Drama tenths for an achievement tier index 0..4.
  if tier < 0 or tier >= AchievementTiers: 0 else: TierDrama[tier]

func achievementKey*(tree: Tree, tier: int): int {.inline.} =
  ## Stable index into a team's claimed set. Ordinal-derived, so reordering
  ## `Tree` silently re-keys every claim — don't.
  ord(tree) * AchievementTiers + tier

func achievementName*(tree: Tree, tier: int): string {.inline.} =
  if tier < 0 or tier >= AchievementTiers: "" else: AchievementNames[tree][tier]

func achievementDescription*(tree: Tree, tier: int): string {.inline.} =
  ## v9 (GLORY LAW E6): the tooltip text for a (tree, tier) -- see
  ## `AchievementDescriptions`' own comment for the shipping path.
  if tier < 0 or tier >= AchievementTiers: ""
  else: AchievementDescriptions[tree][tier]

func captureDistinctionName*(distinction: CaptureDistinction): string {.inline.} =
  ## v12 (contract §3): the endcard label for a capture distinction.
  CaptureDistinctionNames[distinction]

func captureDistinctionDescription*(distinction: CaptureDistinction): string {.inline.} =
  ## v12 (contract §3): the kid-register tooltip for a capture distinction.
  CaptureDistinctionDescriptions[distinction]

func heatRung*(embers: int): int {.inline.} =
  ## Rung for an ember count. Each rung costs more than the last.
  result = 0
  for threshold in HeatThresholds:
    if embers >= threshold:
      inc result
    else:
      break

func heatMult*(embers: int): int {.inline.} =
  ## The live multiplier for a team's ember count.
  let rung = heatRung(embers)
  HeatLadder[if rung > HeatLadder.high: HeatLadder.high else: rung]

func levelForXp*(xp: int, brMode: bool = false): int {.inline.} =
  ## Level 0..MaxLevel for a cog's CURRENT-LIFE xp. Monotonic in xp, so a
  ## level can never dip while the life continues.
  ##
  ## `brMode` (GLORY v11, default false so every pre-v11 call site and test
  ## keeps its exact CTF answer): scales `LevelThresholds` by
  ## `BrLevelThresholdMultPct` -- see that constant's own comment for why
  ## BR's damage-only, flagless xp pool needs a taller ladder than CTF's.
  result = 0
  for threshold in LevelThresholds:
    let t =
      if brMode: threshold * BrLevelThresholdMultPct div 100
      else: threshold
    if xp >= t:
      inc result
    else:
      break

func levelName*(level: int): string {.inline.} =
  LevelNames[if level < 0: 0 elif level > MaxLevel: MaxLevel else: level]

func clampLevel*(level: int): int {.inline.} =
  if level < 0: 0 elif level > MaxLevel: MaxLevel else: level

# ── Buff accessors: the five integer sites the sim reads ──────────────────

func levelWindupTicks*(base, level: int): int {.inline.} =
  ## Trigger windup after the ladder. Floored at 1: a zero-windup shot would
  ## delete the peek-and-duck read the whole gunfight is built on.
  let ticks = base + LevelWindupDelta[clampLevel(level)]
  if ticks < 1: 1 else: ticks

func levelGunRange*(base, level: int): int {.inline.} =
  base * LevelGunRangePct[clampLevel(level)] div 100

func levelMaxHp*(base, level: int): int {.inline.} =
  base + LevelBonusHp[clampLevel(level)]

func levelFireCooldown*(base, level: int): int {.inline.} =
  ## Floored at 1 tick so a cooldown can never reach zero and fire every tick.
  let ticks = base * LevelFireCooldownPct[clampLevel(level)] div 100
  if ticks < 1: 1 else: ticks

func levelSprayReset*(base, level: int): int {.inline.} =
  let ticks = base * LevelSprayResetPct[clampLevel(level)] div 100
  if ticks < 1: 1 else: ticks

func levelGrenadeCharges*(level: int): int {.inline.} =
  LevelGrenadeCharges[clampLevel(level)]

func levelCarrierSpeedPct*(base, level: int): int {.inline.} =
  ## The heart's speed tax, waived at L5.
  if LevelCarrierSpeedWaived[clampLevel(level)]: 100 else: base

func siteMultPct*(ownerIsSelf, ownerIsNone: bool): int {.inline.} =
  ## The within-arena gradient, by ownership of the ground the deed happened
  ## on. Caller resolves ownership by NEAREST HOME PEDESTAL — never by an
  ## x-midline, which four bases do not have.
  if ownerIsNone: SiteMultNeutralPct
  elif ownerIsSelf: SiteMultHomePct
  else: SiteMultEnemyPct

func mintGlory*(deed: Deed; embers, sitePct: int; carrying: bool): int =
  ## THE SINGLE MINT. Every glory award in the engine resolves here, so no
  ## deed can dodge the economy.
  ##
  ## Order is load-bearing: base, then the site gradient (WHERE), then heat
  ## (the streak), then the carry multiplier (possession as leverage).
  ## Penalties take no multiplier at all — a team on a rampage does not pay
  ## eight times for a friendly-fire kill, and a penalty must never be
  ## cheaper on home ground.
  let base = deedGlory(deed)
  if base <= 0:
    return base
  result = base * sitePct div 100
  if paysHeat(deed):
    result = result * heatMult(embers)
  if carrying and isDrama(deed):
    result = result * CarrierHoldMultPct div 100

func mintAchievement*(tier: int, sitePct: int, isFirst: bool): int =
  ## Achievement mint. Takes the site gradient but NEVER heat (law 4), and
  ## x3 for the first team in the episode to complete the tier (law 2).
  result = tierGlory(tier) * sitePct div 100
  if isFirst:
    result = result * AchievementFirstMultPct div 100

# ───────────────────────────────────────────────────────────────────────────
# §6b  THE MULTIPLIER RECUT (v13) — the armed pure-product economy
# ───────────────────────────────────────────────────────────────────────────
#
# Built VERBATIM from the FROZEN 2026-09-02 recut contract (table + owner
# directive; see GloryVersion's v13 changelog for the file refs). Everything
# in this section is DEAD CODE while `GameConfig.gloryMultiplierRecut` is
# false: nothing on the dark path calls into it, which is the byte-identity
# guarantee. Armed, the episode score is
#
#     score = RecutSeed × Π(per-event factor) ÷ 2^(FF halvings)
#
# with each factor an INTEGER (owner constraint §4: whole numbers only) and
# the division the ONLY non-integer-producing element (table §4's accepted
# structural note -- the int ledger reports the FLOOR of the division; the
# canonical (product, halvings) pair is kept losslessly on the sim).
#
# In log space the score is exactly Σ log-factors (directive §2) -- the unit
# tests assert that property directly.

const
  RecutSeed* = 1
    ## Directive §2 open-guards line, verbatim: "Seed = 1; a no-deed episode
    ## scores seed; losers still bank 0 at the league." The league-side loss
    ## gate is roster.nim's existing playerWon gate, untouched.

  RecutClassTable*: array[Deed, int] = [
    1,      # dNone (never minted; neutral by construction)
    # ×1 — commons (table §1 row 1): "still mint, still pop, still count
    # toward K/D/Elo, just carry no score weight" (§5.8). A ×1 class takes
    # NO live-state factor of any kind (heat/carry/territory/stack) -- that
    # exemption is load-bearing (§3: commons NEVER shift, on any ground).
    2,      # dFirstBlood      FIRST!       ×2 (table §1 row 2)
    1,      # dHonorableKill   TAG          ×1
    1,      # dSprayKill       SPRAYED      ×1
    1,      # dGrenadeKill     BOMBED       ×1
    1,      # dPointBlankKill  POINT-BLANK  ×1
    3,      # dLongshotKill    LONGSHOT     ×3
    3,      # dSplashMultiKill MULTI!       ×3
    2,      # dRevengeKill     PAYBACK      ×2
    2,      # dRunDown         CHASE        ×2
    4,      # dAceTag          BOUNTY       ×4
    1,      # dTeamKill        OWN PAINT — NOT a class: the penalty is a
            #                  DIVISION (table §4), handled entirely by
            #                  `recutFfHalvings` below. This row is never
            #                  read on the FF path; 1 = inert if it ever is.
    4,      # dFlagSteal       STEAL        ×4
    8,      # dCapture         CAPTURE      ×8 (bumped, §1)
    4,      # dCarrierKill     PEEL         ×4
    6,      # dDenial          DENIED!      ×6 (bumped, §1)
    2,      # dEscortKill      ESCORT       ×2
    2,      # dAssist          ASSIST       ×2 (in-flight #339, priced §1)
    2,      # dRescue          RESCUE       ×2 (in-flight #339, priced §1)
    1,      # dClutchHeal      (retired; ×1 = weightless either way)
    1,      # dShieldSoak      SHIELD SOAK  ×1
    8,      # dWipe            WIPEOUT      ×8 (bumped, §1)
    1,      # dLevelUp         RANK UP      ×1
    1,      # dAchievement     — tier-priced: `RecutTierClass`, never here.
    # BR-native marquee band (§1b), armed+brMode mints only:
    2,      # dDuoDown         ×2 (ESCORT/CHASE tier by ruling — see enum)
    2,      # dClosingTime     ×2
    4,      # dLastLight       ×4
    8,      # dVictory         ×8
  ]

  RecutTierClass*: array[AchievementTiers, int] = [1, 1, 2, 2, 4]
    ## TierGlory's conversion (table §1): Tier I/II ×1, Tier III/IV ×2,
    ## Tier V ×4 (bumped). The FIRST-claim ×3 (`AchievementFirstMultPct`)
    ## survives as an integer factor — the table's own recomputed BR superb
    ## (9,437,184) requires "Tier V claimed FIRST" = ×4×3, so the ×3 is
    ## contract arithmetic, not an invention here.

  RecutStackLadder* = [1, 2, 3, 5, 8, 13]
    ## FIBONACCI ally-stack (table §2, ruled): multiplier by k =
    ## teammates-in-context, k=1..6, clamped at both ends. What k COUNTS is
    ## mode-specific (§2): CTF = literal same-team players in the moment;
    ## BR = allies-in-context through the dJointAct joint-act-window
    ## predicate (the 2026-09-01 alliance-vocab spec's 120-tick per-victim
    ## damage-incident machinery — `AssistWindowTicks` is the ruled shared
    ## constant). Exact ally-counting refinement is PARKED BEHIND T5 by the
    ## table itself; the sim.nim predicate is the minimal contract-named
    ## one and is flagged as such to conformance review.

  RecutProductCap* = int64(1) shl 62
    ## Saturation guard for the running product. The table's superb ceiling
    ## is ~9.4M (2^23.2); an adversarial marquee/heat/stack chain could in
    ## principle exceed int64, so folds saturate here instead of wrapping.
    ## Saturation is unreachable under any measured episode shape — this is
    ## an overflow guard, not an economy cap (the ruling bans caps on the
    ## FF side; the product side has no ruled ceiling and this bound is
    ## ~2^38 above the contract's own superb).

func recutStackMult*(k: int): int {.inline.} =
  ## The Fibonacci stack factor for k teammates-in-context. k <= 1 (alone,
  ## or a non-contextable deed) is neutral; k past the table's last column
  ## holds at ×13 (the table defines 6 columns and nothing above them).
  if k <= 1: RecutStackLadder[0]
  elif k >= RecutStackLadder.len: RecutStackLadder[^1]
  else: RecutStackLadder[k - 1]

func recutShiftedClass*(deed: Deed, sitePct: int): int {.inline.} =
  ## The deed's integer class with the territory rung shift applied
  ## (table §3): a deed minted on ENEMY ground climbs one integer rung
  ## (×2→×3, ×3→×4, ×4→×5, ×6→×7, ×8→×9); home/neutral ground is
  ## unchanged; commons (×1) NEVER shift, on any ground — load-bearing,
  ## not a style choice. Enemy ground is recognised by the same
  ## `deedSitePct` signal the additive economy already prices
  ## (`SiteMultEnemyPct`); neutral (dead in this engine, see
  ## `SiteMultNeutralPct`) and home fall through unshifted.
  result = RecutClassTable[deed]
  if result >= 2 and sitePct == SiteMultEnemyPct:
    inc result

func recutFactor*(deed: Deed; embers, sitePct: int; carrying: bool;
                  stackK: int = 1): int =
  ## THE ARMED SINGLE MINT — one de-duplicated event's ONE integer factor
  ## (contract §7a): its class (territory-shifted, §3) × every live-state
  ## multiplier active at the mint tick — heat (only for deeds that pay
  ## heat, same gate the additive mint used), carry (possession as
  ## leverage, ×2, only for drama deeds — same gate), ally-stack (§2).
  ## Evaluated ONCE per shared fact; the caller folds it into the ONE
  ## per-team (= per-duo in BR) running product. A ×1 common returns
  ## exactly 1 — no live-state factor can attach to it (§5.8).
  ##
  ## `dTeamKill` never routes here (it is a division, not a factor — see
  ## `recutFfHalvings`); if it ever does, its ×1 row makes it inert.
  let class = recutShiftedClass(deed, sitePct)
  if class <= 1:
    return 1
  result = class
  if paysHeat(deed):
    result = result * heatMult(embers)
  if carrying and isDrama(deed):
    result = result * CarrierHoldMultPct div 100
  result = result * recutStackMult(stackK)

func recutAchievementFactor*(tier: int, isFirst: bool): int =
  ## The armed factor for one achievement-tier claim: `RecutTierClass`
  ## (×1/×1/×2/×2/×4) × the surviving FIRST-claim ×3
  ## (`AchievementFirstMultPct` — see `RecutTierClass`'s own comment for
  ## why the ×3 is contract arithmetic). Never heat (law 4, unchanged);
  ## never territory (claims mint at the team's own pedestal — home ground
  ## never shifts, so passing the site through would be a no-op by
  ## construction and is skipped for clarity).
  if tier < 0 or tier >= AchievementTiers:
    return 1
  result = RecutTierClass[tier]
  if isFirst and result > 1:
    result = result * AchievementFirstMultPct div 100

func recutFfHalvings*(incidents: int, brMode: bool): int {.inline.} =
  ## Table §4, ruled and baked per mode: BR = ÷2 per `dTeamKill` incident;
  ## CTF = ÷2 per TWO incidents. Both compounding, NEITHER capped (owner,
  ## verbatim: "capping anything feels wrong"). Returns the total number of
  ## halvings the episode's incident count has earned. Under armed
  ## downedMode the incident charges once at FINALIZE (directive §10's
  ## audit-verified live behavior — the down-vs-bleed-out split is an OPEN
  ## owner feel-check, deliberately NOT built here).
  if brMode: incidents else: incidents div 2

func recutFold*(product: int64, factor: int): int64 {.inline.} =
  ## Folds one event factor into the running product, saturating at
  ## `RecutProductCap` (overflow guard only — see the cap's comment).
  if factor <= 1: return product
  if product >= RecutProductCap div int64(factor):
    return RecutProductCap
  product * int64(factor)

func recutScore*(product: int64, halvings: int): int64 {.inline.} =
  ## The reported integer episode score: seed×product ÷ 2^halvings,
  ## FLOORED. The table accepts the non-integer tail of the uncapped
  ## division explicitly (§4's structural note: CTF max-FF median-win =
  ## 1.125); the platform's league-score wire is integer, so the int
  ## report floors — the canonical (product, halvings) pair on the sim
  ## keeps the exact value. Flagged to conformance review, not hidden.
  if halvings <= 0: return product
  if halvings >= 63: return 0
  product div (int64(1) shl halvings)

# ───────────────────────────────────────────────────────────────────────────
# §7  ONE KILL, ONE DEED — the anti-stacking rule
# ───────────────────────────────────────────────────────────────────────────
#
# A kill can satisfy several descriptions at once: a point-blank spray kill
# on the enemy carrier, on their doorstep, who happened to be a 3-star. If
# each match minted, that single kill would pay five times, and the deed that
# is easiest to co-satisfy would quietly dominate the ledger.
#
# 🚨 This is the failure mode Muster paid for twice. Once as the double-pay
# bug — `game.events` was never cleared in the training path, so a combo
# completed at tick 10 was re-paid ~390 more times, which was the whole
# reward-magnitude explosion that a normalisation constant had been
# band-aiding. And once as the layer monopoly: at v14 the combo layer reached
# 64-84% of all reward mass and buried both glory AND combat even though every
# layer was "correctly specified" on its own. The banked law is that a layer's
# MAGNITUDE can bury the others regardless of intent, so you audit reward mass
# per layer rather than checking each layer is present.
#
# So: one kill mints exactly ONE kill-class deed, the highest-priority match
# in the fixed order below. `dFirstBlood` is the single exception — it is a
# one-shot per episode and cannot be farmed by construction, so it stacks.

type
  KillContext* = object
    ## Everything known first-hand at the kill site. Filled in at the call
    ## site in `sim.nim`, never reconstructed later by counter-diffing.
    friendly*: bool        ## the victim was a teammate.
    victimCarrying*: bool  ## the victim held a heart.
    nearVictimHome*: bool  ## inside DenialPx of the victim's own pedestal.
    victimLevel*: int      ## the victim's level at the moment it died.
    multi*: bool           ## this blast or cone activation killed 2+.
    rangePx*: int          ## shooter-to-victim distance.
    gunRange*: int         ## the LIVE map's config.gunRange, so `killDeed`
                           ## can re-derive `PointBlankPx`/`LongshotPx` as a
                           ## fraction of THIS game's range rather than
                           ## CTF's own (see `CtfReferenceGunRange`). Zero
                           ## (every test's bare `KillContext{}`) is the
                           ## "unresolved" sentinel: `pointBlankPxFor`/
                           ## `longshotPxFor` fall back to the unscaled
                           ## reference constant, so every existing pure
                           ## test keeps its exact pre-v11 answer.
    weaponSpray*: bool
    weaponGrenade*: bool
    avengesKiller*: bool   ## the victim had killed this cog inside RevengeTicks.
    avengesPartner*: bool  ## GLORY v11 (BR increment 3): the victim is the
                           ## same cog that killed THIS killer's DEAD DUO
                           ## PARTNER (`partner.lastKilledBy`) -- BR's own
                           ## gate onto "PAYBACK", since `avengesKiller`
                           ## above is structurally unreachable there (a
                           ## killer who had ever died is already
                           ## permanently eliminated in a one-life episode,
                           ## so it can never be the one pulling the
                           ## trigger now). Filled at the kill site
                           ## (sim.nim's `killPlayer`), same discipline as
                           ## every other `KillContext` field.
    fleeing*: bool         ## the victim was moving away from the killer.
    escorted*: bool        ## a TEAMMATE of the killer -- not the killer --
                           ## currently carries the enemy heart. Distinct from
                           ## `victimCarrying`, which is about what the VICTIM
                           ## held; this is about what the KILLER's own side
                           ## is running. The killer's own carry already gets
                           ## `CarrierHoldMultPct`'s multiplier through
                           ## `mintGlory`, so this prices covering the runner
                           ## as its own act rather than double-counting theirs.

func scaledByGunRange(refPx, gunRange: int): int {.inline.} =
  ## `refPx` (measured at `CtfReferenceGunRange`) rescaled to the SAME
  ## fraction of `gunRange`. `gunRange <= 0` is the unresolved sentinel
  ## (see `KillContext.gunRange`'s own comment) -- returns `refPx` itself,
  ## unscaled.
  if gunRange <= 0: refPx
  else: refPx * gunRange div CtfReferenceGunRange

func pointBlankPxFor*(gunRange: int): int {.inline.} =
  scaledByGunRange(PointBlankPx, gunRange)

func longshotPxFor*(gunRange: int): int {.inline.} =
  scaledByGunRange(LongshotPx, gunRange)

func denialPxFor*(gunRange: int): int {.inline.} =
  scaledByGunRange(DenialPx, gunRange)

func killDeed*(ctx: KillContext): Deed =
  ## Resolve a kill to its ONE deed. Order is the pricing hierarchy: the
  ## penalty first so a friendly kill can never be dressed up as a highlight,
  ## then the objective context (what the victim was DOING outranks how they
  ## were shot), then the shot itself. `escorted` sits below every marquee
  ## kill descriptor (ace tag, multi, longshot, point-blank, revenge,
  ## rundown) -- it describes the surrounding TEAM context, not the kill
  ## itself, so a kill that is ALSO one of those stays classified as the more
  ## specific, rarer feat. It sits above the plain weapon/floor tiers so an
  ## escort kill is reachable at all: those three would otherwise catch every
  ## remaining kill first.
  if ctx.friendly: return dTeamKill
  if ctx.victimCarrying and ctx.nearVictimHome: return dDenial
  if ctx.victimCarrying: return dCarrierKill
  if ctx.victimLevel >= AceLevel: return dAceTag
  if ctx.multi: return dSplashMultiKill
  if ctx.rangePx >= longshotPxFor(ctx.gunRange): return dLongshotKill
  if ctx.rangePx <= pointBlankPxFor(ctx.gunRange): return dPointBlankKill
  if ctx.avengesKiller or ctx.avengesPartner: return dRevengeKill
  if ctx.fleeing: return dRunDown
  if ctx.escorted: return dEscortKill
  if ctx.weaponSpray: return dSprayKill
  if ctx.weaponGrenade: return dGrenadeKill
  dHonorableKill

func killXp*(ctx: KillContext): int =
  ## XP for a kill: ZERO, with two exceptions that are not kill rewards.
  ## A friendly kill is a penalty, and the carrier kill is priced as the
  ## FLAG RETURN it causes (the heart goes home because the carrier died).
  ## The kill itself levels nobody -- the damage that produced it already
  ## did, in proportion to who actually dealt it.
  if ctx.friendly: XpTeamKill
  elif ctx.victimCarrying: XpPerReturn
  else: 0

# ───────────────────────────────────────────────────────────────────────────
# §8  THE AUDIT — every deed carries a fire counter, or it is dead code
# ───────────────────────────────────────────────────────────────────────────
#
# Muster shipped, and then found by measurement, at least five reward layers
# that never fired: a drama layer keyed on `unit.glory` when glory lives on
# Army (so `hasattr` was always False and all 11 heads got identical reward
# for 2M steps); a spacing layer checking `.pos` on units that have `.x`/`.y`;
# two assist windows keyed on event types nothing emits. Each looked
# plausible in review. The banked rule is blunt: *never assume a reward layer
# works because the code exists — every layer ships with a per-layer audit
# accumulator, and a layer stuck at 0.0 is DEAD.*
#
# We own the same scar independently: `arcStandoff` taught us that a lever
# which never fires makes an A/B read as a clean no-op, indistinguishable
# from a lever that does nothing, and the lever-liveness audit found the real
# hidden class is a LIVE branch with a permanently null input.
#
# So `SimServer` carries `deedCounts` and `deedGloryMass` per deed. The test
# asserts every deed in the catalog can fire, and the mass readout is what
# tells us whether one deed has become the 64-84%-of-mass layer that steers
# everything. Neither is optional and neither may be gated on `collectEvents`.

func deedName*(deed: Deed): string =
  ## Human-readable herald name, in paintball-league register. NOT a stable
  ## wire contract — its only consumers are `sim.nim`'s stdout herald
  ## (Docker logs, `logGameEvent`) and a non-asserting debug `echo` in
  ## `tests/test_glory_sim.nim`. Free to reword; nothing parses this string.
  case deed
  of dNone: "none"
  of dFirstBlood: "first tag"
  of dHonorableKill: "clean tag"
  of dSprayKill: "spray tag"
  of dGrenadeKill: "bomb tag"
  of dPointBlankKill: "point blank tag"
  of dLongshotKill: "longshot tag"
  of dSplashMultiKill: "double splash"
  of dRevengeKill: "payback"
  of dRunDown: "chase down"
  of dAceTag: "ace tag"
  of dTeamKill: "own paint"
  of dFlagSteal: "heart steal"
  of dCapture: "capture"
  of dCarrierKill: "the peel"
  of dDenial: "doorstep stop"
  of dEscortKill: "escort tag"
  of dAssist: "assist"
  of dRescue: "rescue"
  of dClutchHeal: "clutch patch"
  of dShieldSoak: "shield soak"
  of dWipe: "wipeout"
  of dLevelUp: "rank up"
  of dAchievement: "achievement"
  of dDuoDown: "duo down"
  of dClosingTime: "closing time"
  of dLastLight: "last light"
  of dVictory: "victory"

func deedPopWord*(deed: Deed): string =
  ## 🎖 (VOCABULARY wave, V4, Maxwell's ruling: "instead of splat appearing on
  ## the dead body... we should have a one word name for each thing that
  ## causes glory") ONE word (or one punchy compound) that rides beside a
  ## deed's floating "+Ng" score pop, in the crowd's own kids'-paintball
  ## register. Deliberately its OWN table, not derived from `deedName`:
  ## `deedName` is prose ("point blank tag") built for a log LINE, this is a
  ## one-line HUD tag built to be read in a third of a second at speed --
  ## different jobs, different lengths, so they diverge for `dPointBlankKill`,
  ## `dDenial`, `dAceTag` and others below. NOT a stable wire contract, same
  ## rule as `deedName`: free to reword.
  ##
  ## Empty string for anything that can't be honestly one-worded OR never
  ## reaches the pop in the first place -- `dNone` (never minted),
  ## `dShieldSoak` and `dAchievement` (both excluded by `popsScore`; a claim
  ## pops through the LABELLED achievement path instead, carrying its own
  ## name). The renderer falls back to a bare "+N" for an empty word, so a
  ## future deed added here with no entry degrades safely instead of drawing
  ## garbage.
  ##
  ## `dLevelUp` is ALSO excluded by `popsScore` (v10) but keeps a real word
  ## here anyway -- `addXp` (sim.nim) reads `deedPopWord(dLevelUp)` directly
  ## to build its own star-count label ("RANK UP **") rather than going
  ## through the generic deed/word pop path this table otherwise feeds, so
  ## the word stays live code, not just a comment (contrast `dClutchHeal`
  ## below, whose retired word is memorial-only).
  case deed
  of dNone: ""
  of dFirstBlood: "FIRST!"
  of dHonorableKill: "TAG"
  of dSprayKill: "SPRAYED"
  of dGrenadeKill: "BOMBED"
  of dPointBlankKill: "POINT-BLANK"
  of dLongshotKill: "LONGSHOT"
  of dSplashMultiKill: "MULTI!"
  of dRevengeKill: "PAYBACK"
  of dRunDown: "CHASE"
  of dAceTag: "BOUNTY"       ## not "ACE" -- `Bounty` is already this exact
                             ## threshold's achievement name (gun tree, tier
                             ## III), so the pop and the tier it feeds read
                             ## as the same idea.
  of dTeamKill: "OWN PAINT"  ## matches the herald, which already says this.
  of dFlagSteal: "STEAL"
  of dCapture: "CAPTURE"
  of dCarrierKill: "PEEL"    ## `deedName`'s own "the peel" -- the deed's
                             ## established nickname everywhere else in this
                             ## codebase, so the pop and the doc comments
                             ## agree.
  of dDenial: "DENIED!"
  of dEscortKill: "ESCORT"
  of dAssist: "ASSIST"
  of dRescue: "RESCUE"
  of dClutchHeal: ""         ## v9: excluded from `popsScore` (zero+
                             ## tombstoned, GLORY LAW E1); never drawn. The
                             ## word stays on record ("SAVE") only in this
                             ## comment, not in code that could draw it.
  of dShieldSoak: ""         ## excluded from `popsScore`; never drawn.
  of dWipe: "WIPEOUT"
  of dLevelUp: "RANK UP"    ## v10: excluded from `popsScore`, but read
                             ## directly by `addXp` (sim.nim) for its own
                             ## star-count pop -- see this table's own
                             ## header comment.
  of dAchievement: ""        ## excluded from `popsScore`; claims carry their
                             ## own name through the labelled pop path.
  of dDuoDown: "DUO DOWN"    ## v13 marquee band (armed+brMode mints only).
  of dClosingTime: "CLOSING TIME"
  of dLastLight: "LAST LIGHT"
  of dVictory: "VICTORY"

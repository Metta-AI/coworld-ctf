## Glory: the priced-deed economy, the achievement curriculum, and the
## per-life unit ladder. Ported from Muster's `src/server/glory_spec.py` +
## `patronage.py`, re-fit to paintbot (see docs/designs/GLORY.md).
##
## **This module is the SINGLE SOURCE OF TRUTH for every glory number.** The
## sim mints through `deedGlory`/`deedDrama`, the achievement tracker prices
## through `tierGlory`, and the ladder reads `LevelThresholds`. Muster's
## lockstep principle: one accessor, so a table can never drift from its
## consumer. An unknown deed prices at zero rather than a stray value.
##
## **Three things here are causal, not analysis.** Unlike the tier-2 SimEvent
## channel, glory changes gameplay: XP drives levels, levels grant buffs, and
## buffs change hit points, fire timing and range. So every number below is
## INTEGER (no float drift across platforms), the ledger enters `gameHash`,
## and nothing here may be gated on `collectEvents`.
##
## **The anti-snowball rule is that levels are PER LIFE.** A cog's XP resets
## to zero on death and its buffs go with it. A runaway cog is therefore also
## a fat bounty (`dStarfall`), and the counter-play to a snowball is the same
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
    dStarfall          ## killing a StarfallLevel+ cog — a named character
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

    # ── Survival and support ─────────────────────────────────────────────
    dClutchHeal        ## healing at 1 hp. Our medkit rate is 0.62/Ep against
                       ## winners' 1.84-2.60; this prices the gap directly.
    dShieldSoak        ## per hit point your shield absorbed for the team.
    dWipe              ## the enemy team eliminated.

    # ── Progression ──────────────────────────────────────────────────────
    dLevelUp           ## a cog gained a level: the feed notices, the ledger
                       ## barely does (Muster's `star_up`).
    dAchievement       ## an achievement tier claimed; priced by tier, not
                       ## here. Never climbs heat (see `paysHeat`).

const
  GloryVersion* = 5
    ## Bumped on any pricing change, so a ledger can be attributed to the
    ## table that produced it. A cross-version comparison is invalid.
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
    40,     # dStarfall
    -60,    # dTeamKill  (NEGATIVE: a teammate's life at full price)
    # objective
    40,     # dFlagSteal
    250,    # dCapture
    90,     # dCarrierKill
    120,    # dDenial
    14,     # dEscortKill
    # survival and support
    25,     # dClutchHeal
    4,      # dShieldSoak (per hit point)
    400,    # dWipe
    # progression
    6,      # dLevelUp
    0,      # dAchievement (priced by tier — see TierGlory)
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
    30,     # dStarfall — a named cog dies
    0,      # dTeamKill — anti-drama; it costs glory but must never light heat
    # objective
    25,     # dFlagSteal
    70,     # dCapture
    35,     # dCarrierKill
    45,     # dDenial
    15,     # dEscortKill
    # survival and support
    30,     # dClutchHeal
    0,      # dShieldSoak — ambient soak, funds you, is not a moment
    400,    # dWipe
    # progression
    5,      # dLevelUp — the feed notices, the ledger barely does
    0,      # dAchievement — tier-priced (TierDrama)
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

  HeatLadder* = [1, 2, 4, 8]
    ## Multiplier by rung. x2 is a solo kill, x4 is a few back-to-back, x8 is
    ## a genuine rampage.
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
  SiteMultNeutralPct* = 120   ## the open field.
  SiteMultEnemyPct* = 150     ## initiative into DEFENDED ground.

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

  LevelThresholds* = [10, 18, 24, 36, 50]
    ## Cumulative XP for levels 1..5, within ONE life. FIT FROM THE REAL
    ## FIELD (tools/ladder/gloryscore.py over 120 two-team league episodes,
    ## 2026-08-21): under work-based xp an active life peaks at p50=9,
    ## p90=24, p99=48 (post the mirror's peel-order fix; and note the scored
    ## field is v0.7.9x, which emits no item_pickup events -- re-fit when
    ## 0.7.2xx event files land in the cache, since pickup/heal xp will push
    ## these peaks up) -- so L1 catches a decent life (~p55), L3 (the plume,
    ## tithe and starfall threshold) lands at ~p92 = the 1-2 per team-episode
    ## design target, and L5 sits at ~p99, the once-an-episode legend. The
    ## earlier [12,30,60,100,160] was guessed against kill-based xp and made
    ## L5 a never-an-episode legend (0 in 120 real episodes).
    ## The shape is Muster's rolestreak ladder (per life, reset on death),
    ## NOT its veterancy ladder (career, never resets). Paintbot has no
    ## career, so we get to ship ONE ladder and skip the scar Muster carries:
    ## its two 5-star ladders sit ~4x apart, and any analysis joining them
    ## joins on a false key.
    ##
    ## RE-MEASURED 2026-08-25 (GLORY C1, after zeroing the bare-touch pickup
    ## xp below): monkeypatched a copy of `score_episode_derived` with the
    ## grenade/spray_can/shield `item_pickup` branches paying 0 instead of
    ## `XP_PICKUP` (the med_kit branch untouched, matching the sim-side cut),
    ## re-ran over the SAME 120-episode selection gloryscore.py's own
    ## `--min-version 0.7.200` default resolves today. Result: BYTE-IDENTICAL
    ## percentiles (p25:6 p50:9 p75:15 p90:24 p95:30 p98:39 p99:48, 4820/6870
    ## active lives) and cadence (L3+ mean 2.04/team-ep, L5 mean 0.32/ep) --
    ## because that version filter is a STRING compare ("0.7.95" >= "0.7.200"
    ## is true lexically), the selected sample is still entirely v0.7.95-98,
    ## which emits ZERO `item_pickup` events (confirmed directly: 0 pickup
    ## rows across all 120 selected files). So the bare-touch xp this wave
    ## deletes was ALREADY contributing nothing to the distribution that fit
    ## these thresholds -- they hold unchanged, not re-derived. The real test
    ## (does the cut change anything once pickups are on the wire) still
    ## needs the 0.7.2xx cache the original comment above was already
    ## waiting on.

  # ── What levels a cog: WORK, not kills (Maxwell's ruling, 2026-08-21) ──
  #
  # TWO CURRENCIES, TWO QUESTIONS -- keep them split:
  #
  #   XP     (this block)  per-COG. Pays the PROCESS: damage landed, healing
  #                        taken, tools picked up, flag play. Drives the
  #                        ladder and therefore the buffs. Kills pay ZERO.
  #   GLORY  (DeedGlory)   per-TEAM. Pays OUTCOMES and DRAMA: kills,
  #                        multikills, starfall, the peel, first blood --
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
  XpPerHeal* = 3              ## per hit point a med kit restores. Healing is
                              ## levelling work in itself, not just the
                              ## clutch save -- and it is aimed at our
                              ## measured 0.62 kits/Ep vs winners' 1.84-2.60.
  XpPerClutchHeal* = 6        ## ON TOP of the restore: the save at 1 hp.
  XpPerPickup* = 4            ## ⚠️ v6 (GLORY C1, Maxwell's own law: "these
                              ## are things where the player goes above and
                              ## beyond normal gameplay" -- extended here from
                              ## achievements to xp): a BARE touch is not
                              ## work, so this only still pays at the ONE
                              ## pickup site that is genuinely work-gated --
                              ## `tryPickupMedKits`/the med-kit tithe, where
                              ## the engine refuses the pickup entirely unless
                              ## the cog is already hurt (`hp < playerMaxHp`),
                              ## so every mint of this constant sits on top of
                              ## a real heal. Taking a grenade, spray can or
                              ## shield mints ZERO xp now -- see the "no xp
                              ## here" comments at their pickup sites in
                              ## sim.nim. Re-measured against the real field
                              ## post-cut: no change (see `LevelThresholds`'s
                              ## own re-measurement note -- this era's cache
                              ## never had pickup xp in it to begin with).
  XpPerShieldSoak* = 2        ## per hit point absorbed for the team.
  XpPerSteal* = 12            ## flag actions are the objective spine.
  XpPerCapture* = 30
  XpPerReturn* = 12
    ## The heart returns home when its carrier dies, so in THIS game the peel
    ## IS the return: killXp prices the carrier kill as this FLAG ACTION, not
    ## as a kill. (This constant shipped dead once -- declared, zero
    ## consumers -- the third instance of the dead-layer class in this
    ## project. The mirror tool gloryscore.py greps would have caught it;
    ## now the wire is killXp itself.)
  XpTeamKill* = -20
    ## Friendly fire actively DE-LEVELS you. The one place the ladder bites
    ## back, and it is aimed at the loss that was once 0.81 lives/Ep.

  StarfallLevel* = 3
    ## Killing a cog at this level or above pays `dStarfall`. This is the
    ## mechanic that makes a levelled enemy a walking bounty and your own
    ## veteran worth escorting — the reason the power fantasy does not run
    ## away with an episode. It is also the level the crowd can SEE: at
    ## StarfallLevel a cog wears the ember plume (`LabelVeteranMark`) and its
    ## team's heart starts producing kit (the tithe, below).

  # ── THE TITHE: a 3-star cog makes their own heart produce kit ───────────
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
  # So the tap is fed by EARNING, not by STANDING. Every TitheXp points of
  # NEW xp scored at StarfallLevel or above drops one pickup at the team's
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

  TitheXp* = 20
    ## New xp per pickup produced. At XpPerDamage 3 that is roughly a
    ## pickup every 7 hit points landed once the plume is lit.
  TitheCooldownTicks* = 90
    ## Minimum ticks between two pickups from one heart, so a single
    ## multi-kill burst cannot dump the whole allowance at once.
  TitheMaxPerLife* = 4
    ## Hard ceiling per cog per LIFE. With the per-life reset this bounds the
    ## whole mechanic: a team's kit income is capped by how many veterans it
    ## can keep alive, and every one of them is a `dStarfall` bounty.

  # ── The kit cycle a tithed heart produces ───────────────────────────────
  # Fixed rotation rather than a roll: the sim's RNG draws are load-bearing
  # for replay determinism, and a rotation needs none. Medkit leads because
  # our heal rate is the measured gap (0.62/Ep against winners' 1.84-2.60).
  TitheCycle* = ["med kit", "grenade", "spray can", "shield"]

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
  #   L2 Marksman   gun range +15%,       reach, and the spray finally recycles
  #                 spray reset -40%
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
  LevelGunRangePct*: array[0 .. MaxLevel, int] = [100, 100, 115, 115, 115, 115]
    ## Gun range as a percentage of the map's default.
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
  DenialPx* = 220             ## a carrier killed this close to their own
                              ## pedestal died on the doorstep.
  RevengeTicks* = 240         ## ~10s to answer your killer.
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

  TierGlory*: array[AchievementTiers, int] = [2, 4, 8, 16, 32]
  TierDrama*: array[AchievementTiers, int] = [5, 5, 15, 15, 30]  ## tenths
  AchievementFirstMultPct* = 300
    ## The first team in the episode to complete a tier claims at x3.
  AchievementSweepBudgetPct* = 15
    ## Law 3 as Muster states it: a full sweep must stay under this share of a
    ## MEDIAN WINNER's episode glory.
    ##
    ## ⚠️ UNCALIBRATED. We have no measured median for paintbot yet, and a
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
    treeShield      ## the endzone armor: soak, not damage.
    treeMedKit      ## the heal line, where we run 5.9x worse than winners.
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
     "Bounty",              ## III  killed a level>=StarfallLevel enemy
     "Longshot",            ## IV   a kill past LongshotPx
     "Sharpshooter"],       ## V    a cog reaches max rank (L5)
    # treeSpray — "The Can". v3: "Shake It" (pick up a can) is GONE.
    ["First Coat",          ## I    a spray kill
     "Full Coverage",       ## II   2 spray kills in one game
     "Repainted",           ## III  2 spray kills on one pickup
     "The Muralist",        ## IV   3 spray kills on a single pickup
     "Double Splash"],      ## V    one cone activation kills 2+ enemies
    # treeGrenade — "The Bomb". v3: "Pull the Pin" (pick up a nade) is GONE.
    ["Delivery",            ## I    a grenade kill
     "Fireball",            ## II   2 grenade kills in one game
     "The Bombardier",      ## III  3 grenade kills in one game
     "Blast Radius",        ## IV   a grenade kill plus a 2+ multikill
     "Double Blast"],       ## V    one blast kills 2+ enemies
    # treeShield — "The Wall". v3: "Suit Up" (pick up a shield) is GONE.
    ["Aegis",               ## I    absorb 3 hp
     "Blockade",            ## II   absorb 6 hp in one game
     "Bulwark",             ## III  absorb 6 hp AND land an enemy kill
     "Rampart",             ## IV   absorb 9 hp in one game
     "Atlas"],              ## V    absorb 12 hp in one game
    # treeMedKit — "The Patch". v3: "Field Dressing" (take a med kit) is
    # GONE -- the take is normal play; the SAVE it buys is the achievement.
    ["The Save",            ## I    heal at 1 hp
     "Triage",              ## II   2 clutch heals in one episode
     "Second Wind",         ## III  a KILL landing within 120 ticks of your
                            ##      latest clutch heal -- detected at the
                            ##      kill site, so the heal must come FIRST
                            ##      (v3.1: the poll used to compare "now" to
                            ##      the heal tick and never checked order or
                            ##      that a kill fell inside the window at
                            ##      all -- CURRICULUM audit C6/C7).
     "Miracle Worker",      ## IV   3 clutch heals in one episode
     "Lifeline"],           ## V    a clutch heal taken WHILE CARRYING the heart
    # treeCarrier — "The Heart". v3.1 (CURRICULUM audit C1/C8): tier I/II used
    # to read `steals >= 1` (an uncontested pickup, satisfiable by walking
    # into an empty base) and live `carryingFlag` plus a hold timer (pure
    # possession-plus-duration) -- both law-2b violations no different from
    # the pickup tiers v3 already deleted everywhere else, exempted only by a
    # comment's ASSERTION that carrier play is special. It is not: re-cut to
    # the same standard as every other tree -- a CONVERTED, contested act.
    ["Hands On",            ## I    a steal landed while a LIVE enemy stood
                            ##      within ContestedStealPx -- an uncontested
                            ##      walk-in no longer counts.
     "Fighting Carry",      ## II   an enemy kill landed WHILE CARRYING the
                            ##      heart -- live possession alone (the old
                            ##      "hold for 120+ ticks") no longer counts.
     "Delivered",           ## III  score the enemy heart
     "Uphill",              ## IV   score while your team is outnumbered
     "Full Run"],           ## V    steal and score on the same life
    # treeDefender — "The Peel". v3: "Eyes Back" (a heart return) is GONE --
    # `resetFlag` credits `returns` to every LIVING teammate when a heart
    # comes home, not to whoever caused it, so it was bystander credit, not
    # an individual act (see the comment at `resetFlag` in sim.nim).
    ["The Peel",            ## I    kill the enemy carrier
     "Doorstep",            ## II   a denial inside DenialPx
     "Double Peel",         ## III  2 carrier kills in one game
     "Turnaround",          ## IV   peel then steal within RevengeTicks
     "Lockdown"],           ## V    2 denials in one episode
    # treeSquad — "The Squad" (TEAM tree). Kit tiers now read CONVERSION
    # (`teamConvertedKits`) -- a teammate landed the kit's signature act --
    # never live possession, which was arrival wearing a team hat.
    ["Kitted",              ## I    2 of 4 kits CONVERTED, team-wide
     "Combined Arms",       ## II   3 of 4 kits converted
     "Full Kit",            ## III  4 of 4 kits converted
     "Clean Sheet",         ## IV   FULL-GAME zero team kills (conclusion-only)
     "The Parade"],         ## V    4 of 4 converted AND a capture this game
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
  ## `dAchievement` is excluded because a claim pops through `claimAchievement`'s
  ## LABELLED path instead, carrying the name it just earned. Popping it here
  ## too would price one moment twice on screen.
  ##
  ## A PENALTY still pops. `dTeamKill` is 0-drama (anti-drama: it must never
  ## light heat) but friendly fire is the largest single loss we have measured,
  ## so "-60g" over the body is one of the most valuable things on this HUD.
  ## That is why this is NOT `isDrama`, which would silently swallow it.
  deed != dShieldSoak and deed != dAchievement

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

func levelForXp*(xp: int): int {.inline.} =
  ## Level 0..MaxLevel for a cog's CURRENT-LIFE xp. Monotonic in xp, so a
  ## level can never dip while the life continues.
  result = 0
  for threshold in LevelThresholds:
    if xp >= threshold:
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
    weaponSpray*: bool
    weaponGrenade*: bool
    avengesKiller*: bool   ## the victim had killed this cog inside RevengeTicks.
    fleeing*: bool         ## the victim was moving away from the killer.
    escorted*: bool        ## a TEAMMATE of the killer -- not the killer --
                           ## currently carries the enemy heart. Distinct from
                           ## `victimCarrying`, which is about what the VICTIM
                           ## held; this is about what the KILLER's own side
                           ## is running. The killer's own carry already gets
                           ## `CarrierHoldMultPct`'s multiplier through
                           ## `mintGlory`, so this prices covering the runner
                           ## as its own act rather than double-counting theirs.

func killDeed*(ctx: KillContext): Deed =
  ## Resolve a kill to its ONE deed. Order is the pricing hierarchy: the
  ## penalty first so a friendly kill can never be dressed up as a highlight,
  ## then the objective context (what the victim was DOING outranks how they
  ## were shot), then the shot itself. `escorted` sits below every marquee
  ## kill descriptor (starfall, multi, longshot, point-blank, revenge,
  ## rundown) -- it describes the surrounding TEAM context, not the kill
  ## itself, so a kill that is ALSO one of those stays classified as the more
  ## specific, rarer feat. It sits above the plain weapon/floor tiers so an
  ## escort kill is reachable at all: those three would otherwise catch every
  ## remaining kill first.
  if ctx.friendly: return dTeamKill
  if ctx.victimCarrying and ctx.nearVictimHome: return dDenial
  if ctx.victimCarrying: return dCarrierKill
  if ctx.victimLevel >= StarfallLevel: return dStarfall
  if ctx.multi: return dSplashMultiKill
  if ctx.rangePx >= LongshotPx: return dLongshotKill
  if ctx.rangePx <= PointBlankPx: return dPointBlankKill
  if ctx.avengesKiller: return dRevengeKill
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
  of dStarfall: "starfall"
  of dTeamKill: "own paint"
  of dFlagSteal: "heart steal"
  of dCapture: "capture"
  of dCarrierKill: "the peel"
  of dDenial: "doorstep stop"
  of dEscortKill: "escort tag"
  of dClutchHeal: "clutch patch"
  of dShieldSoak: "shield soak"
  of dWipe: "whitewash"
  of dLevelUp: "rank up"
  of dAchievement: "achievement"

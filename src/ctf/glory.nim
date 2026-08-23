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
## as the counter-play to everything else: kill it. This is a DELIBERATE
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
                       ## dies. This is what makes a leveller a bounty.
    dTeamKill          ## NEGATIVE. Friendly fire cost us up to 63% of the
                       ## death gap before v59; pricing it keeps it closed.

    # ── Objective ────────────────────────────────────────────────────────
    dFlagSteal         ## the heart left its pedestal on your back.
    dFlagReturn        ## you sent your heart home.
    dCapture           ## you scored the enemy heart.
    dCarrierKill       ## THE PEEL: killing the enemy carrier. Invisible in
                       ## every readout we own today, and the highest-value
                       ## defensive act in the game.
    dDenial            ## killing a carrier inside DenialPx of their home —
                       ## the capture stopped on the doorstep.
    dEscortKill        ## a kill landed while a teammate carries: the escort.

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
  GloryVersion* = 2
    ## Bumped on any pricing change, so a ledger can be attributed to the
    ## table that produced it. A cross-version comparison is invalid.
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
    35,     # dFlagReturn
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
    15,     # dFlagReturn
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
  HeatThresholds* = [1, 4, 10]
    ## Cumulative embers to reach each rung above x1.
  HeatEmberCap* = 12
    ## Just above the x8 floor: a tear maxes the ladder, but no streak can
    ## HOARD heat that survives going quiet.
  HeatEmberDecay* = 4
    ## Embers shed per quiet window — about a rung, so flames bleed inside
    ## one or two windows rather than minutes.
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
  XpPerPickup* = 4            ## taking ANY kit (med kit, grenade, spray can,
                              ## shield). One-shot per pickup and bounded by
                              ## the spawn timers, so it cannot be farmed;
                              ## it pays the go-and-get-tools behaviour that
                              ## is our measured conversion weakness.
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
  #   L1 Blooded    windup -1 tick        the lead we measured at +70pp
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
    "recruit", "blooded", "marksman", "ironhide", "quickdraw", "legend"
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
    treeDefender    ## peel, return, deny.
    treeSquad       ## TEAM: the full kit fielded at once.

const
  AchievementNames*: array[Tree, array[AchievementTiers, string]] = [
    # treeGun — "The Sidearm"
    ["Trigger Discipline",  ## I    land a gun hit
     "Blooded",             ## II   a gun kill
     "Marksman",            ## III  3 gun kills in one game
     "Longshot",            ## IV   a kill past LongshotPx
     "Deadeye"],            ## V    a cog reaches max rank (L5)
    # treeSpray — "The Can"
    ["Shake It",            ## I    pick up a spray can
     "First Coat",          ## II   a spray kill
     "Full Coverage",       ## III  2 spray kills plus a multikill, one game
     "Repainted",           ## IV   2 spray kills on one pickup
     "The Muralist"],       ## V    3 spray kills on a single pickup
    # treeGrenade — "The Bomb"
    ["Pull the Pin",        ## I    pick up a grenade
     "Delivery",            ## II   a grenade kill
     "Fireball",            ## III  2 grenade kills in one game
     "Blast Radius",        ## IV   a grenade kill plus a 2+ multikill
     "The Bombardier"],     ## V    3 grenade kills in one game
    # treeShield — "The Wall"
    ["Suit Up",             ## I    pick up a shield
     "Aegis",               ## II   absorb 3 hp
     "The Door Holds",      ## III  absorb 6 hp in one game
     "Bulwark",             ## IV   absorb 6 hp AND land an enemy kill
     "Atlas"],              ## V    absorb 12 hp in one game
    # treeMedKit — "The Patch"
    ["Field Dressing",      ## I    take a med kit
     "The Save",            ## II   heal at 1 hp
     "Triage",              ## III  2 clutch heals in one episode
     "Back From the Dead",  ## IV   clutch-heal then kill within 120 ticks
     "Miracle Worker"],     ## V    3 clutch heals in one episode
    # treeCarrier — "The Heart"
    ["Hands On",            ## I    steal the enemy heart
     "Breakaway",           ## II   hold the heart for 120+ ticks
     "Delivered",           ## III  score the enemy heart
     "Against the Odds",    ## IV   score while your team is outnumbered
     "The Long Walk"],      ## V    steal and score on the same life
    # treeDefender — "The Peel"
    ["Eyes Back",           ## I    return your heart
     "The Peel",            ## II   kill the enemy carrier
     "Doorstep",            ## III  a denial inside DenialPx
     "Turnaround",          ## IV   peel then steal within 240 ticks
     "Nothing Gets Through"], ## V  2 denials in one episode
    # treeSquad — "The Squad" (TEAM tree)
    ["Kitted",              ## I    hold 2 distinct pickups at once, team-wide
     "Combined Arms",       ## II   3 distinct pickups at once
     "Full Kit",            ## III  all 4 pickups live at once
     "Clean Sheet",         ## IV   reach tick 600 with zero team kills
     "The Parade"],         ## V    all 4 pickups live AND a capture this game
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

func killDeed*(ctx: KillContext): Deed =
  ## Resolve a kill to its ONE deed. Order is the pricing hierarchy: the
  ## penalty first so a friendly kill can never be dressed up as a highlight,
  ## then the objective context (what the victim was DOING outranks how they
  ## were shot), then the shot itself.
  if ctx.friendly: return dTeamKill
  if ctx.victimCarrying and ctx.nearVictimHome: return dDenial
  if ctx.victimCarrying: return dCarrierKill
  if ctx.victimLevel >= StarfallLevel: return dStarfall
  if ctx.multi: return dSplashMultiKill
  if ctx.rangePx >= LongshotPx: return dLongshotKill
  if ctx.rangePx <= PointBlankPx: return dPointBlankKill
  if ctx.avengesKiller: return dRevengeKill
  if ctx.fleeing: return dRunDown
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
  ## Stable wire/report name. Used by the feed, the audit dump and the
  ## replay ledger, so it must not drift from the enum.
  case deed
  of dNone: "none"
  of dFirstBlood: "first blood"
  of dHonorableKill: "honorable kill"
  of dSprayKill: "spray kill"
  of dGrenadeKill: "grenade kill"
  of dPointBlankKill: "point blank kill"
  of dLongshotKill: "longshot kill"
  of dSplashMultiKill: "splash multikill"
  of dRevengeKill: "revenge kill"
  of dRunDown: "run down"
  of dStarfall: "starfall"
  of dTeamKill: "team kill"
  of dFlagSteal: "heart steal"
  of dFlagReturn: "heart return"
  of dCapture: "capture"
  of dCarrierKill: "carrier kill"
  of dDenial: "denial"
  of dEscortKill: "escort kill"
  of dClutchHeal: "clutch heal"
  of dShieldSoak: "shield soak"
  of dWipe: "wipe"
  of dLevelUp: "level up"
  of dAchievement: "achievement"

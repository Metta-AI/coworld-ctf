## Glory: paintbot's own score, PORTED onto Battle Royale (GV45+). Every
## kill, save and clean play mints GLORY to a team's ledger; a streak of it
## lights HEAT, a rung of rampage multiplier that only pays while you keep
## playing. Separately, each cog climbs a five-rung ladder by doing real
## work -- damage landed, kits converted -- and each rung buys a real,
## playable buff. Achievements are the third leg: a curriculum of named
## feats a team can chase without needing to win outright. Read
## docs/designs/GLORY.md for the original, paintbot-native tour (score
## fiction, deeds, heat, achievements, xp/stars, versioning) -- nothing here
## requires knowing any OTHER game to make sense.
##
## **BR PORT NOTES (this file forked from main's `src/ctf/glory.nim` at
## GloryVersion 10; see `GloryVersion`'s own comment below for the full
## divergence list).** Two structural facts about BR change what "glory"
## means here, both load-bearing, neither a redesign of the mechanism:
##
##   1. BR is ONE LIFE, not several. `killPlayer` sets `lives = 0`
##      unconditionally on any brMode death (no respawns, ever) -- so
##      calling `resetLadder` at that moment is a no-op in every practical
##      sense: the seat being reset is already permanently out. The
##      per-life ladder therefore degenerates CORRECTLY into a one-life
##      power curve with no redesign -- "climb once during your one life;
##      dying ends the climb because it ends you."
##   2. BR's real maps are FLAGLESS, unconditionally
##      (`tools/br_spec_to_ctf.nim:93`; confirmed structurally, not just by
##      convention: `tryPickupFlags` refuses outright on a flagless map, so
##      `carryingFlag`/`flags[team].carrier` can never leave their initial
##      state). Every flag-keyed deed (`dFlagSteal`, `dCapture`,
##      `dCarrierKill`, `dDenial`, `dEscortKill`), the carry-hold multiplier,
##      and two whole achievement trees (`treeCarrier`, `treeDefender`) are
##      therefore PERMANENTLY UNREACHABLE on a real BR match. They are KEPT
##      in this file rather than deleted -- both because `gameHash` must
##      stay mode-independent (a flagged map run through this same engine is
##      a live path; see `sim_state.gameHash`'s own header) and because a
##      future flagged BR mode is not ruled out -- but their unreachability
##      on today's real maps is made EXPLICIT and TESTED at the sim-side
##      gate (`satisfiedAchievements` in sim.nim), not left as a silent
##      dead branch. See that proc's own comment for the enforcement.
##
## **v1 (this port) SHIPS WITHOUT THE SUPPLY DROP.** BR has zero supply-drop
## code today (no `SupplyDropPickup`, no spawn/expire/pickup lifecycle) --
## building it is a feature add, not a port, so it is deliberately deferred
## (Maxwell's call, pending). Every supply-drop-specific constant/field main
## carries (`SupplyDropXp`, `SupplyDropCooldownTicks`, `SupplyDropMaxPerLife`,
## `SupplyDropCycle`, `Player.supplyDropCredit/supplyDropsThisLife/
## lastSupplyDropTick/supplyShared/supplySaves`) is CUT from this file and
## from BR's `Player`, not stubbed -- absent feature, absent fields, the
## same discipline `hasBarrier`/`puddleTicks` already hold BR's own
## config-gated features to. `AceLevel` and the level ladder are UNCHANGED
## by this cut (they buff windup/hp/cooldown/spray-reset/grenade-charges/
## carrier-speed on their own); only the "a veteran's heart produces kit"
## flavor mechanic and `treeMedKit` (which gates entirely on the consume-a-
## drop counters this cut removes) are affected -- `treeMedKit` joins
## `treeCarrier`/`treeDefender` as explicitly-unearnable-in-v1, same
## enforcement pattern, see `satisfiedAchievements`.
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
## episode. ON BR this mechanism degenerates but does not disappear: a
## brMode death is permanent (one life), so `resetLadder` firing at that
## death is a no-op in EVERY practical sense -- there is no next life for
## the reset to matter to. The anti-snowball property BR gets instead comes
## from a different layer entirely (elimination itself: a snowballing cog
## that finally dies takes its whole seat out of the game, not just its
## buffs) -- see `resetLadder`'s BR call site in `killPlayer` for the
## mechanical note.
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

const
  GloryVersion* = 1
    ## BR's OWN version track, starting fresh at the port -- NOT comparable
    ## to main's `GloryVersion` (which reached 10 before this file forked
    ## from it at that point). Bumped on any pricing/gating change here, so
    ## a BR ledger can be attributed to the table that produced it, same
    ## discipline main's history (see git log on `src/ctf/glory.nim` before
    ## the fork) already established.
    ##
    ## v1 (this port, GV45+): the initial BR port of glory. Ported the full
    ## deed table, heat ladder, site gradient and level ladder unchanged in
    ## SHAPE from main's v10; retuned `LevelThresholds` and redistributed
    ## `DeedGloryTable`'s flag-deed share against a real BR match's own XP/
    ## deed cadence (see this constant's retuning note inline on
    ## `LevelThresholds`, and the Phase 2 report for the full derivation).
    ## Cut the supply drop outright (feature absent, not stubbed -- see this
    ## file's header). `treeCarrier`/`treeDefender`/`treeMedKit` ported but
    ## made EXPLICITLY unearnable on BR's flagless/no-supply-drop reality,
    ## enforced and tested at `satisfiedAchievements` (sim.nim), not left
    ## silently dead. Achievements gained a continuous-eval engagement gate
    ## (`brAchievementEngaged`, sim.nim) mirroring BR's own win-gated
    ## `brEngaged` pattern (sim.nim, pacifist/spotless) -- glory's tiers are
    ## NOT win-gated like BR's native set, so without this gate an
    ## unengaged/hiding team could farm a continuously-evaluated tier BR's
    ## own achievement audit already fixed once for its native system (see
    ## `tests/test_br_placement.nim`'s header).

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
    ## Cumulative XP for levels 1..5, within ONE life.
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
  XpPerCapture* = 30
    ## DESIGN-CONSISTENCY CHECK (GLORY C7, not a field-fit):
    ## `levelForXp(XpPerCapture) == 3` -- a single capture alone promotes a
    ## fresh life straight to L3, the plume/supply-drop/ace threshold.
    ## Intentional: completing the objective should feel like an instant
    ## power spike, not a fractional xp tick. Still ⚠️ UNCALIBRATED against
    ## any real paintbot capture-value field measurement -- this only checks
    ## that the number is INTERNALLY consistent with the ladder it feeds.
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
    ## AceLevel a cog wears the ember plume (`LabelVeteranMark`).
    ##
    ## BR v1: the physical "heart produces kit" half of this (main's supply
    ## drop -- `SupplyDropXp`/`SupplyDropCooldownTicks`/`SupplyDropMaxPerLife`/
    ## `SupplyDropCycle`/`dropSupply`/`SupplyDropPickup`) is CUT, not stubbed
    ## -- see this file's own header note. AceLevel still marks veteran
    ## status (the plume, `dAceTag` bounty pricing, the buff ladder) with
    ## zero change; only the physical pickup-spawning tap and `treeMedKit`
    ## (which gated on consuming one) are affected.

  # ── What each level BUYS ────────────────────────────────────────────────
  #
  # Muster grants no mechanical power at all: a 5-star champion has the same
  # speed, damage, hp and vision as the primer beside it, and the ruling in
  # `unit_skill_trees.py` is explicit that this is deliberate — "a unit's
  # strength CAUSES its star count, not the reverse. This is pure
  # measurement." We are inverting that on purpose.
  #
  # The ladder is built so that every rung grants a distinct CAPABILITY
  # rather than a bigger number, so a levelled cog plays differently instead
  # of just harder. Values are cumulative and applied at five integer sites
  # in `sim.nim`; all arithmetic stays integer.
  #
  # RANK RENAME (Maxwell, 2026-08-28, vocabulary only -- mechanics/
  # thresholds/xp/star-counts below are UNTOUCHED): a rank names the PERSON,
  # not the piece -- "a masterpiece is the piece, not the artist making it."
  # Recruit/Tagger/Marksman/Ironhide/Quickdraw/Legend -> Primer/Dabbler/
  # Splatter/Drencher/Artist/Maestro. L5 was briefly considered as
  # "Muralist," which collides with THE CAN's own tier IV achievement name
  # ("The Muralist", `AchievementNames`, treeSpray) -- re-ruled to Maestro
  # instead, and "The Muralist" achievement stays exactly as it is.
  #
  #   L1 Dabbler    windup -1 tick        the lead we measured at +70pp
  #   L2 Splatter   spray reset -40%     the spray finally recycles
  #   L3 Drencher   +1 max hp             now a real threat -- and a bounty
  #   L4 Artist     fire cooldown -25%,   rate of fire, and two nade charges
  #                 grenade holds 2
  #   L5 Maestro    windup -1, carry     the once-an-episode legend (hp
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
    ## v6 (GLORY C2): the +15% range rung ("Splatter", L2+) is RETIRED --
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
    "primer", "dabbler", "splatter", "drencher", "artist", "maestro"
  ]
    ## What the feed and the replay pip call each rung. RANK RENAME
    ## (Maxwell, 2026-08-28), vocabulary only -- see the "What each level
    ## BUYS" comment above. L5 is "maestro", not "muralist": that name
    ## collided with THE CAN's own tier IV achievement ("The Muralist"),
    ## which stays exactly as it is.

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
                    ## 🚨 BR v1: EXPLICITLY UNEARNABLE -- gates entirely on
                    ## `supplyShared`/`supplySaves`, both CUT with the supply
                    ## drop (this file's header). Enforced at
                    ## `satisfiedAchievements` (sim.nim), tested, not silent.
    treeCarrier     ## steal, run, score.
                    ## 🚨 BR v1: EXPLICITLY UNEARNABLE on every real BR map.
                    ## All 5 tiers gate on flag facts (steal/carry/capture),
                    ## and BR's real maps are FLAGLESS unconditionally
                    ## (`tools/br_spec_to_ctf.nim:93`) -- `tryPickupFlags`
                    ## refuses outright on a flagless map, so the underlying
                    ## counters can never move. Enforced at
                    ## `satisfiedAchievements` (sim.nim), tested, not silent.
                    ## Kept (not deleted) because `gameHash` and this file
                    ## stay mode-independent -- a hypothetical flagged BR
                    ## config would earn it normally.
    treeDefender    ## peel, deny, turn the tables.
                    ## 🚨 BR v1: EXPLICITLY UNEARNABLE on every real BR map,
                    ## same reasoning as `treeCarrier` immediately above (all
                    ## 5 tiers gate on a carrier that flagless play can never
                    ## produce).
    treeSquad       ## TEAM: the full kit fielded at once.
                    ## 🚨 BR v1: tier V ("Victory Lap") gates on a CAPTURE on
                    ## top of 4/4 kits converted -- unearnable on flagless
                    ## maps for the same reason `treeCarrier` is. Tiers I-IV
                    ## survive (kit conversion doesn't require the flag),
                    ## though tier I-III's "med" leg is itself unearnable
                    ## without the supply drop (`teamConvertedKits`, sim.nim)
                    ## -- so BR v1 can reach at most 3 of 4 kits (nade/spray/
                    ## shield-via-assist), never "Full Kit" (III) or above.

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
    ["Hands On",            ## I    a steal landed while a LIVE enemy stood
                            ##      within ContestedStealPx -- an uncontested
                            ##      walk-in no longer counts.
     "Delivered",           ## II   score the enemy heart (v6, GLORY C4: was
                            ##      III -- field claim rate 18.8% vs
                            ##      "Fighting Carry"'s 11.7% (n=240 team-
                            ##      eps) means THIS is the easier act; swapped.
     "Fighting Carry",      ## III  an enemy kill landed WHILE CARRYING the
                            ##      heart -- live possession alone (the old
                            ##      "hold for 120+ ticks") no longer counts.
                            ##      (v6, GLORY C4: was II -- the rarer act,
                            ##      moved up; see "Delivered" above.)
     "Uphill",              ## IV   score while your team is outnumbered
     "Fast Break"],         ## V    steal the heart and slam it home within
                            ##      `FastBreakTicks` (240t, ~10s) of the
                            ##      steal -- a genuine speed-run act, not
                            ##      possession-plus-duration. (v8, GLORY
                            ##      FAST BREAK wave: replaces "Full Run",
                            ##      which read `captures >= 1 and
                            ##      stealTickThisLife >= 0` -- PROVEN
                            ##      redundant with "Delivered" (II) in this
                            ##      engine, not merely correlated: every
                            ##      capture this engine can ever produce
                            ##      already satisfies that old check, since
                            ##      there is no flag hand-off mechanic (a
                            ##      carry is set once, at the steal, cleared
                            ##      only by that same carrier's death or
                            ##      capture) -- n=45 field claims, identical
                            ##      claim-tick distributions for ("carrier",
                            ##      1) and ("carrier", 4). See `GloryVersion`'s
                            ##      own v8 changelog entry for the full proof
                            ##      this replaces.)
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
     "Full Kit",            ## III  4 of 4 kits converted
     "Clean Sheet",         ## IV   FULL-GAME zero team kills (conclusion-only)
     "Victory Lap"],        ## V    4 of 4 converted AND a capture this game
                            ##      (v6, GLORY C6: was "The Parade" --
                            ##      "victory lap" is the paintball-league
                            ##      idiom for a dominant, capped-off win)
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
    ["Steal the enemy's heart while a live enemy is close enough to contest it.",
     "Carry the enemy's heart all the way home for a capture.",
     "Get a kill while you're carrying the enemy's heart.",
     "Score a capture while your team has fewer players alive than the enemy.",
     "Steal the heart and capture it again in one fast run."],
    ["Kill the enemy who is carrying your team's heart.",
     "Stop a carrier right at your own team's doorstep.",
     "Kill an enemy carrier twice in one game.",
     "Peel a carrier off your heart, then steal the enemy's yourself soon after.",
     "Stop carriers at the doorstep twice in one game."],
    ["Your team gets real use out of 2 of the 4 kits in one game.",
     "Your team gets real use out of 3 of the 4 kits in one game.",
     "Your team gets real use out of all 4 kits in one game.",
     "Finish the whole game without a single teammate shooting a teammate.",
     "Use every kit AND capture the enemy's heart in the same game."],
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
  of dAceTag: "ace tag"
  of dTeamKill: "own paint"
  of dFlagSteal: "heart steal"
  of dCapture: "capture"
  of dCarrierKill: "the peel"
  of dDenial: "doorstep stop"
  of dEscortKill: "escort tag"
  of dClutchHeal: "clutch patch"
  of dShieldSoak: "shield soak"
  of dWipe: "wipeout"
  of dLevelUp: "rank up"
  of dAchievement: "achievement"

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

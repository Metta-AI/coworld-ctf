# GLORY GRADIENT — S1b TOP-DECILE ATTRIBUTION (2026-09-09)

Measurement + test only. No sim/scoring/glory code changed, no
GLORYVERSION bump, no wire change, no settings POST, no deploy. Tools
added under `tools/glory/` (`attribution_decompose.py` /
`attribution_analyze.py`); a permanent, unmodified-source reachability
test added at `tests/test_zero_mint_reachability.nim`.

## Era stamp — SAME population as the census, no re-scoping

GloryVersion 15, coworld_version 0.7.361-0.7.367 (GameVersion 59 for
0.7.361-0.7.364, 60 for 0.7.365-0.7.367 — same scoring economy, see the
census), Paintbot Season 2 BR ladder, rounds r4515-r4539, **305 episodes,
4,880 seat-episodes, top-decile threshold p90=576 (of `reported`), n=509**.
`GloryVersion` moved to 16 on origin/main via PR #477 but was NOT live on
any build as of this population — this is still the PRE-#477 baseline.

## JOB 1 — full top-decile attribution

### Method

The census's own recipe/achievement figures name WHICH DEEDS contributed
(`closing_time_amt × jointact_amt × win8`), but HEAT, CARRY, ALLY-STACK and
TERRITORY are not deeds — they are multiplicative modifiers folded INSIDE
a deed's `amount` at mint time (`glory.nim recutFactor`:
`shiftedClass × heatMult × carryMult × stackMult`), invisible to a decoder
that only reads the final folded `amount`. Splitting them out needs the
live sim state at mint time (heat embers, territory site, carry flag,
ally-stack k), which is not independently recoverable from the replay wire
by observation — so this reads it from a **private, local, never-shipped
instrumentation** of `src/ctf/sim.nim`'s `awardDeed` (one line at the
`recutFactor` call site, stashing the sub-factor breakdown into the tier-2
`GloryDeed` event's existing, always-`""`-on-the-live-path `content`
field — a debug string only, zero sim/scoring behavior change, never
committed). See `tools/glory/README.md`'s "S1b addendum" section for the
full diff and rebuild recipe. Re-extracts the SAME cached `.replay` files
the census already downloaded (no new network access).

Every per-event breakdown is cross-checked
(`shiftedClass × heatMult × carryMult × stackMult == amount`): **0
mismatches across all 4,880 seat-episodes' glory_deed events.** Every
seat-episode's bucketed total is cross-checked against the census's own
already-validated `recon_final` via the identical integer method
(fold `amount`s, halve by FF incidents, multiply the win factor, cap at
2^24): **4,880/4,880 (100.00%) reconciled.**

### Convention

A "share" is `log2(bucket subtotal) / log2(recon_final)` — summing logs of
the multiplicative legs that compose the ONE product, identical to the
census's own Q4 method (its 42.2% recipe figure) and the achievements
addendum's Q2 method (its 18.0% figure), so all three numbers are directly
comparable. `FRIENDLY_FIRE` is reported as a negative share (a halving
divides the product; it never adds a leg — the armed economy cannot
produce a negative multiplicative factor, only a division). 1/509 top-decile
rows hit the 2^24 cap; for that row shares are computed against the
UNCAPPED reconstructed total rather than the clamped 24-bit denominator.

### Attribution table (top decile, n=509; mean / median % of log2-magnitude)

| contributor | mean % | median % | fires in |
|---|---:|---:|---:|
| PLACEMENT (dFinal8/4/2 base class) | 31.19% | 32.97% | 484/509 |
| RECIPE (dClosingTime/dJointAct base class) | 20.12% | 19.11% | 423/509 |
| ACHIEVEMENTS (whole achievement product) | 17.95% | 9.83% | 509/509 |
| WIN (×8 finalize multiplier) | 12.11% | 16.51% | 270/509 |
| OTHER KILL/OBJECTIVE DEEDS (base class) | 8.74% | 8.53% | 266/509 |
| TERRITORY (enemy-ground rung shift, any deed) | 7.50% | 7.97% | 501/509 |
| HEAT (streak multiplier, any deed) | 2.29% | 0.00% | 105/509 |
| ALLY-STACK (RecutStackLadder, any deed) | 0.11% | 0.00% | 6/509 |
| CARRY (×2 possession multiplier) | 0.00% | 0.00% | 0/509 |
| FRIENDLY-FIRE (halvings, subtracts) | 0.00% | 0.00% | 0/509 |

**RESIDUAL: 0.000% mean, 0.000% median, 0.000% max** (ground-truth
instrumentation — ok to state as exactly zero, not "<5%": every event's
factor is read directly from the sim's own computation, not inferred).

### Reconciliation

4,880/4,880 (100.00%) seat-episodes' integer reconstruction matches the
census's own validated `recon_final`, using the SAME fold/halve/win/cap
method census_decode.py uses. 0 `UNRESOLVED`-bucket events (the per-event
`shiftedClass×heat×carry×stack == amount` check never failed).

### Cross-check against the census's own 42.2% recipe figure

Reproducing the census's exact Q4 method
(`log2(closing_time_amt × jointact_amt × win8) / log2(final)`) on this SAME
top-decile population gives **42.2% mean / 44.6% median (n=451)** — an
exact match to the original census finding, confirming this is the same
population measured the same way. The finer split above shows WHY that
number is 42.2% and not smaller: it silently bundles WIN (12.11%) and the
territory-shift riding on `dClosingTime`/`dJointAct` specifically into the
"recipe" label. `dClosingTime` (fires far more often, e.g. up to several
kills per seat during the closing-zone window) dominates the recipe;
`dJointAct` fires in only 15/509 top-decile seat-episodes (pact-gated,
matches the "pacts form ~1/episode" finding) and is nearly irrelevant in
aggregate.

### What actually makes a top round?

Ranked by mean share: **PLACEMENT (31.2%) > RECIPE (20.1%) >
ACHIEVEMENTS (18.0%) > WIN (12.1%) > OTHER KILLS (8.7%) > TERRITORY (7.5%)
> HEAT (2.3%) > ALLY-STACK (0.1%) > CARRY = FRIENDLY-FIRE (0%).**

- **HANDED, not chosen** (43.3% combined): PLACEMENT and WIN are not
  actions a seat performs — they are the SORT ORDER outcome of surviving
  longer than 8/4/2 other teams, and the single binary fact of being the
  one winner out of sixteen. A seat cannot "do more placement"; it either
  clears the population threshold or it does not, and only one seat per
  episode ever banks WIN. Together these are the single biggest reason a
  top-decile score is large, and neither is a deed a policy selects.
- **CHOSEN, with caveats** (56.7% combined: RECIPE + OTHER KILLS + HEAT +
  ALLY-STACK + TERRITORY + ACHIEVEMENTS + CARRY): the recipe legs, ordinary
  kills (mostly `dLongshotKill`, `dLastLight`, `dFirstBlood`), heat
  maintenance and ally-stacking ARE deed choices — but two of the biggest
  chosen items are themselves closer to structural TIMING than skill:
  `dClosingTime` fires automatically for any kill landed during the
  zone-closing window (a matter of when the fight happens, not how it is
  won), and TERRITORY fires on 501/509 (98.4%) of top-decile
  seat-episodes because a 16-seat map's "home pedestal" is a single point
  — nearly the entire map reads as enemy ground by construction, so this
  is closer to a map-geometry constant than a positioning choice.
  ACHIEVEMENTS mint on a one-shot claim basis (once a threshold is
  crossed there is no further modulation), so they behave more like a
  second placement ladder than a graded skill signal.
- **The honest split**: genuinely graded, skill-driven, repeatable choice
  — kills at range/heat maintenance/ally-stacking — is closer to **~11%**
  (OTHER KILLS + HEAT + ALLY-STACK) of a top-decile score's magnitude.
  Everything else is either handed by population size (PLACEMENT, WIN),
  a one-shot claim (ACHIEVEMENTS), or a near-constant of map geometry and
  round timing (TERRITORY, most of RECIPE). **This is the load-bearing
  finding for S4**: the owner's target that the mid band's spread come
  from deeds CHOSEN is currently financed mostly by facts the seat does
  not control.

## JOB 2 — zero-mint deed and achievement classification

15 of 31 deeds mint zero; 35 of 40 achievement slots mint zero (census /
achievements addendum). Every one classified below with a scripted
reachability test or a direct code citation (file:line). "Probably
behavioural" is never used as an answer on its own — each verdict below
either ran real code (`tests/test_zero_mint_reachability.nim`, or the
already-shipped, independently re-run test suite) or names the exact
unconditional guard.

### Deeds (15)

| deed | verdict | evidence |
|---|---|---|
| dFlagSteal | STRUCTURAL | `sim.gameMap.flagless` is unconditional on every real BR map; `tryPickupFlags` refuses pickup outright (`src/ctf/sim.nim:5257`), so a flag carrier never exists to steal — `sim_types.nim:3150-3154` confirms this in-source. |
| dCapture | STRUCTURAL | Same root: pickup refused ⇒ `carrier` never leaves -1 ⇒ the capture branch of `checkWinCondition` never fires (`sim.nim:5253-5256`'s own comment). |
| dCarrierKill | STRUCTURAL | `killDeed`'s `ctx.victimCarrying` gate (`glory.nim:2973`) needs a flag carrier; flagless BR never produces one (`sim.nim:5257`). |
| dDenial | STRUCTURAL | Same `victimCarrying` gate, plus `nearVictimHome` (`glory.nim:2972`); same flagless root. |
| dEscortKill | STRUCTURAL | `killDeed`'s classifier slot IS reachable (verified live: `tests/test_zero_mint_reachability.nim`, `killDeed(KillContext(escorted:true, rangePx:100, gunRange:331)) == dEscortKill` passes) — the FEEDER is dead: `escortCarrier` (`sim.nim:2941-2947`) reads `sim.flags[otherTeam].carrier`, permanently -1 on a flagless map. |
| dAssist | STRUCTURAL | `if not sim.config.brMode: sim.awardDeed(..dAssist..)` (`sim.nim:3117`) — explicit CTF-only mode gate, comment: "the BR overlay rides increment 2." |
| dRescue | STRUCTURAL | `if not sim.config.brMode and sim.players[menaced].alive: sim.awardDeed(..dRescue..)` (`sim.nim:3135`) — same CTF-only gate. |
| dWipe | STRUCTURAL | `if sim.config.brMode: return` (`sim.nim:6568`), the FIRST line of the wipe-award proc — explicitly "DISABLED outright in brMode," with an in-source measurement of why (one mint was 95.8% of a winner's whole episode glory in a 16-team single-elimination board). |
| dDuoDown | STRUCTURAL | SOLO-TEAM GUARD (`sim.nim:3009-3018`): requires `victimTeamSeats >= 2`; this population is 16-solo (1 seat = 1 team), so the guard is always false. |
| dTagBack | **BEHAVIOURAL** | Verified LIVE on this exact commit: `tests/test_glory_recut.nim` "armed: dTagBack mints from the completed revive, tagger-attributed, ×2" (line ~634) and `tests/test_loot_rework.nim` "T1 (P1) a pact ally CAN revive a downed solo partner" (line ~1116) both PASS (re-run 2026-09-09). Requires: an active pact (GV56 registry) + the ally physically closing to within `DownedTagRange` (40px) of a downed teammate for `downedReviveTicks` consecutive ticks before bleed-out, undisturbed by zone paint. The field DOES down players (4,577 `downed` events across the 305 episodes) but has **zero** `revived` events — the compound requirement (rare pact + risky stand-and-revive under fire) apparently never lines up live. |
| dVictory | STRUCTURAL | `if sim.config.gloryMultiplierRecut and sim.config.brMode and not isDraw and not sim.config.winAsMultiplier: awardDeed(..dVictory..)` (`sim.nim:5931-5934`) — explicitly RETIRED when `winAsMultiplier` arms (comment: "the dVictory deed above is RETIRED when the flag is armed"). This population's win_mult=×8 (verified via the census's own 100% reconciliation) proves `winAsMultiplier=true` universally here, so the gate is always closed. |
| dSprayKill | **BEHAVIOURAL** | Verified via `tests/test_zero_mint_reachability.nim`: `killDeed(KillContext(weaponSpray:true, rangePx:100, gunRange:331)) == dSprayKill` PASSES. Spray's cone reach (`SprayPaintReach = 5×SoldierBodyPx = 170px`) clears the BR-scaled point-blank threshold (`pointBlankPxFor(331) ≈ 34px`) and stays under longshot (`≈220px`) — a real, non-empty band exists. Nobody landed a spray-can kill in that band across 305 episodes. |
| dGrenadeKill | **BEHAVIOURAL** | Same probe: `killDeed(KillContext(weaponGrenade:true, rangePx:100, gunRange:331)) == dGrenadeKill` PASSES. `GrenadeBlastRadius=52px` also exceeds point-blank (34px); a clean mid-range grenade kill is geometrically possible. |
| dSplashMultiKill | **BEHAVIOURAL** | Already covered by the SHIPPED exhaustive sweep in `tests/test_glory.nim` ("a kill resolves to exactly one deed for every context"): `seen[dSplashMultiKill] > 0` is asserted and passes — the classifier's `multi` branch is reachable. Needs one grenade/spray activation to land 2+ kills at once; apparently never happened live. |
| dRunDown | **BEHAVIOURAL** | Same sweep: `seen[dRunDown] > 0` passes — the `fleeing` (`opening = dx·velX + dy·velY > 0`) branch is reachable. Needs a victim moving away from the killer at the exact kill tick; apparently rare/never captured live in 305 episodes. |

**Tally**: 10 STRUCTURAL (all traced to 3 root causes — flagless BR: 5;
CTF-only mode gate: 2; solo-team/win-factor retirement: 3), 5 BEHAVIOURAL.

### Achievements (35 of 40 dead)

Grouped by tree; every gate read directly from `satisfiedAchievements`
(`sim.nim:637-711`) and the engine's OWN `UnattainableAchievementTiers`
audit list (`sim.nim:715-725`).

| tree.tier | verdict | evidence |
|---|---|---|
| treeMedKit (all 5) | STRUCTURAL | Engine's own `UnattainableAchievementTiers` list (`sim.nim:715-725`): `treeMedKit` is omitted wholesale on this port (no `supplyShared` field — see `teamConvertedKits`'s own GLORY-PORT-TODO comment, `sim.nim` ~495-501). |
| treeSquad.III "Full Kit" | STRUCTURAL | Same engine audit list: explicit v12 TOMBSTONE, "deliberately zero-claim, no gate line at all" (`sim.nim:692-696`). |
| treeSquad.II (kits≥3) | STRUCTURAL | `kits` hard-caps at 2 in BR: the third "shield" leg reads `player.assists>=1` (`sim.nim` ~507), and `assists` itself requires `victimDamager.team == killer.team` (`sim.nim:3108`) — a TEAMMATE, impossible with 1 seat per team. |
| treeSquad.V "Victory Lap" | STRUCTURAL | Doubly blocked: needs `kits >= KitLegsImplemented(3)` (same cap as II) AND `anyCapture` (flagless BR never captures) (`sim.nim:708`). |
| treeSquad.I (kits≥2) | **BEHAVIOURAL** | Needs BOTH a grenade kill AND a spray kill from the same seat in one episode (the only two of three "kit legs" not structurally dead in BR) — compound of the two already-behavioural `dGrenadeKill`/`dSprayKill` facts above. |
| treeCarrier (all 5) | STRUCTURAL | Every gate reads `contestedSteals`/`carryKills`/`captures` (`sim.nim:675-680`) — all flag-locked, same flagless-BR root as `dFlagSteal`/`dCapture`. |
| treeDefender (all 5) | STRUCTURAL | Every gate reads `carrierKills`/`denials`/`peelTick`/`stealTickThisLife` (`sim.nim:682-688`) — all flag-locked, same flagless-BR root as `dCarrierKill`/`dDenial`. |
| treeShield.I (assists≥1) | STRUCTURAL | Counter itself requires a teammate (`sim.nim:3105-3111`, same as treeSquad.II above), impossible at team size 1. |
| treeShield.II (escortKills≥1) | STRUCTURAL | Requires `ctx.escorted` (flag-locked feeder, same as `dEscortKill`). |
| treeShield.III (rescues≥1) | STRUCTURAL | Requires `menaced.team == killer.team` (`sim.nim:3123-3125`) — a teammate. |
| treeShield.IV (secondWind) | STRUCTURAL | Chains off `rescuedTick`, which chains off III — cascading team-size block. |
| treeShield.V (squadVolleyDone) | STRUCTURAL | `SquadVolleyMinDistinct = 3` (`glory.nim:1685`) distinct teammate killers within a window (`sim.nim:800-820`); a 1-seat team can never produce more than 1 distinct killer. |
| treeGun.IV (level≥MaxLevel) | **BEHAVIOURAL** | Not mode-gated — BR's XP ladder is deliberately TALLER (`BrLevelThresholdMultPct`, `levelForXp`'s own comment: "BR's damage-only, flagless xp pool needs a taller ladder than CTF's"), so reaching the absolute max level within one BR life is harder but not blocked; tier III (Ace, one rung below) already fires 5 times live, so the ladder is climbable — nobody reached the top rung in these 305 episodes. |
| treeSpray (all 5) | **BEHAVIOURAL** | Downstream of `dSprayKill`'s own 0 — see the deed table above. |
| treeGrenade (all 5) | **BEHAVIOURAL** | Downstream of `dGrenadeKill`'s own 0. |

**Tally**: 23 STRUCTURAL, 12 BEHAVIOURAL (23+12=35, matches "35 of 40
dead"). Every STRUCTURAL verdict traces to one of the SAME 3 root causes
already named for the deeds (flagless BR, teammate/solo-team requirement,
engine-port omission) — there is no fourth cause anywhere in the
achievement catalog.

## What is NOT verified

- The `dSprayKill`/`dGrenadeKill`/`dSplashMultiKill`/`dRunDown` BEHAVIOURAL
  verdicts prove the SCORING classifier is reachable; they do not prove a
  bot policy or human seat can reliably reach that shot geometry in live
  play — that is a separate combat-behavior question this investigation
  did not measure (mint RATE, not mint POSSIBILITY).
- `dTagBack`'s BEHAVIOURAL verdict rests on the SHIPPED test suite passing
  on this exact commit (re-run once, 2026-09-09) plus the field's own
  `downed`-event count (4,577) and `revived`-event count (0); it does not
  construct a full multi-tick live-field pact-and-revive scenario end to
  end (that would require driving a live sim through many ticks with two
  coordinated policies, out of scope for a reachability check).
- `treeGun.IV`'s BEHAVIOURAL verdict is argued from the XP-ladder
  comparison (tier III fires, so the ladder is climbable) and the
  `BrLevelThresholdMultPct` comment, not from a constructed max-XP
  scenario reaching `MaxLevel` inside one BR life-length; a direct
  injection test was judged lower priority than the deed-band tests given
  the time budget.
- Sub-second gunRange/map-variant sensitivity: the `pointBlankPxFor`/
  `longshotPxFor` scaling used throughout (`gunRange=331`) is this
  population's live `br-golden-map.json` value; a different BR map
  variant with a different `gunRange` would shift these bands and could
  change which deeds are geometrically live — not re-checked across every
  map variant in the pool.

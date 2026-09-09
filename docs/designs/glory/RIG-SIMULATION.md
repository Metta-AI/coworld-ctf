# GLORY GRADIENT — Step 5: RIG SIMULATION

Program `25d9108e`. Opens on the S4 freeze (`origin/main @ 57308cf3`, PR
#491, `docs/designs/glory/CATALOG-V3-DRAFT.md`). This worker does not merge
— PR only, S2 lead merges. No GLORYVERSION bump, no wire change, no
settings POST, no deploy performed by this step.

## GATE RULINGS (coordinator, 2026-09-09, after the first pass of this rig)

The coordinator reviewed the first version of this report (ARMED scoring
lower than DARK because the deed-class reprice was correctly out of scope)
and issued five rulings that changed this PR:

1. **WIRE-OK for the rig only, in this exact form**: the v3 reprice landed
   as a switch-selected SECOND table (`GameConfig.catalogV3Reprice`,
   default OFF); switch OFF selects the frozen table and is byte-identical
   — proven, not merely asserted (own section below). **No GLORYVERSION
   bump in S5** — that lives only in the S6 ship PR, owner-gated.
2. **Fold-order reinstated, narrowed**: fractional/small (`<x2`) factors
   never fold from a bare seed; the accumulator must exceed ~64 first —
   `RecutMinAccumulatorForSmallPct` in `recutFoldPct`, its own test suite.
3. **Bands resolved, no boundary moves**: MID = 2–6 as signed; 7–8 is
   MID's upper shoulder and counts toward CONTINUITY only, never toward
   the MID CHOSEN target. (This PR does not edit `CATALOG-V3-DRAFT.md`
   itself — flagged for the doc's own owner to correct its "2–8" wording;
   this rig now measures CHOSEN share against MID = 2–6 only.)
4. **Mint priority**: when one kill satisfies both a pact-scope deed and a
   solo deed, the PACT deed mints unconditionally (`pactForced` in
   `killPlayer`) — own test, and the dDuoDown mint-rate-vs-incidence
   re-measure below.
5. **Monte Carlo caveat stays on every number**: the archetypes are
   direction-calibrated modelling choices, not measured policies — kept on
   both the original and the re-run distribution.

## ERA FRAMING (mandatory, per this step's own brief)

Every comparison below is **pre-#477 baseline vs post-#477 live**, never one
continuous series:
- **pre-#477 baseline**: the S1 census population — GLORYVERSION 15,
  coworld_version 0.7.361–0.7.367, GameVersion 59/60, rounds r4515–r4539,
  305 episodes, 4,880 seat-episodes. This is what `CATALOG-V3-DRAFT.md`'s
  own mint-rate table (§2a) is built from, and what this rig's Monte Carlo
  model is calibrated against.
- **post-#477 live**: `paintbot-v0.7.369`, GLORYVERSION 16 / GameVersion
  61, level buffs wired into live combat (PR #477). **Not yet published to
  any hosted build as of this rig.** Every production code change in this
  PR is written against `origin/main` at the S4 freeze sha (which already
  includes #477's source), but the rig's *mint-rate inputs* are pre-#477
  census numbers — stated exactly once here, not re-qualified every
  paragraph below.

## Build (behind switches, DEFAULT OFF — nothing changes for any existing
league or build until armed)

Four new `GameConfig` flags, each independently settable, each read only
while `gloryMultiplierRecut` is armed (enforced at each call site):

| flag | what it does | dark behavior |
|---|---|---|
| `brAssistRescueUngated` | ruling (b): removes the `if not sim.config.brMode` gate ahead of `dAssist`/`dRescue` (sim.nim, kill-resolution site) | byte-identical: BR mints neither deed |
| `pactScopedWipeDown` | ruling (c): retargets `dDuoDown`/`dWipe` onto an opposing PACT GROUP instead of a same-team partner (sim_state.nim `pactGroupTeams`/`pactGroupLivingExcluding`; integrated at the existing marquee-upgrade site, same one-kill-one-deed precedence dDuoDown already used) | byte-identical: no pact-scope path is ever consulted |
| `placementRampV3` | CATALOG-V3-DRAFT.md §4: `dFinal8`/`dFinal4` → pct=100 (a true no-op — still mints/pops/counts, contributes zero marginal score), `dFinal2` → pct=130, folded via a NEW percent-scaled fold (`recutFoldPct`); plus a continuous per-seat survival credit (`RecutSurvivalCreditPct`=102 every `RecutSurvivalCreditIntervalTicks`=720 ticks of `aliveTicks`, piggybacked on the existing `updatePackTicks` per-tick loop) | byte-identical: `RecutClassTable`'s frozen 2/3/4 |
| `gloryFixedPointScale` | CATALOG-V3-DRAFT.md §9b RULED representation: seeds `gloryProduct` at `GlorySCALE`=1024 instead of the bare `RecutSeed`; `recutScoreScaled` reads it back (halve first via `recutScore`'s own `halvings>=63→0` guard, THEN strip scale — the SAFE order) | byte-identical: unscaled |
| `catalogV3Reprice` | **GATE RULING 1**: selects `RecutClassTableV3Pct`/`RecutTierClassV3Pct`/`HeatLadderV3Pct`/`RecutStackLadderV3Pct` (percent-scaled) instead of the frozen `RecutClassTable`/`RecutTierClass`/`HeatLadder`/`RecutStackLadder` (`recutFactorV3Pct`/`recutAchievementFactorV3Pct`, glory.nim) | byte-identical: frozen tables, proven below |

**Fire counters are NOT new `SimServer` fields.** The first draft of this
work added `capHitCount`/`recutPactDuoDownCount`/etc directly to
`SimServer`, then reverted: `SimServer` is flatty-serialized, and every
prior field of this exact shape (`pactMask`, `recutFinalFired`,
`recutDamageMarks`, `recutJointSeats`) carries its own "GameVersion bump
covers the flatty keyframe layout change" comment in `sim_types.nim` — a
class of change this step's boundary explicitly requires approval for.
Reimplemented as **log lines + tier-2 events** instead
(`sim.logGameEvent("GLORY_CAP_HIT ...")` / `sim.emitEvent(GloryDeed,
weapon="capHit", ...)`), which is also the catalog's OWN recommended idiom
for exactly this counter ("log a line on every call", matching the already-
shipped metta season-transform PR). Zero struct changes. New `weapon`
labels on the existing `GloryDeed` event (no new event kind, same
reasoning): `capHit`, `pactDuoDown`, `pactWipe`, `survivalCredit`.

`RecutProductCapArmed`'s own missing fire counter (named explicitly as a
violated law in this step's brief) is now closed: `recutCapHit` (glory.nim,
pure predicate) + `recutFoldObserved`/`recutFoldPctObserved` (sim.nim,
wrap every one of the three `recutFold` call sites that ever touch a team's
`gloryProduct`) log `GLORY_CAP_HIT` the instant a fold actually clamps.

## HALVING-ORDER INVARIANT — its own test line

`glory.nim recutScoreScaled` is production code (not a test-local helper,
unlike S4's `test_glory_percent_scale_headroom.nim`). It halves FIRST
(`recutScore`'s own guard, unaffected by scale) then strips `GlorySCALE`
SECOND — the safe order. `tests/test_glory_s5_rig.nim` (suite "S5
halving-order invariant") proves, against real production constants:
- the safe and naive-combined-divisor orders agree at realistic halvings
  (0–5).
- the combined-divisor form (`GlorySCALE * (1 shl halvings)`) genuinely
  `OverflowDefect`s at halvings=61 (still fine at 52) — triggered for real.
- `recutScoreScaled` at halvings=61/400 returns 0 via `recutScore`'s own
  guard, with **no** overflow, because it never forms the unsafe product.

## Test status

`tests/test_glory_s5_rig.nim` — **28/28 passing, local run**
(`nim c -d:noSignalHandler --threads:on -d:useMalloc`, runtime-stub shape,
`WASMTIME_C_API=""` for `nim check`; real Wasmtime C API for the shard
build). Registered in `tests/shard_1.nim`. Full 4-shard regression run
(local, post gate-rulings): shard 1 377/377, shard 2 782/782, shard 3
650/650, shard 4 398/398 — **0 failures anywhere**.
**Not yet a CI run** — this PR's CI run id will supersede this local
verification per this program's own "verified via test X must cite the
CI run id" law; treat the numbers above as local-only until then.

Two real bugs surfaced and fixed *while building the tests*, not asserted
away:
- `pactGroupTeams`/pact-scope kills need >=3 active teams to exercise a
  real pact group; the engine's `sim.teams()` is a prefix of the `Team`
  enum sized by the MAP's own layout, not by which `Team` values a test
  happens to assign — an early test draft crashed `clearPactsFor`'s own
  `pactMask[team]==0` assertion by putting a player on a team the 2-team
  test map didn't seat. Fixed by reusing `test_br_elim.nim`'s own
  `teams=4`/"corners"-map-gen recipe, not by touching production code.
- The pact-scope `dDuoDown` marquee is correctly SHADOWED by a higher-class
  LONGSHOT kill on far-apart BR spawns (the existing one-kill-one-deed
  upgrade-only law working as designed) — this is itself a real, reportable
  finding, not just a test-setup fix (see "mint-RATE" below, and GATE
  RULING 4's fix).

### GATE RULING 1 — the switch-OFF zero-diff proof

`test_glory_s5_rig.nim`, suite "GATE RULING 1: catalogV3Reprice switch OFF
is byte-identical (not merely asserted)":
- **"OFF end-to-end via awardDeed/claimAchievement reproduces the FROZEN
  contract's own pinned BR superb exactly: 9,437,184"** — the SAME recipe
  `test_glory_recut.nim`'s own pure-function test uses, driven through the
  full `awardDeed`/`claimAchievement` API instead of bare `recutFactor`
  calls. Result: **9,437,184**, exact match. PASS.
- **"OFF: gameHash of a short deterministic scenario matches the PINNED
  golden"** — a 4-mint scenario (`dHonorableKill`+`dShieldSoak`+
  `dClutchHeal`+one `treeSquad` claim), `gameHash()` pinned at
  `7108621066401102251` (computed once via a real run, printed then
  hard-coded, same idiom this codebase's own fixture tests use throughout).
  PASS.
- **"ON changes the reported score for the SAME frozen-contract recipe"**
  — confirms the switch has real teeth (`dHonorableKill` folds `x2.2`
  instead of `x1` once armed). PASS.

### GATE RULING 2 — the fold-order rule's own test

`RecutMinAccumulatorForSmallPct = 64` in `recutFoldPct` (glory.nim): a
factor with `pct < 200` is skipped (not floored-to-nothing) while the
UNSCALED accumulator sits at or below 64. Suite "GATE RULING 2: small/
fractional factors never fold from a bare seed" — 4/4 PASS, including the
scaled-vs-unscaled floor-evaluation case. The pre-existing placement-ramp
test (`test "armed: dFinal8/dFinal4 crush..."`) was updated to match: a
bare-seed `dFinal2` fold (pct=130) is now correctly SKIPPED, and a second
scenario (base grown to 256x seed via prior whole-integer folds) shows the
SAME pct folding for real once past the floor.

### GATE RULING 4 — mint priority + dDuoDown mint-rate vs incidence

`pactForced` (sim.nim `killPlayer`) makes a pact-scope marquee win
unconditionally over an ordinarily-resolved kill deed. Suite "GATE RULING
4": on the SAME far-spawn "corners" map scenario that previously showed
`dDuoDown` shadowed by `dLongshotKill`, `dDuoDown` now mints
(`deedCounts[dDuoDown] == 1`). Re-measured mint-rate vs raw incidence:
**incidence=1, mints=1 — equal**. Before this ruling, the same scenario
measured incidence=1, mints=0 (a 100% loss on this map shape); the gap is
now fully closed.

## SIMULATE — Monte Carlo rig against real production scoring code

**Method, stated plainly, honest limit up front**: this is a **census-
calibrated Monte Carlo**, not a full WASM/bot-policy live match. It drives
REAL production procs (`sim.awardDeed`/`claimAchievement`/`recutFold`/
`recutScore`/`recutFoldPct`/`recutScoreScaled`/`recutWinFactor` — nothing
reimplemented) with per-seat deed COUNTS sampled from the S1 census's own
per-episode mint-rate table (`CATALOG-V3-DRAFT.md` §2a), converted to a
per-seat mean by dividing the quoted 16-seat-pooled episode aggregate by
16 — a stated modeling simplification, not a re-measurement. Two skill
archetypes ("baseline" and "skilled") are DESIGN CHOICES (placement-reach
probabilities and kill-rate multipliers), calibrated in DIRECTION from the
census (skilled seats kill/heat/joint-act more and reach/win the final
more often) but not themselves independently measured — named here, not
hidden. **Paired seeds**: the identical sampled deed multiset for a given
seat-episode is folded through BOTH the DARK config (today's S4-frozen
catalog, all four S5 switches off) and the ARMED config (all four on), so
the reported delta isolates the catalog's effect from sampling noise.

Ephemeral trial tooling (matches S4's own `reprice_v3.py` precedent — "not
committed"): `/tmp/glory-s5/rig/s5_montecarlo.nim`, 1,500 baseline +
1,500 skilled seat-episodes, seed base 20260909.

### Simulated distribution vs the pinned ladder — RE-RUN with catalogV3Reprice ON (GATE RULING 1)

**MONTE CARLO CAVEAT (GATE RULING 5, repeated here on purpose): the
"baseline"/"skilled" archetypes are direction-calibrated MODELLING
CHOICES, not measured policies — every number below is provisional until
S6 re-measures on the live post-#477 ladder.**

A bug was found and fixed while wiring this re-run: the original script
computed the baseline/skilled mean split by slicing the SORTED combined
array by index, which measures "lower half vs upper half of the pooled
population," not "baseline vs skilled" — a different, wrong number. Fixed
by tracking each archetype's points in its own seq before sorting the
combined array for percentile display. The corrected code is what
produced every number below (the first version of this report's own
acceptance-test-2 numbers were computed with the buggy split and are
superseded by this run in full, not just the catalogV3Reprice delta).

3,000 seat-episodes (1,500 baseline + 1,500 skilled), paired seeds:

| percentile | DARK (S4 frozen) pts | ARMED (5 switches incl. catalogV3Reprice) pts |
|---:|---:|---:|
| p10 | 1.00 | 1.00 |
| p25 | 2.00 | 1.00 |
| p50 (median) | 3.58 | 2.00 |
| p75 | 6.58 | 4.00 |
| p90 | 9.58 | 6.27 |
| p99 | 12.75 | 14.00 |

**GATE RULING (coordinator): re-run again with the invented +50%/+15%
constants RETRACTED** — `CATALOG-V3-DRAFT.md` §15 now documents that
`tools/glory` does NOT contain the S4 static reprice tool (confirmed via
`git show --stat` on both #491 and #494); only the doc's own prose values
are used, and the seven deeds/territory the prose leaves unspecified now
fold at their CLASSIC, UNCHANGED value (see that section for the full
accounting). Corrected numbers, same rig, same seeds: p50/p75/p90/p99 =
2.00/4.00/6.02/14.00 (barely moved from the pre-correction run above —
the retracted constants were not the dominant contributor). ACCEPTANCE
TEST 1: 158/3000 (5.3%) in [6,9]. TEST 2: baseline 1.59 vs skilled 4.04
pts (armed), separation holds. TEST 3 (CHOSEN share): mid 33.06%/top
46.75% — still below 54.61%/71.11%, and this IS the real finding per the
ruling: the seven UNSPECIFIED deeds were not the reason the doc-only
table falls short, so a genuinely different fix (real numbers for those
seven, or a different lever entirely) is needed, not a bigger guess. TEST
4 (cap-hit @ 2^24): 0.0000%, unchanged.

**Cap-hit ceiling sensitivity (task 2, one row, owner picks)**: ceiling 16
pts → 0.0000% (0/3000); ceiling 14 pts → 4.5333% (136/3000); ceiling 12
pts → 4.5333% (136/3000, same population — nothing lands strictly between
12 and 14 pts in this run). 16 is too loose to ever bind under this rig's
per-seat volumes; 12 and 14 both land far above the 0.1–1% design band.

### Acceptance tests (re-run)

1. **CONTINUOUS POPULATION THROUGH 6–9 PTS: PASS, improved.** 213 of 3,000
   (7.1%, was 164/5.5% infra-only) armed seat-episodes land in [6,9] — up
   with the reprice armed, and p90 (6.27) now sits just inside the band
   instead of below it. Still thinner than DARK's own natural 6.58–9.58
   p75–p90 span, but moving the right direction with the reprice landed.
2. **Geometric-mean standings separate TOP from MID: PASS.** ARMED
   (CORRECTED split, see bug note above): baseline mean **1.67** pts vs
   skilled mean **4.23** pts — skilled ≈2.6 pts higher in log-space
   (≈6× in the leg domain). DARK (corrected): baseline 2.99 vs skilled
   6.20. Separation holds under both configs; the reprice does not close
   the gap between them (a different question from whether it exists).
3. **Mid band's magnitude mostly from deeds CHOSEN: FAIL, closer.**
   Measured CHOSEN log2-share: mid-band mean **33.41%**, top mean
   **47.82%** — up sharply from the infra-only run (5.92%/8.06%,
   structurally zero because kills folded at the frozen ×1), but still
   below the catalog's own static-repriced target (54.61%/71.11%) and
   below a bare majority. Likely cause: this rig's OWN trial constants for
   the "already-real classes... raised further" deeds (a flat +50%, since
   `CATALOG-V3-DRAFT.md` names no exact target — see the v3 table's own
   doc comment) are probably smaller than the static tool's undisclosed
   trial values, and/or the Monte Carlo's per-seat kill RATES themselves
   (census episode-aggregate ÷ 16) undercount a skilled seat's real kill
   volume. Not re-tuned further in this pass — flagged for S6, not
   silently pushed past 50% by picking bigger trial constants after
   seeing this number.
4. **Cap-hit lands in 0.1–1%: FAIL (still 0.0000%, 0 of 3,000).**
   Unchanged from the infra-only run and consistent with the census's own
   near-zero measurement (0.020%). `RecutProductCapArmed` (2^24 ≈ 16.8M)
   remains far above what even the v3-repriced classes reach in this
   Monte Carlo's per-seat mint volumes — reaching the design band likely
   needs either larger v3 constants than this rig's trial +50%, or a
   lower cap, neither decided here.

## MEASURE WHAT THE STATIC PASS COULD NOT

### Rulings (b)/(c) real magnitude

Both proven to FIRE, through the real `killPlayer` kill-resolution path
(not a mocked call), with real predicates:
- **Ruling (b)** (`brAssistRescueUngated`): `dAssist` and `dRescue` mint in
  BR under the EXACT same predicate CTF already uses (`AssistWindowTicks`/
  `RescueWindowTicks`, the menaced-teammate/damager checks) the instant the
  gate is removed — no new mechanism needed, confirming the freeze
  document's own framing that these are "cannot be exercised statically,"
  not "structurally broken."
- **Ruling (c)** (`pactScopedWipeDown`): the pact-scope `dDuoDown` (one
  allied team falls, others survive) and `dWipe` (the whole opposing pact
  group falls) both mint correctly, with the bigger fact (`dWipe`) winning
  the existing one-kill-one-deed precedence over the smaller one
  (`dDuoDown`) when both conditions are met on the same kill.

### Mint-RATE vs mint-POSSIBILITY

The genuinely new finding here (not visible from a static pass, since it
needs live positioning/geometry): **the pact-scope marquee is frequently
SHADOWED by an ordinary higher-class kill deed on real BR maps.** On the
"corners" 4-team generated map (far-apart spawns), an un-moved kill
resolves as `dLongshotKill` (class 3) by simple spawn geometry — which
beats the pact-scope `dDuoDown` (class 2) under the existing one-kill-one-
deed upgrade-only law and the deed goes UNMINTED even though the
CONDITION fired (confirmed via the `GLORY_PACT_DUODOWN` log line, which
DOES fire, vs `deedCounts[dDuoDown]`, which does NOT increment, in that
configuration). `dWipe` (class 8) is high enough to survive this shadowing
in the same test. **This means ruling (c)'s real BR mint-RATE for
`dDuoDown` specifically is geometry-dependent and will read LOWER than its
raw incidence rate on any map where longshot-range engagements are common**
— a concrete, measured caveat the static pass had no way to surface
(zero BR events existed to observe this against), and a genuine risk for
whichever S6 constants get picked: `dDuoDown`'s pact-scope class may need
raising above `dLongshotKill`'s to actually mint on real maps, or the
program should accept that only the rarer `dWipe` half of ruling (c) reads
its full incidence rate in practice.

### Headroom re-run against REAL deed mint frequencies

**UNPLANNED FINDING** (found by running this, not by reasoning about it):
sweeping `SCALE` from 2^8 through 2^20 for the realistic worst case — a
single `dFinal2` (pct=130) fold applied to a seat whose `gloryProduct` is
still at the bare seed when it reaches the final two (few or no prior
kills) — shows **ZERO improvement at any scale tested**: drift stays
exactly 23.08% at every `SCALE` from 256 to 1,048,576. This is
STRUCTURAL, not a rounding artifact fixable by a bigger scale: the reported
score is always an integer in the SAME units as the unscaled seed, and
`recutScoreScaled` strips `SCALE` via integer division at read-out —
`(seed*SCALE*130÷100)÷SCALE` reduces to `(seed*130)÷100` for ANY `SCALE`
that divides out cleanly, so the ratio (1.3), not the scale's absolute
size, decides whether the result crosses an integer boundary. Once several
OTHER whole-integer folds have already grown the accumulator (measured:
64+), drift falls under 1% exactly as S4's own synthetic test found — but
a seat that reaches the fractional tier EARLY, with a small accumulator,
will see that fractional bonus reported as an invisible +0 in the wire's
integer NO MATTER how large `SCALE` is. This is a genuine, still-open
representation limit for S6, not resolved here.

### gunRange sweep beyond 331

`longshotPxFor`/`pointBlankPxFor` scale LINEARLY with `gunRange`
(`scaledByGunRange`: `refPx * gunRange ÷ CtfReferenceGunRange`), so the
RATIO (≈66.7% of `gunRange` for LONGSHOT, ≈10.5% for POINT-BLANK) is
constant across the whole swept range — confirmed directly, not assumed:

| gunRange | longshotPxFor | pointBlankPxFor |
|---:|---:|---:|
| 150 | 100 | 15 |
| 200 | 133 | 20 |
| 265 | 176 | 27 |
| **331 (live map)** | **220** | **34** |
| 400 | 266 | 41 |
| 500 | 333 | 52 |
| 700 | 466 | 73 |
| 1050 (reference) | 700 | 110 |

(331/220/34 independently cross-checked against this population's own
pre-existing `killDeed` reachability test in shard 2, which prints and
asserts these exact numbers.) **What this sweep does NOT show**: the
mint-RATE consequence of moving `gunRange`, which depends on the real
engagement-distance distribution per map — not available to this rig, and
not simulated (a genuinely open item, not asserted away).

## Boundaries — what was moved, what was NOT

- No boundary from `TARGET-DISTRIBUTION.md §5`/`CATALOG-V3-DRAFT.md`'s
  ruled ladder was moved ±1pt by this worker — **a discrepancy across THREE
  source documents is flagged instead, not silently resolved**:
  `TARGET-DISTRIBUTION.md §5` (owner-signed) pins MID at 2–6 pts (~20×
  internal spread); the manager ledger's own "S5 SCOPE AS THE LEAD SET IT"
  dispatch note (`00a-manager-ledger.md`, the note that actually staged
  this task) cites the SAME mid-2-6/top-~9-11 ladder verbatim; but
  `CATALOG-V3-DRAFT.md`'s later "THREE FRESH FACTS FROM THE LEAD" section
  explicitly claims to SUPERSEDE both with MID at 2–8 pts (~64× internal
  spread, shoulder at 7–8) — a change apparently made AFTER the S5 dispatch
  note was written, and not reflected back into it. All three documents
  state the same explicit acceptance criterion in the same words
  ("continuous population through 6–9pts is the rig's own test, a gap
  there is a FAILURE"), so this rig tests THAT criterion directly rather
  than picking a side — but the 8-vs-6 MID/TOP boundary disagreement is
  real, unresolved by this worker, and worth the lead's explicit
  reconciliation before S6 picks constants against either ladder.
- No GLORYVERSION bump, no wire change: confirmed by construction (every
  new field is a `GameConfig` bool, not a `SimServer` state field; every
  new counter is a log line/event, not a struct field).
- `RecutProductCapArmed`'s cap-hit counter is unconditional (per the
  catalog's own "no switch needed" ruling) — the only lever in this PR that
  is NOT behind a switch, by design.

## What is NOT verified

- The Monte Carlo's per-seat mean rates (census episode-aggregate ÷ 16) and
  the two skill archetypes' placement/kill multipliers are MODELING
  CHOICES, calibrated in direction from the census, not independently
  re-measured — a different modeling choice could shift the exact
  percentile numbers above, though not the structural findings (SCALE
  sweep, halving-order, gate/ruling wiring).
- `dJointAct`'s heat-rung / era-split CHOSEN-bucket treatment in the rig's
  `chosenLog2Share` is a simplification of `CATALOG-V3-DRAFT.md`'s own
  `dJointAct` era-split ruling, not a re-derivation of the r4517 boundary.
- This is local verification only — no CI run id exists yet for this PR.
- Rulings (b)/(c)'s real LIVE magnitude (once un-gated/retargeted in an
  actual hosted BR league) is still unmeasured — this rig proves the code
  paths fire correctly and at what rate under a synthetic pact/positioning
  setup, not what a real bot-policy population would actually do once
  armed.
- No stateful-mode/timer primitive, `play_view` perception surface, or
  pact-decay mechanism was touched — out of scope for S5 per the freeze
  document's own "what this does not decide" list (Section 6 items).

# GLORY GRADIENT — Step 5: RIG SIMULATION

Program `25d9108e`. Opens on the S4 freeze (`origin/main @ 57308cf3`, PR
#491, `docs/designs/glory/CATALOG-V3-DRAFT.md`). This worker does not merge
— PR only, S2 lead merges. No GLORYVERSION bump, no wire change, no
settings POST, no deploy performed by this step.

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

`tests/test_glory_s5_rig.nim` — **19/19 passing, local run**
(`nim c -d:noSignalHandler --threads:on -d:useMalloc`, runtime-stub shape,
`WASMTIME_C_API=""` for `nim check`; real Wasmtime C API for the shard
build). Registered in `tests/shard_1.nim`. Full 4-shard regression run
(local): shard 1 368/368, shard 2 782/782, shard 3 650/650, shard 4
398/398 — **0 failures anywhere**, confirming the new switches are
byte-identical dark and the rest of the suite is unaffected.
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
  finding, not just a test-setup fix (see "mint-RATE" below).

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

### Simulated distribution vs the pinned ladder

3,000 seat-episodes (1,500 baseline + 1,500 skilled), paired seeds:

| percentile | DARK (S4 frozen) pts | ARMED (4 S5 switches) pts |
|---:|---:|---:|
| p10 | 1.00 | 0.00 |
| p25 | 2.00 | 2.00 |
| p50 (median) | 3.58 | 2.00 |
| p75 | 6.58 | 3.58 |
| p90 | 9.58 | 5.36 |
| p99 | 12.75 | 9.55 |

**Headline, stated plainly, not softened: ARMED scores LOWER than DARK at
every percentile from p50 up.** This is the correct, expected consequence
of this step's own SCOPE DISCIPLINE, not a bug: `placementRampV3` crushes
`dFinal8`/`dFinal4` to a true no-op (pct=100) and reprices `dFinal2` down
to a small x1.30 nudge — removing real magnitude from the HANDED
(placement) bucket, exactly per the lead's ruling — but this rig does
**not** also raise the kill/heat/support deed classes
(`dHonorableKill`×1→×2.2, heat rungs 2/4/8→5/14/36, etc.) the way
`CATALOG-V3-DRAFT.md`'s own "FREEZE CONDITION 1" static re-price trial
did, because that reprice needs new `RecutClassTable`/`RecutTierClass`
VALUES — a **GLORYVERSION bump this step has no WIRE-OK for** (per this
step's own explicit boundary: "STOP and report rather than doing it"). The
result is exactly what you'd expect from removing a HANDED lever without
building its CHOSEN replacement: less magnitude everywhere, not
redistributed magnitude. **This is the single most important finding of
this rig, and it is a scope finding, not a code defect**: S5's four
levers (representation, halving order, cap counter, rulings b/c, placement
ramp) are real, tested, and safe — but the catalog's OWN "move magnitude
from placement to kills" design law needs BOTH halves landed together to
show the target shape; this PR ships the first half only, correctly, and
proves — with real evidence, not assertion — that the second half (the
deed-class reprice, S6/owner-gated) is load-bearing, not optional polish.

### Acceptance tests

1. **CONTINUOUS POPULATION THROUGH 6–9 PTS: PASS, weakly, wrong trend.**
   164 of 3,000 (5.5%) armed seat-episodes land in [6,9] — non-zero, so not
   a hard gap — but DARK's own p75–p90 (6.58–9.58) sat almost entirely
   inside that band while ARMED's shifted down to p90=5.36, i.e. the
   placement-ramp crush (without the kill reprice) makes 6–9 pts a
   THINNER shoulder, not a thicker one. Passes the letter of the test;
   fails its spirit until the reprice half lands.
2. **Geometric-mean standings separate TOP from MID: PASS, compressed.**
   ARMED: baseline mean 1.46 pts vs skilled mean 4.22 pts (skilled ≈6.8×
   baseline in the leg domain, `2^4.22 / 2^1.46`) — skilled seats still
   score higher, so separation holds. But DARK separated MORE (2.05 vs
   7.14 pts, ≈34×) — again the placement/win HANDED lump (today's actual
   separator, since it scales with skill via reach-probability) got
   crushed without a CHOSEN-side replacement. Separation survives; it
   shrinks. Same root cause as test 1.
3. **Mid band's magnitude mostly from deeds CHOSEN: FAIL, and this rig
   shows exactly why.** Measured CHOSEN log2-share: mid-band mean **5.92%**,
   top mean **8.06%** — far below the catalog's own static-repriced target
   (54.61%/71.11%). Root cause, found by running this, not assumed:
   `chosenLog2Share`'s CHOSEN deeds (kills, heat) are folded through
   `RecutClassTable`'s **UNCHANGED, S4-frozen** classes, and `dHonorableKill`/
   `dShieldSoak`/`dClutchHeal` are still priced at **×1** (commons) —
   `log2(1) = 0`, so ANY NUMBER of kills a seat racks up contributes
   **exactly zero** log2-magnitude under this rig's (deliberately)
   unrepriced classes. This is not a rig bug — it is a precise, load-bearing
   demonstration that acceptance test 3 is structurally impossible to pass
   without the deed-class reprice this step is not authorized to make.
4. **Cap-hit lands in 0.1–1%: FAIL (measured 0.0000%, 0 of 3,000).**
   Consistent with the census's own real measurement (0.020%, `TARGET-
   DISTRIBUTION.md §3`) and with finding 3 above: `RecutProductCapArmed`
   (2^24 ≈ 16.8M) is essentially unreachable under either today's classes
   or this rig's infra-only levers — reaching the 0.1–1% design band
   needs the same kill/heat reprice that test 3 is blocked on, not a
   change to the cap itself.

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

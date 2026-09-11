# GLORY GRADIENT — S7: SIZING THE CAP CEILING WITH S4b ARMED

Epic `25d9108e`, step S7. Opens on the S6 live read
(`01e-gv62-cohort-attribution-2026-09-09.md`, "MEASURED" section): top-decile
CHOSEN 72.26% (all rows) — clears the freeze floor decisively — but 154/5,456
seat-episodes (2.823%) sit AT `RecutProductCapArmed`, and those 154 rows are
154/555 = 27.75% of the top decile. The lead's ruling (S2 lead, under the
owner's delegation, recorded in this program's own dispatch notes): S4b
(`LIGHTABLE-MODES-S4B.md`) does not arm alone — a gradient into a wall that
still catches over a quarter of the top decile contradicts the owner's own
feel rulings ("jackpots RARE by design", "the top must feel earned, not a
fluke", "most players live in mid-risk pushing for its upper band"). **S7's
job**: with S4b armed, find a cap ceiling such that cap-hit lands in
0.1–1% of seat-episodes AND the top decile's capped share is under ~5%,
while the freeze floor, CONTINUITY, and SEPARATION still hold, and the
jackpot ratio moves toward the owner-signed ~1000× target.

**Headline finding, stated first**: on REAL GV62 play (behaviour held
fixed), **S4b changes ZERO seat-episodes' capped status** at 6 of the 7
tested cap levels, and only a handful at the 7th (2^19) — the sizing
question here is answered almost entirely by the CAP VALUE, not by S4b.
S4b's own, real, measurable effect on this population is a small, honest
CHOSEN-share nudge (+0.04 to +0.09 percentage points at the top decile) via
the achievement axis, not a cliff-smoothing mechanism. This is a genuine,
reportable disagreement with `LIGHTABLE-MODES-S4B.md`'s own framing (built
against a synthetic toy sweep, not real play) — see "A vs B" below.

**Second headline**: the real population's cap-hit response to a rising
ceiling is a **smooth, monotonic decay** (154 → 129 → 89 → 80 → 41 → 32 →
30 → 17 → 0 capped rows as the ceiling rises 2^14 → uncapped) — **not** the
CLIFF `RIG-SIMULATION.md`'s synthetic Monte Carlo reported (0% flat from
2^14.5–2^16, then a jump to 6.07% at 2^14/2^12). See "A vs B" for why these
disagree.

---

## Decision (S2 lead, 2026-09-09, under the owner's delegation — owner may overrule)

**CEILING = 2^21 reported points**, decided: `RecutProductCapArmed` →
`int64(1) shl 31` internal (current is `2^14` reported = `2^24` internal).
Per §3's sweep table: cap-hit 0.312% of seat-episodes, top-decile capped
3.06%, top-decile CHOSEN ~83% (83.16–83.21%, S4b off/on), CONTINUITY and
SEPARATION hold at every candidate tested — the only candidate that
clears both the cap-hit band and the under-~5% top-decile-capped bound
with margin (§5). This closes §6's primary recommendation as the ceiling
for the arm bundle (§8); it is not left as a further-open candidate.
S4b's own justification is corrected alongside this decision — see
`LIGHTABLE-MODES-S4B.md`'s dated note and §4 below.

---

## 1. Method

### Instrument A (primary): empirical re-fold

Replays the real GV62 per-seat wire event streams — 341 episodes, 5,456
seat-episodes, rounds r4611–r4635, the same cohort `01e-...md` measured —
through a line-for-line extension of `tools/glory/catalog_fold.py`'s v3
fold state machine (`tools/glory/cap_sweep.py`, this PR), with two
parameters the shipped economy has never swept independently:

- **`cap`** — `RecutProductCapArmed` (glory.nim ~L2642,
  `int64(1) shl 24` = 16,777,216 internal units = 16,384 reported units at
  `GlorySCALE`=1024) as an explicit `int`, not the two fixed values
  `catalog_fold.py`'s own `CatalogSwitches.cap` property is limited to.
- **`s4b_armed`** — S4b's "bank lights the jackpot" bonus
  (`achievementLightableModes`, DARK on every cohort measured so far,
  including this one), synthesized from each seat's OWN real
  achievement-claim events: `lightCount` = how many of a tree's four lower
  tiers (wire `hp` 0..3) that seat already banked this episode at the
  moment the tree's top tier (`hp`==4, `AchievementTiers`-1) claims;
  `recutModeLitBonus(lightCount)` (glory.nim ~L2884-2923,
  `RecutModeLitLadder = [1, 1, 2, 3, 4]`) folds via the WHOLE-INTEGER
  `recutFold` — never `recutFoldPct` — strictly AFTER the tier's own
  price, subject to the SAME running product and the SAME cap. Fold order
  confirmed from `src/ctf/sim.nim` `claimAchievement` (~L591-654), not
  prose.

**Why this is a legitimate counterfactual**: the wire's per-event
`amount`/`content` fields already ARE the deed's/claim's own
class×heat×carry×stack (or tier) price, computed independent of the
accumulator or the cap (`catalog_fold.py`'s own module docstring; verified
end to end by the harness proof below). Re-folding the SAME real per-event
prices through a different cap or with S4b's bonus interleaved is asking
"what would this real population have scored under a different economy",
not inventing new events.

**Caveat, stated once, owned everywhere below**: this holds BEHAVIOUR
fixed. No seat in this population played differently because the ceiling
moved or S4b armed — it cannot be, since GV62 was recorded under the
current ceiling with S4b dark. It answers "what would today's real games
have scored", not "what will players do once they can feel the new
ceiling" (e.g. deliberately banking lower tiers to chase the S4b bonus).

### Instrument B (secondary): the rig

The original S5 Monte Carlo rig (`RIG-SIMULATION.md`'s 3,000-seat
census-calibrated simulation, `/tmp/glory-s5/rig/s5_montecarlo.nim`) was
**never committed** and is confirmed gone (checked: not in this worktree,
not under any internal build directory) —
`LIGHTABLE-MODES-S4B.md` itself already flagged this ("a different agent's
`/tmp`, unavailable to this worker") and built its OWN smaller,
deterministic, COMMITTED substitute (`tests/test_glory_s4b_modes.nim`, 3
fixed LOW/MID/HIGH deed-floor shapes × 5 `lightCount` values × FIRST/not).
Rebuilding a fresh calibrated Monte Carlo from scratch to sweep cap×S4b
together was judged out of scope for this step's effort budget (a
multi-day undertaking per `01e-...md`'s own estimate for pipeline work of
comparable size) and carries real risk of silently diverging from the lost
original's calibration. Instrument B here is therefore a **composite read
from the two most relevant existing, committed rig artifacts**, both
independently RE-RUN on this exact commit to confirm they still reproduce
(not just cited from memory):

- `RIG-SIMULATION.md`'s own cap-ceiling sensitivity sweep (S4b never
  existed at the time; this is the S4b-OFF control) — cited, not rerun
  (its own script was equally ephemeral/uncommitted; the NUMBERS are
  already landed prose in a docs PR).
- `tests/test_glory_s4b_modes.nim` — **re-run on this commit, this PR**
  (`nim c -d:noSignalHandler --threads:on -d:useMalloc -r
  tests/test_glory_s4b_modes.nim`, Nim 2.2.10): reproduces EVERY cited
  number in `LIGHTABLE-MODES-S4B.md` exactly, including the stress-scenario
  cap-hit line (`teamGlory=4,503,599,627,370,496 >= cap=16,777,216`) and
  the CONTINUITY numbers (dark 16 distinct points, max gap 9.000 bits;
  armed 24 distinct points, max gap 6.999 bits). Full log:
  `/tmp/glory-s7/nim_compile_test.log` (not committed, reproducible by
  running the command above).

Neither artifact sweeps `cap` AND `s4b_armed` TOGETHER against a
calibrated population — this is Instrument B's own scope limit, flagged
here and again in "What this does not prove", not hidden.

---

## 2. Harness proof

Before trusting any swept cell, `cap_sweep.py` must reproduce `01e-...md`'s
own MEASURED numbers EXACTLY at cap=2^24 (current), S4b OFF. Two
independent checks, both PASS:

**Check 1 — `cap_sweep.py` vs `01e-...md`'s own numbers** (this module's
own `--harness-proof` mode and `test_cap_sweep.py`'s
`test_harness_proof_pins_s6_measured_gv62_numbers`):

| metric | `01e-...md` (S6 MEASURED) | `cap_sweep.py` (this PR) |
|---|---:|---:|
| seat-episode rows | 5,456 | 5,456 |
| capped rows | 154 (2.823%) | 154 (2.823%) |
| top-decile n (p90 threshold) | 555 (threshold=24) | 555 (threshold=24) |
| TOP DECILE (all rows) CHOSEN mean / median | 72.26% / 78.28% | 72.26% / 78.28% |
| TOP DECILE (capped excluded, n=401) CHOSEN mean / median | 84.89% / 98.83% | 84.89% / 98.83% |
| MID BAND [4,256] (n=831) CHOSEN mean / median | 62.06% / 67.01% | 62.06% / 67.01% |

Exact reproduction, every figure, to the reported precision.

**Check 2 — re-running the repo's own committed, UNMODIFIED pipeline
fresh** (independent of `cap_sweep.py` entirely — this is what actually
proves `01e-...md`'s own committed `data/gv62/` snapshot was stale, not
this PR's tooling): `census_decode.py --catalog v3` and
`attribution_decompose.py --catalog v3`, re-run against the SAME cached
replays (internal tracking, not public — the census cache and the
content-populated instrumented attribution cache; the plain cache's
`content` field is empty, so it cannot
resolve HANDED/CONSTANT/CHOSEN buckets even though it gives identical
`reported`/`capped`/`product` values, since the fold never reads
`content`), reproduces `5,456/5,456` rows, `154` capped, and the same
CHOSEN/HANDED/CONSTANT table above, digit for digit. (An important
side-finding: the COMMITTED `data/gv62/seat_episode_rows_gv62.json` and
`00w-s6-remeasure-raw/seat_episode_rows_gv62.json` are both the OLDER,
pre-pipeline-fix v2-style reconstruction — 2,677/5,456 rows read `capped`
under that broken fold, not 154 — an artifact of the original session's
intermediate files never being overwritten with the fixed v3 output. This
does not affect `01e-...md`'s own prose numbers, which are correct and
independently reproduced here from the raw replay cache, not from that
stale snapshot.)

**HARNESS PROOF: PASS.**

---

## 3. Full sweep table

Cap candidates in REPORTED-space log2 bits (the `2^N` framing matches
`TARGET-DISTRIBUTION.md`'s own pinned ladder units): the task's required
set `{14 (current), 15, 16, 17, 18, 20, uncapped}`, plus two supplementary
points (`19`, `21`) added to pin the crossing more precisely (flagged
below as this PR's own addition, not part of the required set).

### Instrument A — empirical re-fold (`tools/glory/cap_sweep.py`)

| cap (pts) | S4b | n | cap-hit % | cap-hit n | top-decile capped % | top CHOSEN (all) | top CHOSEN (clean) | mid CHOSEN | continuity gap | separation | jackpot p999/p50 |
|---|:-:|---:|---:|---:|---:|---:|---:|---:|:-:|:-:|---:|
| 2^14 (current) | OFF | 5456 | 2.823% | 154 | 27.75% | 72.26% | 84.89% | 62.06% | no | 24/24 | 16,384× (14.00 bits) |
| 2^14 (current) | ON  | 5456 | 2.823% | 154 | 27.75% | 72.30% | 84.95% | 62.10% | no | 24/24 | 16,384× (14.00 bits) |
| 2^15 | OFF | 5456 | 2.364% | 129 | 23.24% | 73.64% | 84.10% | 62.34% | no | 24/24 | 32,768× (15.00 bits) |
| 2^15 | ON  | 5456 | 2.364% | 129 | 23.24% | 73.68% | 84.16% | 62.37% | no | 24/24 | 32,768× (15.00 bits) |
| 2^16 | OFF | 5456 | 1.631% | 89  | 16.04% | 75.92% | 83.48% | 62.34% | no | 24/24 | 65,536× (16.00 bits) |
| 2^16 | ON  | 5456 | 1.631% | 89  | 16.04% | 75.97% | 83.53% | 62.37% | no | 24/24 | 65,536× (16.00 bits) |
| 2^17 | OFF | 5456 | 1.466% | 80  | 14.41% | 76.51% | 83.40% | 62.34% | no | 24/24 | 131,072× (17.00 bits) |
| 2^17 | ON  | 5456 | 1.466% | 80  | 14.41% | 76.55% | 83.45% | 62.37% | no | 24/24 | 131,072× (17.00 bits) |
| 2^18 | OFF | 5456 | 0.751% | 41  | 7.39%  | 80.88% | 84.00% | 62.34% | no | 24/24 | 262,144× (18.00 bits) |
| 2^18 | ON  | 5456 | 0.751% | 41  | 7.39%  | 80.93% | 84.05% | 62.37% | no | 24/24 | 262,144× (18.00 bits) |
| 2^19 *(bonus)* | OFF | 5456 | 0.587% | 32 | 5.77% | 82.25% | 84.10% | 62.34% | no | 24/24 | 524,288× (19.00 bits) |
| 2^19 *(bonus)* | ON  | 5456 | 0.605% | 33 | 5.95% | 82.24% | 84.14% | 62.37% | no | 24/24 | 524,288× (19.00 bits) |
| **2^20** | OFF | 5456 | 0.550% | 30 | 5.41% | 82.19% | 84.10% | 62.34% | no | 24/24 | 1,048,576× (20.00 bits) |
| **2^20** | ON  | 5456 | 0.550% | 30 | 5.41% | 82.24% | 84.15% | 62.37% | no | 24/24 | 1,048,576× (20.00 bits) |
| **2^21** *(bonus)* | OFF | 5456 | 0.312% | 17 | 3.06% | 83.16% | 84.12% | 62.34% | no | 24/24 | 2,097,152× (21.00 bits) |
| **2^21** *(bonus)* | ON  | 5456 | 0.312% | 17 | 3.06% | 83.21% | 84.17% | 62.37% | no | 24/24 | 2,097,152× (21.00 bits) |
| uncapped | OFF | 5456 | 0.000% | 0 | 0.00% | 83.98% | 83.98% | 62.34% | no | 24/24 | 576,744× (19.14 bits) |
| uncapped | ON  | 5456 | 0.000% | 0 | 0.00% | 84.03% | 84.03% | 62.37% | no | 24/24 | 890,513× (19.76 bits) |

Reproduce with (the `--episodes`/`--jsonl-dir` inputs are internal census
data, not public):
```
python3 tools/glory/cap_sweep.py \
  --episodes <internal episodes.json> \
  --jsonl-dir <internal attr_replays dir> \
  --cap-bits 14,15,16,17,18,19,20,21,uncapped --s4b off,on \
  --out /tmp/glory-s7/sweep.json
```

**Freeze floor, CONTINUITY, SEPARATION**: hold at EVERY candidate, both
S4b states — top-decile CHOSEN never drops below 72.26% (comfortably
≥50%), mid-band CHOSEN never drops below 62.06% (comfortably a majority),
no 6–9pt gap at any cell, all 24 rounds separate at every cell. These are
not the binding constraints here — cap-hit % and top-decile-capped % are.

**Cap-hit % response is a smooth decay, not a cliff**: 154→129→89→80→41→
32→30→17→0 as the ceiling rises. The population's extreme tail (17
seat-episodes still exceed 2^21, one single outlier reaches
1,732,981,933 ≈ 2^30.7 — a base-outlier row of the same shape
`RecutProductCapArmed`'s own doc comment already names, "the r4039 44.79M
base-outlier") decays gradually across the swept range, not in one jump.

**S4b's real effect on cap-hit is negligible-to-small and non-monotone in
which direction it moves**: identical cap-hit/top-decile-capped at 2^14,
2^15, 2^16, 2^17, 2^18, 2^20, 2^21 and uncapped (S4b changes the CHOSEN
share slightly but flips ZERO rows' `capped` status); at 2^19 specifically
S4b tips ONE additional row over the cap (32→33, 0.587%→0.605%). S4b's
own CHOSEN-share nudge (+0.04 to +0.09pp at the top decile, +0.03 to
+0.05pp mid-band) is real but small on REAL, unchanged historical play —
far smaller than the synthetic toy-shape acceptance tests in
`LIGHTABLE-MODES-S4B.md` suggested (e.g. its own HIGH-shape lightCount=3
scenario put the bonus at 11.6% of a seat's total magnitude), because real
seats RARELY bank 2+ lower tiers of the SAME tree before claiming its top
tier in one match (`CENSUS-2026-09-ACHIEVEMENTS.md`: 35/40 achievement
slots mint zero at all).

### Instrument B — the rig (composite, both re-run on this commit)

| source | S4b | reading |
|---|:-:|---|
| `RIG-SIMULATION.md` cap-ceiling sweep (cited, S4b did not exist yet) | OFF | CLIFF: 0.0000% at bits 16/15.5/15/14.5, jump to 6.0667% (182/3000) at bit 14.0, same 6.0667% at bit 12.0 — "zero population between 14.5 and 16, then a jump" |
| `tests/test_glory_s4b_modes.nim` (re-run this commit) | ON (vs OFF paired) | CONTINUITY: dark 16 distinct log2-glory points (max gap 9.000 bits) → armed 24 distinct points (max gap 6.999 bits); SEPARATION: LOW-floor→HIGH-jackpot spread dark=17.685 bits → armed=19.685 bits (strictly wider); CAP-HIT: 0/60 ordinary-shape points hit the cap; one deliberately-stacked stress scenario (HIGH×7+FIRST, `deedMintCaps` off) reaches `teamGlory=4,503,599,627,370,496` ≫ any candidate ceiling — confirms the cap is reachable "in principle" but says nothing about population RATE |

---

## 4. A vs B: the disagreement, and why

**A says**: the real population's cap-hit response to a rising ceiling is
smooth and monotone (a gently decaying count, 154→0), and S4b changes
essentially nothing about WHICH rows cap. **B (S4b-off half) says**: a
CLIFF — flat zero between bits 14.5–16, then a discontinuous jump to 6.07%
at bit 14. These do not describe the same thing, and the disagreement is
explainable, not a contradiction:

- **B's population is synthetic and coarse.** `RIG-SIMULATION.md`'s own
  Monte Carlo drew per-seat deed COUNTS from a census-aggregate mean rate
  (episode total ÷ 16, a stated simplification) across only two discrete
  ARCHETYPES (baseline/skilled). A population built from two fixed
  archetype policies and integer deed counts naturally clusters into a
  small number of distinct achievable totals — exactly what produces a
  cliff (nothing between two widely-spaced clusters). A's population is
  5,456 REAL seat-episodes, each an emergent combination of whatever a
  real bot policy, a real map, and real opponents produced — a much wider,
  smoother draw space.
- **B's own diagnosis already names the mechanism**: `RIG-SIMULATION.md`
  states the cliff is driven by "which deed combinations a seat happens to
  draw" being "discrete/clustered... an artifact of the archetype model's
  own limited draw space", explicitly flagged as unresolved by that
  worker. A's smooth decay is consistent with that diagnosis being
  correct: the cliff was a modelling artifact of a two-archetype,
  mean-rate Monte Carlo, not a structural property of the real economy.
- **B's own Sharpshooter-rate compression** (task's own hint, confirmed):
  `RIG-SIMULATION.md`'s per-class breakdown shows ACHIEVEMENTS consuming
  25–41% of a Monte Carlo seat's total magnitude — "far more than CHOSEN
  needs" — traced explicitly to the archetype model reusing the census's
  POPULATION-WIDE Sharpshooter claim rate (69.18%) for BOTH baseline and
  skilled seats, a modelling choice, not a measurement. This inflates
  ACHIEVEMENTS' weight in the synthetic rig relative to real play, which
  plausibly also compresses where the synthetic tail clusters (fewer
  distinct achievable totals near the top) versus the real population's
  much wider kill/heat/stack-driven combinatorics.
- **S4b's real vs synthetic magnitude**: B's own deterministic sweep
  (`test_glory_s4b_modes.nim`) shows S4b's bonus as a LARGE fraction of a
  contrived HIGH-shape seat's total (11.6%) because that shape is
  DESIGNED to bank every lower tier before the top claim. A shows the
  REAL population almost never does this in one match — so S4b's toy-rig
  "answer to the cliff" (LIGHTABLE-MODES-S4B.md's own framing) does not
  transfer to real play at anywhere near the same strength. Both readings
  are correct for what they measure; they measure different things.

**Bottom line**: instrument A is the one to size the ceiling from — it is
the real population, it reproduces the S6 MEASURED numbers exactly, and
its smooth-decay finding is corroborated by B's own stated diagnosis of
why B clustered. Instrument B remains useful for confirming the MECHANISM
(S4b's fold order, the cap is reachable, CONTINUITY/SEPARATION improve on
a fixed shape) but not for reading a population-level cap-hit RATE.

---

## 5. Candidates meeting ALL constraints

Constraints: cap-hit ∈ [0.1%, 1%] (owner-signed, `TARGET-DISTRIBUTION.md`
§2); top-decile capped share under ~5% (S2 lead's S7 ruling); freeze floor
top-decile CHOSEN ≥50% and mid-band majority (`CATALOG-V3-DRAFT.md`);
CONTINUITY (no 6–9pt gap); SEPARATION (every round).

| cap | cap-hit in [0.1,1]%? | top-decile-capped <~5%? | freeze floor? | continuity? | separation? | ALL constraints? |
|---|:-:|:-:|:-:|:-:|:-:|:-:|
| 2^14 (current) | no (2.823%, over) | no (27.75%) | yes | yes | yes | **no** |
| 2^15 | no (2.364%, over) | no (23.24%) | yes | yes | yes | **no** |
| 2^16 | no (1.631%, over) | no (16.04%) | yes | yes | yes | **no** |
| 2^17 | no (1.466%, over) | no (14.41%) | yes | yes | yes | **no** |
| 2^18 | yes (0.751%) | no (7.39%) | yes | yes | yes | **no** |
| 2^19 | yes (0.587–0.605%) | no (5.77–5.95%) | yes | yes | yes | **no** (close) |
| 2^20 | yes (0.550%) | borderline (5.41%, "~5%") | yes | yes | yes | **borderline** |
| **2^21** | yes (0.312%) | **yes (3.06%)** | yes | yes | yes | **YES** |
| uncapped | no (0.000%, under) | yes (0.00%) | yes | yes | yes | **no** (violates the 0.1% floor — a designed jackpot needs SOME cap-hit, not zero) |

**No candidate in the task's own required set cleanly satisfies BOTH the
cap-hit band and the under-~5% top-decile-capped bound at the same time**
under a strict (non-"~") reading. 2^20 is the closest required candidate
(cap-hit comfortably mid-band at 0.550%; top-decile-capped at 5.41% is
within rounding of the S2 lead's own tilde-qualified ~5%). The
supplementary point 2^21 is the first cap value tested, required or not,
where BOTH bounds hold with real margin (0.312% cap-hit, well inside
[0.1,1]; 3.06% top-decile-capped, comfortably under 5%). The true crossing
for the <5% bound sits somewhere between 2^20 and 2^21 — not pinned more
precisely than that here (see "What this does not prove").

---

## 6. Recommendation

**Primary: 2^21 reported points** (`RecutProductCapArmed` → `int64(1) shl
31` = 2,147,483,648 internal units = 2,097,152 reported units).

- Cap-hit: 0.312% of seat-episodes — inside [0.1%, 1%] with margin on both
  sides (not hugging either edge, which matters given the population is
  only 5,456 rows and a thin-tail metric like this one is noisy round to
  round).
- Top-decile capped share: 3.06% — cleanly under the ~5% bound, not a
  close call.
- Freeze floor: top-decile CHOSEN 83.16–83.21% (S4b off/on), mid-band
  62.34–62.37% — both far above their floors, and BOTH RISE relative to
  today's cap (72.26%/62.06%) because fewer top-decile rows land in the
  UNRESOLVED-because-capped bucket.
- CONTINUITY and SEPARATION hold, as they do at every candidate tested.
- S4b's own marginal effect here is negligible (identical cap-hit/
  top-decile-capped S4b on vs off) — arming S4b alongside this ceiling
  does not reopen the cap-hit question this ceiling closes.

**Runner-up: 2^20 reported points** (`int64(1) shl 30` = 1,073,741,824
internal / 1,048,576 reported) — the best candidate from the TASK'S OWN
required sweep set. Cap-hit 0.550% sits comfortably mid-band; top-decile
capped 5.41% is arguably "under ~5%" on a generous reading of the S2
lead's own tilde-qualified bound, but is not a clean pass the way 2^21 is.
Prefer this if the lead wants to stay strictly inside the originally
scoped candidate list rather than accept this PR's own supplementary
exploration.

Both candidates leave the jackpot-ratio-vs-median target UNRESOLVED — see
next section.

### The jackpot-ratio tension (flagged, not resolved by this step)

`TARGET-DISTRIBUTION.md` §2 signs JACKPOT ≈~1000× the (target) MEDIAN,
and §5's pinned ladder separately puts the ceiling at ≈16 pts. Neither
target is reachable by a cap choice alone on THIS population, for a
structural reason this step did not create and cannot fix:

- **The population's actual p50 is 1** ("no-deed episode", the bare
  seed) — `TARGET-DISTRIBUTION.md` §3 already named this exact defect
  ("today the median seat-episode scores 4 [pre-#477]... the floor is the
  defect, not the cap"). Against a degenerate median of 1, ANY score above
  1 already reads as an astronomical "×" ratio — raising the cap does not
  move the ratio TOWARD 1000×, it moves it AWAY (16,384× at today's cap →
  2,097,152× at 2^21), because p999 stays pinned to whatever the cap is
  until cap-hit drops under 0.1% (5.46 of 5,456 rows) — and even fully
  UNCAPPED, the organic p999 (576,744–890,513×) is still ~500–900×
  ABOVE the 1000-median target, let alone the degenerate-p50 ratio.
- **The owner-signed ≈16pt pinned ceiling** (`TARGET-DISTRIBUTION.md` §5)
  is also not reachable while satisfying the cap-hit band on this
  population: 2^16 alone reads 1.631% cap-hit (over the 1% ceiling) and
  16.04% top-decile-capped (over 3× the ~5% bound). Hitting the pinned
  16pt ceiling on today's real population REQUIRES accepting a much
  higher cap-hit rate than the S2 lead's own S7 ruling allows.
- **This is a genuine, load-bearing tension between two owner/lead-signed
  targets**, not a bug in this step's method: the pinned absolute-points
  ladder (§5) and the cap-hit-rate/top-decile-capped bounds (S7's own
  brief) cannot BOTH be satisfied by choosing a cap value alone, on
  today's real, floor-dominated population. Reconciling them needs the
  mid-band/floor reshape `TARGET-DISTRIBUTION.md` itself already flags as
  a SEPARATE, larger, not-yet-armed piece of this program (raising the
  effective median so a fixed-ratio jackpot target lands somewhere
  meaningful) — not a decision this step can make by moving the ceiling.
  **Flagged for the lead/owner, not silently resolved here.**

---

## 7. What this does not prove

- **No behavioural response.** Every number above replays REAL, ALREADY
  RECORDED play. No seat in this population chased the S4b bonus, played
  toward a higher ceiling, or adjusted strategy in any way — because none
  of that was live when this cohort was played. A live re-measure after
  arming (the same S6→S7 pattern this whole epic has followed at every
  step) is still required before trusting these numbers as a forecast of
  live behaviour, not just a re-score of history.
- **Instrument B is a composite of two existing, narrower artifacts**, not
  a fresh calibrated Monte Carlo sweeping cap×S4b together — the tool that
  could have done that was never committed and is confirmed unrecoverable.
  Section 4's A-vs-B reconciliation is a reasoned diagnosis (grounded in
  both artifacts' own stated methods and known caveats), not a
  side-by-side apples-to-apples sweep.
- **The <5% top-decile-capped crossing is bounded, not pinned.** Tested at
  integer reported-point granularity only (14 through 21, plus uncapped);
  the true crossing sits somewhere between 2^20 (5.41%) and 2^21 (3.06%),
  not resolved more finely here.
- **The jackpot-ratio-vs-median target is structurally unreachable by a
  cap choice alone on this population** (see §6) — this step surfaces that
  tension; it does not resolve it.
- **One extreme outlier** (product ≈2^30.7, ~1.7 billion internal units)
  exists in this 341-episode window and is not independently
  investigated here (same class of finding `RecutProductCapArmed`'s own
  doc comment already names for the v2 economy, "the r4039 44.79M
  base-outlier" — worth a dedicated look, not blocking this recommendation
  since it sits far above every candidate ceiling tested and is exactly
  the kind of composition the cap exists to catch).
- **24-round window.** Same thin-tail caveat every S6/S7 read in this
  program has carried: cap-hit and top-decile-capped are both percentages
  of small counts (17–154 rows out of 5,456) on one 24-round window: not
  independently re-verified against a second, later window here.

---

## 8. Ship note

**Arming = manifest flip + GLORYVERSION 17→18 + GameVersion 63→64 +
fixture re-record**, per this program's own precedent (PR #504's
`catalogV3Reprice` et al. arming, GLORYVERSION 16→17/GameVersion 61→62):
flip `achievementLightableModes` AND resize `RecutProductCapArmed` to
2^21-reported (`int64(1) shl 31` internal) together, on the
`battle-royale-s2` flagship variant's manifest block ONLY — never
`defaultGameConfig()`'s compiled default (`LIGHTABLE-MODES-S4B.md`'s own
arming note already names this exact non-default-arm discipline for S4b).

**Sequencing** (per the lead's own recorded ship plan, not invented here):
S4b-arm + ceiling-resize together = GLORYVERSION 17→18 + GameVersion
63→64, bundled with the game-side seat-identity consumer (metta #22382
`COWORLD_SEAT_IDENTITY` → `RuntimeConfig` → per-seat identity on `over`),
**sequenced AFTER THE WHOLE's held GV63 wire batch (#525)** completes —
full fixture re-record (nine-plus `.bitreplay` goldens, shell/replay
goldens, static replay viewer rebuild — the same three-part cost #504
itself paid), an era note documenting the GV62→GV6x boundary, and a
24-round after-read on the newly-armed cohort with the same harness used
here (`cap_sweep.py` / `census_decode.py --catalog v3`, the same S6-style
live re-measure this whole program runs at every arm) before calling
this closed.

**Owner GO required** before merge, same as every prior GLORYVERSION bump
in this program — this document sizes the ceiling; it does not arm it.

---

## §Placement — the item-4 gate result and menu

**DECIDED (owner, 2026-09-10): Ladder B.**

The placement ladder (`RecutPlacementRampPct[dFinal8]`/`[dFinal4]`/
`[dFinal2]`) was screened on the same top-decile CHOSEN-share gate this
whole program runs candidates against, alongside the S7 ceiling and S4b
armed. Every ladder below was measured with the ceiling and S4b ON, not
in isolation — placement does not move independently of the rest of the
S8 bundle. The gate's own structural finding: placement fires
disproportionately on the top-decile seats (the same seats a finish-line
milestone rewards), so an aggressive placement ramp erodes top-decile
CHOSEN share by competing with the achievement/kill-chain deeds for the
same seats' score composition — the tighter the ramp, the more headroom
those other deeds keep.

| Ladder | `dFinal8`/`dFinal4`/`dFinal2` | Top-decile CHOSEN (mean) |
| --- | --- | --- |
| Ruled (rejected pre-gate) | ×1.5 / ×2 / ×3 | 34.99% |
| **A** | ×1.10 / ×1.20 / ×1.40 | 68.12% |
| **B — DECIDED** | ×1.15 / ×1.30 / ×1.60 | 67.93% |
| C | ×1.25 / ×1.50 / ×2.00 | 64.48% |
| D | ×1.20 / ×1.50 / ×2.00 | 64.52% |
| F4-pop | ×1.25 / ×2.00 / ×2.50 | 57.09% |
| Tiers-only (placement left at S5's ×1.00/×1.00/×1.30) | — | 68.39% |

Ladder A scored marginally higher (68.12 vs 67.93) but the owner picked
**B** — both sit within the same band, well clear of the Ruled candidate's
34.99% floor and the F4-pop candidate's structural collapse (57.09%,
consistent with the finding above: pricing the FOUR-team finish line like
a near-achievement is the most aggressive way to compete with the
achievement deeds for top-decile share). All three of Ladder B's rungs
stay under the gate's own ≥2× population line, so this move does not
make a placement finish "pop" the score — see `docs/RULES.md`'s S8 table
for the same framing in player-facing terms.

**Final gate line for the shipped branch** (S8 ceiling 2^31 internal +
S4b armed + PLACEMENT LADDER B + tiers IV 250%/V 300%, all together,
re-folded on THIS branch's own `tools/glory/cap_sweep.py`/
`tools/glory/catalog_fold.py` — harness-proof confirmed it reproduces the
S6 MEASURED numbers exactly first, then a reprice-aware extension of the
same fold state machine substituted the branch's own placement/tier
percentages for the wire's historically-recorded GV62 amounts before
folding; every other deed/achievement folds the wire's own recorded
amount unchanged):

- n=5,456 seat-episode rows, cap-hit 0.605% (33/5,456)
- top-decile n=555, threshold=60 reported
- **TOP-DECILE CHOSEN mean=67.93% / median=77.81%** — matches the gate
  menu's own estimate for Ladder B EXACTLY (67.93 / 77.81)
- MID-BAND [4,256] CHOSEN mean=47.70% / median=48.97%
- top-decile placement share mean=1.13% / median=0.00%
- top-decile achievement share mean=21.59% / median=19.28%

This is the number of record — the menu estimate above was measured on a
prior candidate fold; this re-fold, on the shipped branch's own constants,
reproduces it to two decimal places.

---

## Cross-refs

S6 live read (the number this step opens on): internal tracking, not public.
Target bands: `TARGET-DISTRIBUTION.md`. Rig / cliff finding:
`RIG-SIMULATION.md`. S4b mechanism: `LIGHTABLE-MODES-S4B.md`. HANDED/
CONSTANT/CHOSEN mapping + freeze criterion: `CATALOG-V3-DRAFT.md`. Cap
constant + fold order: `src/ctf/glory.nim` (`RecutProductCapArmed`
~L2642, `RecutModeLitLadder`/`recutModeLitBonus` ~L2884-2923,
`recutFoldPct`/`recutFold`/`recutScoreScaled` ~L2935-3049),
`src/ctf/sim.nim` (`claimAchievement` ~L591-654, the S4b fold order).
Tooling: `tools/glory/cap_sweep.py`, `tools/glory/test_cap_sweep.py`,
`tools/glory/catalog_fold.py` (the v3 fold this extends). Mirror:
internal tracking, not public.

# GLORY GRADIENT — Step 4: CATALOG v3 — S4 FREEZE

**ERA STAMP (re-stamped after rebase): frozen 2026-09-09, coworld-ctf PR #491, branch
`maxwell/glory-catalog-v3`, rebased onto `origin/main @ 070d4805` ("docs: sign S3 target distribution
for GLORY GRADIENT (#490)" — the true head at rebase time, superseding the earlier stamp's
`62fa0146`; this range also picks up #482 sweep, #483 census, #485 pinball zipper, #487 Nim-2.2.10
CI pin, and #490 target-distribution, all now merged to main). GLORYVERSION 16 / GameVersion 61
(PR #477) still not published to any paintbot-v* build. Attribution evidence: PR #494
(`maxwell/glory-attribution`, commit `0fc7bba5`), same population as the census — GloryVersion 15,
coworld_version 0.7.361-0.7.367, rounds r4515-r4539, 305 episodes, 4,880 seat-episodes.** The S2
lead merges this PR as the S4 freeze; S5 opens on that merge sha. **This worker does not merge.**

## DESIGN LAW (top of document, binding on every section below)

**S4 converts HANDED and CONSTANT magnitude into CHOSEN magnitude; it does not re-tier what
exists.** Consequently: the placement ramp and TERRITORY are re-priced so the home pedestal's
automatic point and `dClosingTime`'s automatic timing carry CONSTANT-band weight only; the
differentiating magnitude moves to kills / heat / stack / assists / pact deeds. **Heat stays a
METER, never a pop** (Section 5, Section 9's own restated legibility law).

## THREE ROOT-CAUSE RULINGS (ruled this session; the owner may override in the morning)

These supersede the corresponding conditional dispositions in Sections 2b/3 below — those sections
are left in place as the evidence trail, not rewritten, but the ruling here is what stands.

**(a) Flagless BR.** The five flag deeds (`dFlagSteal`, `dCapture`, `dCarrierKill`, `dDenial`,
`dEscortKill`) are **NOT dead — they are CTF-MODE deeds**. v3 lists deeds **PER MODE**; the BR
catalog simply omits them (KEEP for CTF, OMITTED not CUT from BR). Retarget **one** to a BR
analogue (zone/pedestal control) **only if that analogue is itself a CHOSEN deed** — not decided
which one here, flagged for S5 design, not built.

**(b) CTF-only gate on `dAssist`/`dRescue` — UN-GATE FOR BR.** These are the pact era's
chosen-magnitude deeds and exactly what the owner wants graded. Remove the `if not
sim.config.brMode` gate (`sim.nim:3117`, `sim.nim:3135`). **Cannot be exercised in this frozen
population** — the gate means these events never fired in BR, so a static re-price of the recorded
4,880 events cannot manufacture them; their real magnitude is an S5 rig question once the gate is
removed and new episodes are measured.

**(c) Solo-team / win-retirement.** `dDuoDown` and `dWipe` **RETARGET TO PACT SCOPE** — a pact
downing/wiping an OPPOSING pact, consistent with GV15's pact-only joint-act law (matches
`ctf-gv15-jointact-is-pact-only`). Memory `ctf-dwipe-is-dead-no-64x` **stays TRUE for solo** (no
duo exists in 16-solo); the pact-scoped version is a new, reachable deed once pacts are active — not
retroactively measurable from this population for the same reason as (b). **`dVictory` is a
duplicate of WIN ×8 and is RETIRED, not revived** — this was already true by construction
(gated `not winAsMultiplier`, Section 2b) and is now also the permanent design decision, not merely
an observed side effect.

Program 25d9108e, task 703813a4. Gate: the S2 lead reviews and merges this as the S4 freeze before
Step 5 (RIG SIMULATION) opens. **This document freezes the MECHANISM and DIRECTION — the design
law, the three root-cause rulings, the representation, and proof that the CHOSEN-magnitude target
is reachable — it does NOT freeze final numeric constants**: deed classes, heat-ladder rungs, cap
thresholds, and pact-decay durations remain the rig's (S5's) to pick. No `glory.nim`/`sim.nim`/
`sim_types.nim` *behavior* was touched, no GLORYVERSION bump, no wire change, no settings POST, no
deploy, no merge. **One
explicit, authorized exception**: `tests/test_glory_percent_scale_headroom.nim` was added as
additive-only test code (per the S4 gate's explicit instruction to prove, not assert, the
representation option's integer headroom) — it defines its own local fold helpers, imports but does
not modify any production proc, and is registered in `tests/shard_1.nim` so it does not run dark.

## FREEZE CONDITION 1 — RE-ATTRIBUTION TABLE (the load-bearing one)

**Method, STATIC PASS ONLY**: re-priced the SAME 4,880 census seat-episodes' recorded events using
PR #494's own `attribution_decompose.py` method and bucket schema verbatim (same event-level
`content` parsing, same `RECIPE_BASE`/`PLACEMENT_BASE`/`OTHER_DEED_BASE`/`HEAT`/`CARRY`/
`ALLY_STACK`/`TERRITORY`/`ACHIEVEMENTS`/`WIN`/`FRIENDLY_FIRE` buckets), substituting catalog-v3
base-class/heat-ladder/achievement-tier values where this catalog proposes a reprice. **No sim, no
rig, no new episodes** — the same recorded events, re-priced. Script:
`/tmp/glory-catalog/attribution-tool/reprice_v3.py` (not committed — ephemeral trial tooling; the
numbers below are what it measured, run locally, four iterations).

**HANDED/CONSTANT/CHOSEN mapping — #494's OWN classification, not redefined**: `HANDED =
{PLACEMENT_BASE, WIN}` (#494's own set, verbatim). Of #494's own `CHOSEN` set, this catalog uses
**TOP-ATTRIBUTION.md's own prose split** (not a new definition): `CONSTANT = {RECIPE_BASE,
ACHIEVEMENTS, TERRITORY}` (the doc's own words — "closer to structural TIMING," "a second placement
ladder," "a map-geometry constant"); `CHOSEN = {OTHER_DEED_BASE, HEAT, ALLY_STACK, CARRY}` (the
doc's own "genuinely graded, skill-driven, repeatable choice," ~11% today).

### `dJointAct` RECLASSIFIED — era-split, lead ruling

The lead ruled on the tension this section originally flagged: since GV15 (ladder r4517), `dJointAct`
fires only inside a declared, formed pact — pact formation is the hardest choice on the board
(Monet's pact arc went 4.7%→29.7% formed across five versions) — so post-r4517 it is CHOSEN, not
CONSTANT. Pre-r4517 rows were unconditional and **stay CONSTANT for those rows only**.

**Boundary OBSERVED in this population, not assumed**: split by `round_number`, then independently
cross-checked against `coworld_version` — **r4515/r4516 = coworld_version 0.7.361 (416 seat-episode
rows); r4517 onward = coworld_version 0.7.362 and later (4,464 rows)**. This is a clean build-version
boundary landing exactly at r4517, matching the ruling precisely — not forced. `dJointAct`'s own
per-firing base class (2) is unchanged by this ruling; only its BUCKET changes, routed to a new,
separately-reported `JOINTACT_CHOSEN` bucket for the 4,464 post-boundary rows, `RECIPE_BASE`
(unchanged) for the 416 pre-boundary rows.

**BASELINE, re-derived with the era-split applied (no other repricing — every other value matches
#494's published table exactly, isolating just this one reclassification's effect)**: HANDED 43.30%
(unchanged), CONSTANT 45.30% (was 45.57%), **CHOSEN 11.40%** (was 11.14%) — rose, as it must (a
reclassification can only move magnitude toward CHOSEN, never away). `JOINTACT_CHOSEN` itself
contributes 0.26% at baseline.

**Repriced (catalog v3, iteration 4 + `dJointAct` era-split — the frozen table)**:

| population | n | HANDED | CONSTANT | CHOSEN |
|---|---:|---:|---:|---:|
| TOP DECILE (p90 of catalog-v3's OWN resulting points, 4.48 pts) | 553 | 10.98% | 17.91% | **71.11%** |
| MID BAND (S3 ladder's own 2–8 pts) | 755 | 27.10% | 18.28% | **54.61%** |
| *[transparency check]* TOP DECILE by the OLD p90 threshold (score≥576), repriced | 509 | 40.10% | 28.26% | 31.65% |

Every population's CHOSEN share rose versus the pre-reclassification table (70.73%→71.11% top,
53.98%→54.61% mid, 30.91%→31.65% old-selection check) — confirms the reclassification is
directionally correct (adding magnitude to CHOSEN, never removing it); had any of these FALLEN, that
would have indicated a bug in the reclassification, not a valid result.

**FREEZE CRITERION MET**: CHOSEN = 71.11% at the top decile (≥50% required) and 54.61% at mid (a
majority, "mostly CHOSEN"). **The transparency-check row is reported, not hidden**: holding the
*population selection* to the OLD scoreboard's top decile and only re-pricing the events, CHOSEN
reaches only 31.65% — because repricing changes WHO ranks in the top decile (kill/heat-heavy seats
overtake the old placement/win-heavy leaders), and grading a repriced economy by the old scoreboard
is not a meaningful test of it. **Top decile and mid band are therefore defined on catalog v3's own
resulting point distribution**, per the S3 ladder's own units — this is a modeling choice, stated
plainly, not a way of hiding a miss. (See "What this does not prove" below for the plain-language
version of this same caveat.)

**What had to be repriced to get there** (direction, not final constants — S5/the rig picks exact
numbers): PLACEMENT crushed hard (`dFinal8`→1.0, `dFinal4`→1.0, `dFinal2`→1.3, from 2/3/4);
`dClosingTime`'s base crushed toward CONSTANT-only weight (→1.1/1.2 win-bumped, from 2/3);
TERRITORY's rung-shift scaled to 15% of its current magnitude; `treeSquad.IV` Clean Sheet crushed
from ×2 to ×1.05; `treeGun.V` Sharpshooter's magnitude scaled down (exponent 0.5) but kept real;
**every kill deed's class raised** (`dHonorableKill` 1→2.2, `dShieldSoak` 1→1.6, `dClutchHeal`
1→1.8, `dPointBlankKill` 1→2.5, plus the already-real classes `dFirstBlood`/`dLongshotKill`/
`dAceTag`/`dLastLight`/`dRevengeKill`/`dRunDown`/`dSplashMultiKill` all raised further); HEAT's rung
values re-spaced far higher (2/4/8 → 5/14/36); ALLY-STACK scaled ×2.5; **`dJointAct` reclassified
era-split (this section)**. **`WIN` was deliberately left untouched** at ×8 (the earlier ruling on
the placement ramp: "the win multiplier stays the win"). Mint-RATE and the gunRange sweep were
explicitly NOT touched, per the freeze brief's own instruction — those are S5's problem.

**Honest limits of this exercise — see the dedicated "What this does not prove" section below for
the two load-bearing caveats (today's leaders vs. tomorrow's, and the unmeasurable rulings b/c).
Additional, smaller limits**:
- These are TRIAL constants proving the criterion is *reachable* by a static reprice, in the
  direction the design law names — **not a recommendation for S5's actual constants**. The rig
  (paired seeds, real policies) is where real numbers get picked; simulators pick constants, this
  freeze only proves the design has room to satisfy the owner's target.
- Boosting kill classes this far (e.g. `dHonorableKill` to ×2.2, heat's top rung to ×36) is
  numerically aggressive; whether it is *desirable* on FEEL grounds (not just on this attribution
  arithmetic) is explicitly an owner/simulator question for S5, not settled by clearing this bar.

## FREEZE CONDITION 2 — WHAT THIS DOES NOT PROVE

Carried into the lead's morning report to the owner in these terms, not softened:

1. **This redesign works by changing WHO is on top, not by making today's leaders more skilful.**
   Today's actual top-decile seats, re-priced under catalog v3 but still graded as "top decile" by
   the OLD scoreboard, are only **31.65% CHOSEN** (the transparency-check row above) — barely moved
   from today's 11.40% baseline. The 71.11%/54.61% numbers describe a **different population**: the
   seats that catalog v3's own pricing would rank at the top, who are disproportionately the
   kill/heat-heavy seats, not the placement/win-heavy seats who rank at the top today. This is the
   intended mechanism (reward what the owner wants graded), not a side effect, but it means the
   freeze proves the CATALOG can produce a CHOSEN-dominated top, not that today's specific top
   performers are secretly more skilful than they appeared.
2. **Rulings (b) `dAssist`/`dRescue` un-gated and (c) pact-scoped `dDuoDown`/`dWipe` could not be
   exercised statically** — zero recorded events in this population (code-gated in BR), so there is
   nothing to reprice. Both are **S5 rig items**, and **each needs a fire counter** so their real
   mint rate is observable the moment the gates are removed and new episodes are measured — this is
   not optional instrumentation, it is how the program would know whether ruling (b)/(c) actually
   moved anything once live, the same switch+counter law every other lever in this catalog follows.

## FREEZE CONDITION 3 — HEADROOM VERDICT (recorded, Section 9/9a/9b below)

The fixed-point accumulator (`SCALE=2^10`) is the adopted S4 representation; the batch-of-5
mitigation and its fold-order constraint are DROPPED. Worst-case drift 0.131% across all tested
seeds, overflow margin ~7 million× below 2^62 including the FF-halving division path. See Section 9
for the full record; not repeated here.

## 0. What this is designed against

- Source read at `origin/main @ 62fa0146` (PR #477 merged: GLORYVERSION 16 / GameVersion 61,
  "wire the six dead levelX() buffs into live combat"). **Not yet published** to any paintbot-v*
  build as of this draft — the S1 census population (r4515–r4539) is entirely GloryVersion 15
  (pre-#477). All `RecutClassTable`/`RecutMintCapTable`/`RecutProductCapArmed` citations below were
  re-verified against this checkout directly (line numbers may have drifted a few lines from
  earlier ledger citations written against an older commit; re-verified, not assumed).
- The census's measured mint rates and magnitude shares are therefore a **pre-#477 baseline**.
  PR #477 did not touch `RecutClassTable`/`RecutTierClass`/`RecutMintCapTable`/
  `RecutProductCapArmed` (verified: these tables and the constants cited here read identically to
  the pre-#477 description in `01a-raw-code-facts-glory-catalog.md`) — it wires level-derived
  combat buffs, a gameplay-power change that may shift *which* deeds fire and how often, not the
  pricing tables themselves. Treat every mint-rate number below as dated to GV15, not invalidated.

## ✅ UN-BLOCKED — top-attribution LANDED (PR #494, commit `0fc7bba5`)

Both jobs that gated this freeze are DONE, superseding the "BLOCKING" framing this draft carried
earlier in the session:
- **JOB 1**: 0.000% residual (ground-truth instrumentation, not an estimate) — see
  `docs/designs/glory/TOP-ATTRIBUTION.md`. The FREEZE CONDITION 1 section above uses this
  attribution directly, re-priced under catalog v3.
- **JOB 2**: all 15 zero-mint deeds and 35 dead achievement slots classified STRUCTURAL (file:line)
  or BEHAVIOURAL — 10 STRUCTURAL deeds / 5 BEHAVIOURAL, 23 STRUCTURAL achievement slots / 12
  BEHAVIOURAL, every STRUCTURAL verdict traced to exactly 3 root causes, which are now the THREE
  ROOT-CAUSE RULINGS recorded at the top of this document. Sections 2b/3 below still show the
  **conditional** framing this draft used before the rulings landed — left in place as the evidence
  trail (their prior-evidence citations are still accurate), but the rulings at the top of the
  document, not the conditionals below, are what's frozen.

**FREEZE STATUS: FROZEN.** This document is no longer a draft. Individual sub-questions were RULED
progressively through the session (the representation option, the mid/top ladder, the placement-ramp
direction, the drain mechanism, the three root causes, the design law, and now the re-attribution
freeze criterion) — every ruling is recorded in place, not re-argued here. PR #491 un-drafts with
this commit; the S2 lead merges it as the S4 freeze, and S5 opens on that merge sha. This worker
does not merge.

## ▶ THREE FRESH FACTS FROM THE LEAD, CARRIED FORWARD (2026-09-09, after this brief was issued)

1. **RULED — the per-leg log2 "geometric mean" display premise was wrong as first stated, and is
   now fixed by definition.** Summing `log2(1+leg)` over the top-k legs and un-logging gives
   `log2` of the **product** of the legs (e.g. legs 5 and 3 store `log2(6)+log2(4)=log2(24)`,
   displaying 23 when the round total those two legs represent is 8), not `log2` of the round
   total. **The lead's ruling that resolves this**: the season DISPLAY is now defined as the
   **geometric-mean LEG**, `2^(EMA of (Σ top-k leg-logs ÷ k))` — the `÷k` normalization is what
   makes the exponentiated number mean something: "this policy's typical **episode** glory," never
   "round total." This draft uses that definition and that label everywhere below; the earlier
   "geometric mean of round glory" phrasing is retired. Section 8b and Section 9 use this exact,
   now-settled definition (not the earlier wrong one) when they evaluate the representation option.
2. **The armed economy structurally cannot produce a factor below 1 — ruled, not just observed.**
   `RecutClassTable`'s own values (every entry ≥1; verified — the minimum value anywhere in the
   current 32-row table is `1`) and `recutFold`'s own guard (`if factor <= 1: return product` — a
   sub-1 factor is silently *ignored*, treated identically to a no-op x1) already showed this
   empirically; the lead has now **ruled** it structurally: a negative leg cannot occur in the
   armed recut economy, full stop. The tier map's "below x1 = the drain" band is therefore **not a
   re-use of an existing mechanism** — it is new capability inside the armed product economy.
   Section 1 costs this explicitly. Note for completeness, not for us: a sign-aware clamp
   (signed-log transform) is being landed in metta anyway because `season_leg_transform` is a
   **per-league setting** — a different league running the dark/additive economy could arm it and
   would genuinely need the negative-leg handling. For Paintbot's armed economy specifically, that
   handling is **a formality with zero live exercise**, matching the earlier "confirmed-by-
   construction, not exercised by real data" finding on the signed-path fixture (PR #22168).
3. **RULED — the mid/top boundary ladder, and it is continuous, not a wall.** Deed-points (log2 of
   the leg): **low 1–2 · mid 2–8, centre 4, with 7–8 as mid's upper shoulder** (a strong mid-risk
   player lands here regularly — still "played the game, but skill varies" at its best, not yet
   intentional/predictable) **· top begins ≈9** (wins become intentional and predictable) **·
   jackpot ≈13–15 (≈1000× median) · ceiling ≈16 (cap-hit ~0.1–1%)**. Simulators may move a boundary
   ±1 point with the reason written down. **The bands are percentile checks, not walls** — the rig
   must show a **continuous population through 6–9**; a gap there in simulation is a **rig
   failure**, not a satisfied boundary. This supersedes the S3 signed target's own "top ≈7–10, mid
   ~20× wide" figures (§3's own "arithmetic tension" flag is resolved by this ladder, not silently
   — the mid band is now wider, 2–8 = 64× internally, not ~20×; **do not re-derive a different mid
   width from the old figures**, this ladder is the current one). Section 4 below applies this
   ladder and names, per the lead's explicit instruction, where this catalog's own proposed deed
   set risks a cliff rather than a smooth climb through 6–9.

## 1. Tier map as applied — candidate, costed, not decided

| band | factor range | who lives here (candidates) | representation today | cost to populate |
|---|---|---|---|---|
| **drain** | below x1 (x0.5–0.9) | failed hail-mary, an extended friendly-fire drain, a punished bad decision | **DOES NOT EXIST** in the armed product economy (fact 2 above) | NEW capability: either (a) teach `recutFold` to accept factor<1 without treating it as a no-op — breaks the "product only grows" invariant other code already relies on (the signed-fixture PR proved the armed economy cannot go negative; a sub-1 *multiplicative* factor would make it possible for the first time), or (b) generalize the existing **division** mechanic (`recutFfHalvings`) to more triggers instead of adding sub-1 multiplicative factors — cheaper, reuses a proven, tested pattern, keeps the "product seeded at 1, every factor ≥1" invariant intact for every other reader (census decoder, signed-fixture tests). **Recommend (b)** as the default direction; (a) is costed here only because the tier map named it. |
| **x1** | exactly 1 | pays nothing unless it **lights** something (set/mode progress) | Already the "commons" band — `RecutClassTable`'s own comment: a x1 class "takes NO live-state factor of any kind... that exemption is load-bearing." | Cheap to keep populated (it already is: `dHonorableKill`, `dSprayKill`, `dGrenadeKill`, `dPointBlankKill`, `dShieldSoak`, `dLevelUp` are x1 today) — but "unless it lights something" is a NEW rule; today x1 mints just log and do nothing, ever. Wiring an x1 mint to progress a set/mode is a Section 6 dependency, not a Section 1 cost. |
| **x1.1–1.5** | fractional, frequent | hits, holding ground, assists, zone-edge survival | **DOES NOT EXIST as a multiplicative factor** — `RecutClassTable` is `array[Deed, int]` (Nim `int`, not a rational/fixed-point type); a literal x1.2 cannot be stored in this table today. | This is exactly the representation question in Section 9 (proof of what it does and does not cost is Section 8). Two paths, both costed in Section 9: (i) log2 deed-points (new engine representation, WIRE blast radius), (ii) percent-scaled integer factor (reuse the *already-live* `AchievementFirstMultPct` pattern — glory.nim's FIRST-claim bonus is already an integer-percent multiplier, `result * pct div 100`, proven at ×300%). |
| **x2–3** | today's deeds | `dFirstBlood`, `dRevengeKill`, `dLongshotKill`, `dSplashMultiKill`, `dAceTag` region, etc. | Already populated — this is most of `RecutClassTable`'s classes 2 and 3. | No new cost — reprice within the existing integer table. |
| **x4–8+** | modes / jackpot / win | `dCapture`, `dWipe`, `dDenial`, the win multiplier (`RecutWinFactorBR`=4, solo win ×8), a future lit-jackpot deed | Already populated for the win/placement axis; the "modes completed" and "lit jackpot" members do not exist yet (Section 6). | Reprice existing classes cheap; the new lit-jackpot deed is the most expensive single item in this catalog (Section 6, gap #4/#8 from the pinball study). |

**Legibility law carried forward, unchanged**: fractional factors (x1.1–1.5, and the drain band if
built) never pop as a floating "+Ng"; they feed a meter whose whole rungs show (heat, done right, is
the existing model — the flame-chip HUD indicator already ships per the pinball study's `glory.nim`
citation). Pops stay reserved for x2 and up, matching `deedPopWord`'s existing exclusion of
`dShieldSoak`/`dAchievement` from the pop path (glory.nim, `popsScore`). This is now a restated LAW,
not just a carried-forward convention — see Section 9's header.

**RULED — the drain needs a visible cue, agreed, generalize the FF-halving division (not a sub-1
factor).** Every drain event needs a switch, a fire counter, **and a visible cue** — the "womp womp"
must be legible, never silent. **Description of the cue, not an implementation**: conceptually the
inverse of a deed pop — where a pop is a bright, upward "+Ng" flash in a deed's own pop-word
vocabulary (e.g. "TAG", "BOUNTY"), a drain cue would be a muted, downward-reading marker (a
distinct color/shape so it is never mistaken for a normal pop) tied to the SAME site-and-tick
convention `deedPopWord` already uses, naming what happened in the existing tagging vocabulary
(e.g. "OWN PAINT" already exists for `dTeamKill`; an extended drain trigger would need its own
one-word label in the same register). The natural second home for it is the endcard's per-player
itemization (Section 11) — a drain event is exactly the kind of "what actually happened to this
seat's score" line the itemization work already wants to show. **⚠️ Per the S2-gate ruling, the
journey lane owns the endcard bundle and this catalog does not author endcard changes — the cue is
described here and flagged for the lead's gate to route (Section 11), not designed or built in this
draft.**

## 2. Deed catalog restructured against the tier map

Mint rates are the S1 census (GV15, 305 episodes, 16 seats pooled). Current class is
`RecutClassTable`'s value, re-verified against `origin/main @ 62fa0146`. Disposition is a
**candidate**, not a decision; every zero-mint row is explicitly BLOCKED on top-attribution JOB 2
unless noted otherwise.

### 2a. Live deeds (16 of 31 mint at least once)

| deed | pop word | current class | mint rate | proposed tier | disposition (candidate) |
|---|---|---:|---|---|---|
| `dFirstBlood` | FIRST! | 2 | 1.00/ep, 100% | x2 (unchanged) | KEEP-PENDING — universal floor deed; S5 rig must check it against the mid-band shape, not blocked on evidence. |
| `dHonorableKill` | TAG | 1 (commons, exempt from all live-state factors) | 3.84/ep, 99.02% | candidate for x1.1–1.5 "hits" band | RE-PRICE (candidate) — moving the modal kill off pure x1 is the single biggest lever on "the middle is empty," but it breaks the commons' own "never shift" law by design; needs S5 sim before committing. Not blocked on JOB2 (this deed mints constantly; it is a design choice, not an evidence gap). |
| `dSprayKill` | SPRAYED | 1 | 0, 0% | if behavioural: RE-SCOPE into the heat meter as a *hit*, not a kill-only deed; if structural: CUT | **BLOCKED on JOB2** — addendum's own finding: "not proven structurally unreachable," only that nobody in this population landed one. |
| `dGrenadeKill` | BOMBED | 1 | 0, 0% | same as `dSprayKill` | **BLOCKED on JOB2**, same evidence gap. |
| `dPointBlankKill` | POINT-BLANK | 1 | 0.15/ep, 14.10% | candidate for x1.1–1.5 band | KEEP-PENDING, not blocked — real signal at a real (measured, re-cut) range threshold. |
| `dLongshotKill` | LONGSHOT | 3 | 1.22/ep, 69.18% | x2–3 (unchanged) | KEEP-PENDING — feeds `treeGun` tier V (Sharpshooter) too; any reprice must move both together. |
| `dSplashMultiKill` | MULTI! | 3 | 0, 0% | same conditional as `dSprayKill` | **BLOCKED on JOB2.** |
| `dRevengeKill` | PAYBACK | 2 | 0.046/ep, 4.59% | seed for the missing proactive drain-risk mechanic (pinball gap #6) | RE-SCOPE — the only existing reactive hail-mary shape; extend into a genuine chosen risk, not just reprice its class. Not blocked (a design direction, not an evidence gap). |
| `dRunDown` | CHASE | 2 | 0, 0% | same conditional as `dSprayKill` | **BLOCKED on JOB2.** |
| `dAceTag` | BOUNTY | 4 | 0.016/ep, 1.64% | x4–8 (unchanged) | KEEP-PENDING — already a working rare, skill-gated, top-band deed; good precedent, not a gap. |
| `dTeamKill` | OWN PAINT | not a class (FF **division**, not a factor) | 0.0066/ep, 0.66% | stays outside the product, in the drain band's *division* mechanism (see §1) | KEEP-PENDING — this IS today's only drain, and per fact 2 above it's the model to generalize, not replace. |
| `dClutchHeal` | (retired word) | 1, frozen ("×1 = weightless either way") | 0.46/ep, 37.70% | candidate for x1.1–1.5 band | RE-PRICE — a real support action currently scoring exactly zero; a strong, frequent "chosen" mid-band candidate. Not blocked, a pure design choice. |
| `dShieldSoak` | SHIELD SOAK | 1 | 4.11/ep, 81.97% | candidate for x1.1–1.5 band ("holding ground") | RE-PRICE — the cap infrastructure already exists (`RecutMintCapTable[dShieldSoak]=3`, currently inert arithmetic since the class is x1) and only needs the class to move off x1. One of the cleanest "deeds chosen, not placement" candidates (Section 4). |
| `dLevelUp` | RANK UP | 1, "unbounded but ×1 zero+tombstone" | 4.56/ep, 99.67% | KEEP at x1 (deliberate tombstone) OR RE-PRICE small, now that PR #477 wired level buffs into live combat | KEEP-PENDING — flag as a candidate needing S5 re-evaluation specifically because #477 changed the gameplay context (leveling now has a real power payoff) even though scoring hasn't moved. |
| `dClosingTime` | (closing time) | 2 (bumped to 3 on win via `recutShiftedClass`) | 5.85/ep, 99.67% | x2–3, but **RE-SCOPE candidate**: gate on a deliberate contest during the closing window, not passive survival into it | RE-SCOPE (candidate) — 99.67% fire rate makes this behave like a second floor deed, in tension with the owner's "deed value = difficulty" law; not blocked, a design tension to resolve in S5. |
| `dLastLight` | (last light) | 4 | 0.24/ep, 22.95% | x4–8 (unchanged) | KEEP-PENDING. |
| `dJointAct` | joint act | 2 | 0.16/ep, 7.21% | stays as the pact-gated co-engagement axis; needs the decay mechanism (Section 6) | KEEP + BUILD (decay), not a reprice. |
| `dFinal8` | final 8 | 2 | 7.99/ep, 100% | **must shrink** — the owner's law: placement becomes "a small deliberate reward, not the engine of the middle" | RE-PRICE DOWN — direct law conflict today (100% universal fire rate at class 2, cumulative with Final4/Final2 to a ×24 winner stack); constants not decided here (simulators pick constants), but the direction is not in question. |
| `dFinal4` | final 4 | 3 | 3.99/ep, 100% | same | RE-PRICE DOWN, same reasoning. |
| `dFinal2` | final 2 | 4 | 1.99/ep, 100% | same | RE-PRICE DOWN, same reasoning. |

### 2b. Zero-mint deeds — all 15, every disposition conditional and named

Per the manager ledger's own prior code-level checks (not yet JOB2's formal scripted-test
sign-off), these split into two evidence tiers. **Neither tier is a final disposition** — JOB2's
scripted reachability test + file:line citation is still the authoritative confirmation this
program's own law requires ("probably X" is not an answer for either direction).

**(i) Strong prior structural evidence already in hand (11 of 15)** — formal JOB2 sign-off still
pending, but the code facts already point one way:

| deed | prior evidence (re-verified this draft) | conditional disposition |
|---|---|---|
| `dFlagSteal`, `dCapture`, `dCarrierKill`, `dDenial`, `dEscortKill` | CTF-objective deeds; called only from flag/carrier code paths that never fire on a flagless BR map | CUT-for-BR / RE-SCOPE if a CTF/flag mode returns |
| `dAssist`, `dRescue` | grouped with the CTF-objective set by the S1 census's own finding ("flag/carrier/denial/escort/assist/rescue... structurally dead on flagless BR maps"); **not independently re-derived from source this draft** — carried as-is, flagged for JOB2 to confirm at the file:line level since these two names are ambiguous (a generic combat "assist" vs a CTF-objective "assist") | CUT-for-BR / RE-SCOPE, same bucket, **lower confidence than the flag/carrier group** |
| `dWipe` | **Re-verified directly**: `awardWipe` (sim.nim ~6558) opens with `if sim.config.brMode: return` — unconditionally disabled in BR, CTF untouched | CUT-for-16-solo-BR / already correctly scoped for CTF |
| `dDuoDown` | Needs a 2-seat team to be "re-emptied after a revive" (per `RecutMintCapTable`'s own comment); structurally impossible with 1 seat/team | CUT-for-16-solo / RE-SCOPE-if-duos-return |
| `dTagBack` | A revive needs "an upright same-team seat" — impossible with 1 seat/team (matches census Q5's own finding) | CUT-for-16-solo / RE-SCOPE-if-duos-return |
| `dVictory` | **Re-verified directly**: gated `not sim.config.winAsMultiplier` (sim.nim ~5947) — the deed is retired-by-construction the moment the win-as-multiplier flag arms, which it does in every measured GV15 episode | CUT (already fully retired by its own design; nothing to re-price — the win multiplier replaced it) |

**(ii) Genuinely open, no structural evidence either way (4 of 15)** — the addendum's own explicit
language: "not proven structurally unreachable... that distinction matters for S4":

| deed | conditional disposition |
|---|---|
| `dSprayKill` | if structural (e.g. the weapon/loadout path never reaches a kill credit): CUT. If behavioural (nobody chooses the weapon or lands the kill): RE-SCOPE into the heat meter as a hit-credit, not a kill-only deed — this is the more useful direction if it's confirmed live but rare, since it feeds Section 5's "tags-as-hits" redesign directly. |
| `dGrenadeKill` | same conditional. Note a related open finding from the raw code-facts pass: **no self-grenade-harm exclusion was found in the damage loop** (sim.nim, `absorbDamage` applies unconditionally to all in-range players) — unverified by test, but if true it may partially explain low grenade-kill rates (players avoid grenades near themselves). Flagging for JOB2, not asserting. |
| `dSplashMultiKill` | same conditional as the two above. |
| `dRunDown` | same conditional. |

**Disposition tally for the 15 zero-mint deeds**: 0 finalized (by design — this is a draft). Of the
15, **4 are genuinely BLOCKED** with no directional evidence yet; **11 carry directional evidence**
from prior steps' own code checks (re-verified 3 of them — `dWipe`, `dVictory`, and the `RecutMintCapTable`
comment for `dDuoDown`/`dTagBack` — directly against source this draft) but **all 15 await JOB2's
formal scripted-test sign-off** before any disposition freezes, per this program's own law.

## 3. Achievement trees — same treatment (40 slots, 35 dead)

Same conditional-disposition discipline as Section 2b; re-derived from `01b-achievements-addendum`
plus a source re-check of `Tree`/`AchievementTiers`/`RecutTierClass` (glory.nim:1782-1930, 2555).

| slot(s) | mint rate | evidence | conditional disposition |
|---|---|---|---|
| `treeSquad.IV` (Clean Sheet) | **100.00% of seat-episodes, universal, x2** | Mean **60.3%** / median **50.0%** of a whole-population score's log2-magnitude (top-decile: mean 18.0%/median 9.8%) — the single biggest floor-inflator in the whole catalog | **RE-SCOPE (highest-priority item in this section)** — a 100%-universal freebie is close to the literal opposite of the owner's LOW-band definition ("didn't really accomplish anything"); gate it on an actual chosen act (surviving *and* contesting, not merely avoiding a team-kill) or fold it into the x1.1–1.5 meter band instead of a hard x2 pop. Not blocked on JOB2 — this is squarely a design decision against measured data, not an evidence gap. |
| `treeGun.{I,II}` | 46.76% / 5.16%, both x1 no-ops | 32.6% of ALL achievement mint events pay zero multiplier, of which these two tiers are the bulk | RE-SCOPE — matches the tier map's own "x1 pays nothing unless it lights something" rule exactly: wire these as literal progress toward `treeGun.{III,IV,V}` becoming a lit mode (Section 6), rather than leaving them decorative. Not blocked. |
| `treeGun.III` (Ace) | 0.10%, x2 | mirrors `dAceTag`'s own rarity | KEEP-PENDING, coordinate any reprice with `dAceTag`. |
| `treeGun.IV` (max level) | **0%, dead** | one of the 35 dead slots; not individually re-derived from source this draft (episode-length vs. XP-curve reachability not checked) | **BLOCKED on JOB2** — genuinely unclear whether this is a structural cap (episode too short to reach max level) or behavioural (players never push for it); no directional evidence gathered yet, flagged rather than guessed. |
| `treeGun.V` (Sharpshooter) | **69.18%(!), x4 + x3 FIRST** | the one achievement the addendum calls "true to the lead's framing" — real, skill-gated, meaningfully rare at the FIRST-claim layer (4.32% of all seat-episodes win the FIRST race) | KEEP-PENDING — this is the **model to generalize**, not a gap. Best existing precedent for "set completed → lit multiplier." |
| `treeSpray` (5 tiers), `treeGrenade` (5 tiers) | 0%, all 10 | addendum: "not structurally blocked in BR — dead because nobody landed a spray/grenade kill," same underlying behavioural fact as the matching deeds | **BLOCKED on JOB2**, same conditional as `dSprayKill`/`dGrenadeKill` above (same root cause, examined once). |
| `treeShield` (5 tiers) | 0%, all 5 | 4 of 5 live-tier gates need assists/escortKills/rescues/`squadVolleyDone` — all require a teammate, structurally impossible in 16-solo | CUT-for-16-solo / RE-SCOPE-if-duos-return, same bucket as `dDuoDown`/`dTagBack`. **Not individually re-verified at the file:line level this draft** — carried from the addendum, flagged for JOB2. |
| `treeMedKit` (5 tiers) | 0%, all 5 | addendum: "engine-omitted on this port" (a GLORY-PORT-TODO in `sim.nim`, per the addendum's own citation — **not independently re-verified this draft**) | CUT (nothing to reprice if the engine doesn't support the underlying action) / RE-SCOPE only if a separate program builds the missing engine support. |
| `treeCarrier` (5 tiers), `treeDefender.{I,III,IV}` | 0%, 8 slots | flag-carry/peel/denial gates, same CTF-objective structural bucket as Section 2b's flag deeds | CUT-for-BR / RE-SCOPE-if-CTF-returns. |
| `treeSquad.{I,II,III,V}` | 0%, 4 slots | not individually traced this draft; presumed squad-cooperation-gated (multiple teammates), same 16-solo bucket as `treeShield` | **BLOCKED on JOB2** — presumed, not confirmed; do not treat as settled. |

**Disposition tally for the 35 dead achievement slots**: 1 clear RE-SCOPE-not-blocked
(`treeGun.{I,II}`, design choice), ~13 slots (`treeCarrier`, `treeDefender.{I,III,IV}`,
`treeMedKit`) carry directional evidence from the addendum but are not independently re-verified at
the file:line level this draft, ~10 slots (`treeShield`, `treeSquad.{I,II,III,V}`) are presumed by
analogy and explicitly flagged as unconfirmed, and 11 slots (`treeSpray`×5, `treeGrenade`×5,
`treeGun.IV`) are genuinely **BLOCKED on JOB2** with the same evidence gap as their deed-side
counterparts.

## 4. How the MID BAND gets its width from deeds CHOSEN

The census's own headline: median seat-episode glory is **4**, and per Section 3, roughly half of a
median score's bit-length is one universal freebie (`treeSquad.IV`) nobody chose. The owner's law —
"played the game, but skill varies," spread from deeds **chosen**, not placement — points at a
concrete, small set of mechanics that are ALREADY frequent enough to carry a wide mid band, if
re-priced off their current x1/inert state:

1. **`dHonorableKill` (99.02% of episodes, 3.84/ep)** — the modal kill. Moving it off pure x1
   commons into the x1.1–1.5 band (representation cost in Sections 8–9) is the single highest-leverage
   move: it is the deed every seat performs, at a rate that varies genuinely by skill (some seats
   get 0, some get 10+), so a small per-kill factor compounds into real spread without any new
   mechanic.
2. **`dShieldSoak` (81.97% of episodes, 4.11/ep)** — a defensive-playstyle choice (soak damage vs.
   retreat), currently x1 and already has cap infrastructure (`RecutMintCapTable[dShieldSoak]=3`)
   sitting inert. Re-pricing this single row into the meter band gives the mid band a genuinely
   different axis from kills — a seat that plays defensively should score visibly differently from
   one that doesn't, which today it cannot.
3. **`dClutchHeal` (37.70% of episodes, 0.46/ep)** — currently frozen at x1 "retired," i.e., a real
   support action that scores exactly zero. Un-freezing it is a pure floor-to-mid-band gift with no
   new mechanic required.
4. **`dPointBlankKill` (14.10%) vs `dLongshotKill` (69.18%)** — these already encode a genuine
   **choice between playstyles** (aggressive close-range vs. patient long-range), and already carry
   different classes (1 vs 3). This pairing is evidence the catalog already has *some*
   deeds-chosen structure; the gap is that too few deeds sit in this "choice" shape and the ones
   that do are drowned out by the universal freebie and the placement ladder.
5. **The proactive drain-risk mechanic (pinball gap #6, seeded by `dRevengeKill`, Section 2a)** —
   this is the piece that is entirely missing today: a healthy player has no way to *choose* to
   push into a bigger, riskier payoff. Building this (Section 1's drain band, generalized from FF
   halvings rather than a new sub-1 factor) is what would let the mid band's *upper* half be
   reached "intentionally," per the owner's TOP-band definition, rather than only its lower half
   being reached by accumulating small choices.

**RULED (lead, condition on approving commons-into-meter repricing): each repriced common keeps
its OWN fire counter.** `dHonorableKill`, `dShieldSoak`, and `dClutchHeal` (items 1–3 above) get
independently observable per-deed mint-rate counters — the existing census tooling (Q1's per-deed
mint table) already reports each of these separately today and needs no new mechanism, only
continuing to report them once they move into the meter band rather than collapsing them into one
opaque "meter ticks" number. **A meter whose inputs are not individually observable is a lever we
cannot audit** — this is a hard requirement on Section 5's heat-meter build too (its own per-source,
per-rung reporting, already specified there) and on any future addition to this tier: every deed
that feeds the meter is independently countable, always.

### Applying the ruled ladder (low 1–2 · mid 2–8, centre 4, shoulder 7–8 · top ≈9+): does this
### catalog's proposed deed set pay smoothly through 6–9, or does it cliff?

The lead's ruling is explicit that this is a design constraint, not a footnote: whatever carries
the mid band's width must keep paying smoothly through 7–8 (the strong-mid-risk shoulder) into
≈9 (intentional/predictable top), not stop at one value and resume at another. Named honestly:

- **The items in this section (1–4 above) are well-shaped for this.** `dHonorableKill`,
  `dShieldSoak`, `dClutchHeal`, and the `dPointBlankKill`/`dLongshotKill` choice are all **frequent,
  small, additive-in-log-space increments** — a seat's total climbs by many independent small
  folds, so however many a seat happens to mint, the running total interpolates continuously across
  the whole 2–8 range with no inherent threshold. This is the right shape for a meter-fed band:
  there is no single gate a seat either clears or doesn't:  a mediocre seat mints a few, a strong
  mid-risk seat mints many, and the population should fill in between by construction, not by
  design accident.
- **The likely cliff is the placement ladder and the win multiplier (`dFinal8/4/2`, `RecutWinFactorBR`),
  named directly, not hedged.** Today these are large, near-100%-fire-rate, threshold-triggered
  *lump* factors (classes 2/3/4, cumulative ×24 for a winner, plus the win multiplier itself, ×4
  duo/×8 solo) — the census's own finding that this recipe explains 42.2%/44.6% of a top-decile
  score's magnitude is exactly this lump. If Section 2a's "RE-PRICE DOWN" for `dFinal8/4/2` is
  executed as a single smaller lump rather than a re-shaped one, the risk is a **two-hump
  population**: seats that don't survive to the final few sit in the lower/mid range from the
  meter-fed deeds alone, and seats that DO survive get a placement+win lump added essentially all
  at once, jumping from wherever the meter left them straight past the 7–8 shoulder into
  double-digit points with nothing filling 6–9 in between. **This is the single most likely source
  of exactly the cliff the lead's ruling warns against, and it sits squarely in a lever this
  catalog already proposes to reprice** — flagging it now rather than after S5 finds it in
  simulation.
- **RULED (lead, agreed): reprice `dFinal8/4/2` DOWN into a small ramp, not a single lump.** The
  proposed shape, not decided to constants: instead of one threshold-triggered lump at
  `dFinal8`/`dFinal4`/`dFinal2`, spread the same total value across a few smaller,
  survival-time-correlated increments (e.g., a small per-milestone bump PLUS a continuous
  survival-duration credit that already climbs before the milestone is crossed) so a seat's points
  ramp up *before* it reaches final-8/4/2 rather than jumping there discontinuously. **The win
  multiplier stays the win** — it is not being repriced away — but per the ruling it must **not be
  the only route from 6 to 9**: the ramp above has to carry a non-winning survivor's points up
  through the shoulder on its own. This is a mechanism proposal, not a constant — **the rig's
  continuity check through 6–9 is the acceptance test**, per the ruling; S5 is where "does this
  actually fill 6–9 continuously" gets checked against real policies, not asserted here.

**What this section does NOT decide**: the exact constants that make the mid band's meter-fed
deeds and the reshaped placement/win lump jointly produce a continuous 2–8→9+ population — that
reconciliation is explicitly S5's rig job (paired seeds, real policies), not this catalog's.

## 5. Heat re-done as the meter

Today (GV15, census): heat rung occupancy by seat-tick share is x1 96.81% / x2 2.33% / x4 0.85% /
x8 0.01%. Mechanism (re-verified against `glory.nim`/`sim.nim`): a per-team ember counter (cap 11,
`sim.heatEmbers`), +1 per heat-paying tag, −2 embers/270 ticks, read through `HeatLadder=[1,2,4,8]`
**sampled before** the triggering deed's own increment.

**Proposed changes** (all candidates, not decided):

1. **Tags-as-hits**: broaden the heat-credit source from "heat-paying tags" (kills) to landed hits
   (a spray/grenade impact is a small credit; a tag is a bigger one — the pinball bumper vs.
   drop-target distinction). This directly serves Section 2b's conditional RE-SCOPE for
   `dSprayKill`/`dGrenadeKill`/`dSplashMultiKill`/`dRunDown` if JOB2 finds them behavioural: instead
   of trying to make a rare spray/grenade *kill* fire more, credit the far more common spray/grenade
   *hit* toward the same meter that already has a live HUD indicator.
2. **Rung re-spacing**: a hit stream is much denser than a kill stream, so `[1,2,4,8]`/cap-11/decay
   270-ticks are almost certainly wrong constants for the new input volume — **this is explicitly an
   S5 rig job, not decided here.**
3. **Per-victim rate cap** (new, needed because of item 1): without one, a spray weapon farming one
   stationary victim would inflate heat far faster than a kill-gated economy ever could. Reuse
   `RecutMintCapTable`'s exact switch+counter idiom: cap heat-credit from the same (attacker,
   victim) pair within a rolling window (e.g., mirroring `RevengeTicks`=240's existing precedent for
   a time-boxed pair-keyed rule), diminishing to zero credit after the cap — same "the deed still
   pops, still counts, but the SCORE effect is capped" law `RecutMintCapTable`'s own comment states.

**Switch**: a new config flag (e.g. `heatCreditsOnHit`, default OFF) gating item 1; heat's existing
kill-only path stays live and byte-identical when off. **Fire counter**: extend the already-measured
rung-occupancy report (census Q1's own table) to log credit source (kill vs hit) once armed, so the
composition of what's filling the meter is directly observable, not inferred. **Rollback**: flag
off, zero behavior change (this is the same "runs for everyone, harmless when off" shape the S0
season-transform PR already used for its own fire counter).

## 6. Modes lit by sets; jackpot lit before it pays; pact as multiball

**Reuse, do not reinvent** — the sourced pinball study and the manager ledger both converge on this:

- `pactActive` **already gates** the STACK co-engagement multiplier (`recutContextK`, sim.nim
  ~2748-2761: `if attackerTeam == killerTeam or sim.pactActive(attackerTeam, killerTeam)`) and
  `dJointAct` (`recutJointActOnDamage`, sim.nim ~2764-2850: every contributing seat mints only "if
  it shares an ACTIVE formal pact... with at least one OTHER contributing team," re-verified at the
  per-seat check `if t != selfTeam and sim.pactActive(selfTeam, t)`). **The gate exists and is
  live.** What is missing, confirmed by reading `pact.nim`'s own `holdFire` union, is an
  **engine-enforced expiry** — a policy's own `holdFire.arms` choice (default `aliveTeams: 2`, i.e.
  "until the final two") can make a pact behave as permanent for the whole episode, with nothing in
  `pactActive` forcing a shorter life. This is pinball's inverted-rarity problem exactly: real
  jackpots are hard to light and then briefly live; ours are comparatively easy to light and then
  can persist open-ended.
- `RecutFinalThresholds`/`recutFinalFired` (sim.nim) is a one-shot-per-threshold latch — the same
  shape as Medieval Madness's "Battle for the Kingdom resets all six requirements after firing."
  Reusable for any new mode-completion or jackpot-lit state.
- `RecutMintCapTable` (glory.nim:2616-2725) is the switch+fire-counter idiom this whole program
  keeps citing as the template for any new lever.

**Proposed builds** (candidates, all cost real engineering, none decided):

1. **Pact decay (the lead's own S2-gate ruling: "a FIRST-CLASS S4 candidate, not a footnote").**
   Add an engine-side maximum pact lifetime (a config constant, e.g. `pactMaxLifetimeTicks`) applied
   *in addition to* whatever `holdFire` the declaring policy chose — `pactActive` returns false once
   either the policy's own hold-fire condition OR the engine max is reached, whichever comes first.
   **Switch**: config flag, default OFF (today's unconditional-until-policy-ends behavior
   preserved). **Fire counter**: count of pacts that expire via the new engine cap vs. via the
   policy's own `holdFire` vs. still active at episode end — this is also the exact signal the
   journey lane's "are pacts solid or not" legibility question needs. **Rollback**: flag off, no
   wire change (this lives entirely server-side in `pactActive`'s evaluation, not the wire
   representation of a pact).
2. **Sets that light a mode, with a real fail state.** Take the achievement-tree "bank of targets"
   shape (already structurally close to a pinball drop-target bank) and add the two properties every
   reference table has and we don't: a stateful "mode active" window (a timer) so a set can be
   entered and *failed*, not just instantly minted; and player-visible/-choosable pursuit (today
   nothing in `plays.py` references achievement trees or the placement ladder at all — a policy
   cannot bias toward one). **Cost**: medium-expensive — new sim state for timers and explicit
   start/fail transitions, plus a `play_view` perception addition (**NOT VERIFIED whether the
   perception surface can expose this today** — carried forward from the pinball study, not
   re-checked this draft). **Switch**: a config flag choosing stateful-mode vs. instant-mint per
   tree, allowing a gradual migration. **Fire counter**: mode-entered / mode-completed /
   mode-failed-timeout, per tree. **Rollback**: flag off reverts to today's instant-mint behavior.
3. **A jackpot lit before it pays** (pinball gap #4/#8 combined). A new deed/factor reachable only
   when a "primed" state is true — e.g. pact active AND heat at a high rung AND a set completed —
   using `recutFinalFired`'s one-shot latch pattern and `RecutMintCapTable`'s switch+counter idiom.
   **This is the single most expensive, most architecturally novel item in this catalog** — a
   genuinely new deed/state machine, not a reuse. **Sequence AFTER S5 sets the target shape** (the
   pinball study's own explicit recommendation); not decided or costed to constants here.

## 7. Designed caps — a live counter for `RecutProductCapArmed`

`RecutProductCapArmed = 2^24` (glory.nim, re-verified at its current location ~line 2589 — the
ledger's earlier citation of 2565 was against an older commit; content, not just line number,
re-checked and matches) already carries a **measured, cited ≤1.5% cap-hit-share target**
(`tests/test_glory_recut.nim:911` per the ledger — not independently re-run this draft) and its own
comment documents it binding on exactly 1 of 12,048 live solo seat-scores historically. **It has NO
live counter today** — `grep -r "cap_hit\|cap-hit"` returns zero matches repo-wide (per the ledger's
own audit; re-confirmable trivially, not re-run this draft to avoid duplicating that grep).

**Proposal**: increment a counter (e.g. `capHitCount`) at the exact site where `recutFold` returns
`cap` because `product >= cap div int64(factor)` (glory.nim, `recutFold`) — the only place the cap
can bind. Log it every episode (armed or not, `capHitCount=0` when off), matching the
already-shipped metta season-transform PR's own "log a line on every call" fire-counter idiom, which
that PR's own author noted specifically contrasts with `RecutProductCapArmed`'s missing counter.
**Switch**: none needed — pure observation, always on, matches "runs for everyone, harmless" (no
scoring/wire change). **Cost**: cheap (a counter + a log line, no mechanism change). **Wire**: no,
unless the count should reach the client (a separate, not-assumed decision). **Rollback**: trivial —
delete the counter, no behavior change since it never altered scoring.

## 8. Is deed-points double-counting? The owner's question, answered directly

The owner's own question, quoted exactly: **"deed points instead of multiplicative was the
original design and strays from the multiplicative goal — is it adding the deed value many
times?"** Answered directly, in his terms: **no, it is not adding the deed value many times.**
Below is the proof, then — more importantly — the honest limits of it.

### 8a. The proof: a deed counts exactly once, in either domain

The identity that makes this work is `log2(a·b) = log2(a) + log2(b)` — multiplication in one
domain is addition in the other, term for term, with no term appearing twice.

**Worked example, using two real deeds from this catalog.** Suppose one seat's leg mints
`dFirstBlood` (class 2) and `dLongshotKill` (class 3) in the same episode:
- **Multiplicative (today's actual mechanism)**: `RecutSeed(1) × 2 × 3 = 6`. The class-2 factor is
  applied once; the class-3 factor is applied once; the product is their single combination.
- **Deed-points (log2 domain)**: `log2(2) + log2(3) = 1.000 + 1.585 = 2.585` points. Exponentiating
  back: `2^2.585 = 6.000` — exactly the same number, the same episode, the same two deeds, each
  contributing exactly one term.

Generalize to a whole leg with N mints of factors `f1, f2, ..., fN`: the product is
`f1 × f2 × ... × fN`; the points total is `log2(f1) + log2(f2) + ... + log2(fN) = log2(product)`.
Every deed appears **exactly once** as one multiplicand on one side and **exactly once** as one
addend on the other — this is not a coincidence of the example, it is the definition of a
logarithm turning products into sums. **A deed is never priced twice under this representation; it
is the same single factor, relabeled into a different domain that happens to add instead of
multiply.** The product is still what a single episode shows — nothing about the multiplicative
*feel* of one match changes.

### 8b. What actually changes: the season-level aggregate, not the episode

The entire reason to consider deed-points at all is a **cross-episode** property, illustrated with
a second worked example. Suppose a policy plays two episodes: episode A totals a leg of 1024
(10 points), episode B totals a leg of 4 (2 points).
- **Arithmetic mean of raw totals**: `(1024 + 4) / 2 = 514` — a single freak episode (A) swamps the
  season number; a season of one jackpot and otherwise nothing looks almost as good as a season of
  two solid 514s.
- **Geometric-mean-of-legs, per the lead's now-ruled definition** (`2^(EMA of Σtop-k leg-logs ÷ k)`,
  Section 0's fact 1 above): average points `(10 + 2) / 2 = 6`, displayed as `2^6 = 64` —
  "typical episode glory ≈ 64," a number that reflects order-of-magnitude consistency, not raw sum.
  A policy scoring 32-and-32 every episode (5+5 points, average 5, displayed 32) reads as MORE
  consistently good than one freak-1024-and-near-zero season, exactly the "one huge game should not
  skyrocket your standing" property the owner asked for at the top of this program.

**This is a season-level property, entirely orthogonal to Section 8a's within-episode proof.**
Nothing about how deeds fold *inside* one episode needs to change for the season to stop being
jackpot-dominated — the season fix is about how multiple episodes' totals average together, not
about how many times one deed is counted within one of them.

### 8c. Where the clean correspondence breaks — named plainly, not defended away

The proof in 8a is exact for the case it covers (whole, ≥1, single-episode-internal factors). It
does **not** extend cleanly to everything this catalog proposes:

1. **Fractional factors (the x1.1–1.5 tier, Section 1).** `log2(1.2) ≈ 0.263` — a real, well-defined
   number, and adding it once is still "one deed, one term," so 8a's proof itself still holds for
   *this* case. What breaks is the **engineering representation**, not the math: today's actual
   product economy cannot store 1.2 as an `int` factor at all (`RecutClassTable` is
   `array[Deed, int]`), and a **percent-scaled integer** approach (Option B below) requires a
   `div`-truncating fold at every single small factor, which **compounds multiplicatively** across
   a long chain (many small heat/hit/hold increments per episode) — a real, measurable rounding
   bias that a fixed-point log2 accumulator would not have, because there each small factor
   contributes a fixed, small, **additive** rounding error instead of a truncation applied
   *inside* a running multiplication. This is a genuine numerical advantage for the log2
   representation on fractional factors specifically — named here, not hidden, because it cuts
   against Section 9's eventual recommendation and deserves to be weighed honestly.
2. **Sub-1 "drain" factors (Section 1, fact 2 above).** `log2(0.8) ≈ -0.32` — trivial to *add* in
   points-space (just a negative delta; log2 naturally handles values below 1 by going negative).
   But per the lead's ruling, the armed economy's product **cannot** go below its seed today, and
   `recutFold`'s own guard (`if factor <= 1: return product`) treats any factor ≤1 as inert.
   **The abstract equivalence (log2(0.8·x) = log2(0.8) + log2(x)) is true regardless of
   representation, but the ENGINEERING capability to apply it is not equally available in both
   domains today**: a points-space accumulator can subtract a negative delta with no new invariant
   broken, while the product-space fold requires new code that changes a load-bearing existing
   invariant (every fold ≥1) other readers depend on (the signed-fixture PR's own structural proof
   rests on it). This is the one place in this catalog where log2 is the *structurally* cheaper
   engineering path for a feature the tier map itself proposes — flagged for Section 9's costing,
   not resolved there in log2's favor by itself, since Section 1 already recommends generalizing the
   FF-halving division instead of building either kind of sub-1 factor.
3. **Precision and accumulation error over a season.** In product-space, a long chain of large
   integer multiplications risks `int64` overflow — which is exactly why `RecutProductCapArmed` and
   `recutFold`'s own cap-check exist. In points-space, the equivalent range is tiny (`log2(2^24) =
   24`), so overflow risk all but disappears — a real, underappreciated robustness benefit of
   points-space. The cost moves instead to **rounding bias**: a fixed-point log2 table (e.g.
   Q16.16) must round each class factor's log2 value to the nearest representable point, and if
   that rounding is not specified as round-to-nearest (vs. always-truncating), the bias compounds
   **additively** across a season of many mints into a systematic under- or over-score — a small
   but real, specifiable design requirement, not a blocker, and not decided here.
4. **The owner's own prior, directly-on-point ruling against a second table with its own
   rounding.** `RecutMintCapTable`'s own comment (glory.nim) already litigated a smaller version of
   this exact question — it explicitly REJECTED a "diminishing rungs" alternative (×2→×1.5→×1.2…)
   for three stated reasons: **the economy is integer-only by owner constraint**; a second table
   with its own rounding doubles the frozen-table conformance-review surface; and it is not
   auditable from the wire without the full per-duo mint order. A fixed-point log2 representation
   is, structurally, exactly this kind of "second table with its own rounding," at a much larger
   scope than the mint-cap decision that rejected it. **This is the strongest single argument
   against Option A below, and it is the owner's own precedent, not a new objection invented for
   this draft.**
5. **The signed-log variant has zero live test coverage for our economy.** The `sign(x)·log2(1+|x|)`
   form exists specifically to handle negative legs; per fact 2 above, the armed economy never
   produces one, so this branch of the transform is "confirmed-by-construction, not exercised by
   real data" — a testing-confidence gap specific to whichever representation choice needs the
   signed form, not a flaw in the math itself.

**Answer to the owner's question, restated plainly**: no, deed-points does not add a deed's value
"many times" — one deed, one term, in either domain, proven in 8a. What is genuinely different
about the two representations is (a) a season-level aggregation change (8b, already decided and
ruled, independent of the sim's internal representation) and (b) a real, specific set of
engineering tradeoffs on fractional factors, sub-1 factors, rounding, and the owner's own prior
integer-only ruling (8c) — those tradeoffs, not a math error, are what Section 9 costs and weighs.

## 9. Representation option — RULED: percent-scaled integer, log2 CONSIDERED and REJECTED

**Lead's ruling on this section (2026-09-09)**: the percent-scaled-integer pattern
(`AchievementFirstMultPct`-style) is **APPROVED** for the fractional tier. No wire change, no
WIRE-OK request. Two conditions were attached, both discharged below with a real test, not an
assertion: (a) prove the integer headroom with actual test code; (b) restate the legibility law as
a hard law. The log2 deed-points option is **retained in this document as "considered, rejected,"**
not deleted — a rejected option with its reasons on record is worth more than a silently dropped
one.

**LAW (restated per the lead's condition (b), binding on every lever in this catalog that touches
the fractional tier or the drain band)**: fractional factors feed the **meter**; they are **never**
individually popped as a floating "+Ng." Pops remain reserved for x2 and up, matching
`deedPopWord`'s existing exclusion of `dShieldSoak`/`dAchievement` from the pop path.

**Confirmed structural facts** (re-verified this draft, not carried on trust):
- `gloryProduct*: array[Team, int64]` (sim_types.nim:4419) — the sim's canonical state is an int64
  product today, exactly as the discussion doc assumed.
- `RecutClassTable`/`RecutTierClass` are `array[Deed/AchievementTiers, int]` — plain integers, no
  fractional factor can be stored today.
- `recutFold`'s guard `if factor <= 1: return product` means even the *storage* question aside, the
  current fold function cannot apply a fractional factor at all without a code change regardless of
  which representation is chosen.
- `AchievementFirstMultPct = 300` (glory.nim:2469 `result * pct div 100`) is an **already-live,
  already-tested** precedent for representing a non-integer-looking multiplier (×3.00) as an
  integer-percent scale, inside the current int64 product, with zero wire change.

### Option A — CONSIDERED, REJECTED — log2 deed-points (sim accumulates fixed-point log2, displays `2^points`)

**Benefits claimed by the discussion doc**: fractional factors become trivial (see 8c(1) above — real,
but the benefit is narrower than "trivial," it is specifically about avoiding compounding
truncation bias); the geometric-mean season is "natural end to end." **The second claim is weaker
than stated, and now that the display semantics are RULED (Section 0 fact 1: `2^(EMA of Σtop-k
leg-logs ÷ k)`, computed in metta), it can be checked directly rather than argued abstractly** —
that computation lives entirely in **metta**, external to the sim (`round_lifecycle.py`, shipped
behind a switch in metta PR #22166), and is **independent of how the sim represents `gloryProduct`
internally**: metta takes whatever integer `gloryProduct`/`recutScore` the sim reports and computes
`log2` of it itself. The now-settled definition does not require the sim to *already be* in log2
space — metta's `÷k`-normalized geometric-mean-of-legs works identically whether the sim hands it
an integer product or a points value. So the "natural end to end" benefit is real only for the
sim's own internal fold arithmetic (addition instead of multiply+cap, and 8c(2)/(3)'s overflow and
sub-1 advantages), not for the season layer, which gains nothing further from a sim-side
representation change now that the display formula is fixed.

**Costs**:
- **WIRE blast radius, confirmed real**: every consumer of `gloryProduct`/`recutScore` as an integer
  (the census's own `census_decode.py`, the platform's `participant_scores` reconciliation path this
  program's own S1 step depends on, any replay/fixture decoder) would need to change or dual-read.
- **Fixture re-record scope**: `tests/test_glory_recut.nim`, `test_glory.nim`,
  `test_glory_conclusion.nim`, `test_glory_fx_wire.nim`, `test_glory_league_score.nim`,
  `test_glory_lockstep.nim`, and `test_match_glory.mjs` all exist and plausibly pin exact
  integer glory values — **not individually audited this draft for how many literal constants each
  pins**; a real, non-trivial re-record cost, sized honestly as "at least these seven files," not a
  guessed number.
- **Determinism risk**: floating-point log2 is not bit-reproducible across platforms; a correct
  build needs a fixed-point (e.g. Q16.16) log2 table with each class factor's log2 value
  precomputed as an exact integer constant, so folding stays integer addition. Buildable, but new
  engine code, new tests, and (per `RecutMintCapTable`'s own precedent for smaller changes) a new
  frozen-table conformance review.
- **Rollback**: needs a switch that keeps BOTH representations live during a trial (wire carries
  whichever the switch selects) — doable, but doubles the tested surface until retired.

Rejection reasons, unchanged by the ruling, kept on record: (1) fractional factors are already
representable today at zero blast radius via a proven, live pattern — the premise that log2 is
uniquely required for "fractional factors trivial" does not hold, though 8c(1) names a real (not
fabricated) numerical edge log2 has there; (2) the season's geometric-mean benefit is already
achieved externally by metta from whatever integer the sim reports, now that the display formula is
ruled rather than open — riding on the sim's internal representation to serve the season layer is
unnecessary, not just premature; (3) the determinism and fixture-re-record costs are large; (4)
8c(4) is the sharpest reason of all: the owner's own `RecutMintCapTable` ruling already rejected a
smaller-scoped version of exactly this "second table, its own rounding" tradeoff, on the stated
ground that the economy is integer-only by owner constraint. **The one item that would reopen this
if evidence changes**: if the drain band (8c(2)) is ever built as a true sub-1 multiplicative
factor rather than a generalized division, that specific feature is genuinely cheaper in log2-space
— worth re-costing on its own, but not a reason to revisit the fractional-tier ruling below.

### Option B — RULED / APPROVED — stay integer, scale fractions via percent (reuse `AchievementFirstMultPct`'s pattern)

**Benefits**: zero wire/fixture blast radius — still an int64 product, same wire shape, same
fixtures, same census tooling, same reconciliation path. Ships as an ordinary `glory.nim`
repricing wave (a GLORYVERSION bump for new deed classes, the same class of change this codebase
already does routinely), not a representation redesign. Directly reuses a pattern already proven
live in production.

### 9a. The headroom test — proof, not assertion (S4 gate condition (a))

Per the lead's explicit instruction, the precision-drift cost above was not left as a claim: a new,
additive-only test file was written and run — `tests/test_glory_percent_scale_headroom.nim`
(registered in `tests/shard_1.nim`), defining its **own** local fold helpers and touching no
`glory.nim` scoring proc. **All numbers below are measured output from an actual local run of this
file (`nim c -r -d:release`), not projected.**

- **Overflow: a total non-issue for the naive per-step fold**, exactly as expected — even the
  adversarial worst case (30 consecutive x1.50 factors from a seed already at the pinned ceiling
  scale, 65536) reaches only ~1.26×10¹⁰, nowhere near int64's ~9.2×10¹⁸ ceiling (it does exceed
  today's real `RecutProductCapArmed` = 2²⁴, which is expected and correct — any real fold would
  route through the same cap check every other class already uses).
- **UNPLANNED FINDING, found by running the test, not by reasoning about it**: the mitigation this
  catalog's Option B costing had proposed — "keep the exact rational product in a high-precision
  intermediate, truncate once at the end" — **fails outright**. Applying it to a 30-factor chain
  triggers a real `OverflowDefect`: the intermediate numerator (`150^30`) overflows int64 by
  roughly 45 orders of magnitude before the single final division ever happens. That specific
  mitigation, as described, does not work and is not usable as stated.
- **A corrected mitigation (batch-of-5 renormalization) fixes the overflow** by folding the
  running ratio into the accumulator every 5 factors instead of once per 30, using the SAME
  pre-multiply defensive pattern `recutFold` itself already uses (check `result >= cap ÷
  maxPerBatchMultiplier` before multiplying, clamp instead of risking overflow) — reuse, not a new
  idiom.
- **The rounding-drift finding, measured, honest, not smoothed over**: with the corrected batched
  mitigation, drift at the **real production seed** (`RecutSeed = 1`) is **23.65%** — a real,
  material loss, not the near-zero the doc's language implied before this test existed. Drift falls
  fast as the accumulator grows past the bare seed: **3.99% at seed 2, 3.94% at seed 4, 3.88% at
  seed 8, 1.46% at seed 16**, and **0.0003% at the pinned ceiling scale (65536)**. The naive
  (unbatched) per-step fold is far worse at the real seed — **99.95% drift**, and is a mathematical
  fixed point: `1 × pct ÷ 100 = 1` for every `pct` in the whole 110–150 tier, so repeating it
  forever changes nothing.
### 9b. SUPERSEDED by a cleaner answer — the FIXED-POINT ACCUMULATOR (coordinator follow-up ruling)

The batch-of-5 mitigation above and its fold-order constraint were **provisional pending one more
test case**, per the coordinator's explicit instruction not to freeze that constraint yet. A third
mechanism — seed the accumulator at a fixed-point `SCALE` (representing "1.0") instead of at the
bare `RecutSeed = 1`, fold exactly the same naive per-step way, and strip `SCALE` off only once at
the point `recutScore` reads the value for the wire — was added to
`tests/test_glory_percent_scale_headroom.nim` and run for real at `SCALE = 2^8 (256)` and
`SCALE = 2^10 (1024)`.

**Measured drift, both scales, all seeds — the decision table**:

| seed | SCALE=256 drift | SCALE=1024 drift |
|---:|---:|---:|
| 1 | 0.58797% | 0.13132% |
| 2 | 0.38247% | 0.13132% |
| 4 | 0.13132% | 0.05141% |
| 8 | 0.11419% | 0.02287% |
| 16 | 0.04855% | 0.01145% |
| 65536 (ceiling) | 0.00001% | 0.00000% |
| **worst across all seeds** | **0.58797%** | **0.13132%** |

**Every seed, both scales, is under 1% — with margin to spare (worst case 0.59%, over 1.7× headroom
below the 1% bar).** Existing integer factors (x2 → pct 200, x3 → pct 300, x12 → pct 1200) fold
**exactly** at both scales (0 drift) — confirmed directly, not assumed, since any whole multiple of
100 divides evenly regardless of scale.

**Overflow margin, including the FF-halving division path, both scales**:
- Multiply path: `RecutProductCapArmed × SCALE × 150` = 644,245,094,400 (SCALE=256) and
  2,576,980,377,600 (SCALE=1024) — both **~7.2 million times below `2^62`**
  (4,611,686,018,427,387,904), an enormous margin, not a close call.
- Halving path: the scaled accumulator at the cap (`RecutProductCapArmed × SCALE` =
  4,294,967,296 / 17,179,869,184) forms without overflow at either scale. Verified the **safe
  order** — halve first (reusing `recutScore`'s own existing `halvings >= 63 → 0` guard verbatim,
  unaffected by `SCALE`), strip `SCALE` second — agrees exactly with a naive combined-divisor order
  (`scale × (1 shl halvings)`) at every realistic halvings count (0–5) tested. The combined-divisor
  order is NOT recommended for production: `scale × (1 shl halvings)` itself would overflow int64
  around halvings≈53–61 depending on scale, where the safe (halve-then-unscale) order never forms
  that product at all and stays correct regardless.

**DECISION, per the coordinator's own stated rule**: drift is ≤1% at every seed with margin to
spare, at both candidate scales. **The fixed-point accumulator becomes the S4 representation. The
batch-of-5 mitigation and its fold-order constraint are DROPPED** — an x1.1 factor applied first,
against the bare seed, is no longer worthless (0.59% drift, not 99.95%), so no deed-ordering
discipline is required of whoever writes the next fractional-tier deed. **Recommend `SCALE = 2^10
(1024)`** over `2^8`: strictly lower drift at every seed tested, and the overflow margin at 2^10 is
still ~7 million× below `2^62` — the extra precision costs nothing measurable in headroom.

### Recommendation (superseded from the batch-of-5 framing, now landed on the fixed-point answer)

**Option B (percent-scaled integer factors) is the RULED path for S4/S5, implemented as a
FIXED-POINT accumulator (`SCALE = 2^10`), not a batch-renormalized rational.** No WIRE-OK sought or
needed — `SCALE` is an internal sim-side implementation detail; `recutScore`'s existing wire output
(after the one `div SCALE` strip) is unchanged in shape or meaning. No fold-order constraint is
carried into S5. S5 should still re-run this test's method (not necessarily this exact synthetic
chain, see "What is NOT verified") against whichever real deeds actually land in the x1.1–1.5
tier, but the representation question itself is closed pending only the top-attribution freeze.

## 10. Every proposed lever — switch, fire counter, rollback (consolidated)

| lever | switch | fire counter | rollback |
|---|---|---|---|
| Reprice modal kill/soak/heal off x1 (§4) | new deed classes behind a GLORYVERSION bump (all-or-nothing per the frozen-table pattern) | **per-deed** mint-rate report, each of `dHonorableKill`/`dShieldSoak`/`dClutchHeal` independently observable (RULED condition, §4) — not one merged meter counter | revert `RecutClassTable` rows, GLORYVERSION bump back |
| Drain band, generalized from FF halvings (§1, §2a) | new halving-trigger conditions behind config flag | `recutFfHalvings` incident count, already logged per episode | flag off, byte-identical to today's FF-only halving |
| Drain visible cue (§1, RULED — described, not authored) | rides the same config flag as the drain-band lever above (no standalone switch) | drain-cue-shown count, alongside the halving-incident counter | flag off, no cue fires (drain itself reverts too) |
| Heat tags-as-hits (§5) | `heatCreditsOnHit` config flag, default OFF | rung-occupancy-by-source report (extends existing census Q1 heat table) | flag off, zero behavior change |
| Heat per-victim rate cap (§5) | ships bundled with tags-as-hits (no standalone toggle proposed) | cap-triggered count per (attacker,victim) window | remove the cap check, revert to uncapped credit (only meaningful once tags-as-hits is armed) |
| Pact engine-enforced expiry (§6) | `pactMaxLifetimeTicks` config flag, default OFF | expiry-cause counter: engine-cap vs. policy-holdFire vs. still-active-at-end | flag off, `pactActive` reverts to today's unconditional-until-policy-ends read |
| Stateful sets/modes with real fail states (§6) | per-tree config flag, stateful vs. instant-mint | mode-entered/completed/failed-timeout, per tree | flag off, reverts to instant-mint achievement path |
| Lit jackpot deed (§6) | new deed behind `RecutMintCapTable`-style cap + a "primed" precondition gate | mint count + primed-but-uncollected count | remove the deed row, GLORYVERSION bump back |
| `RecutProductCapArmed` live counter (§7) | none — always-on observation | `capHitCount`, logged every episode | delete the counter, no behavior change |
| Placement ladder reprice (§2a, `dFinal8/4/2`) | new class values behind a GLORYVERSION bump | existing mint-rate reporting (already 100% observed) | revert class values |
| Representation change (§9 — log2 CONSIDERED/REJECTED; percent-scaled integer as a FIXED-POINT accumulator, `SCALE=2^10`, RULED/APPROVED) | N/A — Option A not being built; the fixed-point accumulator ships as an ordinary GLORYVERSION repricing wave, `recutScore` gains one `div SCALE` strip, same switch as any other class change | headroom/drift measured by `tests/test_glory_percent_scale_headroom.nim` (§9a/9b), not a runtime counter; worst drift 0.59%/0.13% at SCALE 2^8/2^10 across all tested seeds | N/A for Option A (never built); the fixed-point strip rolls back by removing the `div SCALE` and reverting `RecutClassTable`/`RecutTierClass` to their pre-fractional-tier values |

## 11. Endcard implications — flagged, not authored

The S2-gate ruling is explicit: **"S4/S6 must not author endcard changes unilaterally"** — the
journey lane owns `global_plus_pov.html`/the endcard bundle, one author at a time. This catalog
implies, but does not build or design in detail, the following endcard-adjacent needs, flagged for
the lead's gate to route:
- **Per-player itemization** of the multiplier chain (heat rung reached, stack tier, achievement
  tiers claimed, FF halvings taken) on top of the already-shipped combined MATCH GLORY roll-up
  (`renderEndcardBR`/`rollGloryNumber`) — this is the lead-accepted re-scope of pinball gap #3, a
  presentation build, not a scoring change.
- If Section 6's pact-decay or lit-jackpot mechanisms ship, they will need a perceivable "lit"/"expired"
  state somewhere client-side to be legible as a *choice* rather than an invisible server fact — the
  exact surface (HUD, endcard, or both) is explicitly **not decided here** and depends on the
  journey lane's own in-flight work.
- **The drain visible cue (Section 1)**: a muted, downward-reading marker distinct from a normal
  deed pop, described conceptually in Section 1 but **not designed or built here** — flagged for
  the lead's gate to route into either the live-play HUD strip or the endcard's per-player
  itemization (most likely both: a live moment cue plus a summarized line in the post-match
  breakdown). The RULED requirement is that it exist and be legible, never silent; the exact surface
  is the journey lane's call, one bundle author at a time.

## 12. What this document does NOT decide (even though it is now FROZEN on mechanism/direction)

- **No deed's final numeric class value.** The re-attribution table's iteration-4 constants
  (Section "FREEZE CONDITION 1") are a TRIAL proving the 50% bar is reachable in the design law's
  direction — not a recommendation. S5's rig picks the real constants.
- No GLORYVERSION, no wire shape. Representation choice IS frozen (fixed-point accumulator,
  `SCALE=2^10`, Section 9) — that part is decided.
- The three root-cause rulings ARE frozen (top of document) but their IMPLEMENTATION detail is not:
  which BR analogue (if any) retargets a flag deed (ruling a), the exact un-gate mechanics for
  `dAssist`/`dRescue` (ruling b), the exact pact-wipe/pact-down trigger shape (ruling c) — all S5.
- No mid-band width constants — Section 4 applies the RULED ladder (low 1–2 · mid 2–8, shoulder
  7–8 · top ≈9+ · jackpot 13–15 · ceiling ≈16) and names a specific cliff risk (the placement
  ladder/win multiplier), but the actual constants that make the 6–9 population continuous are
  explicitly left to S5.
- No heat rung/decay constants for a hit-based credit stream (the freeze table's heat multipliers
  are trial values, same caveat as above).
- No pact-expiry duration constant.
- No cap-hit-share target beyond the already-existing ≤1.5% (this draft proposes only a counter,
  not a new target).
- Season-display semantics ARE settled (Section 0 fact 1) and used consistently in Sections 8 and 9.

## 13. What was BLOCKED and has now landed, plus what still needs S5

top-attribution JOB1 (0.000% residual) and JOB2 (all 15+35 dead slots classified) have LANDED (PR
#494) — this is what un-blocked the freeze. What's left, all explicitly S5's:
1. **The rig simulation** — needed before any trial constant above becomes a real one, including
   whether the placement-ramp mitigation actually closes the 6–9 continuity requirement against
   real policies (not just this static replay).
2. **Ruling (b)/(c)'s real magnitude** — `dAssist`/`dRescue` un-gated and pact-scoped
   `dDuoDown`/`dWipe` cannot be measured from this frozen population (their events never fired in
   BR); S5 must run new episodes once the code changes land.
3. **The `dJointAct`-is-CONSTANT tension** named in the re-attribution section — whether #494's own
   bucket schema should be revisited for pact deeds specifically, or accepted as-is.

## 14. What is NOT verified (carried forward, not re-checked this draft)

- `tests/test_glory_percent_scale_headroom.nim` (Section 9a) was run **locally only** (`nim c -r
  -d:release`, this session) — not yet exercised by hosted CI (which is independently red on
  `origin/main` itself for an unrelated pre-existing reason, see the PR). All numbers reported are
  real local output, not projected, but the hosted-CI run of this specific new file has not been
  observed.
- The headroom test's chosen chain (30 factors cycling percents 110/120/130/140/150) is a
  representative stress shape, not derived from any specific real deed's measured mint frequency —
  S5 should re-run against whatever actual deeds land in the fractional tier and their real
  per-episode mint counts, not this synthetic chain. This applies to the adopted fixed-point
  accumulator too, not just the superseded batch-of-5 mitigation.
- The fixed-point decision (Section 9b) was tested at exactly `SCALE = 2^8` and `2^10` — the two
  values the coordinator specified — not swept across other scales; `2^10` is recommended as
  strictly better on the two points tested, not as an optimum found by search.
- Whether `play_view` can expose a new "risky moment" / "mode lit" / "pact active" perception signal
  — the pinball study flagged this as unchecked; Sections 6's stateful-modes and pact-decay
  proposals both assume some new perceivable state is buildable, which has not been confirmed.
- Whether any timer/mode-window primitive exists anywhere in the sim beyond zone-phase timing —
  two independent keyword greps found zero hits, but neither was an exhaustive read of an
  8,000+ line file.
- The exact count of literal integer constants pinned in each of the seven `test_glory*`/
  `test_match_glory.mjs` files named in Section 9 — named as a real cost, not individually audited
  line-by-line this draft.
- `docs/paintball/RULES.md` was never grepped for alliance/ally/team-up vocabulary (a planned
  pinball-study follow-up that never completed).
- Whether achievement-tier claims surface as a live HUD gauge in `client/player_hud.js` (only the
  server-side one-shot event is confirmed).
- The exact reachability of `treeGun.IV` (max level within an episode's length) and `treeSquad.{I,II,III,V}`'s
  individual gates — presumed by analogy in Section 3, not independently traced to source this
  draft.
- `dAssist`/`dRescue`'s exact call sites were not independently re-derived from source this draft
  (only `dFlagSteal` was directly grepped to a call site; the rest of the CTF-objective bucket is
  carried from the census/addendum's own characterization).

## 15. S5 ADDENDUM — trial pricing table (S4 static), RECOVERED and landed

**UPDATE: the tool was found.** It was never lost from the repo — it was
always ephemeral, uncommitted, in `/tmp` (as this document's own §"FREEZE
CONDITION 1" already said, correctly, before this addendum: `/tmp/
glory-catalog/attribution-tool/reprice_v3.py`, "not committed"). An S5
worker's independent `git show --stat` check on #491/#494 (below, kept for
the record) correctly found it absent from the COMMITTED repo, but the
coordinator separately located and preserved the original file at
`~/.ctf/knowledge/glory-gradient/00s-s4-repricer-recovered/reprice_v3.py`
(plus `reprice_v3_baseline_check.py` and the two attribution tools it
reuses). **It is now landed verbatim** at `tools/glory/reprice_v3.py` /
`tools/glory/reprice_v3_baseline_check.py` (this PR, epic 25d9108e S5) —
byte-identical to the recovered file, not modified to agree with anything.
Reproduce the 54.61%/71.11% figures with:

```
python3 tools/glory/reprice_v3.py \
  --census-rows /tmp/glory-census/seat_episode_rows_final.json \
  --attr-dir /tmp/glory-attr/replays
```

(both paths are the tool's own defaults, shown explicitly here; the
census/attribution artifacts themselves are the S1/S1b pipeline's own
output, not re-generated by this addendum).

*(Kept for the record, the S5 worker's own before-recovery check: `git
show --stat 57308cf3` touches only this file; `git show --stat f6c8d95e`
adds only the two attribution tools, no repricer, no v3 CLI argument —
correct as far as the COMMITTED repo went, superseded now that the
ephemeral copy has been located and landed.)*

**The trial pricing table, verbatim from `reprice_v3.py`'s own
`NEW_BASE_CLASS`/`HEAT_REMAP`/`STACK_SCALE`/`TERRITORY_SCALE`/
`CLEAN_SHEET_NEW_AMT`/`SHARPSHOOTER_SCALE` — every number below is copied
from the tool, not re-derived**:

| deed/lever | class/value | source |
|---|---:|---|
| `dHonorableKill` | x1 → x2.2 | `NEW_BASE_CLASS` |
| `dShieldSoak` | x1 → x1.6 | `NEW_BASE_CLASS` |
| `dClutchHeal` | x1 → x1.8 | `NEW_BASE_CLASS` |
| `dPointBlankKill` | x1 → x2.5 | `NEW_BASE_CLASS` |
| `dFirstBlood` | x2 → x4 | `NEW_BASE_CLASS` |
| `dLongshotKill` | x3 → x6 | `NEW_BASE_CLASS` |
| `dSplashMultiKill` | x3 → x6 | `NEW_BASE_CLASS` |
| `dRevengeKill` | x2 → x4 | `NEW_BASE_CLASS` |
| `dRunDown` | x2 → x4 | `NEW_BASE_CLASS` |
| `dAceTag` | x4 → x9 | `NEW_BASE_CLASS` |
| `dLastLight` | x4 → x8 | `NEW_BASE_CLASS` |
| `dJointAct`, `dLevelUp` | unchanged (x2, x1) | `NEW_BASE_CLASS` names them but equal to classic |
| HEAT rungs | 1/2/4/8 → x1/x5/x14/x36 | `HEAT_REMAP` |
| ALLY-STACK (k>1) | classic ladder × 2.5 | `STACK_SCALE` |
| `dClosingTime` | base → x1.1 (x1.2 win-bumped) | `NEW_BASE_CLASS` |
| TERRITORY rung-shift | `2^((log2(oldBase+1)-log2(oldBase)) * 0.15)` per-deed (NOT a flat %) | `TERRITORY_SCALE=0.15`, formula in `decompose_episode` |
| treeSquad.IV (Tier IV) | x2 → x1.05 | `CLEAN_SHEET_NEW_AMT` |
| treeGun.V (Tier V) | `max(1.01, amt**0.5)`, `amt`=classic INCLUDING the x3 FIRST bonus where it applies (sqrt(4)=2.0 non-FIRST, sqrt(12)≈3.46 FIRST) | `SHARPSHOOTER_SCALE=0.5` |

**Correction to this worker's own earlier drafts, both now retracted**:
(1) an invented flat +50%/+15% guess for the seven then-"unspecified"
deeds and territory — replaced by the real values above; (2) a SECOND
bug, found only after recovering the tool: `glory.nim`'s
`recutAchievementFactorV3Pct` had applied the Tier V sqrt to the tier
value ALONE then multiplied by the classic x3 FIRST bonus separately
(`sqrt(4)*3=6`) — the tool applies sqrt to the COMBINED amount
(`sqrt(4*3)=sqrt(12)≈3.46`), a materially different number for FIRST
claims. Fixed to match the tool exactly (`glory.nim`, hard-coded compile-
time constants since Tier V's classic amount is fixed and this file
carries zero imports, so no runtime `sqrt` is available). The rig
re-run against these corrected, verbatim values is reported in
`docs/designs/glory/RIG-SIMULATION.md`.

---
Source of truth for this draft, kept in sync: `~/.ctf/knowledge/glory-gradient/04-catalog-v3-draft-2026-09-09.md`.

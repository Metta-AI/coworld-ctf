# Season 2 standing stability sweep

Owner question: *"Is our k factor right? The leaderboard seems to still change fast.
Maybe we need a different number of episodes per round, a different round cadence,
or a different decay. What's the right ratio?"*

Short answer: **retuning the decay rate is the wrong lever.** The instability is
driven by a handful of near-cap rounds dominating the board, and no decay-rate
setting can bound an unbounded input (this was already established for a pure
rate retune — see `ctf-k-retune-cannot-bound-a-ratings-spike.md`). The lever that
actually works is compressing the round-score magnitude itself before it enters
the average. Below is the measurement behind that call.

Everything here is **read-only** against the live Paintbot Season 2 league — no
settings were changed, no backfill was run.

## The update rule being replayed

`GET /v2/leagues/league_b8fa9b35-.../settings` (elevated), `effective_ladder_config`,
read live 2026-09-08:

```
{"algorithm": "score", "round_scoring_rule": "sum", "sum_top_k": 12,
 "standing_aggregation": "rated", "rated_k": 0.05,
 "rated_clamp_multiple": 150.0, "initial_standing": 0.0}
```

```
round_score = sum(top 12 of the entrant's per-episode scores this round)
clipped     = round_score                       if this is the entrant's first round
            = clip(round_score, s/M, s*M)        otherwise (M = rated_clamp_multiple)
standing   <- standing + rated_k * (clipped - standing)
```

The standing subject is the **player**, not the policy version — `round_config`'s
`entrant_attributions` and the leaderboard both key by `player_id`, so a policy
version bump does not reset the EMA.

**Not re-derivable by file:line from `~/projects/metta` main.** The local checkout's
`app_backend/.../ladders/rankings/score.py` (`apply_round`) and `config.py`
(`ScoreRankingConfig`) implement a *different* scheme — `standing_aggregation:
Literal["ewma","mean","max"]` with `half_life_hours` (wall-clock **hours**, not
rounds) — and grep for `rated_k` / `rated_clamp_multiple` / `sum_top_k` inside
`app_backend/` returns zero hits. Whatever backend build actually serves Paintbot
S2 is ahead of, or diverged from, that local source tree. The formula above is
instead the live served config (fetched read-only, above), independently
corroborated by `ctf-standing-is-an-ema-not-a-max.md`'s regression fit (16 live
rows, ~1e-4% average error) and `ctf-rated-clamp-sizing-post-gv57.md`'s clamp
sizing. **Flagged as reconstructed-from-live-config, not source-cited**, per this
task's own fallback instruction.

## The ledger

`tools/ladder/standing_replay.py pull --since 4257` — 253 completed rounds,
r4257–r4526, division `Competition` (Paintbot Season 2), pulled 2026-09-08/09.
r4257 is the winAsMultiplier arm (the GV57 placement-ladder/win-factor economy
going live — `ctf-winasmultiplier-flips-at-gv57.md`); every round in this window
postdates that boundary. **242/253 rounds (r4257–4513) run on GloryVersion 14
builds (0.7.344–0.7.360); the last 11 (r4515–4526) cross into GloryVersion 15
builds (0.7.361+, JointAct alliance-only).** Because `rated_k=0.05` gives an EMA
half-life of 13.5 rounds, the most recent 11 rounds alone still carry **~43% of
the weight** in today's standing (`1-(1-k)^11`) — the recency-heavy tail of any
EMA, doubly worth flagging here since that tail straddles an economy version.
This does not affect the mechanics conclusions below (rated_k/clamp/top_k/
transform/cadence behave identically regardless of what produced the input
scores), but no single-era magnitude claim should be read out of this window.

**Reproduction: exact.** Replaying the full 253-round ledger under the served
config reproduces the live `/v2/divisions/{div}/leaderboard` **top-17 order
exactly** (17/17) at r4524-r4526. Absolute magnitude matches within **~5.2%**
for 10 of 12 spot-checked entrants (docxology, softmaxclaudius-t2, pawchuck,
daveey, daveey-1, soft-codexter-t2, lessandro, richard, softmaxwell, NanosaurusX)
— a previously-documented snapshot-lag artifact, not a formula error
(`ctf-standing-lead-is-a-recent-cap-cluster.md`: "reproduces... within +5%
(snapshot lag)"). Two entrants (Jordan −43%, Aaron −66%) diverge further despite
playing all 253/253 window rounds (ruling out a participation gap); the most
likely explanation is a still-undecaying contribution from a pre-window outlier
round this r4257-anchored ledger cannot see — era-G/H round magnitudes reached
~10¹²  (`docs/SCORING_ERAS.md`), and even after 253 rounds of 0.95ˣ decay a
spike that size leaves a residue in the ~10⁵–10⁶ range, which is exactly the
size of both gaps. **This affects only the absolute-magnitude claim for those
two named entrants, not the sweep**, which only ever compares settings against
each other on the identical ledger.

## Current-setting metrics (the baseline every candidate is measured against)

| Metric | Value |
| --- | --- |
| Mean Kendall tau, consecutive-round top-16 | 0.954 |
| p10 tau | 0.883 |
| #1 changes per 50 rounds | 6.92 |
| Share of #1's standing from their single best round | **31.4%** |
| Rounds for a mid-table (rank 8) policy boosted 1.5x to reach top-3 | 103 |
| Rounds for a top-3 (rank 2) policy halved to fall out of top-3 | **0** (same round) |
| Rank change of #1 when the single largest leg in the window is removed | 0 (that leg — a real 2^24 cap at r4258 — belongs to someone who was never #1) |

Two things jump out. First, **31.4% of the leader's entire standing comes from
one round** — the board's #1 spot is a recent-cap-cluster artifact, matching
prior doctrine, not a steady-play signal. Second, the board is **asymmetric**: a
decline is priced in the very same round (`down=0`), while a genuine improvement
takes over 100 rounds to surface (`up=103`) unless it happens to include a spike.
That asymmetry, not the decay rate per se, is most of what "the leaderboard
changes too fast" is describing.

## Sweep: one axis at a time around the current setting

| Axis | Setting | tau_mean | #1 chg/50 | leader share | up (1.5x→top3) | down (0.5x→out) |
| --- | --- | --- | --- | --- | --- | --- |
| **rated_k** | 0.02 | 0.976 | 3.56 | 0.193 ⁽¹⁾ | never | 9 |
| | 0.035 | 0.963 | 6.32 | 0.267 ⁽¹⁾ | 103 | 0 |
| | **0.05 (current)** | **0.954** | **6.92** | **0.314** | **103** | **0** |
| | 0.075 | 0.939 | 9.88 | 0.372 ⁽¹⁾ | 103 | 0 |
| | 0.1 | 0.926 | 12.85 | 0.417 ⁽¹⁾ | 103 | 0 |
| **clamp_M** | 10 | 0.970 | 3.56 | 0.273 | 116 | 0 |
| | 30 | 0.960 | 5.93 | 0.310 | 103 | 0 |
| | 60 | 0.955 | 6.72 | 0.313 | 103 | 0 |
| | 150 (current) | 0.954 | 6.92 | 0.314 | 103 | 0 |
| | none | 0.953 | 6.92 | 0.315 | 103 | 0 |
| **transform** | raw (current) | 0.954 | 6.92 | 0.314 | 103 | 0 |
| | **log2(1+glory)** | 0.942 | 9.49 | **0.043** | **48** | 0 |
| | rank-points (F1) | 0.919 | 10.67 | 0.105 | never | 0 |
| **sum_top_k** | 6 / 12 / all | identical | identical | identical | identical | identical |
| **episode cadence** | half (20 draws) | 0.959 | 5.55 | 0.682 | never | 0 |
| | current | 0.954 | 6.92 | 0.314 | 103 | 0 |
| | double | 0.947 | 6.35 | 0.278 | never* | 0 |

`⁽¹⁾` **Erratum (2026-09-09, S0 fix PR):** these `rated_k` rows' leader-share
values were originally computed with decay hardcoded at `k=0.05` regardless of
the row's own rate (see "Leader-share definition, stated explicitly" below);
they are corrected here using each row's own swept `rated_k` and supersede the
prior 0.333/0.316/0.341/0.399 values. No other column in this table is
affected by the bug or changes.

`sum_top_k` is confirmed **inert on this ledger**: the scheduler produces exactly
12 legs/entrant/round with zero headroom, matching `docs/SCORING_ERAS.md`'s "H
era: armed, inert" finding — 6/12/all trim nothing, so this lever does nothing
today (it would start mattering the moment scheduling exceeds 12, same as the
existing doctrine already warns).

`*` "double" (pairing consecutive rounds into one bigger, half-as-frequent
update) doesn't reach top-3 within the remaining window in *calendar-round*
terms either — halving the number of standing updates costs more responsiveness
than the bigger per-update jump buys back. "half" (randomly subsampling ~6 of 12
legs/round) makes a single lucky leg an even bigger share of a now-smaller round
sum (share triples to 0.682) — noisier, not more stable in the way that matters.

**Reading the k and clamp rows on their own is the doctrine already on file,
re-confirmed on live data:** lower k or tighter M buys stability by slowing
*everything* down uniformly (`up` gets worse or stalls entirely at k=0.02), because
neither one bounds the input — it's the same "1+k(M-1)" ratio-based bound as
before, at a bigger sample. **`log2` is different in kind**: it acts on the input
distribution directly, cutting the leader's single-round dependency by 86%
(0.314→0.043) while *halving* the time for a real improvement to register
(103→48 rounds) — because compressing five orders of magnitude of round-score
spread down to a narrow log-scale band shrinks the *gap* a genuine climber has to
close, not just the noise around it.

## Top-3 combined candidates

| Setting | tau_mean | #1 chg/50 | leader share | up | down |
| --- | --- | --- | --- | --- | --- |
| log2 only | 0.942 | 9.49 | 0.0432 | 48 | 0 |
| log2 + clamp_M=60 | 0.942 | 9.49 | 0.0432 | 48 | 0 |
| **log2 + rated_k=0.035** | **0.960** | **7.51** | **0.0427** ⁽¹⁾ | **48** | 0 |

`log2 + clamp_M=60` is **identical** to `log2` alone — once magnitudes are
log-compressed, a round-over-round swing of 60x in *log-space* essentially never
happens, so the clamp stops binding. Tightening the clamp is redundant once the
transform is in place; **only one of the two levers is needed.**

`log2 + rated_k=0.035` is the best of the three: it recovers the top-tier tau
that `log2` alone gives up (0.960, better than today's 0.954) and cuts the
leader-change rate from log2-alone's 9.49/50 back toward today's baseline
(7.51/50), while keeping log2's full anti-spike effect (share 0.0427 ⁽¹⁾, still
~7x better than today's 0.314) and its *faster*, not slower, responsiveness (48
rounds, same as log2 alone, versus today's 103). Corrected: adding
`rated_k=0.035` to `log2` barely moves leader share at all versus `log2` alone
(0.0427 vs. 0.0432) — the two combined candidates above were reported as 0.043
vs. 0.061 (a real difference) before the decay-constant fix; post-fix they are
within noise of each other, so the rate half of this combo is not buying
anti-spike protection on top of the transform, only the tau/responsiveness
trade described above.

## Rate sweep extension: k in {0.02, 0.025, 0.03, 0.035}

**Era stamp.** Re-run 2026-09-09 with `tools/ladder/standing_replay.py` at
origin/main commit `62fa01461a0a18265686e35645f617d83b6af224` (script sha256
`79e50b9baa759ef4e4e3eb8dacd27a33c782a84a3abb3ae5082f4c881dd5b1ae`, unchanged
since PR #478 — no tool code edited for this run), same real ledger as above
(253 rounds, r4257–r4526, ledger sha256
`a991f9922fe21ebeb3d3ed802b5a20f72aaecc8cea680cfcfa2ef6fcced4830c`). The
`log2` row and the `log2 + rated_k=0.035` row below reproduce the "Top-3
combined candidates" table above **exactly** (same tau/chg/share/up to every
digit), confirming this is the identical ledger and script, not a re-pull.

| Setting | tau_mean | #1 chg/50 | leader share | up (1.5x→top3) | down (0.5x→out) |
| --- | --- | --- | --- | --- | --- |
| log2 + rated_k=0.02 | 0.979 | 5.73 | 0.0269 ⁽¹⁾ | 103 | 0 |
| log2 + rated_k=0.025 | 0.979 | 4.74 | 0.0319 ⁽¹⁾ | 96 | 0 |
| log2 + rated_k=0.03 | 0.970 | 8.89 | 0.0363 ⁽¹⁾ | 49 | 0 |
| log2 + rated_k=0.035 (from table above) | 0.960 | 7.51 | 0.0427 ⁽¹⁾ | 48 | 0 |

The 0.025 row was first surfaced by two uncommitted 2026-09-09 ad-hoc re-runs
of this same script (raw JSON and scripts preserved in internal tracking, not public);
this section commits that row, plus 0.02 and 0.03 for a complete picture of
the interval, as the doc's own record.

**Leader-share definition, stated explicitly.**

`⁽¹⁾` **Erratum (2026-09-09, S0 fix PR — "fix first" ruling):** every
leader-share value marked `⁽¹⁾` in this document was originally computed with
decay fixed at `k=0.05` regardless of the row's own swept rate and is
**superseded** by the corrected value shown. See the regression test below.

`leader_best_round_share()` used to always decay contributions using the
served-default `rated_k=0.05` (the module constant `CURRENT["rated_k"]`),
**not** the row's own swept `rated_k` — so every non-0.05 `rated_k` row in
this document (all rows in this table, plus the `rated_k` axis rows and the
`log2 + rated_k=0.035` row above) reported leader share decayed at 0.05,
never at that row's own rate. This was a **bug in the helper, not a design
choice**, confirmed by direct inspection (`tools/ladder/standing_replay.py:
452-473`) and by reproduction: it is the full explanation for the 2026-09-09
disagreement where two ad-hoc scripts reported 0.060 vs. 0.032 for the
identical `log2 + rated_k=0.025` setting. The `sweep-slow` script called the
shared helper as-is and got 0.060 (matches this table's old, pre-fix value
exactly). The `sweep-f1` script independently reimplemented the decay using
the row's actual k=0.025 and got 0.032; patching the helper to accept the
swept k and re-running against the same ledger reproduces
0.031876310968393766, matching `sweep-f1`'s figure to 6 significant figures
and this table's corrected 0.0319 value. Both preserved runs were internally
correct given what each one actually computed — the discrepancy was a latent
parameter-threading bug, not noise and not two valid definitions.

**Fixed 2026-09-09 (follow-up PR to #482, per the S2 lead's "fix first — do
not merge a known-wrong column into the source of truth" ruling):**
`leader_best_round_share()` now takes an explicit `rated_k` argument, and its
one call site (`_metrics_for_setting`) threads each swept setting's own rate
through instead of the module constant. Covered by a regression test,
`test_leader_best_round_share_uses_its_own_rated_k`
(`tools/ladder/test_standing_replay.py`), which fails against the old
hardcoded-0.05 signature and passes against the fix. Every `⁽¹⁾`-marked share
value in this document — the `rated_k` axis table, the `log2 + rated_k=0.035`
combined-candidate row, and the four rows in this table — has been
recomputed with the fix on the identical frozen ledger (same sha256 as
above) and reflects each row's own decay rate.

## Rate selection criterion (owner's criterion, applied literally, 2026-09-09)

Owner's criterion, verbatim: *"fewest #1 changes subject to the 1.5x climb
time not being faster than today's ~103 rounds (the owner explicitly does not
want a faster climb)."* Lower `up` is a **faster** climb, so the constraint is
`up >= ~103`. Applied to the `log2` family only — the transform is already
decided (geometric-mean glory stands; see S0 gate ruling), so only the rate
constant is open:

| Setting | up | up >= ~103? | #1 chg/50 | Result |
| --- | --- | --- | --- | --- |
| log2 (rate unchanged, k=0.05) | 48 | No — faster | 9.49 | FAIL |
| log2 + rated_k=0.035 | 48 | No — faster | 7.51 | FAIL |
| log2 + rated_k=0.03 | 49 | No — faster | 8.89 | FAIL |
| log2 + rated_k=0.025 | 96 | No — faster | 4.74 | FAIL |
| **log2 + rated_k=0.02** | **103** | **Yes — tied, not faster** | **5.73** | **PASS** |

Exactly one row satisfies the constraint as literally written:
**`log2 + rated_k=0.02`**, tied at `up=103` (not faster than today). It is not
the lowest-`#1-chg` row overall (`log2 + rated_k=0.025`'s 4.74 is lower, but
that row's `up=96` is faster than today and is excluded); among the rows that
satisfy the constraint it is the only candidate, so it trivially has the
fewest #1 changes subject to the constraint. This is a real tie, not a
comfortable margin — `up=103` matches today's baseline to the exact round,
and 0.02 was not one of PR #478's originally-swept `log2 + rated_k` values, so
this result rests on a boundary the criterion was written to test, not deep
inside a passing region. **No settings change is proposed or applied here**;
this table only reports which rows pass/fail the literal criterion.

**Superseded below.** The "Robustness read" section that follows shows this
literal `~103` anchor reproduces on only 6/30 (20%) of resampled draws — see
"Rate criterion, restated" after it for the corrected, distributional version
of this criterion and the resulting pick.

## Robustness read: bootstrap over resampled round windows (2026-09-09, S0 fix PR)

The rate criterion above rests on **one run, one seed, one ledger window**,
and its only passing row (`log2 + rated_k=0.02`, `up=103`) passes by an
**exact tie** against the baseline — too thin to hang a season-long constant
on by itself. This section bootstraps all five metrics over resampled
round windows of the same frozen ledger (sha256
`a991f9922fe21ebeb3d3ed802b5a20f72aaecc8cea680cfcfa2ef6fcced4830c`) using the
fixed tool, reporting **median + 10th/90th-percentile interval**, ≥20 draws
per metric, fixed seed for reproducibility.

**Method (two schemes, since a fixed-length window can't observe both):**
- `tau_mean` / `#1 chg/50` / `leader share`: computed fresh (own cold-start
  EMA) on 30 sliding **100-round windows** (`rounds[s:s+100]`, `s` drawn
  without replacement from the 154 possible starts).
- `up` / `down`: a 100-round window can't observe `up≈103` at all (not
  enough room left after injection), so these are resampled instead by
  sliding the **injection point** (`from_idx`) across the full 253-round
  ledger — 30 draws of `from_idx` in `[20,126]` (mirrors the doc's own
  `from_idx=126`), which guarantees ≥127 rounds always remain after
  injection, comfortably more than the ~103-round threshold, so a "never"
  result is a real signal and not an artifact of a too-short remainder.

| Setting | tau_mean med [p10,p90] | #1 chg/50 med [p10,p90] | leader share med [p10,p90] | up (finite) med [p10,p90] | up: PASS (≥103 or never) frac |
| --- | --- | --- | --- | --- | --- |
| raw, k=0.05 (today) | 0.946 [0.938,0.955] | 6.25 [2.95,9.00] | 0.333 [0.260,0.542] | 41.5 [0.0,109.1] | **0.20** |
| log2, k=0.05 (log2 alone) | 0.949 [0.938,0.956] | 8.00 [4.00,12.05] | 0.0618 [0.0526,0.0689] | 44.0 [16.9,60.1] | 0.00 |
| log2, k=0.035 | 0.969 [0.960,0.974] | 5.25 [1.50,10.50] | 0.0453 [0.0382,0.0503] | 65.5 [48.0,96.3] | 0.07 |
| log2, k=0.03 | 0.972 [0.964,0.979] | 3.25 [1.40,7.65] | 0.0392 [0.0332,0.0429] | 94.5 [55.9,147.2] | 0.43 |
| log2, k=0.025 | 0.979 [0.971,0.984] | 2.75 [0.45,7.55] | 0.0310 [0.0281,0.0354] | 96.5 [69.5,147.2] | 0.43 |
| **log2, k=0.02** | **0.984 [0.978,0.989]** | **1.50 [0.00,5.10]** | **0.0245 [0.0213,0.0290]** | **121.0 [100.9,155.2]** | **0.83** |

**Does `k=0.02`'s pass survive the spread?** Mostly yes — of the log2-family
rates, `k=0.02` passes the literal `up>=103` criterion on **25/30 (83%)** of
resampled injection points, a clear majority and the highest of any rate
tested (0.43, 0.43, 0.07, 0.00 for 0.025/0.03/0.035/log2-alone respectively —
a smooth, monotonic decline with k, consistent with basic EMA-decay mechanics
rather than noise). Its bootstrapped `up` median (121) sits comfortably above
103, and the 10-90 interval `[100.9,155.2]` barely dips below the threshold
at the low end. So the committed doc's single-window exact tie
**understates**, if anything, how often `k=0.02` clears the bar — it is not
an artifact of that one window.

**But the reference point itself is shakier than the tie suggests.** The
"today ≈103 rounds" baseline that the whole criterion is anchored to only
reproduces `up>=103` on **6/30 (20%)** of resampled injection points; its own
bootstrapped median is **41.5 rounds**, roughly 2.5x faster than the specific
`from_idx=126` draw the committed doc measured it at. That single draw landed
near the slow tail of the baseline's own distribution, not its typical
value. This does not overturn the criterion's PASS/FAIL calls above (which
correctly apply the owner's literal wording to the specific measurement the
owner was shown), but it means "~103 rounds" is a **fragile anchor** for a
season-long constant — a second real-ledger pull, or the owner re-stating the
criterion against a more typical baseline value, would materially change
which rates pass. Flagging this rather than re-deriving the criterion, which
is the owner's call, not this worker's.

Caveats on this bootstrap itself: (1) 100-round window replays cold-start
their own EMA rather than inheriting a running standing, which the "top5
standing" chart discussion elsewhere in this doc already flags as inflating
early-window volatility slightly — the tau/chg/share intervals above are
therefore a mild overestimate of true within-season variance, not an
underestimate. (2) This is still the **same single 253-round ledger pull**
sliced differently, not a second independent pull — see "The ledger" above
for the GloryVersion 14→15 boundary this window straddles (r4515–4526, the
last 11 of 253 rounds); any window or injection draw touching those rounds
inherits that same era-span caveat. (3) `down` was uniformly fast and
near-zero across every draw for every setting (never-frac 0.00 throughout,
medians 0-6 rounds) — the asymmetry noted in "Current-setting metrics" above
(declines register immediately, improvements don't) holds up under
resampling without qualification.

## Rate criterion, restated (2026-09-09) — the pick

**Supersedes** the literal criterion above. The old wording ("no faster than
today's ~103 rounds," a single point estimate) is replaced with a
**distributional** form: *"the 1.5x climb-time distribution under the new
rule must not be faster than today's climb-time distribution,"* compared by
bootstrapped **medians and p10** (see "Robustness read" above), not a single
draw.

**⚠️ Anchor caveat, verbatim:** the old "~103" reference was unstable (6/30
draws, bootstrapped median 41.5); the criterion is now distributional for
that reason.

Why this changes the outcome: today's bootstrapped median `up` is **41.5
rounds**, not 103 — the single-draw 103 was an unlucky (slow-tail)
realization. Under the distributional criterion, every log2 candidate at
`k >= 0.02` has a higher (slower-or-equal) median **and** p10 than today's
41.5/0.0: log2 alone 44.0/16.9, `k=0.035` 65.5/48.0, `k=0.03` 94.5/55.9,
`k=0.025` 96.5/69.5, `k=0.02` 121.0/100.9. The owner's "no faster climb"
concern is satisfied by the **whole log2 family** — the climb constraint
stops discriminating between rates, so the pick falls to the owner's primary
symptom instead: the board changes too fast.

**The pick: `rated_k = 0.025`.** Fewest #1 changes of the extended rows
(4.74/50, vs. 5.73 / 8.89 / 7.51 for `k=0.02` / `0.03` / `0.035`), tau 0.979,
corrected leader share 3.2% (0.0319), decay half-life `ln(2)/0.025 ≈ 27.7`
rounds. Chosen on fewest #1 changes with stability and leader share both in
hand, once the climb constraint no longer discriminates.

**Runner-up: `k = 0.02`.** Better leader share (0.0269 vs. 0.0319) but
*more* #1 changes (5.73 vs. 4.74/50) — the honest trade against the pick,
not a second-place tie.

**⚠️ Era-span caveat, verbatim:** r4257-r4526 is not one cohort — 242/253
rounds are GloryVersion 14, the last 11 cross into GloryVersion 15 (JointAct
pact-only, PR #467); ~7% of 100-round windows touch that tail.

**This pick is a recommendation on record, not an authorisation.** The POST
does **not** follow from it. It still waits on: the `log2` transform
actually landing (a code change, not a settings knob, per "Recommendation"
below); the sign-aware clamp fix for negative legs; a live-league audit of
every league running `rated` aggregation with an armed clamp; and the
owner's GO relayed by the S2 lead. No settings were changed to produce this
section.

## Recommendation

**Switch the round-score transform from raw to `log2(1 + round_score)` and lower
`rated_k` from 0.05 to 0.035.** Leave `sum_top_k` and `rated_clamp_multiple`
untouched — top_k has no headroom to spend today, and the clamp becomes a
no-op once log2 is in place.

**2026-09-09 update:** this `rated_k=0.035` pick predates the owner's rate
criterion being formalized. Applying that criterion literally (see "Rate
selection criterion" above) does **not** select 0.035 — only `rated_k=0.02`
passes. The transform half of this recommendation (raw → log2) stands; the
rate half is superseded by the criterion section above pending the owner's
read on that finding.

- Leader's single-round dependency: 31.4% → 4.3% ⁽¹⁾ (corrected; previously
  miscomputed as 6.1% by the decay-constant bug fixed in this document)
- Time for a genuinely-better policy to reach top-3: 103 rounds → 48 rounds (faster)
- Consecutive-round rank stability (tau): 0.954 → 0.960 (slightly better)
- #1 turnover: 6.92/50 rounds → 7.51/50 rounds (a small, acceptable cost)

**What it takes to apply this:**
- **`log2` transform is a code change**, not a settings POST — `round_scoring_rule`
  today only knows `sum`/`mean`/`max` per-episode aggregation; a log-compressing
  round-score transform does not exist as a settings knob and would need to be
  added to whatever service computes `round_score` before it reaches the ranking
  algorithm. This is the one part of the recommendation that is **not** a same-day
  change.
- **`rated_k=0.035` is a settings POST** (`ladder.ranking.rated_k`), same
  mechanism as the existing `rated_clamp_multiple` arming — Softmax-team
  credential + `X-Use-Elevated-Privileges: true`, live for future rounds only,
  no migration.
- **Neither requires a backfill.** Per `ctf-rated-clamp-sizing-post-gv57.md`,
  arming a new ranking setting only changes *future* rounds; a
  `standing:backfill-rated` replay is a separate, explicitly-opt-in, riskier step
  this doc does not recommend taking.
- **Sequencing:** the settings-only `rated_k` change can ship today independent
  of the code change, and on its own is a modest, unambiguous improvement (tau
  0.954→0.963 per the single-axis table above) — but it does **not** touch the
  31.4% single-round-share problem, which is the log2 change's job. Treat them
  as two shippable steps, not one bundled release.

## Charts

- `.harness/screenshots/standing-sweep/stability_vs_responsiveness.png` —
  stability (tau) vs. responsiveness (rounds to top-3) scatter, one point per
  setting swept, current setting marked with a star.
- `.harness/screenshots/standing-sweep/top5_standing_current_vs_recommended.png`
  — top-5 standings over r4257–r4526 under current vs. recommended settings,
  same ledger, same 5 policies (ranked under the current setting's own final
  order). Downscaled copies at `/tmp/standing-sweep/owner/`.

Note on the second chart's first ~50 rounds: the reconstruction's own cold start
(standing initialized directly from each player's first in-window round, since
this ledger starts at r4257 rather than that player's true first-ever round)
produces a visible decaying artifact in the CURRENT (raw) panel for one entrant
(softmaxclaudius-t2) that isn't present in the real, continuously-tracked
standing. Read the right two-thirds of each panel as representative; the
RECOMMENDED (log2) panel barely shows this artifact at all, since log-compressing
a lumpy opening round is a smaller effect in log-space — a incidental second
point in log2's favor.

## Tests

`python3 -m pytest tools/ladder/test_standing_replay.py -q` → **5 passed**.
Fixture: `tools/ladder/testdata/standing_fixture.json` (first 15 rounds of the
real pull, r4257–r4271). Covers: exact reproduction of pinned standings on the
fixture; the clamp's one-round-move bound (`1+k(M-1)`) holding on the fixture's
real 2^24 leg at r4258; the rank-points transform staying bounded at [0,25];
and (added 2026-09-09, S0 fix PR) `test_leader_best_round_share_uses_its_own_
rated_k` — a regression test for the decay-constant bug above, asserting two
settings that differ only in `rated_k` produce materially different leader
shares. Confirmed to fail (`TypeError: unexpected keyword argument 'rated_k'`)
against the pre-fix signature and pass against the fix.

## What is NOT verified

- The `metta` main source tree does not contain the fields this doc replays
  (see "The update rule" above) — the formula is confirmed against the live
  served config and against independent prior regressions, not against a
  current file:line in the deployed backend's own source.
- Jordan/Aaron's absolute-magnitude gap (see Reproduction) is diagnosed, not
  proven — the pre-window-residue explanation is the best fit to the evidence
  gathered (both play every window round; magnitude order is consistent with a
  known era-G/H outlier scale) but was not traced to a specific pre-r4257 round.
- The responsiveness/spike experiments are single synthetic injections on real
  data (1.5x/0.5x scaling of one real subject's legs from the window's midpoint,
  20-draw average only for the "half" cadence's stability numbers) — they
  characterize the mechanism, not a guarantee about any specific future policy's
  climb time.
- No settings were changed and no backfill was run; this is a recommendation,
  not a live change.
- **2026-09-09 extension:** the `log2 + rated_k=0.02` pass on the rate
  criterion is a single-run, single-seed **point estimate** on one real
  ledger window; it was not re-verified against a second independent ledger
  pull or an independently re-derived `mid_subject`/`top_subject` pair, and
  `up=103` is an exact tie against that one point estimate. The bootstrap
  in "Robustness read" above resamples within this same pull and shows the
  pass holds on 83% of resampled injection points (not an artifact of one
  window) — but it is still the same single 253-round pull sliced
  differently, not a second pull, and the baseline `~103` anchor itself
  reproduces on only 20% of the same draws (bootstrapped median 41.5), which
  the owner has not yet been asked to weigh in on.
- **2026-09-09 fix PR:** the `leader_best_round_share()` decay-constant bug
  (confirmed by direct code inspection and reproduction of both preserved
  figures) is now **fixed** — `rated_k` is threaded through explicitly and
  covered by a regression test (`test_leader_best_round_share_uses_its_own_
  rated_k`) confirmed to fail pre-fix and pass post-fix. Every leader-share
  value in this document has been recomputed with the fix; values marked
  `⁽¹⁾` are the ones that changed. Not independently re-verified by a second
  reviewer.
- **Era span, reported not fixed:** this ledger (253 rounds, r4257–r4526) is
  known to straddle a GloryVersion/GameVersion boundary — see "The ledger"
  above (242/253 rounds on GloryVersion 14, the last 11 on GloryVersion 15).
  Every table and the bootstrap in this document replay this single window
  as-is; none of the mechanics conclusions (rated_k/clamp/top_k/transform
  behave identically regardless of what produced the input scores) require
  a single-era window, but no absolute-magnitude or "typical season" claim
  should be read out of it, and this sweep was not re-scoped to a
  single-era subwindow to address it.

## Win-gated extension (2026-09-14)

Owner's new rule: an entrant's per-episode leg is 0 unless that entrant
**WON** the episode (a draw banks the full leg for everyone); the gate
applies BEFORE the log, so a gated leg is exactly 0 bits. Replayed here as
**R2**, alongside **R0** (today: raw, k=0.05) and **R1** (Step A as
decided: `signed_log2(x) = sign(x)·log2(1+|x|)`, k=0.025) on the identical
window. Harness extended, not rewritten: `tools/ladder/standing_replay.py`
gained `signed_log2`/`inverse_transform`, the winner-decode primitives
(`download_replay`/`decode_episode_summary`/`pull_winner_map`/
`gate_ledger_by_win`), and generalized bootstrap helpers; all 5 pre-existing
tests still pass unchanged. Driver scripts:
`tools/ladder/standing_sweep_reproduction_check.py` and
`tools/ladder/standing_sweep_win_gated.py`.

**Window, era, winner-field provenance.** The doc's own r4257-r4526 ledger
predates per-episode winner decodability at this session's build capacity
(GloryVersion 14/15, no built `extract_events` for that wire GameVersion).
The win-gate instead uses the largest window this session COULD decode
winners for: **r4828-r5077, 246 rounds**, coworld_version
`0.7.397-0.7.406`, **GameVersion 63 / GLORYVERSION 18** throughout (r4828 is
the first GLORYVERSION-18 round; confirmed the same GameVersion holds past
this window too, at r5264/`0.7.409`). The platform's `participant_scores`
never says who WON — only score — so "winner" is read off the replay's own
`summary` event (`summary["winner"]` team-color, `summary["draw"]` bool,
`summary["slot_team"]` slot→team; the same field `tools/glory/
census_decode.py` already reads), decoded with the already-built
`census_gv63_gv18_build` extractor (matches this window's GameVersion
exactly). **Cross-check by content, round r4828:** of 15 episodes, the
declared winner was NOT the top glory scorer in **12/15** — e.g. one
episode's winner finished glory-rank 3 (score 20) behind the top scorer's
2,894 — confirming score cannot stand in for winner. Decode yield:
3,649/3,655 episodes (99.8%); the rest are dropped from both gated and
ungated counts, never guessed.

**R0/R1 reproduction (on THIS doc's own r4257-r4526 ledger, not the
win-gate window).** R0: tau 0.954, #1 chg/50 6.92, leader share 0.314, up
103, down 0 — exact match on every reported digit. R1 (`signed_log2`,
k=0.025): tau 0.9793 vs this doc's 0.979, chg/50 4.74 exact, leader share
0.031876 vs 0.0319, up 96 exact — 3-s.f. match. Also confirmed directly:
this ledger has zero negative legs (0/48,752), so `signed_log2` is
byte-identical to this doc's plain `log2` here.

**Metrics table, win-gate window (r4828-r5077, 246 rounds).** Bootstrap: 30
draws, 100-round sliding sub-windows for tau/#1-chg/leader-share (own
cold-start EMA per window, same method as "Robustness read" above); 30
draws of the injection point for climb time.

| Rule | k | tau (boot median [p10,p90]) | #1 chg/50 (boot median [p10,p90]) | leader share (boot median [p10,p90]) | climb time, median [p10,p90] (never-frac) | frac legs zeroed | standing scale: median / top, bits (un-logged) |
| --- | ---: | --- | --- | --- | --- | ---: | --- |
| R0 today | 0.05 | 0.906 [0.889,0.920] | 7.00 [4.00,10.50] | 0.250 [0.217,0.412] | 7.0 [0,22] (0%) | — | 170,871 / 287,443 (raw, no log) |
| R1 step A | 0.025 | 0.951 [0.938,0.960] | 4.00 [1.50,6.00] | 0.036 [0.028,0.045] | 50.5 [13,64] (0%) | — | 34.3 (2.11e10) / 40.4 (1.45e12) |
| R2 win-gate | 0.02 | **0.961 [0.949,0.965]** | **1.00 [0.00,4.50]** | 0.055 [0.034,0.081] | never (100%) ⁽²⁾ | 92.7% | **5.41 (41.6) / 9.95 (988)** |
| R2 win-gate | 0.025 | 0.948 [0.931,0.959] | 2.50 [0.00,5.00] | 0.081 [0.062,0.115] | never (100%) ⁽²⁾ | 92.7% | 5.38 (40.5) / 10.23 (1,204) |
| R2 win-gate | 0.03 | 0.937 [0.919,0.946] | 3.50 [0.00,7.00] | 0.096 [0.073,0.131] | never (100%) ⁽²⁾ | 92.7% | 5.33 (39.3) / 10.52 (1,466) |
| R2 win-gate | 0.035 | 0.920 [0.904,0.934] | 5.50 [0.00,10.50] | 0.107 [0.089,0.140] | never (100%) ⁽²⁾ | 92.7% | 5.37 (40.4) / 10.78 (1,758) |
| R2 win-gate | 0.05 | 0.885 [0.861,0.900] | 8.25 [5.00,11.00] | 0.145 [0.126,0.179] | never (100%) ⁽²⁾ | 92.7% | 5.33 (39.3) / 11.39 (2,690) |

`⁽²⁾` **Not a real "never" finding — an injection-methodology artifact,
flagged not hidden.** The doc's `up` test scales a subject's RAW legs by
1.5x; under the win gate ~93% of that subject's legs are already zero, and
`1.5 × 0 = 0`, so the injection barely reaches the signal a gated
round_score is built from. See arming flag (b) below.

**Three top-5 standings, end of window (r5077).** Full top-16 + wins/246r:
`~/.ctf/knowledge/glory-gradient/01h-win-gated-standing-sweep-2026-09-14.md`.

| Rule | #1 | #2 | #3 | #4 | #5 |
| --- | --- | --- | --- | --- | --- |
| R0 today (raw) | relh (226w) | daveey-1 (186w) | Lawrence (210w) | Jordan (290w) | @lessandro (153w) |
| R1 step A (signed_log2, k=0.025) | Jordan (290w) | softmaxclaudius-t2 (218w) | Andre von Auto (228w) | relh (226w) | Lawrence (210w) |
| R2 win-gate (signed_log2, k=0.02) | Jordan (290w) | daveey (262w) | soft-codexter-t2 (200w) | Andre von Auto (228w) | softmaxclaudius-t2 (218w) |

R0 ranks almost independently of wins (`relh`, 226 wins, above `daveey`'s
262); R2 tracks win count far more directly (`daveey` jumps R0-rank-7 to
R2-rank-2).

**Two arming flags — stated, not resolved:**

- **(a) sum-vs-mean under the log-domain transform is a still-open choice.**
  `round_scoring_rule: "sum"` is unchanged by this study — under
  `signed_log2`, summing 12 already-logged legs is equivalent to taking
  `log2` of the PRODUCT of the 12 underlying raw legs, not their typical
  size, so a standing that accumulates many rounds of 12-leg sums compounds
  fast: R1's un-logged top standing above is **~1.4e12**. Whether the round
  aggregation under a log-domain transform should stay `sum` (compounding,
  today's behavior) or switch to `mean` (representing a typical leg) is a
  real design choice this sweep did not make and flags for the arming
  decision, not this doc.
- **(b) climb time under the win gate is unmeasured, not slow.** The
  score-scaling injection this doc uses elsewhere is inert on gated legs
  (see `⁽²⁾` above). A meaningful read needs either a **win-injection
  test** (give the subject additional wins, not bigger scores on existing
  ones) or an **arm-and-watch** of the live setting for one EMA half-life,
  `ln(2)/0.02 ≈ 35 rounds`, before trusting any climb-time claim under
  gating.

**k = 0.02 supersedes the 0.025 pick above ONLY under the win gate; the
0.025 pick stands for the ungated transform.**

### Flag closure (2026-09-15)

Closes both arming flags above, plus one more configuration (R3) run to
separate what the gate delivers from what the log delivers, on the
identical r4828-r5077 window. Harness: `tools/ladder/standing_replay.py`
gained an `agg="sum"|"mean"` round-score-aggregation parameter (additive,
default `"sum"`, all 5 pre-existing tests unchanged); three new driver
scripts, `standing_sweep_win_injection.py`, `standing_sweep_sum_vs_mean.py`,
`standing_sweep_r3_raw_gate.py`. Read-only throughout — `grep -rn
"\.post(\|\.put(\|POST\|PUT" tools/ladder/*.py` returns no live-call hits
(only docstring/comment mentions of the served config).

#### (1) Win-injection (closes flag b)

Two designs, both bootstrapped over 30 (N0, seed) draws, run under R0
(raw, k=0.05) / R1 (`signed_log2`, k=0.025, ungated) / R2 (`signed_log2`,
k=0.02, win-gated). Calibration: top-quartile per-episode win rate
q3=0.0715; median winning raw leg=43; median non-winning raw leg=2.

**Design 1 — synthetic 17th entrant** (cold-starts at N0, wins each of 12
episodes/round independently at probability p; raw leg = win magnitude on
a win, loss magnitude on a loss):

| p | Rule | top-5, median [p10,p90] rounds (never-frac) | #1, median [p10,p90] rounds (never-frac) |
| --- | --- | --- | --- |
| q3 (0.0715) | R0 | never (100%) | never (100%) |
| | R1 | never (100%) | never (100%) |
| | R2 | 0 [0,0] (80%) | 0 [0,0] (80%) |
| 1.5×q3 (0.1072) | R0 | never (100%) | never (100%) |
| | R1 | 0 [0,0] (97%) | never (100%) |
| | R2 | 3 [0,78] (27%) | 0 [0,2] (60%) |
| 2×q3 (0.1429) | R0 | never (100%) | never (100%) |
| | R1 | never (100%) | never (100%) |
| | R2 | **0 [0,62] (0%)** | **0 [0,49] (13%)** |

**Design 2 — uplift a real ~rank-8 subject** (win probability redrawn at
baseline×{1.5,2} from N0; every real raw leg kept exactly as recorded):

| Uplift | Rule | top-5, median [p10,p90] (never) | #1, median [p10,p90] (never) |
| --- | --- | --- | --- |
| 1.5× | R0 | 7 [0,45] (10%) | 49 [0,118] (37%) |
| | R1 | 0 [0,15] (70%) | 85 [85,85] (97%) |
| | R2 | never (100%) | never (100%) |
| 2.0× | R0 | 7 [0,49] (3%) | 45 [0,65] (30%) |
| | R1 | 0 [0,13] (77%) | 88 [88,88] (97%) |
| | R2 | 29 [3,166] (87%) | never (100%) |

R0/R1's Design-2 rows are the subject's own real, unmanipulated trajectory
— the uplift is provably a no-op under ungated rules, since win/loss is
never read by `_round_score` when the raw legs themselves are unchanged —
reported only as the contrast point, not re-simulated per multiplier.

**Reading: the gate rewards winning big far more than winning often.**
Design 1's synthetic entrant (healthy win magnitude, 43 raw ≈5.46 bits/win)
reaches top-5 in 100% of draws and #1 in 87% at just 2×q3, often on round
0. Design 2's real subject reaches top-5 in only 13% of draws even at 2×
its baseline win rate, because its own real per-episode magnitudes (median
non-winning leg = 2) stay small even on the newly-counted "wins" —
winning more often at a small magnitude barely compounds.

**Why "round 0" is real, not a bug (platform-confirmed).** A first-round
entrant's standing is the round's own score, not `k × score`. Platform
(`~/projects/metta` origin/main,
`app_backend/src/metta/app_backend/v2/ladders/rankings/score.py`,
`apply_round`): `if ranking.rounds_played == 0: ranking.standing =
round_score`. Same rule in this harness,
`tools/ladder/standing_replay.py:552-562`: `if s is None or s == 0.0:
clipped = score` then `new_s = clipped if s is None else s + rated_k *
(clipped - s)`. At 2×q3, expected wins/round = 12×0.1429=1.715, each worth
`log2(44)≈5.46` bits, so an average FIRST round already scores ≈9.4 bits —
above rank-5's 6.41 bits and near rank-1's 9.95 (top-16 table, "Win-gated
extension" above) — a strong debut is an instant top-5 by construction,
not an injection error.

#### (2) Sum vs mean (closes flag a)

Re-ran R2@k=0.02 with `agg="mean"` (divide the kept legs' summed bits by
how many were kept) vs today's `agg="sum"`, same window:

| agg | tau | #1 chg/50 | leader share | standing scale: median/top, bits (un-logged) | rank1-5 gap, median bits [p10,p90] |
| --- | ---: | ---: | ---: | --- | --- |
| sum (today) | 0.9550 | 1.22 | 0.0519 | 5.41 (41.6) / 9.95 (988) | 3.09 [1.49,4.31] |
| mean | 0.9551 | 1.22 | 0.0516 | 0.454 (0.37) / 0.837 (0.79) | 0.258 [0.13,0.36] |

Identical ranking (tau/chg/share match to noise). **Why it's forced, not
coincidental — checked exactly, not assumed:** per-player-round leg counts
in this window are 9 (13 rows), 10 (78), 11 (147), **12 (1,702), 13
(2,734)** — `top_k=12` trims the 2,734 thirteen-leg rounds down to 12 by
dropping the SMALLEST value, which under the gate is essentially always
one of the zero (lost) legs, so `sum` is unaffected by that trim. For the
94.9% of player-rounds with exactly 12 or 13→12 kept legs, `mean =
sum ÷ 12` exactly — a constant divisor, a pure rescale that cannot move
any ranking-based metric (5.41→0.454 bits is exactly ÷12; the rank1-5 gap
shrinks by the same ÷12, 3.09→0.258). Only the remaining **5.1% (238/4,674
player-rounds)** have fewer than 12 legs, where `mean`'s divisor is
smaller than 12 and could in principle favor that round — the empirical
tau/#1-chg/leader-share (0.9550→0.9551, 1.22→1.22, 0.0519→0.0516) show
this minority case doesn't move the ranking either. Multi-win rate (a
player winning ≥2 episodes in one round, the only case `sum`/`mean` could
diverge on in kind) is **832/4,674 player-round pairs = 17.8%** — real and
non-trivial, but doesn't matter here because the denominator is
overwhelmingly the same constant regardless.

**Decision: KEEP `sum`.** Two wins in one round should read as two wins
added, not diluted toward a per-episode average; `sum` keeps that
legible. The compounding concern that motivated flagging this (an
un-logged standing near 1e12) is **R1-only** (ungated: all 12 real legs
contribute every round, so summing their logs really does log the
product) — under the gate, ~11 of 12 legs are already zero most rounds, so
there is little "product" left for `sum` to compound; switching to `mean`
here would only shrink the display, not fix a problem that exists
elsewhere.

#### (3) R3 — win gate on the raw rule (owner's revertibility question)

Today's R0 exactly (raw legs, sum-of-top-12, clip(s/150,s·150) except
first round, EMA) with the win gate applied to the raw legs and no log
transform — needs no `season_leg_transform` migration.

| k | clamp | tau | #1 chg/50 | leader share | median/top raw | rank1÷5 ratio, median [p10,p90] |
| ---: | --- | ---: | ---: | ---: | --- | --- |
| 0.02 | M=150 | 0.969 | 1.02 | 0.335 | 8,557 / 98,336 | 6.15 [3.67,26.22] |
| 0.025 | M=150 | 0.968 | 1.02 | 0.361 | 8,912 / 107,240 | 5.86 [2.96,28.66] |
| 0.05 | M=150 | 0.952 | 4.07 | 0.517 | 8,417 / 134,596 | 6.02 [2.80,23.88] |
| 0.02 | none | 0.967 | **4.67** | 0.332 | 24,938 / 107,468 | 1.75 [1.18,2.94] |
| 0.025 | none | 0.967 | 5.49 | 0.368 | 25,598 / 116,536 | 1.75 [1.31,2.95] |
| 0.05 | none | 0.961 | 7.72 | 0.489 | 18,396 / 142,185 | 2.25 [1.35,5.46] |

Top-5 @ k=0.02, M=150: Jordan (290w, 98,336), Lawrence (210w, 84,563),
daveey (262w, 46,453), @lessandro-forum-power-user (153w, 31,727),
softmaxclaudius-t2 (218w, 26,359).

**Finding: the clamp floor binds on 53.5% of eligible round-evaluations**
(53.4-54.1% across the swept k) — always at exactly `standing/150`
(floor_ratio_median = 0.006667 = 1/150 identically) — a fully-lost round
still banks 0.667% of the entrant's prior standing, over half the time it
happens. Disabling the clamp doesn't touch leader share (0.332 vs 0.335)
but makes #1 turnover clearly worse (4.67 vs 1.02 chg/50) — the clamp is a
rank-churn stabilizer here, not a spike suppressor.

**Verdict: the log, not the gate, does the anti-spike work.** R3@k=0.02
leader share **0.335** sits close to today's ungated baseline (0.314,
"Current-setting metrics" table above) and **~6.4x worse than R2@k=0.02's
0.052**. The gate alone actually improves tau/#1-chg slightly over R2
(0.969/1.02 vs 0.955/1.22) — it does fix rank churn — but single-round
domination is unresolved without the log transform.

#### Standings-rewrite irreversibility (next to the R2 recommendation)

Arming `season_leg_transform` runs the arm-migration
(`ladders/season_leg_transform_migration.py`) that rewrites EXISTING
standings, not just future rounds' inputs. The setting itself reverts by a
second POST from the pre-arm ("A-pre") snapshot; the rewritten standings
do **not** — reverting those requires
`app_backend/scripts/rollback_season_leg_transform_migration.py` with
production DB access. This is the concrete reason the owner's own pick was
rehearse-then-arm, not arm-directly. (Relayed for this record; this
worker's own read-only pass over a local `~/projects/metta` checkout did
not locate these two paths to independently re-cite file:line — flagged,
not silently dropped.)

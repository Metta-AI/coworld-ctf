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
| **rated_k** | 0.02 | 0.976 | 3.56 | 0.333 | never | 9 |
| | 0.035 | 0.963 | 6.32 | 0.316 | 103 | 0 |
| | **0.05 (current)** | **0.954** | **6.92** | **0.314** | **103** | **0** |
| | 0.075 | 0.939 | 9.88 | 0.341 | 103 | 0 |
| | 0.1 | 0.926 | 12.85 | 0.399 | 103 | 0 |
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
| log2 only | 0.942 | 9.49 | 0.043 | 48 | 0 |
| log2 + clamp_M=60 | 0.942 | 9.49 | 0.043 | 48 | 0 |
| **log2 + rated_k=0.035** | **0.960** | **7.51** | **0.061** | **48** | 0 |

`log2 + clamp_M=60` is **identical** to `log2` alone — once magnitudes are
log-compressed, a round-over-round swing of 60x in *log-space* essentially never
happens, so the clamp stops binding. Tightening the clamp is redundant once the
transform is in place; **only one of the two levers is needed.**

`log2 + rated_k=0.035` is the best of the three: it recovers the top-tier tau
that `log2` alone gives up (0.960, better than today's 0.954) and cuts the
leader-change rate from log2-alone's 9.49/50 back toward today's baseline
(7.51/50), while keeping log2's full anti-spike effect (share 0.061, still 5x
better than today) and its *faster*, not slower, responsiveness (48 rounds, same
as log2 alone, versus today's 103).

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
| log2 + rated_k=0.02 | 0.979 | 5.73 | 0.059 | 103 | 0 |
| log2 + rated_k=0.025 | 0.979 | 4.74 | 0.060 | 96 | 0 |
| log2 + rated_k=0.03 | 0.970 | 8.89 | 0.061 | 49 | 0 |
| log2 + rated_k=0.035 (from table above) | 0.960 | 7.51 | 0.061 | 48 | 0 |

The 0.025 row was first surfaced by two uncommitted 2026-09-09 ad-hoc re-runs
of this same script (preserved with raw JSON and scripts at
`~/.ctf/knowledge/glory-gradient/00e-sweep-raw-runs/{sweep-slow,sweep-f1}/`);
this section commits that row, plus 0.02 and 0.03 for a complete picture of
the interval, as the doc's own record.

**Leader-share definition, stated explicitly.** `leader_best_round_share()`
always decays contributions using the served-default `rated_k=0.05` (the
module constant `CURRENT["rated_k"]`), **not** the row's own swept `rated_k`
— so every non-0.05 `rated_k` row in this document (all rows in this table,
plus the `rated_k` axis rows and the `log2 + rated_k=0.035` row above) reports
leader share decayed at 0.05, never at that row's own rate. This is a **bug
in the helper, not a design choice**, confirmed by direct inspection
(`tools/ladder/standing_replay.py:452-473`) and by reproduction: it is the
full explanation for the 2026-09-09 disagreement where two ad-hoc scripts
reported 0.060 vs. 0.032 for the identical `log2 + rated_k=0.025` setting.
The `sweep-slow` script called the shared helper as-is and got 0.060 (matches
this table exactly). The `sweep-f1` script independently reimplemented the
decay using the row's actual k=0.025 and got 0.032; patching the helper to
accept the swept k and re-running against the same ledger reproduces
0.031876310968393766, matching `sweep-f1`'s figure to 6 significant figures.
Both preserved runs were internally correct given what each one actually
computed — the discrepancy is a latent parameter-threading bug, not noise and
not two valid definitions. No fix is applied to the helper in this PR (this
section extends the doc, it does not change tool behavior or retroactively
recompute the rows above); a future change to thread the swept `rated_k`
through `leader_best_round_share` would alter every non-0.05-`rated_k` share
value already committed in this file, so it should be its own reviewed step.

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

- Leader's single-round dependency: 31.4% → 6.1%
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

`python3 -m pytest tools/ladder/test_standing_replay.py -q` → **4 passed**.
Fixture: `tools/ladder/testdata/standing_fixture.json` (first 15 rounds of the
real pull, r4257–r4271). Covers: exact reproduction of pinned standings on the
fixture; the clamp's one-round-move bound (`1+k(M-1)`) holding on the fixture's
real 2^24 leg at r4258; the rank-points transform staying bounded at [0,25].

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
  criterion is a single-run, single-seed result on one real ledger window; it
  was not re-verified against a second ledger pull or an independently
  re-derived `mid_subject`/`top_subject` pair, and `up=103` is an exact tie
  against the baseline rather than a comfortable margin. The
  `leader_best_round_share()` decay-constant bug is confirmed by direct code
  inspection and reproduction of both preserved figures, but no fix was
  written or tested — only documented.

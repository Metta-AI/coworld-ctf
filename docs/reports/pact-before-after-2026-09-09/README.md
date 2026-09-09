# Monet pact before/after dataset (2026-09-09)

This dataset measures Monet's (our Season 2 Paintbot policy's) pact
behavior and ladder outcomes across policy versions spanning the
2026-09-09 pact fixes: v44 (the pre-fix baseline), v45, v46, v47, v48,
v49 (a full n=717 ladder read across rounds 4545-4603), v50 (an
interim n=47 read across rounds 4607-4610 -- the first version where the
final-four detour clamp actually reaches the wire), and v53 (an interim
n=48 read across rounds 4620-4623, GloryVersion 17 -- `fire_superiority`'s
`engageDist` doctrine raised 600->750, compared against a freshly-computed
pooled pre-v53 GV17 baseline, v51+v52, n=88; see the GameVersion-62 (GV17)
era note below). "Pact" here means the
in-game alliance mechanic: two teams declare each other as partners and,
once the declaration is mutual, hold fire and can act jointly for the rest
of the episode.

## How this was measured

Every number in this dataset comes from real hosted league replays and
policy logs on disk, not from local simulation:

- **Outcomes (win, rank, score-ratio)** are read directly from the
 league API's own per-episode results (participant scores, win flags),
 the same source the platform itself uses to settle the round. They do
 not depend on replay decoding succeeding.
- **Pact mechanics (declared, formed, JointAct count, kickoff coverage)**
 are read by decoding the actual hosted replay with the era-matched
 decoder binary (a GloryVersion 15 decoder for the early post-fix window,
 a GameVersion 60 decoder from round 4529 on) and scanning the decoded
 event stream for the game's own pact-declare and pact-formed events.
- **What Monet itself committed (wire-declared partners, partner counts,
 the reason Monet named a given partner)** comes from the policy's own
 committed-call log for that episode (the wire log), independent of
 whether the replay decodes.
- **Score-ratio** is our team's score divided by the median score of all
 participants in that same episode (paired against the same-round field,
 not a cross-round average) -- this is what makes score-ratio comparable
 across rounds with different maps and lobbies.

## The era caveat (read this before comparing v44 to anything else)

Two different engine rule sets are represented here, and they are **never
pooled together** in this dataset:

- **pre-GloryVersion-15** (v44's main baseline, rounds 4499-4513, engine
 builds up to 0.7.360): a joint-action reward could be earned by any
 two-team co-fire, with no pact required.
- **post-GloryVersion-15** (first round 4515, engine 0.7.361 on): the same
 reward is gated on an active pact between the two teams.

Because of this, v44's JointAct-per-episode number is **not** comparable
to v45 and later on that one axis -- it looks high only because the reward
paid for free before the gate existed. Everywhere this matters, this
dataset also carries a same-era control cohort, **v44_gv15_control**
(same v44 build, but the 25 episodes it played after the GloryVersion-15
gate went live, rounds 4515-4516) -- using this control shows v44 also
drops to zero JointAct/episode once the gate applies, confirming the gap
between v44 and v45 on that one metric is an era artifact, not a real
regression.

A second, smaller engine bump (GameVersion 59 to 60, at round 4529) is
perception-only (a new visibility label) and does not change scoring or
pacts; episodes on either side of it are pooled together in this dataset.

## The GameVersion-61 (GV16) era note, inside v49

A third engine change lands inside the v49 read itself, at round 4552:
engine builds 0.7.369-0.7.374 carry GameVersion 61 ("GV16"), which wires
six level-up combat buffs into the fight system. The pact mechanic and the
scoring formula are both untouched by this change, but fights now run
roughly 2.3x longer on average. Rounds 4545-4551 (engine 0.7.367,
GameVersion 60) are pre-GV16; rounds 4552-4603 are post-GV16. This dataset
reports both a pooled v49 row and the two era-split rows
(`v49_pre_gv16`, `v49_post_gv16`) in `summary.csv` and `episodes.csv`.
v50's entire read window (rounds 4607-4610) sits inside this same GV16 era
(builds 0.7.375-0.7.376, both a strict superset of 0.7.374's GameVersion,
confirmed unchanged via `sim_types.nim`), so v50 needs no era split -- its
one `summary.csv`/`episodes.csv` row is directly comparable to
`v49_post_gv16` and nothing else.

**What is comparable across this seam and what is not:** win rate,
rank<=4, and score-ratio are all read from the API's own per-episode
results, independent of fight length, so they compare cleanly across GV16
and against v48. Deed-rate metrics (`tags_per_ep_*`, `jointact_per_ep`)
are **not stationary** across this seam purely because of longer fights
producing more scoring opportunities per episode, not because of any pact
or scoring change -- treat a shift in those two columns between the
pre/post-GV16 rows as a fight-length artifact, not a policy effect.

## The GameVersion-62 (GV17) era note, starting v53

A fourth engine change, larger than GV16's, lands at round 4611:
GameVersion 61->62 / GloryVersion 16->17 (PR #504, source `e6807465`),
catalog-v3 reprice default ON for battle-royale-s2 -- a real scoring-
formula change (a parallel percent-scaled fixed-point fold alongside the
old whole-integer path; `dLongshotKill` reprices 3x->6x; a new
`survivalCredit` wire deed). `ReplayCompatibleGameVersions` was replaced
to exactly `["62"]`, so GV16 and GV17 replays are decoded with different
binaries and are **never pooled** in this dataset. v53 is the first
version read in this era: pv `a3479a93` (platform 54), rounds 4620-4623,
n=48, compared against a pooled pre-v53 GV17 baseline built the same way
for this read -- v51 (pv `3307ac7c`, rounds 4613-4616, n=50) + v52
(pv `a77e7f6d`, rounds 4617-4619, n=38) = n=88, identical fire doctrine
except `engageDist` (600, vs v53's 750). **v51 and v52 are not
independently included as their own rows in `summary.csv`/`episodes.csv`**
(only v53 is, per this read's brief) -- the pooled baseline numbers live
in v53's own `READ_N40.md` and source JSON under
`/tmp/monet_v53/read/baseline_v51v52_*.json`, not in this dataset's CSVs.
Two newer builds surfaced mid-window (0.7.378, 0.7.379); both were
independently verified via `gh api .../compare/e6807465...<sha>` to be
GameVersion/GloryVersion-unchanged (a dark/unarmed achievements PR plus a
pure-docs commit), so all 48 v53 episodes decode with the same GV17
binary and none were excluded on that basis.

## What changed, one line per version

- **v45** -- Monet started naming real rival team names as pact partners
 instead of a placeholder, so a wire-declared pact could actually match a
 real opponent.
- **v46** -- Monet re-affirms its partner list once the match itself
 starts (not only before it), and only holds fire on a partner who has
 named Monet back.
- **v47** -- a harness-level re-emit of the committed pact at the first
 in-match tick, plus raising the partner cap from 3 to 5.
- **v48** -- a re-sync fix so that re-emit fires on every episode, not only
 some.
- **v49** -- no loot detours once only four teams remain. Now read at
 n=717 (rounds 4545-4603): the clamp never armed in any episode (0/717
 reached the final four with a detour attempted), so on the ladder v49
 is functionally v48 for this one mechanic -- the fix is shipped and
 harmless, but has not yet been exercised by a real final four.
- **v50** -- dropped the gate that kept v49's final-four clamp from ever
 arming (the gate required the zone-ring endgame to be inactive, which in
 practice always overlapped with reaching the final four, so the clamp
 code was unreachable). Read at n=47 (rounds 4607-4610): the clamp now
 reaches the wire -- the policy's own "final4" phase line fires in 11/47
 episodes, 100% of the 8/47 where a second, independent log signal
 (Monet's periodic "Teams still alive" line) also confirms alive_teams<=4
 while Monet was still alive. A known follow-up gap reproduces at this
 n: a separate harness code path ("ladder maintenance", used to re-sync
 pact partners) can re-install an uncapped loot/supply_run detour after
 the clamp has already fired, in 3 of the 11 phase-reached episodes (real,
 multi-second exposure in 1 of the 3; near-zero in the other 2 because the
 episode ended immediately after). Win/rank/formed/kickoff are all flat
 vs `v49_post_gv16` at this n; the final-four engagement-initiative and
 P(F2|F4) metrics this fix specifically targets have not moved yet either,
 but the F4-reached sub-sample is small (n=11-17) -- see `v50`'s row in
 `summary.csv` for the exact figures and `READ_N40.md` under
 `/tmp/monet_v50/read/` for the full read.
- **v53** -- `fire_superiority`'s `engageDist` doctrine raised 600->750
 (GV17 era, platform 54). Read at n=48 (rounds 4620-4623) against a
 pooled pre-v53 GV17 baseline (v51+v52, n=88, identical doctrine except
 `engageDist`): shots fired/ep is flat (3.208 vs 3.114), range shots
 (>=866px, the live map's longshot line)/ep is slightly down (0.313 vs
 0.375) but conversion-to-kill on those shots is up (26.7% vs 12.1%) and
 `dLongshotKill` tags/ep are up 2.3x (0.104 vs 0.045), while
 `dHonorableKill` tags/ep drop by more than half (0.083 vs 0.273) --
 consistent with engaging from farther out trading close-range kills for
 longshot-class ones. Final-four initiative (engaged-first share 41.2%
 vs 32.0%) and P(F2|F4) (72.2% vs 53.1%) both trend up but on small
 F4-reached sub-samples (n=17-18), not distinguishable from noise.
 **Rollback trigger B (rank<=4 down, p<0.10) FIRED**: rank<=4 dropped to
 22.9% (11/48) from the baseline's 44.3% (39/88), p=0.0157 -- reported
 informational-only per this read's brief (n=48<100), not acted on, but
 flagged as the header follow-up before any keep/ship call. See `v53`'s
 row in `summary.csv` and `/tmp/monet_v53/read/READ_N40.md` for the full
 read.

## The field reference: how often rivals form pacts, and when

Across the same 48-episode v45 cohort, the rest of the field (all other
teams, not Monet) formed 47 mutual pact pairs across 28 of the 48
episodes -- the mechanism clearly works when both sides are set up to use
it. Of those pairs, 77% declare at the exact tick the match's active
phase begins, not scattered earlier during the pre-match huddle. The root
cause of Monet's early gap: the game engine only registers a pact
declaration once the match has actually started (its "Playing" phase);
Monet's own declarations, before the v46 fix, were only ever committed
before that phase began, so they were structurally invisible to the
engine's own pact-formed check even though the wire log showed Monet
"declaring." Rivals with a live, current commit at the moment play starts
get theirs registered; Monet, declaring only pre-match, did not.

## Files

- `summary.csv` -- one row per version (or control cohort), aggregate
 metrics with confidence intervals where available.
- `episodes.csv` -- one row per episode, merged across all nine read
 cohorts (v44_baseline, v44_gv15_control, v45, v46, v47, v48, v49, v50,
 v53). v49's 717 rows carry `era` = `GV15` or `GV16` per round (see the
 GV16 era note above); `v49_pre_gv16` / `v49_post_gv16` in `summary.csv`
 are the same 717 episodes split on that boundary, not a separate read.
 v50's 47 rows are all `era` = `GV16` (see the v50 era note above). v53's
 48 rows are all `era` = `GV17` (see the GV17 era note above); v51/v52
 (the pooled pre-v53 GV17 baseline) are NOT included as their own rows.
- `REPORT.md` / `REPORT.html` -- the before/after narrative, funnel table,
 outcome table, and one chart (`REPORT.html` only).
- `CHECKS.md` -- independent recomputation of n / formed-count / win-count
 from `episodes.csv`, checked against each version's own metrics file.

## Column dictionary

### summary.csv

| column | meaning |
|---|---|
| `version` | internal read-cohort label (`v44_baseline`, `v44_gv15_control`, `v45`..`v48`, `v49`, `v49_pre_gv16`, `v49_post_gv16`, `v50`, `v53`) |
| `platform_version` | the ladder's own policy-version number, where a source file states it explicitly; "n/a" / "(inferred...)" otherwise -- see CHECKS.md |
| `policy_version_id` | first 8 hex characters of the full policy-version UUID |
| `rounds` | the round-number range the n episodes were drawn from |
| `era` | which engine rule era (pre/post GloryVersion 15, and GameVersion where relevant) |
| `n` | completed episodes read |
| `declared_wire_pct` | % of episodes where Monet's own committed call named at least one pact partner |
| `declared_sim_pct` | % of episodes where the game engine's own event log recorded Monet actually declaring in-sim (requires the post-match-start registration point); "n/a (pre-GV15)" where the mechanism did not yet exist to measure |
| `formed_pct` | % of episodes where a pact became mutual (both sides recorded the declare) |
| `kickoff_coverage_pct` | % of episodes where Monet's re-affirm-at-match-start line fired (v46+ only) -- **two different sub-definitions live under this one column name**: v46/v47 count the strict `reason=kickoff` label only (rare, ~8%, the natural first-call case); v48/v49/v50 count the broader `reason=kickoff-reemit` label (the harness's synthetic re-emit introduced in v47, ~83-92%). Do not read a jump between v47 and v48 on this column as the mechanism suddenly working 10x better -- it is a metric-definition change, not a policy change. v50 uses the same `kickoff-reemit` definition as v48/v49, so it IS comparable to those two. v53 reuses `tags_and_kickoff_final.py`'s own regex (`reason=` followed by `[a-zA-Z_]+`, which truncates `kickoff-reemit` at the hyphen to `kickoff`), so it counts both the strict and reemit reason strings under one umbrella -- its 77.1% is in the same broad-definition family as v48-v50 and directly comparable to them, and to the freshly-computed pooled v51+v52 GV17 baseline (79.5%), which used the identical script. |
| `partners_per_commit` | mean number of partner seats named per committed pact-aim line |
| `jointact_per_ep` | mean count of the joint-action reward event credited to Monet per episode (see era caveat above) |
| `tags_per_ep_mean` / `_median` | mean/median count of scoring "tag" events credited to Monet's seat per episode |

**Tags-definition note (v49):** the source read pipeline's own headline
v49 figure (`tags/ep mean 0.556`, see `V49_FULL_TABLE.md` /
`v49_full_report.json` under `/tmp/monet_v49/read/`) used a narrower deed
filter than every other version in this dataset. v44/v45/v46/v48 all use
the same definition, `tags_and_kickoff_final.py`'s `tags_per_ep()`: count
every decoded `glory_deed` event with `source == our_position`, of any
deed kind (kills, level-ups, final-N placement deeds, etc, not only a
narrow "tag" kind), per episode. The `tags_per_ep_mean` / `_median` /
`share_2plus_tags_pct` values reported here for v49, v49_pre_gv16 and
v49_post_gv16 were recomputed with that exact same function pointed at
`v49_full_rows.json` + the decoded replay cache, so they are comparable
to v44 through v48 on this column -- do not use the 0.556 figure from the
source pipeline's own v49 report, it is a different, narrower metric.
| `share_2plus_tags_pct` | % of episodes with 2 or more tags credited |
| `win_pct` (+ CI) | % of episodes Monet's team won, with 95% CI |
| `rank4_pct` (+ CI) | % of episodes Monet placed in the top 4, with 95% CI |
| `score_ratio_median` (+ CI) | median of (our score ÷ same-episode field median score), with bootstrap 95% CI |
| `verdict` | the read pipeline's own keep/rollback/informational call for that cohort |

### episodes.csv

| column | meaning |
|---|---|
| `version` | which read cohort this episode belongs to |
| `platform_version` | see above |
| `round` | league round number |
| `episode_id` | episode UUID |
| `engine_version` | coworld/game build string for this specific episode |
| `era` | engine rule era for this episode |
| `declared_wire` | True/False -- Monet's committed call named a pact partner |
| `declared_sim` | True/False -- the game engine recorded Monet's in-sim declare; `n/a_pre_gv15` where the mechanism did not exist yet |
| `formed` | True/False -- a mutual pact formed |
| `partners_named` | total partner-seat mentions summed across all of Monet's pact-aim commit lines in the episode; `n/a_not_tracked` for v44_baseline where this was not recorded |
| `kickoff_present` | True/False -- Monet's re-affirm-at-match-start line fired; `n/a_pre_v46` where the feature did not exist yet |
| `tags` | `n/a_not_exported` for every row -- only the population-level aggregate (`tags_per_ep_*` in summary.csv) was computed by the source pipeline, never a per-episode count |
| `jointact` | count of the joint-action reward event credited to Monet this episode |
| `win` | True/False |
| `rank` | 1-indexed placement among the episode's field by score |
| `score` | `n/a_not_exported` for every row -- raw scores were not exported, only the ratio below |
| `score_ratio` | our score ÷ median score of the same episode's field |
| `decode_ok` | True/False -- the era-matched replay decoder read this episode cleanly; `n/a_not_tracked` for v44_baseline where decode-failure counts were not recorded by that era's pipeline |

## Known gaps (see CHECKS.md for the full list)

- v47 is a genuine interim read at n=12 (target was n>=40); its numbers
 are point estimates only and should not be treated as a settled
 before/after comparison.
- v48 is an interim read at n=37 (target was n>=40, missed by 3); the
 positive direction (pact-formed and win rate both up) is consistent
 with v46's own finding, but is not yet the final read for that cohort.
- v49 is now a full read (n=717, 0 decode failures) and is included in
 `episodes.csv`; it pools GV15 and GV16 engine eras (see the GV16 era
 note above) and its final-four detour clamp never armed (0/717), so it
 reads as functionally-v48 on the ladder for that one mechanic.
- `platform_version` for v45 could not be found in any source file read
 for this dataset (see CHECKS.md).
- v50 is an **interim** read at n=47 (meets the n>=40 floor, but marked
 interim because it is a single read of a mechanism that only just started
 arming, with an open follow-up gap): the final-four clamp reaches the
 wire for the first time (11/47 phase-line fires), but a ladder-
 maintenance-resend path can still leak an uncapped detour past it (3/11
 phase-reached episodes, real exposure in 1 of the 3). The F4-outcome
 metrics (engaged-first share, P(F2|F4)) this fix targets are read on a
 small sub-sample (n=11-17 F4-reached episodes) and have not shown a
 measurable move yet vs `v49_post_gv16`. See `/tmp/monet_v50/read/
 READ_N40.md` for the full read.
- v53 is an **interim** read at n=48 (meets the n>=40 floor; single read,
 GV17 era, GameVersion/GloryVersion confirmed unchanged across two newer
 builds seen mid-window via `gh compare`). The engagement-composition
 shift it targets shows up as expected (range-shot conversion and
 longshot tags/ep both up, honorable tags/ep down), and F4 initiative/
 P(F2|F4) trend up, but both on small F4-reached sub-samples (n=17-18).
 **Rollback trigger B fired** (rank<=4 22.9% vs the pooled v51+v52
 baseline's 44.3%, p=0.0157) -- reported informational-only per this
 read's brief (n<100), not acted on here (report only, no champion
 changes), but it is the header follow-up: get a larger same-era read
 before treating this cohort as a clean win. See `/tmp/monet_v53/read/
 READ_N40.md` for the full read.

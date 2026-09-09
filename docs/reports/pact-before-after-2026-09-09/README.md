# Monet pact before/after dataset (2026-09-09)

This dataset measures Monet's (our Season 2 Paintbot policy's) pact
behavior and ladder outcomes across six policy versions spanning the
2026-09-09 pact fixes: v44 (the pre-fix baseline), v45, v46, v47, v48, and
a first-round verification pass on v49. "Pact" here means the in-game
alliance mechanic: two teams declare each other as partners and, once the
declaration is mutual, hold fire and can act jointly for the rest of the
episode.

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
- **v49** -- no loot detours once only four teams remain (this only
 matters in the final four, which no sampled v49 episode reached yet).

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
- `episodes.csv` -- one row per episode, merged across all six read
 cohorts (v44_baseline, v44_gv15_control, v45, v46, v47, v48). v49 is
 excluded (no per-episode rows export exists yet, see REPORT.md caveats).
- `REPORT.md` / `REPORT.html` -- the before/after narrative, funnel table,
 outcome table, and one chart (`REPORT.html` only).
- `CHECKS.md` -- independent recomputation of n / formed-count / win-count
 from `episodes.csv`, checked against each version's own metrics file.

## Column dictionary

### summary.csv

| column | meaning |
|---|---|
| `version` | internal read-cohort label (`v44_baseline`, `v44_gv15_control`, `v45`..`v48`, `v49`) |
| `platform_version` | the ladder's own policy-version number, where a source file states it explicitly; "n/a" / "(inferred...)" otherwise -- see CHECKS.md |
| `policy_version_id` | first 8 hex characters of the full policy-version UUID |
| `rounds` | the round-number range the n episodes were drawn from |
| `era` | which engine rule era (pre/post GloryVersion 15, and GameVersion where relevant) |
| `n` | completed episodes read |
| `declared_wire_pct` | % of episodes where Monet's own committed call named at least one pact partner |
| `declared_sim_pct` | % of episodes where the game engine's own event log recorded Monet actually declaring in-sim (requires the post-match-start registration point); "n/a (pre-GV15)" where the mechanism did not yet exist to measure |
| `formed_pct` | % of episodes where a pact became mutual (both sides recorded the declare) |
| `kickoff_coverage_pct` | % of episodes where Monet's re-affirm-at-match-start line fired (v46+ only) |
| `partners_per_commit` | mean number of partner seats named per committed pact-aim line |
| `jointact_per_ep` | mean count of the joint-action reward event credited to Monet per episode (see era caveat above) |
| `tags_per_ep_mean` / `_median` | mean/median count of scoring "tag" events credited to Monet's seat per episode |
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
- v49 has no per-episode rows export; only a first-round, 8-episode
 ship-verification pass exists at the time of this dataset. It is
 reported in `summary.csv` with a verdict but excluded from
 `episodes.csv`.
- `platform_version` for v45 could not be found in any source file read
 for this dataset (see CHECKS.md).

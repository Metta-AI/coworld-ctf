# Monet pact fixes: before/after, 2026-09-09

Full dataset and column definitions: `README.md`, `summary.csv`,
`episodes.csv`. Independent recomputation check: `CHECKS.md`. Chart
(formed % and win % by version): `REPORT.html`.

All numbers below carry their episode count (n), round range, and engine
era; confidence intervals are given where the source pipeline computed
one. No number here is pooled across the pre/post GloryVersion-15 engine
boundary (see README's era caveat).

## a. The funnel: wire-declared to sim-declared to formed to kickoff coverage

| version | rounds | n | wire-declared | sim-declared | formed (mutual) | kickoff coverage |
|---|---|---|---|---|---|---|
| v44 (pre-fix) | 4499-4513 | 172 | 14.5% (25/172) | n/a (pre-GV15) | 3.5% (6/172) | n/a (feature didn't exist) |
| v44_gv15 control | 4515-4516 | 25 | 12.0% (3/25) | 12.0% (3/25) | 4.0% (1/25) | n/a (feature didn't exist) |
| v45 | 4517-4526 | 106 | 95.3% (101/106) | 12.3% (13/106) | 4.7% (5/106) | n/a (feature didn't exist) |
| v46 | 4527-4534 | 96 | 95.8% (92/96) | 18.8% (18/96) | 9.4% (9/96) | 8.3% (8/96) |
| v47 (interim, n=12) | 4535-4536 | 12 | 100% (12/12) | 16.7% (2/12) | 0.0% (0/12) | 8.3% (1/12) |
| v48 (interim, n=37) | 4540-4542 | 37 | 100% (37/37) | 100% (37/37) | 29.7% (11/37) | 91.9% (34/37) |
| v49 (pooled, GV15+GV16) | 4545-4603 | 717 | 95.8% (687/717) | 95.8% (687/717) | 27.6% (198/717) | 83.1% (596/717) |

Also cited: the small pre-fix sample recorded before this pipeline existed
(`monet-pact-baseline-2026-09-09.md`): 37 episodes, wire-declared in 4/37,
formed in 0/37 -- consistent in direction with the 172-episode v44 baseline
above (both single-digit declare, near-zero formed).

Reading the funnel: v45's fix (naming real partners instead of a
placeholder) is what moves wire-declared from ~14% to ~95%+ -- Monet is now
committing a real, matchable partner nearly every episode. But
sim-declared stays low through v45 and v46 (12-19%) because most of those
wire commits still land before the match's active phase starts, where the
game engine does not register them (see README's field-reference section).
v48's re-sync fix is what finally closes that gap: sim-declared jumps to
100% and formed nearly triples versus v46 (29.7% vs 9.4%).

## b. The outcome table: win, rank<=4, score-ratio, tags/episode

| version | n | win % [95% CI] | rank<=4 % [95% CI] | score-ratio median [95% CI] | tags/ep (mean) |
|---|---|---|---|---|---|
| v44 (pre-fix) | 172 | 7.0% [4.0, 11.8] | 24.4% [18.6, 31.4] | 1.00 [0.86, 1.33] | 0.70 |
| v45 | 106 | 4.7% [2.0, 10.6] | 21.7% [14.9, 30.5] | 0.76 [0.67, 1.27] | 1.55 |
| v46 | 96 | 1.0% [0.2, 5.7] | 30.2% [21.9, 40.0] | 1.00 [0.80, 2.00] | 1.83 |
| v47 (interim, n=12) | 12 | 8.3% [1.5, 35.4] | 50.0% [25.4, 74.6] | 4.67 [1.50, 320] | 3.58 |
| v48 (interim, n=37) | 37 | 10.8% [4.3, 24.7] | 32.4% [19.6, 48.5] | 1.33 [0.67, 2.67] | 2.00 |
| v49 (pooled, n=717) | 717 | 3.6% [2.5, 5.3] | 23.6% [20.6, 26.8] | 1.00 [1.00, 1.00] | 1.64* |

None of the pre-registered rollback triggers (score-ratio 95% CI upper
bound under 1.0 at n>=100, or a significant drop in rank<=4 versus the
prior baseline) fired at any read point through v48. Win rate dipped at
v46 (1.0%) before recovering by v48 (10.8%); rank<=4 and tags/episode both
trend up from v44 through v48. v47's outcome numbers (n=12) carry
confidence intervals wide enough that they should be read as a single
noisy data point, not a trend.

*v49's tags/ep (1.64) is recomputed with the same per-episode deed-credit
definition used for every other row here (any glory_deed event credited to
Monet's own seat), after the source pipeline's own headline v49 figure
(0.556) turned out to use a narrower deed filter -- see README's
tags-definition note. Neither rollback trigger fired for v49 either, at
n=717 or in either era split.

## c. Field reference: how the rest of the field forms pacts

In the same 48-episode v45 cohort used for the reciprocity study, rival
teams (not Monet) formed 47 mutual pact pairs across 28 of the 48
episodes -- the mechanism works reliably for the field. Of those pairs,
77% both declare at the exact tick the match's active phase begins,
concentrated at match-start rather than spread through the pre-match
huddle. This is the same registration point Monet's pre-v46 declarations
missed: the game engine only records a pact declaration once the match is
actually underway, and Monet's commits, before the v46 fix, were only
ever made before that point.

## d. What changed, one plain sentence per version

- **v45**: Monet started naming real rival team names as pact partners,
  instead of a placeholder that could never match a real opponent.
- **v46**: Monet re-affirms its partner list once the match itself starts,
  and only holds fire on a partner who has named Monet back.
- **v47**: a harness-level re-emit of the committed pact at the first
  in-match tick, plus a higher partner cap (3 to 5).
- **v48**: a re-sync fix so the re-emit fires on every episode, not just
  some of them.
- **v49**: no loot detours once only four teams remain. Now read at n=717
  (rounds 4545-4603): the clamp never armed in any episode (0/717 reached
  the final four with a detour attempted), so v49 is functionally v48 on
  the ladder for this one mechanic.

## e. Caveats

- **n and era**: v44's 172-episode baseline is entirely pre-GloryVersion-15
  (the joint-action reward paid without a pact); every version from v45 on
  is post-GloryVersion-15 (the reward requires an active pact). The
  same-era v44_gv15_control (n=25) confirms the resulting JointAct/episode
  gap between v44 and v45+ is an engine-era artifact, not a v45 effect.
- **v47 is not a readable result.** n=12 versus a target of n>=40; the
  policy version was benched by the ladder scheduler after a single round
  before more episodes could accumulate. Treat every v47 number as an
  informational point estimate only.
- **v48 is interim, not final.** n=37 versus a target of n>=40 (3 short);
  polling budget was exhausted before the next round closed. Direction is
  positive and consistent with v46's own finding, but this is not the
  closed-cohort number.
- **v49 is now a full ladder read** (n=717, rounds 4545-4603, 0 decode
  failures). It pools two engine eras that are never pooled elsewhere in
  this dataset outside the v49 rows: GameVersion 60 (GV15, rounds
  4545-4551, n=80) and GameVersion 61 (GV16, rounds 4552-4603, n=637,
  six level buffs live, fights run roughly 2.3x longer). Win rate,
  rank<=4 and score-ratio compare fine across that seam (pooled and both
  era splits are all in `summary.csv`); deed-rate metrics (tags/ep,
  JointAct/ep) are not stationary across it because they scale with
  fight length, not the pact mechanic. The final-four detour clamp v49
  introduced never armed (0/717), so on the ladder v49 is functionally
  v48 for that one mechanic.

## f. Chart

See `REPORT.html` for an inline chart of pact-formed % and win % by
version, with n labeled under each version.

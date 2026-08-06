# Merge order for the rest of epic 3757029c — this is load-bearing

Epic owner, 2026-08-06. Getting this wrong costs a second full fixture re-record, which is the
single most expensive mechanical step left in the epic.

## The order

    1. archetypes            (10fc7a24)  MAP-CHANGING, Lane A serial, in flight
    2. corridor floor        (49cb2dce)  MAP-CHANGING, Lane A serial, not started
    3. pit expectations      (78d0db3c)  test re-pins, in flight
       sightline diagnostic  (5aad43b3)  test re-pins, in flight
    4. pool re-curation      (c752704b)  re-curate + re-pin render hashes + pool-review.html
    5. GV39 fairness         (d768ba09)  GameVersion bump + FULL fixture re-record -- LAST

## Why GV39 goes last, and why it is currently mis-sequenced

`maxwell/mapgen-gv39-fairness` has 8 commits and has ALREADY done a re-record and ALREADY re-pinned
the pool render hashes (commit 4bad92c), against a base from before W0, the small-board fix, the
city clipping and the corrected measuring stick all landed. **Every one of those changed which map
a seed produces**, and the corrected stick additionally changed which candidate best-of-K SHIPS.
So those pins are stale and the re-record has to happen again.

That is not the branch's fault — it was started deliberately in parallel because a fixture
re-record is the longest pole in the epic, and the fairness diagnoses it carries are correct and
independent. But the ORDER matters now: a GameVersion bump must be the last map-affecting thing to
land, because its whole cost is proportional to how many maps changed since it was recorded.

**Do not merge it half-done.** A partial bump with un-re-recorded fixtures strands every replay.
Better to hand back an unfinished branch with an honest status than to merge a broken one.

## Why the pool goes after the map-changing work

`c752704b` re-curates the pool, re-pins 20 crc32 render hashes and regenerates
`docs/pool-review.html` (which AGENTS.md requires to ship with any pool/generator change, and which
is currently stale — last regenerated at 1dcbb01, before the rewrite landed). All three outputs are
functions of the generated maps. Running it before archetypes and the corridor floor land means
doing it twice, and the task's own description says so.

It also owns 2 of the 5 remaining suite failures (`shared pool rendering matches the pre-extraction
images`, `the curated pool sits below the hand-authored control`), so **the suite cannot reach zero
until it runs**. That is the tension: suite-zero wants it early, cost wants it late. Late is
correct — a green suite pinned to maps that are about to change is not a green suite, it is a
re-pin waiting to fail.

## The rule this encodes

Order by PERISHABILITY, not by readiness. Work whose output is a function of the generated maps
(fixtures, render hashes, curated pools, baselines) must land after the work that changes the
generated maps, no matter which finished first.

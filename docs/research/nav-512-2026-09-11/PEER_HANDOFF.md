# Peer handoff: nav-512 research complete

Written at the close of the resumed navigation campaign (2026-09-11).
Nothing in this file authorizes a budget change, a publication or a
merge.

## Where the final candidate lives

- **Final research source checkpoint: root `c651dec9`** (root worktree
  `nav-budget-screen`, branch `james/nav-budget-screen`, local only, on
  top of the `origin/main 58e6c947` merge). It carries H1 (hole-based
  heap sifts), H2 (clearance certificate for `segmentClear`) and H3
  (eleven frameless inline helpers) plus documentation nits, with the
  production default still `ColdPlanBudgetPerTick = 256`. The root has
  since merged newer `origin/main` (HEAD `a8e713ba` at the time of
  writing) and is committing the final evidence; runtime sources were
  verified unchanged between `58e6c947` and the later upstream commits.
- **This peer tree is not the final candidate.** Its committed state is
  `e730021a` (H1 only, with the heap oracle tests). Its working tree adds
  H2 uncommitted (`src/shell/body_planner.nim`, the segment oracle
  `tests/body_segment_reference.nim`, `tests/test_shell_body_segment_exact.nim`,
  `tests/shard_2.nim`). It contains **no H3 annotations**. The H3 and
  the combined production patch were implemented and measured from the
  root tree; the peer's copies are the archived `H3/H3_production.patch`
  and `current-main/production.patch` in the root's archives.

## What to do with this tree's WIP

Preserve it; do not commit it as is. Any commit touching `src/*.nim`
must be preceded by the committed replay-viewer rebuild and stamp check
required by AGENTS.md, which was deliberately deferred to the root for
the accepted combined source. The uncommitted H2 here has the same computations as the H2 hunk
inside `c651dec9`; root adds the outside-as-obstacle proof comment, so the
text is not byte-identical. It has no independent implementation value beyond
this tree's history; the peer's untracked research files (25 paths under
`docs/research/nav-512-2026-09-11/`) are all copied into the root tree
(every `.md` verified present there) and are superseded by the root's
committed record.

## Status of native work and hosts

All native jobs are finished: 9-game screens for H1, H2 and H3 on the
old base; current-base 12 correctness, 6 training-confirmation and 36
held-out games on m5a; 24 games each on c6a.4xlarge and c8i-flex.4xlarge;
P0 Fluffy and P1 perf diagnostics; the cross-architecture probes. The
root reports all 102 current-base games archived with sidecar hashes and
the owned EC2 instance `i-08b7fb62b50e0740a` stopped. The peer never had
native access and ran everything read-only or in its scratchpad.

## Result, in one paragraph, with its limits

The current-main candidate with a shared pool of 512 units per configured
seat per tick passed every registered
gate: same-budget exactness at 256 on all six held-out cells, training
confirmation, the frozen six-cell m5a held-out protocol, and the fleet
card on AMD c6a and Intel c8i-flex in pinned and unpinned placement, with
every individual pair improving total, p50, p95 and maximum frame time
and every stream repeat-exact and equal across the three families. The
peer independently recomputed all of it from raw logs. Limits carried
forward: relative speed only (the 32-seat stress cells still miss the
24 Hz deadline on most frames on the m5a-class core at either budget),
two workloads at 32 seats on the fleet, synthetic pinned clients, reflex
windows in which plays are not stepped, the stale-counter diagnostics
(not a route-quality measure), the eleven-helper diagnostic tradeoff,
and the unresolved Mac/Linux internal-state hash difference in the
original planner.

## Where future work starts

Start from the root's `QUALIFICATION.md` (evidence index, limits) and
`INTEGRATION.md` (the concrete steps a budget change needs: fresh main,
GameVersion under AGENTS.md rules, re-derived budget tests, nine
fixtures re-recorded, viewer rebuild and stamp, design and module docs,
the stale `bench_body_port` asserts), on a fresh `origin/main` checkout,
not from this tree. The peer's reviews that remain useful as background
are `PEER_PLAN.md` (attribution and the elastic-minter arithmetic),
`NEXT_EXACT_PLAN.md` and `DIRECT_LOOKUP_REVIEW.md` (unselected exact
mechanisms, if ever needed), `STALE_COUNTER_REVIEW.md`, and
`CROSS_ARCH_REVIEW.md` with the first-divergence probe, all present in
the root.

No new research, experiment, native access or source edit was started
for this handoff.

PHASE 26 COMPLETE

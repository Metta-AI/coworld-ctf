# Navigation research parked — 2026-09-10

James asked Codex and Claude to stop, make the work durable, merge, and park.
He explicitly approved archiving the research and restorable implementation
while leaving the live runtime unchanged. This is that archive, not a release
of the navigation rework. No Phase 10/11 completion or throughput doubling is
claimed. No further experiments are authorized by this handoff itself.

## Start here

- [Claude handoff](../research/PARK_HANDOFF_CLAUDE.md): results, negative
  experiments, practices, pitfalls, and unfinished acceptance gates.
- [Scoreboard](../research/SCOREBOARD.md) and [ledger](../research/LEDGER.md):
  chronological evidence and decisions.
- [Acceptance map](../research/ACCEPTANCE_MAP.md) and
  [next steps](../research/NEXT.md): acceptance constraints, not completed work.
- [C10 full screen](../research/C10_FULL_PARK_RESULT.md): final collected result.
- [C11 review](../research/C11_COUNT_REVIEW.md): exact interval/table proof;
  implementation and native measurements have not started.

## What is preserved

The evidence directory contains the research reports, raw measurements,
traces, frozen sources, runners, and evaluators. Historical reports describe
research checkouts, not the runtime shipped by main. Dates and hashes matter:
old benchmark shapes and old route hashes are not interchangeable.

`implementation.patch` is a binary Git patch for every changed path outside
this evidence directory, from the exact main commit in `base.txt` to the
research commit in `research-head.txt`. It includes the implementation,
contracts, tests, tools, historical documentation changes, and viewer delta.
`commit-history.txt` preserves the 147-commit research history as text.
The original research branch and local worktrees are also retained.

`worktrees/` preserves each side worktree's base as a patch against the same
main commit, then its uncommitted tracked diff and authored untracked source
files. These include rejected candidates and instrumentation: do not apply
them wholesale to a production branch. `worktree-inventory.json` records
ownership paths and the files saved. Compiler caches and built executables
are intentionally excluded; frozen source, build commands, logs and hashes
are preserved. The unrelated original checkout is untouched.

## Restore the primary research code

First run `python3 docs/designs/nav-rework-evidence-2026-09-09/park-2026-09-10/verify_restore.py`
from the archive checkout. It checks all eight saved bases against the saved
blob/mode manifests, then checks that each side-worktree dirty patch applies.
It uses temporary Git indexes and does not change the working tree.

Run from a fresh clone or an existing clean checkout. Use absolute paths for
`archive` and `resume`; do not apply the patch on current main.

```sh
archive="$PWD/docs/designs/nav-rework-evidence-2026-09-09/park-2026-09-10"
resume="/tmp/coworld-nav-resume"
git worktree add --detach "$resume" "$(cat "$archive/base.txt")"
git -C "$resume" apply --check "$archive/implementation.patch"
git -C "$resume" apply "$archive/implementation.patch"
```

The research evidence remains available in the archive checkout. Copy the
entire evidence directory into the resumed checkout if a runner uses relative
research paths. Create a new branch before implementing anything. The patch
restores unqualified GV65 work; do not publish it, reuse its version number,
or regenerate final fixtures without rechecking current main, all version
claims, the final budget, and the qualification requirements.

To restore a side experiment, start another worktree at `base.txt`, apply its
`worktrees/<name>/base.patch`, then `working-tree.patch`, then copy the
`untracked/` contents to their relative paths. Its historical base hash is
also recorded. No historical research commit object is required for this
patch-based restore.

## Verified boundaries and remaining work

`restore-verification.json` records temporary-index reconstruction of every
non-evidence tracked blob and mode for the primary and seven side bases.
The merge changes documentation/evidence only. Runtime source, SDK, tests,
configuration, fixtures and the viewer remain identical to the merge base.

Retained research shared memory cap is 32 MiB; James permitted up to 64 MiB
for non-colossal maps if needed. Colossal/total cap remains 256 MiB. Permission
to increase a cap is not evidence of qualification. B1024 remains provisional.
The retained H1 corpus hash is
`ee2488d32085fb4de3457c4cf841298c14b87add2225964d934f80f2a7c1013d`.
Isolated C10 screens use the earlier frozen query code and its different hash.

The configured m5a tick gate and activation qualification remain incomplete;
throughput doubling is unproved. Final budget selection, containment,
canonical Docker/fleet checks, current GameVersion claims, all nine replay
fixtures, viewer regeneration and a complete clean suite remain future work.
Do not relabel known replay failures as an accepted green suite.

## Practices to carry forward

Preregister thresholds and sample counts; compare paired fresh processes on
native hardware; publish every failed row. Prove exactness before timing.
Use actual traces and control arms to distinguish a mechanism from incidental
code generation. Inspect generated C for accidental reference ownership in
hot loops. Keep root and peer writable paths separate, dispatch via files,
and verify results independently. A narrow statistical miss stays a negative
under the registered rule; it is not proof that the underlying effect is zero.

See [park operations](OPERATIONS.md) for final host and process state.

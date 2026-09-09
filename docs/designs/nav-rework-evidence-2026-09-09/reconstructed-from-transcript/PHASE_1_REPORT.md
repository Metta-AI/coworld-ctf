# Phase 1 report — literal corpus and red navigation laws

[RECONSTRUCTED FROM TRANSCRIPT: the original scratchpad file (7,354 bytes, 2026-09-04 17:29) was lost to /tmp cleanup. The text below is what the orchestrator displayed with `head -150` and `sed -n 150,220p`; because the second command started at line 150 the two views overlap by one line and the join is exact. A trailing section after "Final branch evidence" may have been cut if the file exceeded 220 lines; the displayed content ends at the "Working tree is clean." paragraph, which reads as the final paragraph.]

## Outcome

Phase 1 is complete in
`/Users/jamesboggs/coding/coworlds/coworld-ctf-worktrees/nav-rework`.
No production source changed.

- Commit A `f289a8ee` freezes the 3,072-case literal corpus, strict reader,
  independent 4 px float oracle, deterministic resampling/cost helpers, and
  explicit writer.
- Commit B `7f589dc2` adds the standalone regression file. Its corpus/oracle
  test is green and its three post-change laws are red for the intended current
  causes.
- The existing body-navigation suite remains green.
- No shard imports the red file. This is the approved Phase 1 exception; Phase
  7 removes it.

## Boundary freshness

Command (exit 0):

```sh
git status --short --branch && git fetch --prune origin && \
git rev-parse --abbrev-ref HEAD && \
git rev-list --left-right --count HEAD...origin/main && \
git log -1 --format='%H %s' HEAD && \
git log -1 --format='%H %s' origin/main
```

Output excerpt:

```text
## james/s2-nav-rework...origin/main
james/s2-nav-rework
0       0
52103b107832e12f30a719dd299bc7636c3dd12f shell: close new play uploads once the match is Playing; fill v1 reconnect recovery (#418)
52103b107832e12f30a719dd299bc7636c3dd12f shell: close new play uploads once the match is Playing; fill v1 reconnect recovery (#418)
```

The phase-boundary merge was therefore a no-op. It touched neither
`src/shell/body*.nim` nor `src/shell/episode.nim`.

## Corpus generation and determinism

Command (exit 0):

```sh
nim c -d:release -d:noSignalHandler --threads:on \
  -o:/tmp/build_nav_route_corpus tools/build_nav_route_corpus.nim && \
/tmp/build_nav_route_corpus
```

Output excerpt:

```text
Hint: mm: orc; threads: on; opt: speed; options: -d:release
114839 lines; 1.998s; 341.93MiB peakmem; ... [SuccessX]
map 1/64 br-gen-20049
...
map 64/64 br-gen-26528
wrote 3072 cases to tests/fixtures/shell/nav_route_corpus.json
```

Command (exit 0):

```sh
/tmp/build_nav_route_corpus /tmp/nav_route_corpus.regen.json && \
cmp tests/fixtures/shell/nav_route_corpus.json \
  /tmp/nav_route_corpus.regen.json && \
shasum -a 256 /tmp/nav_route_corpus.regen.json
```

Output excerpt:

```text
map 1/64 br-gen-20049
...
map 64/64 br-gen-26528
wrote 3072 cases to /tmp/nav_route_corpus.regen.json
cd66119a02ff39f4e67028ce6969402781f07b96dcbcd7b0cba6f1cfe1f6d88e  /tmp/nav_route_corpus.regen.json
```

The checked-in fixture is byte-identical to the regeneration. Its recorded
pool digest is
`2169d51f53af12907977041223be9852e2e43781f2322273a62930cc33907b0f`,
the SHA-256 of `data/br_s2_map_pool.json`.

Command (exit 0):

```sh
jq '{schema,v,source_commit,pool_sha256,oracle_rules,todos,case_count:(.cases|length),first_case:.cases[0],last_id:.cases[-1].id}' \
  tests/fixtures/shell/nav_route_corpus.json
jq -r '.cases[] | [.pool_index,.roster_size,.profile,.dynamic,.distance] | @tsv' \
  tests/fixtures/shell/nav_route_corpus.json | sort | uniq -c | \
  awk '$1 != 1 {print}' | head -20
```

Output excerpt:

```text
"schema": "coworld_nav_route_corpus"
"v": 1
"source_commit": "52103b107832e12f30a719dd299bc7636c3dd12f"
"oracle_rules": "weighted_astar_4px_float32_danger_midpoint_block_x8_v1"
"case_count": 3072
"last_id": "m63-br-gen-26528-r32-s31-hunter-both-far"
```

The uniqueness pipeline printed nothing: every expected cross-product stratum
occurs exactly once.

## Standalone red contract

Command (exit 1, expected):

```sh
nim c -r -d:release -d:noSignalHandler --threads:on \
  tests/test_shell_body_nav_rework.nim
```

Output excerpt:

```text
[Suite] shared navigation rework Phase 1 contract
  [OK] literal corpus provenance and independent oracle are frozen
Check failed: body.actFromBelief(0).movementMask != 0
body.actFromBelief(0).movementMask was 0
  [FAILED] a new valid goal moves on its acceptance tick
Check failed: body.actFromBelief(1).movementMask != 0
body.actFromBelief(1).movementMask was 0
  [FAILED] an exhausted old endpoint does not stall a replacement goal
Check failed: not scheduledFullBoardPlan and seat.job.workUnits == workBefore and
seat.mintJob.workUnits == mintBefore and
seat.planner.workspaceCapacity notin mapSizedCapacities
  [FAILED] active action ticks perform no full-board route search
```

The failures are attributable: the existing follower emits no movement while
the first plan is pending, it retains an exhausted old endpoint while replacing
the route, and the action/scheduler path still schedules and advances a
map-sized per-seat `BodyPlanner` workspace.

## Existing regression gate

Command (exit 0):

```sh
nim c -r -d:release -d:noSignalHandler --threads:on \
  tests/test_shell_body_nav.nim
```

Output excerpt:

```text
[Suite] shell body seat navigation
  [OK] route and duck caches are bounded, pinned, LRU, and non-minting
  [OK] cold and warm path planning are deterministic on a unique corridor
  [OK] cold_plan_budget_256_round_robin
  [OK] prewarmed activation has no playing-tick cold work until new intent
  [OK] follower corridor, octants, and stuck state match stencil
```

All 20 existing tests passed. Linker warnings reported cached objects built for
macOS 15 while linking for 14; they did not change the exit status or test
result.

## Static and version checks

Commands (all exit 0):

```sh
nim check -d:noSignalHandler --threads:on tools/build_nav_route_corpus.nim
git diff --check origin/main...HEAD
tools/ci/check_gameversion.sh origin/main
```

Output excerpts:

```text
114843 lines; 1.335s; 279.02MiB peakmem; ... [SuccessX]
base (origin/main) = GV52 —   GameVersion* = "52"
head (HEAD) = GV52 —   GameVersion* = "52"
OK: GV52 unchanged from the base — no rule change claimed.
```

## Documentation audit

The required `audit-documentation` pass was performed before each commit.
No authoritative repo docs changed: Phase 1 adds test-only truth and an
explicitly documented refresh tool, changes no runtime/API/config behavior, and
the approved plan reserves the final public navigation/design rewrite for
Phase 10. The red file's header records its deliberate standalone status.

## Final branch evidence

Command (exit 0):

```sh
git status --short --branch
git rev-list --left-right --count HEAD...origin/main
git diff --name-only origin/main...HEAD
git log --oneline origin/main..HEAD
```

Output:

```text
## james/s2-nav-rework...origin/main [ahead 2]
2       0
tests/fixtures/shell/nav_route_corpus.json
tests/nav_route_corpus_support.nim
tests/test_shell_body_nav_rework.nim
tools/build_nav_route_corpus.nim
7f589dc2 test: pin shared-navigation liveness failures
f289a8ee test: freeze shared-navigation route corpus
```

Working tree is clean. No production source, replay fixture, GameVersion,
viewer bundle, remote branch, PR, or Asana state changed.

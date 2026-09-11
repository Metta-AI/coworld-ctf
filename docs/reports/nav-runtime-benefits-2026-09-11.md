# Navigation runtime optimizations — 2026-09-11

This ports output-preserving optimizations from the parked navigation research
onto the current planner at `bf5eadc895c7a06baa4a7e1d0168de8e210e2e32`.
James explicitly requested runtime integration on September 11. The original
routing rewrite and its final qualification remain unfinished.

## Changes and invariants

- `body_map.rayClear`: integer nearest/ties-to-even sampling, major-axis
  specialization, and empty-space skips bounded by the existing Chebyshev
  clearance raster. It visits the same potential blocking samples as the old
  floating sampler. Provenance: research W1, W2, W6 and W7, through `addaad7a`.
- `body_nav`: one reference owns immutable danger kernels, perimeter offsets
  and a precomputed grid-cell-center wall table. Seats retain separate writable
  fields and visit buffers. The previous tuple-to-seat sequence assignments
  copied geometry under ORC. Provenance: M1 (`5a6c4963`) and R1 (`ae5658fc`).
- Danger ray decisions advance by addition instead of repeated multiplication
  (D0a). The visited-cell order and float32 addition order remain unchanged.
- Visit stamps use bytes (V1). Before a generation repeats, the buffer clears.
  This saves three bytes per grid cell per seat, at the cost of more frequent
  clearing. One shared byte per grid cell is added for the wall lookup. Kernel
  and perimeter sharing saves the former per-seat copies. These are allocation
  payload changes, not a measured process-RSS claim.

`rebuildDanger` must receive the immutable map used to construct its system;
all current callers do. Out-of-map weapon-ray endpoints remain blocked.

No routing algorithm, planner budget, danger cadence, source selection, cap,
GameVersion, ABI or public configuration changes. C2 caching, C10 SIMD, C11,
provisional B1024/GV65 and the new routing index are not included.

The implementation reuses the repository's measured algorithms and existing
Nim reference ownership. A generic line library would not guarantee the
current game's exact rounding, side-cell blocking and accumulation order.
No dependency is added. See the official [Nim ownership documentation](https://nim-lang.org/docs/destructors.html)
for reference and sequence ownership semantics.

## Validation

`test_shell_body_ray.nim` compares the original float sampler with the port
across exhaustive small-map single-blocker pairs, seeded long rays and their
reverse directions, boundaries, zero-length rays and clearance saturation.

`test_shell_body_danger_exact.nim` compares every float32 bit and maximum with
an independent copy of the previous implementation in
`body_danger_reference.nim`. It covers partial grid cells, walls, off-map
sources, empty sources, seven ranges through 1300 px, separate writable seat
state, and varying origins through repeated byte-stamp rollovers. Both tests
are in shard 2. The oracle intentionally retains uint32 stamps and the old
ray arithmetic and wall lookups.

Local arm64 Nim 2.2.6: both new tests, existing body-map and body-navigation
tests pass. Both runtime-linked and runtime-stub server checks pass. The
committed replay viewer is rebuilt with `tools/build_replay_viewer.sh`; its
module QA passes. `check_gameversion.sh origin/main` confirms unchanged GV63.

Independent Claude Code review completed in two fresh passes. Pass 1 found
no correctness bugs and requested stronger blocked-cell coverage; that test
was strengthened and rerun on both architectures. Pass 2 concluded
`VERDICT: JUST NITS`. Reviews are preserved beside the measurements.

## Native performance evidence

The [registered protocol](nav-runtime-benefits-2026-09-11/PROTOCOL.md) fixes
inputs, thresholds and process order before timing. `bench_body_port --case
danger` now includes range 1300 alongside 331 and 1050; `--case ray` measures
4,096 fixed rays. Timing rows retain raw nanoseconds. Both builds use this
same driver. The BR golden fixture is one map; seed 4242 does not represent
a multi-map performance corpus.

All five process pairs passed with identical danger fingerprints and ray clear
counts. The median of paired candidate/baseline median ratios was:

| Stage | Baseline median (ms) | Candidate median (ms) | Paired median ratio | Paired p95 ratio |
|---|---:|---:|---:|---:|
| Eight-source danger, 331 px | 3.794 | 1.736 | 0.4593 | 0.4568 |
| Eight-source danger, 1050 px | 14.953 | 5.336 | 0.3473 | 0.3468 |
| Eight-source danger, 1300 px | 18.404 | 6.308 | 0.3433 | 0.3430 |
| 4,096 fixed rays | 82.398 | 1.379 | 0.01674 | 0.01692 |

Times are medians of the five process medians; paired ratios are calculated
within each pair first. See [summary.json](nav-runtime-benefits-2026-09-11/summary.json)
and the twenty raw result files beside it. The benchmark records the baseline
Git HEAD for both binaries because the candidate is an uncommitted source
port; `candidate-sources.sha256` identifies its exact measured source bytes.
Native amd64 Nim 2.2.4 also passes both differential tests and the existing
navigation suite. The strengthened cell-center wall test was rerun after the
timing loop, keeping compilation outside measured process intervals.

These stage measurements do not establish whole-tick latency or qualify the
archived rewrite's 2x target.

## Reproduce and maintain

Use `nimby --global sync nimby.lock`, then compile with the production
Dockerfile's Nim 2.2.4 and flags:

```sh
nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on \
  -o:/tmp/bench_body_port tools/bench_body_port.nim
taskset -c 5 /tmp/bench_body_port --case danger --warmups 5 --samples 50 \
  --output /tmp/danger.json
taskset -c 5 /tmp/bench_body_port --case ray --warmups 5 --samples 50 \
  --output /tmp/ray.json
```

Run natively on amd64 for timing; emulated Docker timings do not qualify it.
Keep source hashes, raw results and compiler versions together. Preserve the
old oracle independently when editing traversal. Rollover tests must vary
origins: repeating one footprint can conceal stale stamps. Do not interpret
microbenchmark wins as complete-game wins or archive CI as runtime evidence.

The owned sandbox m5a host was temporarily restarted for these measurements.
The token broker vends a different AWS account and no sandbox scope; sandbox
profile access was therefore used for this owned host. Public SSH used the
previously pinned host key; Tailscale membership was unnecessary.

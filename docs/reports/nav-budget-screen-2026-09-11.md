# Current-planner budget screen — 2026-09-11

This follow-up tests higher pooled planning budgets on the runtime optimizations
merged in [the preceding integration](nav-runtime-benefits-2026-09-11.md).
The experiment base is `83e60c243ed20aa7c756f372306768066054644e`.
The shipped constant remains 256 units per configured seat per tick.
These units include planner work other than node pops; they are not a literal
promise of 256 A* expansions for each cog.

## Results and decision

Keep the shipped budget at **256**. More units reduced navigation waiting,
but worsened whole-frame tail latency at 32 seats. Even the baseline exceeded
the 24 Hz deadline on this single-CPU setup, so this screen establishes no
safe production headroom for an increase. It also does not establish that
production itself misses its deadline: its scheduling/resources may differ.

All 12 games exited successfully with 1,200 measured frames each (14,400 total).
Every run had the intended seat count, every guest initialized, and no play-fault
annotation appeared. Per-budget navigation counters matched exactly across the
two process repeats; this is not a full replay or path-quality equality claim.

| Units/seat | Seats | Frame p95, both runs (ms) | Worst frame (ms) | Frames >41.667 ms, per run | Pending seat-ticks | No-path seat-ticks |
|---:|---:|---:|---:|---:|---:|---:|
| 256 | 16 | 25.47, 25.27 | 144.38 | 3, 3 | 125 | 43 |
| 512 | 16 | 23.82, 24.26 | 164.14 | 26, 30 | 45 | 26 |
| 1024 | 16 | 30.30, 30.41 | 198.61 | 21, 21 | 12 | 17 |
| 256 | 32 | 51.05, 51.26 | 293.12 | 103, 103 | 210 | 61 |
| 512 | 32 | 57.70, 58.84 | 341.21 | 186, 188 | 87 | 42 |
| 1024 | 32 | 57.80, 57.75 | 393.12 | 194, 194 | 22 | 32 |

Seat-ticks sum the number of affected seats over ticks; lower is less waiting,
not proof of better routes. At 32 seats, 512 units cut pending seat-ticks from
210 to 87 and no-path seat-ticks from 61 to 42, but nearly doubled the number
of frames over the deadline (103 to 186–188). At 1024 units, pending fell to 22
and no-path to 32, while 194 frames exceeded the deadline in each repeat.

The 16-seat 512-unit p95 improved slightly, but its worst frame and count over
the deadline increased. Do not select a budget from p95 alone. No slow samples
were removed and no measured game was rerun to replace a result.

The largest 32-seat frame occurred at tick 362 for all three budgets, rising
from about 293 ms to 341 ms to 393 ms. Other common spikes occurred at ticks
2–3 and 1082. Next useful work is to profile those ticks and planning bursts
in the existing planner, then qualify any proposed increase across more maps,
ranges and route-quality cases. This result does not justify another budget bump.

Frame rows cover ticks 1–1200; shell rows cover 2–1201 because their phase
checks lie on opposite sides of the step. The unmatched boundary rows are
retained. Timing percentiles above cover whole frames, not sums of nested
stage durations. The raw records support a tick-by-tick join for further study.

The [raw archive](nav-budget-screen-2026-09-11/raw-games.tar.gz) contains 346
hashed files, including every game log/config/exit record and build provenance.
All member hashes and the transferred archive SHA-256 were verified:
`1ab87da80ac5f3dc1b4a9c37a76500cb389cd8524621bc32fc0f00013ec25e04`.
Machine-readable results: [summary.json](nav-budget-screen-2026-09-11/summary.json).

## Method and limits

See the [registered protocol](nav-budget-screen-2026-09-11/PROTOCOL.md),
[reproduction instructions](nav-budget-screen-2026-09-11/REPRODUCE.md),
[measurement patch](nav-budget-screen-2026-09-11/server.patch), and
[analysis script](nav-budget-screen-2026-09-11/analyze.py).

The real server runs the practice BR map with 16 or 32 play seats, actual
`edge_ride` WASM guests, movement, weapons, observations and physics. Every
server thread shares one native m5a core; presence clients use other cores.
The comparison changes only the planning constant to 256, 512 or 1024, with
the same measurement patch in each binary. No memory caps change.

Whole-frame measurements exclude the frame limiter and shutdown; they include
normal output preparation and benchmark logging overhead. Shell timing is a
separate nested interval and must not be added to frame timing. The 24 Hz
deadline is descriptive, not a newly invented production acceptance gate.
The current body's calibrated CPU containment gates are separate and remain
unchanged. The old 4/5 ms routing-research gate does not apply to these whole
server frames.

This is one pinned map, one guest play, one gun range and one seed. Deaths,
compile scheduling and changed routes can change the workload across runs.
It is not a path-quality or deterministic-output comparison, and timing success
alone would not qualify a higher runtime budget.

## Lessons for the next session

- Use actual simulation state for this question. A synthetic position update
  with fixed aim and zero cooldown can repeatedly trigger fire freeze and
  distort apparent navigation progress. The rejected synthetic harness and
  its review are retained under `superseded/`; no native timing from it is used.
- A config label is insufficient map provenance. The practice config embeds
  `br-gen-4242` in `mapSpec`, which wins over its `mapPath: arena` label.
- Reducing slots alone does not reduce the roster. Trim `players` and `tokens`
  too, and set `minPlayers`; otherwise configuration processing restores
  32 slots and silently changes the pooled budget or prevents the game starting.
- Completed/failed plan-budget events cover only plans that were suspended.
  Plans completed on the first visit emit no event. Keep no-path, stale-path
  and pending seat-ticks, and do not present event totals as all routes found.
- Keep startup spikes, timeout evidence, and failed runs. A script's exit code
  is insufficient when it continues across failures; verify every run record.
- Preserve source provenance as the repository owner before container builds.
  Git's ownership protection need not be disabled to benchmark bind-mounted
  source. Python was added only to an isolated measurement image; no host or
  production dependency changed.

## Review and validation

Independent Claude review ran in three fresh processes. Pass 1 rejected the
synthetic workload and misuse of the archived timing threshold. Pass 2 verified
the real frame interval and caught roster/setup issues. Pass 3 verified fixes
and returned `VERDICT: JUST NITS`. Reviews are retained alongside the protocol.
Native server builds use the production Nim 2.2.4 compiler and flags, statically
linked Wasmtime. Python orchestration and analysis pass compilation checks. Report links and
registered file hashes were verified. The whitespace check reports two blank
context lines in the verbatim `server.patch`; their single-space prefixes are
unified-diff syntax, not source trailing whitespace, and are retained.
No production source changes, GameVersion bump, fixture regeneration or viewer
rebuild are part of this experiment.

## Infrastructure and checkpoint

The owned sandbox instance `i-08b7fb62b50e0740a` was stopped after the verified
archive download; EC2 readback confirmed `stopped`. Direct SSH used its pinned
host key and did not require Tailscale. The token broker exposes a different
account and no sandbox scope, so the existing sandbox AWS profile was the
authorized fallback. No other instance, hosted Coworld or league was changed.

This report and evidence are a local checkpoint on `james/nav-budget-screen`.
No new runtime change or remote merge is claimed by this follow-up.

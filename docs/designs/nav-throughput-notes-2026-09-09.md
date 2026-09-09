# Nav rework: platform findings and EC2 benchmark recipe (2026-09-09)

Agent-agnostic copy of the learnings from session session_01H4Tq8mKE8YCb7mvENxWfct. Read with docs/designs/nav-throughput-research-handoff-2026-09-09.md and nav-rework-exploration-record-2026-09-09.md.

## Real-hardware findings
- Route quality: 3,072 corpus cases, 0 missing/illegal, route hash identical to
  the Mac (5a1340213fe3...). Activation gate passes. Correctness is platform-
  independent; throughput is not.
- Whole-body tick rows (p95/max ms, 32 seats): B=16,384 -> 12-15; 8,192 -> 6.6-10;
  4,096 -> 4.1-7.8; 3,072 -> 3.6-7.1; 2,048 -> 3.0-6.1; 1,024 -> 2.4-5.4.
  The per-pop cost on this core is ~3x the M4's (~185 ns on M4).
- The moving_goals row fails at EVERY budget (5.36 ms at B=1,024): ~1 ms per
  replan REQUEST is spent outside the pop budget (endpoint attach, per-seat
  4 px weight-table refresh, reconstruct/validate/install). Non-search body
  floor is ~1.7 ms (16 seats) / ~2.0 ms (32 seats) on this core.
- Containment test (32-seat body gate): origin/main = 16.4 ms max_body on this
  box; HEAD = 9.6 ms (40 % cheaper). Its 5.6 ms scaled gate is unattainable on
  this hardware for either, so it is host-calibrated evidence, never a nav
  pass/fail on x86.
- James's rulings (2026-09-09): bounded resumable search + steering contract
  approved; no emulated/local canonical tick gate (tick gating is native or
  real-hardware only); colossal cap raised with int16 weights. Codex had cut
  the budget to 1,024 chasing emulated rows; reverted.

**Why:** the design's "tens of microseconds" and the Mac's 3 ms rows were both
wrong for the pod; only the EC2 box tells the truth, and even the devbox is
not guaranteed to be the exact prod instance type.
**How to apply:** pick the pop budget and any tick-gate claim from EC2 rows
(see (see the notes above)); fix per-request overhead before raising
B; pair every containment number with a same-box main baseline. Evidence:
~/coding/coworlds/docs/designs/nav-rework-evidence-2026-09-09/impl/DEVBOX_NUMBERS_{1,2}.md
and the box's ~/nav-bench/. Design history: (see the notes above).

## EC2 devbox benchmark recipe
Checkout used: `~/coworld-ctf-nav` (clone of GitHub main + branch fetched from
a bundle: `git bundle create x.bundle origin/main..HEAD`, scp, `git fetch
~/x.bundle HEAD && git checkout -B <branch> FETCH_HEAD`). A detached main
worktree lives at `~/coworld-ctf-nav-main` (needs its own `nimby sync`).

Toolchain on the box: `~/.local/bin/nim` 2.2.6, `~/.local/bin/nimby`. In the
checkout run `nimby sync nimby.lock` (writes nim.cfg with package paths).
Runtime deps: `sh tools/runtime_spike/fetch_deps.sh` then
`WASMTIME_C_API=$PWD/tools/runtime_spike/.deps/installed/x86_64-linux/wasmtime-c-api`
(+ C_INCLUDE_PATH/LIBRARY_PATH/LD_LIBRARY_PATH).

TRAP: once WASMTIME_C_API is exported, ANY build that touches src/shell must
carry `-d:noSignalHandler` or it dies with "shell runtime requires
-d:noSignalHandler" (cost me one full sweep).

Harness: `nim c -d:release -d:useMalloc -d:noSignalHandler --threads:on
--opt:speed --stackTrace:on tools/bench_body_nav_rework.nim`, then
`taskset -c 5 ./bench --tick --corpus tests/fixtures/shell/nav_route_corpus.json`
(`--quality --activation --all` also exist). The pop budget is the const
`BodyRoutePopBudgetPerTick` in src/shell/body_route_query.nim; sweep by sed +
rebuild, then `git checkout -- src/shell/body_route_query.nim`.
Containment: `nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on
tests/test_shell_containment.nim` (pin with `taskset -c 4-7` for pod-like).
Scripts and logs: `~/devbox_nav_bench{,2,3,4}.sh`, results in `~/nav-bench/`.

**Why:** the Mac (M4) is ~3x faster per pop than the pod-class Xeon and Docker
emulation is slower than both; only the box numbers decide budgets.
**How to apply:** run sweeps in a nohup script with a DONE sentinel and poll
over ssh (background watchers on the Mac get killed under memory pressure).
See (see the notes above).

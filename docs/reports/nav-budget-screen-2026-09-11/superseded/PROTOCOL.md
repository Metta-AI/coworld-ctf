# Current-planner budget screen

Registered before native timings on 2026-09-11. Base: origin/main at
83e60c243ed20aa7c756f372306768066054644e. No runtime budget is being shipped
by this experiment.

Budgets: 256 (current), 384, 512, 768, 1024 planning units per configured
seat, pooled. Only the constant changes in isolated benchmark source copies.
Use production Nim 2.2.4, release/useMalloc/threads/speed/stackTrace flags,
and runtime-linked Wasmtime. Run on owned m5a.4xlarge, pinned CPU 5, one
measured process at a time. Three repetitions use orders:
256,384,512,768,1024; 1024,768,512,384,256; 512,256,1024,384,768.

Each process measures 128 ticks per row: arena and BR golden fixture;
16/32 seats; ranges 331/1050/1300; initial far goals, targets alternating
near/far every 12 ticks, and forced stuck replans. Initial cold ticks are
included, with no discarded warmups. Inputs are deterministic; navigation
goal changes never move threat tracks. Positions advance four pixels from
output masks when standable, except in the stuck scenario. This motion model
omits physics and collisions and is an explicit stress fixture, not an episode
replay. Threats remain at fixed world coordinates.

Time the entire ShellEpisode.step call, retaining stage timings, pending
plans, published path revisions and mask fingerprints. Frame construction and
motion approximation happen outside that interval. No guest modules are
installed and no sim.step runs. Consequently this is a lower-bound body/shell
screen, not complete-game qualification. A failure rules out adoption under
the current body envelope; a pass requires a subsequent real complete-game
workload before changing the live budget.

Every row/repetition must meet p95 <= 4 ms and maximum <= 5 ms, the existing
body timing envelope. Keep any baseline misses visible. Do not multiply the
budget by a stage microbenchmark speedup. Compare route publication and pending
queues as well as latency; report censoring when plans remain at tick 128.
Require identical per-budget fingerprints/progress across process repeats.
Archive raw results and source/compiler/binary hashes. No resampling to erase
a failure and no threshold changes after observing native timings.

The broker provides account 751442549699 and no sandbox scope. Access to the
owned sandbox benchmark instance therefore uses the existing sandbox profile;
stop it after collecting results. SSH verifies its previously pinned host key
and does not require Tailscale membership.

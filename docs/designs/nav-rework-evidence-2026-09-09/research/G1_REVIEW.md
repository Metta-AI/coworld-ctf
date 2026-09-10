# G1 review: `--tick-gun-range` and `--configured-tick`

Written 2026-09-09 by Claude (peer). Reviewed the working-tree diff against 29cf46f3 for
`tools/bench_body_nav_rework.nim` and `tools/build_nav_route_corpus.nim`; no src change.
No source edits, no remote benchmarks. Independent local check: the harness builds with
the diff, and one configured map (`--configured-tick --pool-index 0`) ran to completion on
this Mac (`G1-local-peer/`, exit 1 by design, timing informational).
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Correct as a diagnostic. Provenance is complete, the frozen corpus is untouched, the pair
selection is deterministic and shares one start, the gun range reaches every consumer, and
the pass rule cannot produce a false pass. Three notes in section 6, none blocking the m8i
run. The first configured-map result is itself a finding (section 5).

## 2. Geometry and range
- `--tick-gun-range PX` (default `NavCorpusGunRangePx` = 331) is threaded into `tickRow` and
  `runTickGate`; `initShellEpisode(..., gunRange, ...)` sets `episode.gunRange` and
  `newBodyNavSystem(map, seats, liveGunRangePx)`, so the danger kernel radius
  (`ceil(range / 8)`), the perimeter, `dangerRangePx`, and the body's live weapon range all
  follow the flag. With 331 the rows are byte-identical in workload to the old `--tick`
  (default unchanged, corpus anchors unchanged, pool map 15 unchanged), which is what makes
  the 331/1300 pair an isolation of range alone. Positive-only validation is present.
- `--configured-tick` reads the checked-in manifest, selects `variants[id ==
  "battle-royale-s2"]`, refuses unless `mapPath == brpool16`, takes `gunRange` from the
  config (1300 at HEAD), and loads `BrS2SoloMapPoolPath` = `data/br_map_pool.json` (11 bare
  specs, 3211 x 1713, metadata `gunRange: 331`, which is correctly ignored because the config
  key is explicit, matching `sim_config.nim:1274/1398`). `mapFromSpecJson($spec)` is the same
  loader `pickBrPoolSpecJson` returns for production. Verified against the tree.
- `activationRow(gate, gunRange)` builds the 32-seat nav system at the configured range, so
  the kernel and per-seat rasters in the ledger are the configured ones; the far query still
  uses seat 11 and a farthest-point goal, independent of the corpus. Good.

## 3. Endpoints and provenance
- `selectPairs` (now exported from `build_nav_route_corpus.nim`) is deterministic: lattice
  scan for the first standable, self-validating start; 17 targets at fixed index strides
  through the same-component lattice list; routes solved on a one-seat nav system at 331 px
  with no danger sources, so the selection is independent of the benchmark range; sorted by
  length with `y`, `x` tie-breaks; near = first quartile, far = third quartile. Both pairs
  share the same start, as the corpus anchors do. No randomness, no clock.
- Importing the corpus writer is side-effect free: its only top-level statements are
  `const`, `type` and procs, and the writer's main is under `when isMainModule`. The two
  exported symbols are `SelectedPair` (start, goal public; route, length private) and
  `selectPairs`. It pulls `arena`, `br_map_pool` and the shell modules the harness already
  imports; the build succeeded here, so there is no name clash.
- Recorded per run: manifest sha256 and pool path and sha256, `gun_range_px`; per map: label
  with index and name, spec sha256, start, near and far goals, the full activation ledger, the
  six tick rows. `--tick` rows now carry `gun_range_px`. Root metadata still carries Nim
  version, arch, flags and the breakdown switch. Sufficient to reproduce.

## 4. False-pass and lifecycle check
- Configured pass = activation pass (256 MiB total and, since `colossal` is false, the 16 MiB
  pool shared bound) AND all six rows under the unchanged 4/5 ms gate. Any failure flips the
  root pass and the exit code; there is no path to a green result by omission.
- The gate constants are untouched; the headroom screen is not applied here, consistent with
  `--tick`.
- `onlyPool` bounds are checked; `--pool-index` semantics differ between the corpus pool (64)
  and the configured pool (11), which is fine because the run is one mode at a time, but the
  usage line does not say so (section 6).
- Lifecycle: each map builds its own `BodyMap`, index, nav system and six episodes; episodes
  are closed by `tickRow`, the rest is scope-freed under ORC, and `activationRow` runs
  `GC_fullCollect` around its RSS delta. One giant map peaked at 542 MB RSS here with the
  32-seat activation system alive during its far query; eleven maps run sequentially, so the
  peak does not accumulate, but the allocator state carried between maps can move timing
  rows. For timing comparability Codex may prefer one process per map (the `--pool-index`
  loop) rather than one process for all eleven; for the ledger and pass rule it does not
  matter.
- The runtime per map is dominated by `selectPairs` (17 routes on a giant map) and the
  activation of a 32-seat system; 26.7 s wall here for map 0 including six tick rows. Fine
  for a diagnostic.

## 5. The first configured result (local, Mac, informational timing; ledger is exact)
`configured:0:br-gen-505`, 1300 px, start (16, 16), near (980, 1156), far (3040, 208):
- Activation ledger: shared upper bound 30,504,907 bytes against the 16,777,216 pool cap;
  total 61,526,603. `mixed_graph` 28,299,561 dominates the shared sum; per seat, danger
  rasters and visited workspaces are 10,984,192 bytes each for 32 seats (343 KB per seat
  each) and packed tables 5,492,096. Per Codex's instruction this is a real configured-pool
  memory failure under the ratified pool cap; the 256 MiB total passing does not excuse it.
- Tick rows: all six fail 4/5 ms on this Mac (p95 10.9 to 12.1 ms), with `danger_p95` 10.0
  to 10.9 ms and `non_nav` 9.4 to 10.3 ms; `weapon_p95` is small here (0.09 to 0.18 ms)
  because the seats start about 3,000 px from the threat cluster and `trackShootable`'s
  distance gate rejects every track before the ray check. Codex's G0 on m5a (corpus map 15,
  where seats sit inside 1,300 px of the cluster) saw `weapon_p95` 11.96 ms; the two runs
  bracket the weapon stage's range-dependent behaviour and are consistent with the source
  trace in `WEAPON_RANGE_REVIEW.md`.
- Mac numbers are not gate evidence; the m8i run decides. The ledger numbers are exact on
  any host.

## 6. Notes (non-blocking)
1. Usage text: state that `--pool-index` indexes the configured 11-map pool under
   `--configured-tick` and the 64-map corpus pool otherwise.
2. The configured block does not record which variant id it matched beyond the hard-coded
   string; adding `"variant_id"` and the manifest's `mapPath` string to the JSON makes the
   row self-describing when the manifest changes.
3. `runConfiguredTick` runs before quality in `main` but `main` still loads the corpus and
   the s2 pool first; harmless, but a configured-only invocation depends on the corpus file
   existing. Acceptable for a diagnostic.

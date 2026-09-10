# C5_PROFILE_READY: configured danger-stage attribution markers (C2 cache tree)

Peer (Claude) profiling-only change in `nav-source-cache` (frozen C2 over
f9dff753). Original C2 bytes were snapshotted first (`C5/original/`, SHA-256
listed). No primary, root, or remote edits; nothing committed. Root runs the
native profile (`run_c5_profile.sh`) on configured index 3 (br-gen-5120) at
1300 px; the Mac run here proves trace structure only.

## 1. What changed (`C5-body_nav-over-C2.patch`, `C5-bench-over-C2.patch`)

- `body_nav.nim`: a `dangerStage` template that is `profileBlock` in
  `-d:ProfileTracePath` builds and the bare body otherwise. Markers, whole
  stages only, inside `rebuildDangerFromPoints`: `danger.clear` (raster
  zero, once per rebuild), `danger.hit.replay` (one per cached source),
  `danger.miss.rays` (one per uncached source: slot claim, bitmap zero,
  ray walk), `danger.closeFloor` (one per source, exact pixel floor),
  `danger.scaleMax` (once per rebuild). No per-ray or per-cell markers.
  The existing `rebuildScheduledDanger` marker is untouched and encloses
  them; the packed-weight publish keeps its `bodyNavBreakdown` clock and
  has no Fluffy marker of its own in `src/shell`, so nothing collides.
- `bench_body_nav_rework.nim`: `startProfileTrace` and `finishProfileTrace`
  around `runConfiguredTick` (the frozen `--tick` path already had them),
  and a `danger_source_cache` field per tick row with hits and misses read
  from the row's nav system after all timing, only in
  `-d:dangerSourceCacheCounters` builds (JSON null otherwise).
- No algorithm, cap, policy, or cache change. Focused cache suite 7 of 7
  and body nav rework suite 16 of 16 pass on the changed tree
  (`local-mac/*.log`); the plain-flag harness still builds.

## 2. Local smoke (Mac arm64, informational; exit 1 is the expected Mac gate failure)

`bench --configured-tick --pool-index 3` with `-d:ProfileTracePath`,
`-d:dangerSourceCacheCounters`, `-d:bodyNavBreakdown`. Trace: 95,580
events, `local-mac/configured-trace.json.gz`; summary
`local-mac/trace-summary.txt`. Marker counts are internally consistent
over the six rows: 756 `rebuildScheduledDanger` ticks, 144 changed
rebuilds (`danger.clear` and `danger.scaleMax` 144 each), 1,152 sources
(`danger.closeFloor` 1,152 = 1,104 hit replays + 48 miss ray walks), which
is 144 rebuilds of the harness's 8 static sources.

Per row (`local-mac/configured-pool3.json`, parse from the first `{`;
traced builds print the profiler's lines to stdout first):

| roster | scenario | hits | misses |
|---:|---|---:|---:|
| 16 | first, moving, stuck | 120 | 8 |
| 32 | first, moving, stuck | 248 | 8 |

That is one miss per static source for the first rebuilt seat and hits
for every other seat: the harness's static 8-source workload is 94 to 97
percent hits, far above the 25 to 58 percent measured on real traces, so
these rows characterise the hit path, not production reuse.

Mac means (nested, attribution only): `danger.hit.replay` 353 us per
source, `danger.miss.rays` 1,463 us per source, `danger.closeFloor` 60 us
per source, `danger.scaleMax` 139 us and `danger.clear` 45 us per rebuild;
`rebuildScheduledDanger` 805 us per tick over 756 ticks. On this host a
changed 8-source rebuild is therefore about 2.8 ms of bitmap replay plus
0.5 ms of close floor plus 0.2 ms of clear and scan; the replay's kernel
adds, not the rays, are the configured danger floor under this workload.
Native values are root's to measure.

## 3. Recipe for root

`run_c5_profile.sh`: builds a timed-and-traced binary (markers on, counters
off) and a counted binary (counters on, trace off), runs
`--configured-tick --pool-index 3` with each on the pinned CPU, and hashes
everything. Nested percentiles are never gate values; the timed binary's
row timings are what a paired comparison would use, and the trace is
attribution of where the danger tick goes.

## 4. Cleanup and ownership

Tree state: C2 (frozen) plus C5 markers and harness changes in
`src/shell/body_nav.nim` and `tools/bench_body_nav_rework.nim`; `tmp/c5/`
holds binaries and raw outputs (copied to `C5/local-mac/`). Reverting C5 is
copying `C5/original/` back or applying the two patches in reverse.
`C5-full-tree-over-f9dff753.diff` is the whole tree diff including C2.

C5 PROFILE READY

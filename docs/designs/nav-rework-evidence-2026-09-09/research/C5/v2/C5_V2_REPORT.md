# C5_V2_REPORT: first fills attributed by tick, pack marker, explicit exit codes

Peer (Claude) v2 of the C5 diagnostic in `nav-source-cache` (frozen C2 over
f9dff753). v1 is preserved unchanged under `C5/v1/`; v2 adds two markers
and a harness row marker on top (`C5v2-*-over-v1.patch`, 14 lines each;
`C5v2-*-over-C2.patch` are the cumulative diffs over the C2 originals in
`C5/original/`). No primary, root, or remote edits; nothing committed.
Focused cache suite 7 of 7 and body nav rework 16 of 16 pass on the v2 tree
(`v2/local-mac/`). Traced timings include tracing overhead and are
attribution only; root's unprofiled C2/C3 comparisons are the authority.

## 1. v2 additions

- `danger.packWeights`: `ProfileTracePath`-only marker around
  `rebuildPackedWeights` inside `publishDangerGeneration`; the equality
  compare, scratch swap and generation bump stay outside it. The
  `bodyNavBreakdown` clock is unchanged.
- `bench.tickRow:<roster>:<scenario>`: one marker per harness row so a
  trace attributes every per-tick `shell.danger` and its nested `danger.*`
  markers to a row and a tick index. Tick 0 is the initial step, 1 to 5
  the warmups (`TickWarmups = 5`), 6 to 125 the 120 measured samples.
- `attribute_clears.py`: timestamp-containment attribution of every
  `danger.clear` (one per changed rebuild) to row, tick index, phase and
  sample index, with per-tick marker sums.
- `run_c5_v2_profile.sh`: records every command's exit code in
  `exit-codes.txt` (no `|| true`); a gate-failure exit of 1 on the traced
  or counted run is expected on non-passing hosts and its JSON is still
  valid (parse from the first `{`, the profiler prints first).

## 2. Root's suspicion confirmed: the 144 rebuilds are first fills

Mac v2 smoke (`v2/local-mac/clear-attribution.json`, attribution only):

| row | ticks | clears initial / warmup / measured | measured ticks with a clear | share of 120 samples | max shell.danger us, measured, with clear | without clear |
|---|---:|---|---|---:|---:|---:|
| 16 first_goals | 126 | 1 / 5 / 10 | 6..14, 31 | 0.083 | 4,217 | 7 |
| 16 moving_goals | 126 | 1 / 5 / 10 | 6..14, 31 | 0.083 | 4,250 | 6 |
| 16 stuck_replans | 126 | 1 / 5 / 10 | 6..14, 31 | 0.083 | 3,891 | 6 |
| 32 first_goals | 126 | 1 / 5 / 26 | 6..31 | 0.217 | 4,381 | 10 |
| 32 moving_goals | 126 | 1 / 5 / 26 | 6..31 | 0.217 | 4,789 | 16 |
| 32 stuck_replans | 126 | 1 / 5 / 26 | 6..31 | 0.217 | 4,187 | 17 |

Every row has exactly `rosterSize` clears, one per seat, at that seat's
first due cadence tick (`floorMod(tick, 32) == seat`), so all first fills
land in ticks 0 to 31. With the harness's static 8 sources, L0 skips every
later cadence visit, so no measured tick after 31 rebuilds anything: the
danger tick is at most 17 us there against about 4 ms on a first-fill
tick. The five warmups absorb only the seats due at ticks 1 to 5; 10 of 120
measured samples at 16 seats and 26 of 120 at 32 seats contain a first
fill. Both shares exceed the 5 percent that defines p95, so on this
workload the configured row p95 and maximum are first-fill ticks by
construction, not a recurring danger floor. The workload itself is valid
and unchanged; this is what it measures.

Where a first-fill tick goes on the Mac (nested, per changed rebuild of 8
sources, from `trace-summary.txt`): hit replay 360 us per source (1,104
of 1,152 sources hit, because the shared cache serves every seat after the
first), miss ray walk 1,525 us per source (48, the first seat's 8 per row),
close floor 61 us per source, `danger.packWeights` 370 us per rebuild,
scale and max 140 us, clear 45 us. The pack is about 8 percent of a
first-fill tick here; the replay of 8 sources is about 70 percent.

## 3. What this means for the C2 configured p95 question

- The configured 6.48 ms worst p95 is measured on ticks that each carry
  one seat's first scheduled fill of 8 sources plus the pack; the C2 cache
  converts 7 of every 8 first fills into replays, which is why C2 improved
  totals and p95 in the real-trace pairs, and why C3 (replay arithmetic)
  could only move the replay share.
- Real episodes behave differently from this harness: the traces showed
  one changed rebuild per 8 to 16 ticks with 3 to 8 sources and 25 to 58
  percent hits, so production p95 depends on how often changed rebuilds
  coincide with planning, not on first fills. Both remain relevant; the
  harness rows characterise activation-time fills at scale, the traces
  characterise steady play.
- Nothing here changes the gates or proposes changing warmups.

## 4. Root run

`run_c5_v2_profile.sh` with `C5_TREE` pointing at a checkout carrying the
v2 snapshot (`v2/snapshot/`), configured index 3 (br-gen-5120), traced and
counted binaries, exit codes recorded, `clear-attribution.json` produced
from the native trace. Report the per-row first-fill tick indices and the
per-tick marker sums; do not read row p95 from the traced binary.

C5 V2 READY

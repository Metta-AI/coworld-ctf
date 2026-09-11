# Navigation research: 512 without a whole-game slowdown

Active research, resumed at James's request on September 11. Target: **512
pooled planning work units per configured cog per tick**, compared with 256,
without slower whole-game frames or relaxed route quality, determinism or memory
limits. Units include connectors, reconstruction and field minting as well as
A* pops. The source default remains 256; nothing has been published.

This campaign optimizes the shipped planner. It does not resume or qualify the
archived C10/C11 rewrite. Start with [BRIEF.md](BRIEF.md), [LOOP.md](LOOP.md)
and the live [LEDGER.md](LEDGER.md). Claude and Codex use separate worktrees.

## Measured results

All initial screens used base 6b6b3408 (runtime sources equal 83e60c24), native
m5a, 32 seats and 1,200 complete frames. Every screen retained all nine games.

| Candidate | Change | Intermediate screen | Candidate 512 versus original 256 |
|---|---|---|---|
| H1 | Shift heap neighbours while holding the displaced node | Pass: total -2.7% versus original 512 | Miss: total +8.3%; tails and misses worse |
| H1+H2 | Clearance raster certifies short legal segments | Pass: total -10.4% versus original 512 | Miss: total +0.9%, p50 +5.7%, maximum +2.7% |
| H1+H2+H3 | Inline eleven small helpers, omitting only their own diagnostic frames | Pass: total -11.3% versus H1+H2 at 512 | **Training pass:** total -11.1%, p50 -14.0%, p95 -27.0%, maximum -6.3%; worst misses 29 versus 108 |

H3 preserves bounds checks and framed callers, verified with a deliberate
bounds defect. Heap/segment oracles, native full-state fingerprints and
same-budget game streams are exact. All three H3 pairs improved every frame
metric. See [H3/RESULT.md](H3/RESULT.md) and the independent peer recomputation
in [H3_PEER_VERDICT.md](H3_PEER_VERDICT.md). A training pass is not production
qualification. No H4 was selected.

## Current qualification

All twelve old-base held-out correctness games passed across six cells, three
maps and both plays. No old-base held-out performance games were run. Upstream
then changed scoring code; root merged origin/main 58e6c947 at 46ddc845 and
rebuilt original 256 and candidate 256/512 binaries. All twelve current-base correctness games passed. The six training-confirmation
games also passed: candidate512 versus original256 median paired total time
was 11.6% lower, p50 15.8% lower, p95 26.2% lower and maximum 6.4% lower;
worst deadline misses were 31 versus 109. The 36 held-out timing games are
running; no held-out or fleet acceptance verdict is available yet.
The frozen [current-main card](current-main/CARD.md) and
[six-cell protocol](qualification/PROTOCOL.md) give exact gates and run order.
Binary and guest bytes are pinned in [current-main/assets.json](current-main/assets.json).

On the updated source, all four local release shards passed (2,301 checks),
as did linked/stub server checks, the Docker viewer build and its source-stamp
check. Native heap/segment/navigation suites passed. Independent source review
found no high/medium issue; its accepted prose/test nits are applied.

Activation memory has equal capacities, object sizes and array payloads.
At 32 seats, original/candidate RSS is about 2.57 GB on the larger map and
9.66 GB on the colossal geometry; differences are below 0.3 MB. No memory-cap
increase is used. These are activation measurements, not peak-gameplay RSS.

## Coverage and limits

- Practice and the golden fixture are the same geometry. Old match fixtures
  301/14005 fail current boot because their BR pickup pools are missing. Their
  failed preflight remains recorded. Current certified pool entries 505/5001
  replace them; the larger map is the first validator pass, seed 5120918.
- The moving play passed real runtime/emit validation and actual game installs.
  It alternates carrier/hunter and moving goals every 12 view ticks while it
  controls a seat. Zone-escape reflexes suspend play stepping for substantial
  windows; their frames remain in every comparison. See the peer verdict.
- Mac and Linux produce matching final paths and tick counts on the diagnostic
  workload, but the original planner's full internal-state digest differs.
  Platform `hypot` values differ on some inputs. The bounded three-tick dump
  has identical stored state; only recomputed diagnostic inputs differ there.
  The complete internal discrepancy is not yet localized. Same-platform
  original/candidate full-state exactness is independently established.
- Common production CPU families and unpinned server execution remain to be
  qualified. [HARDWARE.md](HARDWARE.md) records the fleet and screening host.
  [P0](P0/RESULT.md) and [P1](P1/RESULT.md) are diagnostic profiles, not timing
  acceptance evidence.

Raw archives, hashes, cards, source patches and logs are retained alongside
results. [LESSONS.md](LESSONS.md) records reusable practices. Root owns the
native host; no builds, profiles or compression overlap acceptance timings.
The goal tracker still contains an older blocked objective; this research
objective is recorded here without falsely marking that older work complete.

Local validation logs are in validation-logs.tar.gz (extract at this directory
to restore their referenced paths). Raw diagnostic text dumps have their own
archive under CROSS_ARCH/first_divergence. No generated log is silently omitted
just because the repository ignores *.log.

See [RAW_ARTIFACTS.md](RAW_ARTIFACTS.md) before following older briefs that
reference unpacked patch, perf or log paths. Their exact bytes are archived.

# CACHE_TRACE_RESULT: real-episode source-reuse counts for the shared LOS cache gate

Peer (Claude) capture in the isolated worktree `nav-source-trace` (branch
`james/nav-source-trace`, base 3aeb0398) per `CACHE_TRACE_PLAN.md` revision 2
and `CACHE_TRACE_BASELINE_CORRECTION.md`. Everything here is a count from
real local Season 2 shell episodes driven by the real baseline S2 client.
Revision 2 (after `CACHE_TRACE_REVIEW_REQUEST.md`): the attribution split
is corrected with an explicit previous-rebuild carry model (section 3a),
invariants and max selected-source counts are reported (section 3b), and
the tick-versus-frame ranges are clarified (section 1). The total LRU-64
metric and its gate are unchanged.
No timing was measured and none is claimed. Local Mac (arm64), Nim 2.2.6,
server built `--threads:on -d:release -d:noSignalHandler -d:navSourceTrace`.
Raw artifacts for every run are under `runs/<tag>/` (config, manifest,
`navsrc.txt`, gzipped server log, one client log); the exact source patch is
`navSourceTrace.patch`; the runner scripts, build log, and the two focused
test logs with the define are beside it. `cache_sim_results.txt` is the full
model output; `cache_sim.py` produced it.

## 1. Workload as run

- Config: the shipped `battle-royale-s2` `game_config` from
  `coworld_manifest_paintbot.json` verbatim (brpool16, gunRange 1300,
  maxGames 1, maxTicks 10000, real-time speed, 16 `control: "play"` slots),
  with only `seed` pinned. The 32-seat shape duplicates the 16 slots (two
  play seats per team, the `coworld_manifest_br.json` 32-slot shape) and
  raises `players`, `num_agents`, `minPlayers` to 32. It is a true 32-seat
  workload: 32 clients joined, 32 activations, 31 deaths per run.
- Clients: `players/baseline/baseline.nim` built from the same tree, one
  process per slot, `BASELINE_PLAYBOOK` pointing at the nine reference plays
  built by `policies/starters/common/build_playbook.sh`. Every client logged
  "4/4 modules ready" (the baseline uploads target_law, supply_run, loot,
  edge_ride and maintains its gated ladder).
- Exit: every server exited 0 on its own after GameOver with a winner
  ("win factor" line), between 1,307 and 2,378 playing frames. No wall-clock
  budget applies (not squad mode). Tick numbering: the `tick` in every
  trace line is the sim tick the shell sees, which starts counting before
  the play phase (the shipped config has 600 lobby-chat ticks and 120
  start-wait ticks), whereas "playing frames" counts the play phase only.
  The two differ by about 700 in every run (for example 3,289 last sched
  tick versus 2,580 playing frames for s2_32_679965), which is why the
  table's tick ranges exceed 3,000 while no episode played more than 2,580
  frames. Derived from the config and the logs, not from a separate tick
  counter. No forced `initializeDanger` call ever
  happened (0 `init` lines in every run), so every LOS raster in these
  episodes came from the scheduled cadence.
- Seed finding: the shipped seed 679961 is `LegacyFixedSeed`, so the server
  randomizes it; the smoke run therefore carries a randomized seed
  (194507377 for the failed first attempt, 1846092041 for the recorded one)
  and map br-gen-5001. Pinned seeds 679962 and 679964 both drew br-gen-5204;
  679963 drew br-gen-5263. The batch therefore covers two distinct pool maps
  plus the smoke's third; section 5 records the extra-seed attempt.

## 2. What the trace showed about the rebuild path itself

Per episode (16 seats, about 2,000 to 2,250 ticks): about 680 to 750
scheduled visits, of which 111 to 135 took the changed branch and the rest
(78 to 84 percent) were L0 skips. At 32 seats: about 1,340 visits, 239 to
288 changed. 15 to 30 changed rebuilds per episode had zero sources (a seat
whose selection emptied), which zero and publish the raster without any
ray. The number of source lookups per episode is small in absolute terms:
134 to 196 at 16 seats, 530 to 757 at 32 seats, so roughly one changed
rebuild every 8 to 16 ticks at 16 seats and every 8 to 11 ticks at 32.
Each source costs about 60,000 measured ray-loop iterations (924 perimeter
rays, mean about 65 steps each against a 163-cell radius), so the ray work
per episode is 7.5 M to 12.4 M steps at 16 seats and 32 M to 46 M at 32.

## 3. Cache model results

Keys are (nav system, 8 px source cell); only changed scheduled rebuilds
produce lookups; the saving on a hit is the measured steps of that key;
close floor and raster writes are never counted as saved, so "steps
removed" is an upper bound on the ray work a cache could remove.

| run | map | last sched tick | sched | changed | changed, 0 src | max src | lookups | distinct keys | steps per lookup | LRU removed @32 | LRU removed @64 | LRU removed unbounded | carry-only removed | LRU@64 beyond carry | reuse ticks p50/p90 |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|
| smoke_s2_16 (randomized seed) | br-gen-5001 | 2248 | 746 | 126 | 29 | 4 | 137 | 104 | 60,047 | 0.246 | 0.246 | 0.246 | 0.115 | 0.132 | 6/32 |
| s2_16_679962 | br-gen-5204 | 2023 | 676 | 135 | 16 | 4 | 196 | 121 | 63,228 | 0.394 | 0.399 | 0.399 | 0.162 | 0.238 | 8/64 |
| s2_16_679963 | br-gen-5263 | 2151 | 698 | 111 | 20 | 3 | 134 | 86 | 56,206 | 0.418 | 0.418 | 0.418 | 0.206 | 0.212 | 9/59 |
| s2_16_679964 | br-gen-5204 | 2124 | 690 | 124 | 15 | 4 | 189 | 112 | 59,722 | 0.418 | 0.418 | 0.418 | 0.204 | 0.214 | 12/32 |
| s2_16_679965 (extra seed) | br-gen-5001 | 3277 | 739 | 109 | 23 | 3 | 121 | 92 | 63,390 | 0.253 | 0.253 | 0.253 | 0.119 | 0.134 | 24/64 |
| s2_32_679962 | br-gen-5204 | 2331 | 1340 | 288 | 30 | 8 | 757 | 380 | 61,388 | 0.476 | 0.502 | 0.506 | 0.222 | 0.281 | 8/23 |
| s2_32_679963 | br-gen-5263 | 2357 | 1332 | 239 | 20 | 6 | 530 | 244 | 61,168 | 0.566 | 0.578 | 0.578 | 0.325 | 0.253 | 10/32 |
| s2_32_679964 | br-gen-5204 | 3088 | 1339 | 278 | 25 | 8 | 673 | 376 | 60,449 | 0.403 | 0.450 | 0.453 | 0.163 | 0.289 | 8/20 |
| s2_32_679965 (extra seed) | br-gen-5001 | 3289 | 1345 | 274 | 40 | 8 | 554 | 302 | 62,570 | 0.424 | 0.436 | 0.442 | 0.160 | 0.280 | 11/32 |

Column meanings. "LRU removed" is the shared-cache model (keys shared by
all seats, least-recently-used eviction at the given capacity). "Carry-only
removed" is a separate model with no sharing at all: each seat keeps only
its immediately previous changed rebuild's per-source lists, and a lookup
is served iff that seat's previous rebuild selected the same key. "LRU@64
beyond carry" counts the LRU-64 hits that the carry could not have served
(the key was not in that seat's previous rebuild), so it is the part of the
shared saving that needs memory across seats or across more than one
rebuild. The two models overlap; their sum is not the LRU total.

Revision 1 of this report labelled hits "same-seat" using an ever-seen set
and said a per-seat carry "would also capture" them. That was wrong: a
source can leave a seat's selection and return many rebuilds later. The
explicit carry model above replaces that claim. Duplicate memberships
inside one rebuild were 0 in eight runs and 3 in one. Reuse distance: half
of all shared hits reuse a key within about 8 to 12 ticks of its last use
by any seat, 90 percent within 16 to 64 ticks; capacity 64 is within 0.03
of unbounded in every run.

### 3a. Corrected attribution

Per-seat carry alone removes 0.12 to 0.21 of ray steps at 16 seats and 0.16
to 0.32 at 32 seats. The shared LRU-64 removes 0.25 to 0.42 at 16 seats and
0.44 to 0.58 at 32. The part of the shared saving that the carry cannot
serve is 0.13 to 0.24 at 16 seats and 0.25 to 0.29 at 32 seats. So a shared
cache roughly doubles what a carry would save, and the beyond-carry share
alone stays below the 0.30 line in every run while the total is above it in
seven of nine. The honest reading is: most of the reuse is within one or
two cadence windows (see reuse distance), a large part of it crosses seats,
and neither a carry nor a shared cache is a majority reduction of the ray
work.

### 3b. Invariants and source counts

`cache_sim.py` now asserts, per trace: exactly one nav-system header and
every line stamped with that system id; sched ticks non-decreasing and
every visit on its seat's cadence slot (`tick mod 32 == seat mod 32`);
source counts within 0 to 8 and non-zero only for seats that logged
activation; every changed rebuild matched by exactly one `rays` line with
the same cells; no forced-init line; one step count per key across the
trace. All nine traces pass. Header identity per map: br-gen-5204
sight_fnv 78D6756163262209, br-gen-5263 AAE16E4C92C11402, br-gen-5001
D0E0AA21315A40B0, each identical across the runs that drew that map; grid
401 by 214 and range 1300 px in every run. The maximum selected-source
count was 3 or 4 at 16 seats and 6 to 8 at 32 seats; the 8-source cap was
reached only in 32-seat episodes.

## 4. Gate verdict (count only)

Preregistered rule (plan section 8): proceed only if `steps_removed` at
capacity 64 is at least 0.30 in at least two of three maps for both seat
counts.

- On the total metric, across the three distinct pinned maps (5204, 5263,
  5001, using seeds 679962, 679963, 679965): 16 seats gives 0.399, 0.418,
  0.253, so two of three maps pass; 32 seats gives 0.502, 0.578, 0.436, so
  three of three pass. The repeat draws (679964 on 5204: 0.418 and 0.450)
  and the randomized-seed smoke on 5001 (0.246, matching the pinned 5001
  episode's 0.253) are consistent with those. The rule is met, narrowly at
  16 seats, and map 5001 is a preserved negative at 16 seats in two
  independent episodes.
- Attribution (corrected, section 3a): a per-seat previous-rebuild carry
  alone removes 0.12 to 0.32; the shared LRU-64 saving beyond what a carry
  serves is 0.13 to 0.29 and below 0.30 in every run. The shared cache is
  worth roughly twice a carry on this workload, but neither is a majority
  of the ray work.
- Map coverage: the first batch drew only two distinct maps; the extra
  seed 679965 (section 5) drew the smoke's map 5001, so three distinct
  pinned maps are covered at both seat counts, as the plan asked.

Recommendation: the total LRU-64 count gate passes and does not reject the
shared-source direction. The measured reuse is dominated by short-distance
(one to two cadence windows) repeats, a large part of it across seats. Any
design review should compare (a) a per-seat carry of the previous rebuild's
per-source cell lists (0.12 to 0.32), (b) a small shared LRU of 16 to 64
entries (0.25 to 0.58), and weigh both against the entry size: a
visible-cell list per source is up to the disc of radius 163 cells (about
83,000 cells, or up to about 330 KB as int32 indices) and the measured
60,000 steps per source bound the visited-cell count, so 64 entries could
retain several megabytes against the 32 MiB shared cap. That memory
question, and whether the ray share of the rebuild is large enough to
matter for tick p95, are timing and ledger questions for root's remote
queue, not answered by this trace.

## 5. Extra seed for a third distinct map

`tools/nav_source_trace_extra.sh` tried pinned seeds from 679965 upward until
the brpool16 draw was neither 5204 nor 5263. The first try, 679965, drew
br-gen-5001, the smoke's map, and ran at both seat counts (16 clients
joined, 16 activations, 15 deaths; 32 joined, 32 activations, 31 deaths;
both exited 0 with a winner after 2,576 and 2,580 playing frames; 0 init
lines). Its rows are in the table above. Map 5001 is the low-reuse map at
16 seats in both of its episodes (0.253 pinned, 0.246 randomized) while
still reaching 0.436 at 32 seats; the map-to-map spread at 16 seats
(0.25 to 0.42) is the largest source of variance in this capture and
argues for reporting per map, never a pooled mean.

## 6. Cleanup state

The instrumentation remains applied only in this trace worktree
(`git status`: `src/shell/body_nav.nim` modified, three temporary `tools/`
scripts untracked, and this evidence folder untracked). Nothing was
committed anywhere. Root production source, the research worktree's source,
and remote hosts were not touched. `tmp/navsrc/` in the trace worktree holds
the built binaries, the playbook, and the raw run directories; the evidence
folder carries everything needed to re-derive the tables.

CACHE TRACE CAPTURE DONE

# CACHE_TRACE_PLAN: real-episode source-reuse trace for the shared LOS cache gate

Peer (Claude) plan answering `CACHE_TRACE_RECON_REQUEST.md`, revised after
`CACHE_TRACE_BASELINE_CORRECTION.md`. Revision 2 (2026-09-10) replaces the
edge_ride-only workload with the real protocol-adaptive baseline Season 2
client and records what the smoke run verified. Implementation and capture
live in the isolated worktree `coworld-ctf-worktrees/nav-source-trace`
(branch `james/nav-source-trace`), owned by the peer per the correction note;
root production source and remote hosts stay untouched. This is a count gate
(hit rate and ray steps removed), never timing.

Scope reminder: the wavefront direction is closed (WF0/WF1). This plan gates
the remaining candidate from `WF1_PROPOSAL.md` section 7, an exact shared
per-source LOS cache, before any implementation. The decision rule stays the
one already written there: below roughly 30 percent of ray steps removed on
the real workload, reject the direction.

## 0. Revision 2 corrections and smoke results

- Corrected claim: revision 1 said `edge_ride` on every seat was the most
  realistic local policy. That was wrong. `players/baseline/baseline.nim`
  detects the Season 2 PlayContext on its first message and runs
  `runS2Session` (`players/baseline/baseline/s2play.nim`), which uploads the
  reference playbook from `BASELINE_PLAYBOOK` and maintains a gated ladder:
  `target_law` (prefer weakened, isolated), `supply_run` when hurt near a
  medkit, `loot` when gear is near and no enemy is close, `edge_ride` as the
  always-on base. Nine reference plays build from
  `policies/starters/common/build_playbook.sh`; the baseline uploads the four
  it calls. The gating workload is therefore real baseline S2 clients on the
  shipped `battle-royale-s2` game config. Real participant plays still differ
  from the baseline; that remains the stated limitation.
- Config shape, resolved from code and one smoke: the shipped variant has 16
  `control: "play"` slots, and `readConfigTokens` extends `slots` to the
  token count (`src/ctf/sim_config.nim:487`), so a 16-seat run must carry no
  32-entry token list. The manifest config has no tokens; slot auth then
  requires only the roster name (`slotAuthMatches`, `src/ctf/roster.nim`),
  so the client URL must pass `name=Player<slot+1>`; a missing name is
  refused with HTTP 403 "Player credentials do not match configured roster"
  (first smoke attempt, corrected in the runner). The 32-seat shape is the
  same config with the 16 slots duplicated (two play seats per team, the
  `coworld_manifest_br.json` 32-slot shape), `players`, `num_agents` and
  `minPlayers` raised to 32. It is a true 32-seat workload, not 32 slots
  with 16 inactive seats; both shapes are reported separately.
- Finite exit, resolved from code and smoke: `maxGames 1` sets
  `quitAfterFrame` when the phase reaches GameOver (`src/ctf/server.nim:5465`)
  and the process exits after finalization. The smoke server exited 0 after
  1,553 playing frames with a winner; no wall-clock budget applies because
  the shipped config is not squad mode (`cogsPerTeam` 1). Runs are at the
  shipped real-time speed; no `fastMode`.
- Seed finding: the shipped `seed 679961` equals `LegacyFixedSeed`
  (`src/ctf.nim:8`, 0xA6019), so the server treats it as unpinned and
  randomizes the seed and therefore the pool map on every process
  ("seed not pinned; randomized" in the smoke log). Live play thus spreads
  over the pool per episode. The batch pins seeds 679962, 679963, 679964 so
  each run is reproducible and names its map; the smoke used a randomized
  seed and is kept as an extra sample, labelled as such.
- Smoke result (16 seats, randomized seed, map br-gen-5001, 1300 px): 746
  scheduled visits, 126 changed rebuilds, 620 unchanged (L0 skip), 16
  activations, 15 deaths, 0 forced-init lines, 137 source lookups over the
  whole episode, 104 distinct keys, ray steps removed 0.246 with an
  unbounded cache and 0.246 at capacity 32. Below the gate on this one
  episode. The batch decides.

## 1. Verification: can source points be captured without a production feature?

Answer: not from anything that exists today. A temporary, define-gated
diagnostic log is required. Evidence, all read-only:

- The existing danger trace records counts only. `recordDanger` receives
  `DangerRebuild(tick, seat, sourceCount)` (`src/shell/body_nav.nim:616`);
  the ordered points are not stored anywhere reachable after the tick.
- The public accessors `selectedDangerSources*` and
  `selectedDangerSourceSeats*` (`src/shell/body_nav.nim:562-571`) return the
  current selection, but only in-process on an owned `BodyNavSystem`. The
  server exposes no log, endpoint, or replay field that prints them, and the
  per-second `SHELL_NAV` line carries state counts only
  (`src/shell/episode.nim:1537`).
- Replays cannot re-drive the shell. The replay player carries no shell and
  replays re-drive masks (`src/ctf/replay_runtime.nim`), so shell bodies and
  their danger rebuilds never run during playback. The GameVersion mismatch
  (fixtures GV63, source GV65, `ReplayCompatibleGameVersions = ["63"]` in
  `src/ctf/sim_types.nim:32`) is therefore moot for this purpose: even a
  compatible replay would not produce source points. Do not replay fixtures
  for this trace.
- An owned-episode harness could read the accessor after every step, but it
  would have to drive plays and lifecycle itself, which is exactly the
  "not a real episode" objection the request rules out.

Conclusion: add a `when defined(navSourceTrace)` block that is compiled only
through `SHELL_EXTRA_NIM_FLAGS` in `tools/run_shell_demo.sh`. Without the
define the production binary is byte-for-byte unaffected. This is a temporary
diagnostic, to be removed after capture, not a feature.

## 2. What the server path actually does (so the trace models it exactly)

- Cadence: `rebuildScheduledDanger` runs every tick from
  `src/shell/episode.nim:1498`. A seat is due when
  `floorMod(tick, 32) == floorMod(seat, 32)` (`dangerSeatDue`,
  `DangerCadenceK = 32`). Seats are visited in ascending seat index, so the
  per-tick request order is deterministic given state.
- Selection: `selectDangerSources` keeps the nearest at most 8 fresh candidates
  (`MaxDangerSources = 8`), ordered by insertion into a nearest-first array.
- L0 skip: if the ordered points and count equal the previous selection, no
  raster work runs; `dangerTick` advances and any installed route expires.
  These rebuilds must appear in the trace as `changed=0` and must not count as
  cache lookups.
- Changed branch: `rebuildDangerFromPoints` zeroes the raster, then per source
  in order: `cellOf(source)` (8 px cells, `NavCell = 8`), one `addVisibleCell`
  at the origin, one `castRay` per perimeter offset, then the exact-pixel
  close floor over a square of `closeCells` around the source. Then a
  whole-raster max pass and `publishDangerGeneration`.
- Activation: the server never calls `initializeDanger`. Shell activation is
  `activate` in `src/shell/episode.nim:1141`, which calls `setSeatActive(true)`
  and installs a safe hold; the first LOS raster for that life is the first
  due scheduled rebuild after that. Death calls `resetNavigationLife` then
  `setSeatActive(false)` (`resetAfterDeath`, line 1127). Note the nav
  constructor builds seats with `active: true` (`src/shell/body_nav.nim:319`);
  before shell activation those seats receive an empty `DangerInput`
  (`dangerInputs`, line 1192), select zero sources, and take the unchanged
  branch. The trace must record these so "activation" is separated from
  "first scheduled rebuild with sources".
- Map and range: the episode's `BodyNavSystem` is built once per episode from
  `sim.gameMap` and `config.gunRange` (`resetShellForSim`,
  `src/ctf/server.nim:4058-4080`). Map and range are fixed for the life of a
  nav system, so the map/range generation for cache keys is the nav-system
  instance, which the trace identifies by a header line.

## 3. Temporary diagnostic instrumentation (proposed diff shape, root applies)

All in `src/shell/body_nav.nim`, inside `when defined(navSourceTrace)`. Lines
go to stderr; `run_shell_demo.sh` already merges stdout and stderr into
`RUN_DIR/server.log`. Prefix every line with `NAVSRC ` so extraction is one
grep.

1. Header at nav-system construction (end of `newBodyNavSystem`):
   `NAVSRC sys id=<counter> grid=<gridWidth>x<gridHeight> range_px=<dangerRangePx> radius=<geometry.radius> perimeter=<geometry.perimeter.len> sight_fnv=<FNV-1a 64 of sightBlocked bytes> seats=<n>`
   The counter is a threadvar incremented per construction; it is the
   map/range generation key. `sight_fnv` proves two systems share geometry.
2. Activation and death, in `setSeatActive`:
   `NAVSRC active seat=<i> active=<0|1>`
   No tick is available there; the surrounding tick-stamped lines bound it.
   Also log `NAVSRC init seat=<i>` in `initializeDanger`; the expectation is
   zero such lines in a server run, and the trace verifies it.
3. Every scheduled visit, in `rebuildScheduledDanger` after `changed` is known:
   `NAVSRC sched tick=<t> seat=<i> changed=<0|1> n=<count> cells=<cx>:<cy>[,<cx>:<cy>...] pts=<x>:<y>[,...]`
   Cells come from `system.map.cellOf(point)`; raw points are kept so the
   close-floor square can be reproduced and so cell rounding can be audited.
4. Per-source measured ray work, in `rebuildDangerFromPoints`: a threadvar
   step counter incremented once per `castRay` while-loop iteration, reset
   before each source and read after its perimeter loop. Emit one line per
   changed rebuild:
   `NAVSRC rays tick=<t> seat=<i> src=<cx>:<cy>:<steps>[,...]`
   Steps are exact loop iterations of the production ray code, so the cache
   model uses measured per-key work instead of a geometric estimate. The
   counter adds one increment per iteration only under the define.

Volume: about one due seat per tick, under 300 bytes per line, so a
3,000-tick episode writes under 1 MiB.

Exactness of the instrumentation: nothing above changes control flow or
values. The step counter is write-only from the ray loop. No binary-identity
claim is made for the no-define build (line metadata and stamps can differ).
Verification used instead: the focused suites `test_shell_body_nav_rework`
and `test_shell_body_seat` (danger fingerprint goldens included) pass when
built with `-d:navSourceTrace`; logs are preserved beside the patch. Every
line carries `sys=<id>` from the seat's own field, never from the last
header printed.

## 4. Workload: real server episodes, policy choice, and limitations

Launcher: `tools/run_shell_demo.sh`, unchanged except for the two overrides
in section 5 that a sed-produced scratch copy adds. It builds `src/ctf.nim`
with `SHELL_EXTRA_NIM_FLAGS`, patches `config.practice.json` with
`tests/fixtures/shell/shell_demo_config.json`, launches the real BR server
with `season2Shell`, and attaches 32 presence clients.

Two facts about this launcher matter for reuse measurement:

- Presence clients are not policies. Movement comes from the server-side
  demo play: `edge_ride` (`play_sdk/reference/edge_ride.nim`) on
  `demoPlay.seats` 0 to 7 only. The other 24 seats hold at spawn. A source
  that never moves lands in the same 8 px cell every cadence, which inflates
  hit rates. The plan therefore runs two movement conditions and reports
  both; the all-mover condition is the gating one.
- The demo config keeps the practice map: `config.practice.json` carries an
  inline `mapSpec` (`br-gen-4242`, 3211 by 1713) and top-level `gunRange 497`.
  An inline `mapSpec` wins over `mapPath` (`src/ctf/sim_config.nim:1339-1389`),
  so the shipped `brpool16` pool is not used unless the patch deletes
  `mapSpec`. The patch format supports deletion (`null` pops the key).

Real participant plays are not available locally; the play SDK ships
`hello_play` and `edge_ride` only. `record_br_match.sh` and the
`record_br_*` roster scripts launch policy binaries into the non-shell BR
mode (no `control: "play"` slots), so they would not exercise shell danger
rebuilds at all. `edge_ride` on every seat is the most realistic local option
and is stated as a limitation: live plays will move differently, and the
trace's hit rate is evidence about the mechanism, not a forecast of the
production rate.

Chosen conditions:

| Condition | Movers | Seats | Map | gunRange | Ticks | Runs |
|---|---|---|---|---|---|---|
| A (gating) | `edge_ride` on all seats | 32 | brpool16, seeds 679961, 679962, 679963 | 1300 | 3000 | 3 |
| B (gating) | `edge_ride` on all seats | 16 | brpool16, same three seeds | 1300 | 3000 | 3 |
| C (contrast) | default demo, 8 movers | 32 | brpool16, seed 679961 | 1300 | 3000 | 1 |
| D (contrast) | `edge_ride` on all seats | 32 | practice inline map, unchanged | 497 | 3000 | 1 |

Eight runs total. The seeds are the manifest seed and its successors so the
map pick is the real `brPoolIndex(seed, n)` spread
(`src/ctf/br_map_pool.nim:105`); the actual map name for each run is read
from the run's resolved config (`mapSpec.name`), not assumed. Because
`mapSpec` is resolved once at config parse (line 1388), every game inside one
server process uses the same map even though the seed increments on reset
(`src/ctf/server.nim:4943`). One map per process is therefore one episode per
process: `maxGames 1`.

Ticks: the demo zone schedule sums to 3,000 ticks, and eliminations by zone
damage produce real life boundaries. `maxTicks 3000` bounds the episode
without changing the schedule. `fastMode true, speed 16` (the values
`record_br_match.sh` uses) shortens wall time; the danger cadence is
tick-indexed, so wall speed does not change the trace. Section 7 checks that
claim rather than assuming it.

## 5. Exact commands

Run from the worktree root. `RUN_TAG` names the condition and seed.

Scratch copy of the launcher with two env overrides (patch file and seat
count). The copy must live under `tools/` because the script cds to its own
parent. It is temporary and is deleted in step 6.

```bash
sed -e 's#"$REPO_ROOT/tests/fixtures/shell/shell_demo_config.json"#"${SHELL_DEMO_PATCH:-$REPO_ROOT/tests/fixtures/shell/shell_demo_config.json}"#' \
    -e 's#for seat in $(seq 0 31); do#for seat in $(seq 0 $((${SHELL_DEMO_SEATS:-32} - 1))); do#' \
    tools/run_shell_demo.sh > tools/run_shell_demo_trace.sh
chmod +x tools/run_shell_demo_trace.sh
diff tools/run_shell_demo.sh tools/run_shell_demo_trace.sh   # expect exactly two changed lines
```

Condition A patch (32 seats, all movers, brpool16, 1300). Written to the
research tree so it is part of the manifest.

```bash
mkdir -p docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace
python3 - <<'PY'
import json
base = json.load(open("tests/fixtures/shell/shell_demo_config.json"))
for seed in (679961, 679962, 679963):
    p = dict(base)
    p["mapSpec"] = None            # drop the inline practice map
    p["mapPath"] = "brpool16"
    p["gunRange"] = 1300
    p["seed"] = seed
    p["maxTicks"] = 3000
    p["maxGames"] = 1
    p["fastMode"] = True
    p["speed"] = 16
    p["demoPlay"] = dict(base["demoPlay"], seats=list(range(32)))
    json.dump(p, open(f"docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace/patch_A_{seed}.json", "w"), indent=1)
    q = dict(p)
    q["slots"] = base["slots"][:16]
    q["demoPlay"] = dict(base["demoPlay"], seats=list(range(16)))
    json.dump(q, open(f"docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace/patch_B_{seed}.json", "w"), indent=1)
c = dict(base); c.update(mapSpec=None, mapPath="brpool16", gunRange=1300, seed=679961, maxTicks=3000, maxGames=1, fastMode=True, speed=16)
json.dump(c, open("docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace/patch_C_679961.json", "w"), indent=1)
d = dict(base); d.update(maxTicks=3000, maxGames=1, fastMode=True, speed=16)
d["demoPlay"] = dict(base["demoPlay"], seats=list(range(32)))
json.dump(d, open("docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace/patch_D_practice.json", "w"), indent=1)
PY
```

Open question for root before running B: `config.practice.json` has 32
`tokens`; with 16 slots the server may reject or ignore the extra tokens.
If the 16-seat server refuses the config, keep 32 slots and set
`SHELL_DEMO_SEATS=16` so only 16 presence clients bind; the other 16 slots
never activate and the trace shows them as never-active seats. Record which
of the two shapes was used.

One run (repeat per condition and seed; the port avoids the demo default and
the fleet-owned 21400 to 21403):

```bash
export RUN_TAG=A_679961
export SHELL_EXTRA_NIM_FLAGS="-d:navSourceTrace"
export SHELL_DEMO_PATCH="$PWD/docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace/patch_${RUN_TAG}.json"
export SHELL_DEMO_SEATS=32          # 16 for condition B
export SHELL_DEMO_PORT=21895
export TMPDIR="$PWD/tmp/cache-trace-runs"; mkdir -p "$TMPDIR"
tools/run_shell_demo_trace.sh > "$TMPDIR/launcher_${RUN_TAG}.log" 2>&1 &
LAUNCHER=$!
# The server exits by itself after maxGames; the launcher's tail does not.
RUN_DIR=""; until [ -n "$RUN_DIR" ]; do sleep 2; RUN_DIR=$(ls -d "$TMPDIR"/coworld-ctf-shell-demo-* 2>/dev/null | tail -1); done
until grep -q '^game 1 done' "$RUN_DIR/server.log" 2>/dev/null; do
  kill -0 $LAUNCHER 2>/dev/null || break; sleep 5; done
sleep 2; kill -INT $LAUNCHER; wait $LAUNCHER 2>/dev/null || true
```

Root should confirm the exact end-of-game line by reading the first run's
server log rather than trusting `game 1 done`; that string comes from the
squad-mode branch at `src/ctf/server.nim:5462` and may not print in this
mode. A fallback is to wait until the server PID exits.

Preserve the raw artifacts and extract the trace:

```bash
OUT=docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace/${RUN_TAG}
mkdir -p "$OUT"
cp "$RUN_DIR/config.json" "$RUN_DIR/server.log" "$OUT/"
grep '^NAVSRC ' "$RUN_DIR/server.log" > "$OUT/navsrc.txt"
python3 -c "import json;c=json.load(open('$OUT/config.json'));print(json.loads(c['mapSpec'])['name'] if isinstance(c.get('mapSpec'),str) else c['mapSpec']['name'], c['gunRange'], len(c['slots']))" > "$OUT/identity.txt"
printf 'head=%s\nnim=%s\nflags=%s\nseed=%s\ndate=%s\n' "$(git rev-parse HEAD)" "$(nim -v | head -1)" "$SHELL_EXTRA_NIM_FLAGS" "$(python3 -c "import json;print(json.load(open('$OUT/config.json'))['seed'])")" "$(date -u +%FT%TZ)" > "$OUT/manifest.txt"
```

Cleanup after all runs: `rm tools/run_shell_demo_trace.sh`, revert the
`navSourceTrace` block, and confirm `git status` shows only the research
tree.

## 6. Offline cache model

Script placed by root at `research/cache-trace/cache_sim.py` (contents
below). It models only actual raycast calls: the per-source perimeter ray
work on the changed branch. The close floor is exact-pixel and stays
uncached, so it is never counted as saved. Kernel accumulation into the
seat's raster is not a ray and is also not counted as saved; a hit still has
to replay the visible-cell list into the seat's raster, so "ray steps
removed" is an upper bound on the work a cache could remove, and the plan
says so wherever the number is reported.

Model rules:

- Key: `(sys_id, cell_x, cell_y)`; `sys_id` is the nav-system header counter
  and carries map and range. Different processes never share keys.
- Event stream: `sched` lines with `changed=1` produce one lookup per source
  in the logged order; `changed=0` lines produce nothing (L0 already skips
  them). `rays` lines supply the measured steps per key at that rebuild.
- Cost on miss: the measured steps for that source. Saved on hit: the
  measured steps the miss would have paid, taken from the same `rays` line.
  Because the ray code is deterministic on static geometry, the steps for a
  key are the same at every occurrence; the script asserts this and reports
  any violation as a defect in the instrumentation rather than averaging.
- Replacement: LRU with capacities 8, 16, 32, 64, 128, 256, and unbounded.
  Unbounded gives the compulsory-miss floor (distinct keys).
- Intra-rebuild duplicates (two selected sources in the same cell) are
  reported separately as `dup_hits` and included in the hit count, matching
  the dedupe rule from `WF1_ROOT_REVIEW.md`.
- Life and activation: `active seat=i active=0` invalidates nothing in the
  shared cache (keys are geometry only), but the script reports lookups per
  life so a long-lived static camper does not hide a low rate elsewhere.

```python
#!/usr/bin/env python3
"""LRU model over NAVSRC traces. Usage: cache_sim.py navsrc.txt [more...]"""
import sys, re
from collections import OrderedDict

def parse(path):
    sys_id = None; lines = []
    for raw in open(path):
        if not raw.startswith("NAVSRC "): continue
        kind, *rest = raw[7:].split()
        kv = dict(t.split("=", 1) for t in rest)
        if kind == "sys": sys_id = kv["id"]
        kv["sys"] = sys_id
        lines.append((kind, kv))
    return lines

def rebuilds(lines):
    pending = {}
    for kind, kv in lines:
        if kind == "sched" and kv["changed"] == "1":
            cells = kv["cells"].split(",") if kv["n"] != "0" else []
            pending[(kv["tick"], kv["seat"])] = (kv["sys"], cells)
        elif kind == "rays":
            sys_id, cells = pending.pop((kv["tick"], kv["seat"]))
            steps = [int(s.split(":")[2]) for s in kv["src"].split(",")] if kv["src"] else []
            assert len(steps) == len(cells), (kv, cells)
            yield sys_id, kv["tick"], kv["seat"], list(zip(cells, steps))

def simulate(all_rebuilds, cap):
    lru = OrderedDict(); hits = misses = dup = saved = total = 0
    seen_steps = {}
    for sys_id, tick, seat, srcs in all_rebuilds:
        in_this = set()
        for cell, steps in srcs:
            key = (sys_id, cell); total += steps
            if key in seen_steps: assert seen_steps[key] == steps, ("nondeterministic steps", key)
            else: seen_steps[key] = steps
            if key in lru:
                hits += 1; saved += steps; lru.move_to_end(key)
                if key in in_this: dup += 1
            else:
                misses += 1; lru[key] = steps
                if cap and len(lru) > cap: lru.popitem(last=False)
            in_this.add(key)
    return dict(cap=cap or "inf", lookups=hits + misses, hits=hits, dup_hits=dup,
                hit_rate=hits / max(1, hits + misses), total_steps=total,
                saved_steps=saved, steps_removed=saved / max(1, total),
                distinct_keys=len(seen_steps))

def main(paths):
    for path in paths:
        lines = parse(path); rb = list(rebuilds(lines))
        sched = [kv for k, kv in lines if k == "sched"]
        print(f"== {path}: sched={len(sched)} changed={sum(kv['changed']=='1' for kv in sched)} "
              f"unchanged={sum(kv['changed']=='0' for kv in sched)} "
              f"activations={sum(k=='active' and kv['active']=='1' for k,kv in lines)} "
              f"init_lines={sum(k=='init' for k,_ in lines)}")
        for cap in (8, 16, 32, 64, 128, 256, None):
            r = simulate(rb, cap)
            print("  " + " ".join(f"{k}={v:.4f}" if isinstance(v, float) else f"{k}={v}" for k, v in r.items()))

if __name__ == "__main__": main(sys.argv[1:])
```

The script is small enough to read in full; it does no timing and makes no
claim beyond counts.

## 7. Checks that make the numbers trustworthy

1. Instrumentation exactness: build with and without the define; the
   no-define binary must match the current head build. With the define,
   `dangerFingerprint` golden tests must still pass (root's test run, not a
   claim here).
2. Consistency: every `sched changed=1` line has exactly one `rays` line with
   the same tick and seat and the same source count; every key has one
   step count across the whole trace (the script asserts both).
3. Speed independence: run condition A seed 679961 once at `speed 1,
   fastMode false` for 600 ticks and compare the `NAVSRC` lines for those
   ticks against the fast run. Presence-client join timing can shift
   activation ticks, so identical activation ticks are not required; what
   must match is the per-life sequence of selections once seats are active.
   If they differ, record it and report both, do not pick the better one.
4. Activation separation: count `active=1` lines, the tick of each seat's
   first `changed=1` rebuild after it, and confirm zero `init` lines.
5. L0 share: report changed versus unchanged rebuild counts per run; this
   also independently confirms the L0 behaviour on a real episode.
6. Map identity: `identity.txt` per run, plus the header `sight_fnv`; the
   three seeds must yield three different names, otherwise the pool spread
   assumption failed and the plan is amended, not the result.

## 8. Preregistered decision rule

Primary metric: `steps_removed` at LRU capacity 64 in conditions A and B, per
run. Secondary: `hit_rate`, `distinct_keys` (compulsory floor), and the
capacity at which `steps_removed` reaches within 5 points of the unbounded
value.

- Proceed to a cache design review only if `steps_removed` at capacity 64 is
  at least 0.30 in at least two of three maps for both seat counts.
- Otherwise the shared per-source LOS cache is rejected on the count gate,
  the same way the wavefront direction was, and the negative is preserved
  under `research/cache-trace/`.
- Condition C (8 movers) is reported for contrast only; if C passes and A
  fails, that is evidence the demo's static holders were inflating earlier
  optimism, and it is recorded as such.
- Condition D (practice map, 497 px) is the corpus-like control; a pass on
  D with a fail on A is the workload-scope mismatch again and is reported,
  not averaged.

No timing is derived from this trace. If the gate passes, timing belongs to
root's remote queue after C1 is confirmed DONE, under a separate
preregistration.

## 8a. Where the capture landed

Executed 2026-09-10 in the trace worktree. Results, verdict, and every raw
artifact: `nav-source-trace/docs/designs/nav-rework-evidence-2026-09-09/research/cache-trace/CACHE_TRACE_RESULT.md`
(root copies finished artifacts after review). The runner actually used is
`tools/nav_source_trace_run.sh` in that worktree (real baseline S2 clients,
not the demo script's presence clients), so sections 4 and 5 above describe
the superseded revision 1 procedure and are kept for the record.

## 9. Bounded effort

- Instrumentation: about 40 lines under one define in `body_nav.nim`.
- Runs: eight episodes at 3,000 ticks, fast mode; wall time is dominated by
  the compile and the presence-client startup, not the game.
- Analysis: one script, one table per run, one summary table across runs.
- Out of scope: any change to selection, cadence, thresholds, or the ray
  code; any remote run; any replay of GV63 fixtures.

CACHE TRACE PLAN READY

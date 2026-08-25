# BR final match report — first true 16-duo battle royale

Recording: `br-final-match.bitreplay` (root of this worktree, also mirrored into
`static-replay-viewer/` for the hosted viewer). Recorded via
`tools/record_br_match.sh` against the round-9 multi-room-interiors map
(`br-match-map-r9-301.json`, generator seed 53017), on top of the integration
branch as it stood after `1b18cfc` (BR endgame: alive-team readback +
close-on-nearest hunt override) and `e8ab343` (round-9 map draw), before the
zone-art and zone-paint-perf commits that landed later on this branch. This is
the first end-to-end recording of the mode contract in
`docs/designs/BR_MAPGEN.md` §1 played by real bots: 16 duos (32 seats), one
life per seat, no respawns, a closing zone as the only clock.

## Setup

- Map: 3211×1713 (giant), 16 spawn groups, `gunRange` 331px (map-derived, not
  config-overridden — see `record_br_match.sh`'s note on why `gunRange` is
  deliberately absent from the match config).
- 32 seats, 16 teams of 2 (`duo00`…`duo15`, colors `red, blue, green, yellow,
  black, silver, ivory, pink, umber, rust, orange, plum, lime, navy, azure,
  peach` in that slot order), `lives=1`, `brMode=true` (no respawns),
  `barrageMaxPerSec=0` (barrage disabled so the zone is the only pressure
  source).
- Zone: 5 phases, `z` (rect scale) `0.75 → 0.55 → 0.40 → 0.28 → 0.17`, waits
  `600/480/360/240/180` ticks, shrinks `420/360/300/240/180` ticks, `dps`
  `0/2/4/8/12`. Center is drawn, not fixed at map center (§4.3).
- Lobby ends and `Playing` starts at tick 360 (`gameStartTick`). The match
  ends at tick 3229 (`maxTicks` was 6000 — it ended on elimination, not the
  clock), so play covered 2869 ticks and never reached the phase-4 shrink's
  scheduled end (3120–3360) or phase 5 at all.

## What happened

**Combat was rare and concentrated.** Of 32 seats, only 8 (both seats each of
`red`, `blue`, `green`, `yellow`) ever fired a shot; the other 24 seats (12
duos) recorded zero `gun_trigger` events for the entire match. Total: 87 shots
fired, 22 hits, 25.3% aggregate accuracy — individual seats ranged 16.7–41.7%.
Only 4 of the match's 30 recorded deaths were player-caused kills:

| tick | killer | victim |
|---|---|---|
| 1318 | red (slot 0) | green (slot 18) |
| 1430 | red (slot 0) | green (slot 2) |
| 1510 | blue (slot 1) | yellow (slot 3) |
| 2022 | blue (slot 17) | yellow (slot 19) |

`red` and `green` fought each other; separately, `blue` and `yellow` fought
each other. No other pair of teams ever exchanged fire.

**The zone did the eliminating.** The other 26 deaths (13 of the 15
non-winning teams eliminated outright, plus the last two `red`/`blue` seats
that survived their early duels) were zone damage, not combat. The sharpest
moment is tick 1408–1423: as phase 2's wait begins (rect already shrunk to
its phase-1 target, `dps` now 2), six teams — `lime, umber, navy, azure,
rust, peach` — lose their second seat within those 15 ticks, all
zone-caused. That is 12 seats gone almost at once, purely from positioning
relative to a rect none of them were fighting over (`green`'s elimination at
1430, by contrast, was the `red` combat kill from the table above — close in
time but a different cause).

**Elimination order** (tick a team's second seat died): `lime` 1408,
`umber` 1418, `navy`/`azure` 1419, `rust` 1421, `peach` 1423, `green` 1430
(combat), `black` 1993, `yellow` 2022 (combat), `orange` 2159, `silver` 2242,
`red` 2606, `plum` 2607, `blue` 2866, `pink` 3229 (the match's final tick).
`ivory` (`duo06`) is the only team never fully eliminated and won.

**The final stretch had no fight in it.** From tick 2606 (5 teams alive) the
alive-team count only fell — 4 at 2606, 3 at 2607, 2 at 2866 — comfortably
inside the hunt override's `aliveTeams <= 4` trigger window for the last
~620 ticks of the match. Per-tick position data
(`tools/extract_events.nim --frames`) shows:
- `blue` (the team eliminated at 2866) jittered within a roughly 100×130px
  box (`~(720,890)` to `~(796,819)`) during its last ~260 ticks alive — some
  movement, but not a clear approach toward either surviving team.
- `ivory` and `pink`, the final two, sat at **exactly** fixed coordinates —
  `(1427,738)` and `(2026,732)` respectively, 599px apart — for the entire
  363-tick stretch from `blue`'s death to the match's end. Neither team moved
  a single pixel. No shots were fired between them. `pink` died to the zone
  at tick 3229; `ivory` never engaged and won with **zero recorded deaths**
  the entire match.

This means the close-on-nearest hunt override (`1b18cfc`, verified firing
"with sane, decreasing-distance chase targets" in that commit's own smoke
match) did not visibly engage in this recording's final stretch, despite its
trigger condition being active for over 600 ticks. This is a real,
data-backed observation, not a re-run of that commit's own smoke test — worth
a follow-up before the doctrine treats the hunt override as field-proven, but
out of scope for this lane (perf + this report) to root-cause further.

**Alive-team readback did work.** The subagent verification pass below
confirms the scoreboard chip tracked all 16 duos' live/dead state correctly
and in real time through to the endcard (16 alive early → 2 at the final
two-team stretch → 1 winner), matching this report's own event-log tally
exactly.

## Viewer verification (static-replay-viewer, port 21404)

A separate check loaded `br-final-match.bitreplay` in the hosted static
viewer end to end:
- Loaded and played with no wasm/JS errors (only a benign `favicon.ico` 404
  in the console across the whole session).
- Early game: map, terrain and all ~32 soldier sprites render correctly.
- Endgame (tick 2869 of 2869 on the viewer's own start-relative clock, i.e.
  absolute tick 3229): an endcard reads **"DUO06-0 + DUO06-1 WIPES THE
  FIELD"**, header pill **"IVORY WINS"**, win condition `ELIMINATION`, and
  the per-team breakdown shows `duo06` alone at 2 lives with all 15 other
  duos at 0 — matching this report's event-log reconstruction exactly.
- Live HUD scoreboard at intermediate ticks correctly reflects the shrinking
  alive-team set (confirmed only `duo06`/`duo07` at "2" lives with the other
  14 rows at "0" during the final stretch) — a direct, positive confirmation
  of the alive-team readback mechanic, not just the endcard.
- Zone-tide paint visibly covers nearly the whole board by the final stretch,
  leaving a small safe-zone island — consistent with the recorded zone-phase
  math above.

## Perf: the tide-cache fix (`d8e958c`), measured

Commit `d8e958c` fixed `ensureZoneTideCache`'s cache key, which used to
include `sim.tickCount` — a value that is different on every tick by
definition, so the cache could only ever hit *within* one tick (deduping
multiple viewers), never *across* ticks, even while the zone rect sat frozen
for hundreds of ticks during a `zonePhases` "wait" window. This section
measures that fix against this same recording rather than asserting it.

**Primary evidence — deterministic rebuild count, immune to machine load.**
`ensureZoneTideCache` now returns whether it actually rebuilt; a probe build
(`-d:zoneTideCacheProbe`, instrumentation added for this measurement, gated
off by default — see "where things are" below) counts calls/hits/misses.
Two real runs of `tools/render_replay_movie_fast` over this recording, one
built from the current commit (`d8e958c`) and one from its immediate parent
(`244afe4`, the last commit before the cache-key fix), over the **identical**
tick window (500–900, every tick — squarely inside phase 1's wait, where the
rect never moves):

```
after  (d8e958c): ZTC calls=401 hits=400 misses=1
before (244afe4):  ZTC calls=401 hits=0   misses=401
```

Same replay, same 401 ticks, same call site. Before the fix: every single
call rebuilds (0% hit rate) — expected, since the old key included
`sim.tickCount`, which is different on every one of those 401 calls by
definition. After the fix: 400 of 401 calls hit the cache and skip both the
flood-fill rebuild and the sprite re-encode entirely; the one miss is the
first call, which legitimately establishes the cache. That is the fix,
measured directly, not inferred.

The same probe over the **full match** (ticks 360–3229, every tick — the
"primary" re-simulation path the replay viewer and broadcast client both
use) on the current commit:

```
ZTC calls=2870 hits=1679 misses=1191
```

**58.5% of every frame-build call across the whole match now skips the
rebuild.** That number is not incidental: the config's four wait-phase
windows sum to 600+480+360+240 = 1680 ticks, and the measured hit count
(1679) matches within 1 — the one-tick slop is the first tick of each wait
window, which is still a miss (the rect just changed getting there). This
confirms the cache hits on precisely the ticks it should: every tick the
rect doesn't move, and only those ticks. (The pre-fix code was not re-run
over the full 2869-tick match: an attempt was abandoned after the shared
machine's concurrent load throttled it to single-digit-percent CPU and
multi-second per-frame times — see the wall-clock caveat below. It didn't
need to finish: the 401-tick matched window above already gives a real,
paired measurement of the same mechanism, and the pre-fix miss rate over any
window follows from the same architectural fact — a strictly-monotonic tick
in the key, one call per tick — that produced the observed 401/401.)

**Secondary evidence — wall clock, heavily caveated.** This machine was
under real concurrent fleet load for the entire measurement window (multiple
other agents' processes competing for CPU; one comparison run was throttled
to single-digit percent CPU and produced 5–8 second per-frame times that are
obviously load artifacts, not signal — consistent with this project's
standing finding that fleet load corrupts wall-clock timing measurements).
Treat the numbers below as directional only:

- Matched wait-window sample (ticks 500–900, inside phase 1's wait, rect
  frozen the whole time), non-probe binaries, per-frame `build` time
  (`buildSpriteProtocolUpdates`, of which zone paint is one part):
  before-fix median 1ms / p90 3ms / sum over 401 frames 3117ms; after-fix
  median 1ms / p90 2ms / sum 2570ms. Directionally consistent with the fix
  (lower after), but both distributions are dominated by a handful of
  multi-second fleet-load spikes in the tail, so this is weak evidence on
  its own — the call-count number above is the one to trust.
- Matched shrink-window sample (ticks 1000–1350, phase 1's shrink, rect
  moves every tick so the cache cannot hit either before or after the fix):
  both builds cost ~140–195ms/frame, confirming no regression where none is
  expected. This also surfaces the honest next lever the fix's own commit
  message named but didn't take: **shrink-phase frames cost roughly
  100× a settled wait-phase (post-fix) frame** (190ms vs ~1–2ms). Shrink
  windows total 420+360+300+240 = 1320 of this match's 2869 played ticks
  (46%) — the "monotone accumulation" idea the commit message deferred
  (touch only the frontier band on a shrink tick instead of rebuilding the
  full bars) is where the next real win is, not anywhere in the wait
  windows this fix already closed.

## Where things are

- Report: `/private/tmp/br-integrate/BR_FINAL_MATCH_REPORT.md` (this file).
- Recording: `/private/tmp/br-integrate/br-final-match.bitreplay`, mirrored
  at `/private/tmp/br-integrate/static-replay-viewer/br-final-match.bitreplay`
  for the hosted viewer at `http://127.0.0.1:21404/index.html?replay=br-final-match.bitreplay`.
- Probe instrumentation: `-d:zoneTideCacheProbe` in `src/ctf/global.nim`
  (`ensureZoneTideCache`) and `tools/render_replay_movie_fast.nim`, gated
  off by default — a permanent, cheap diagnostic in the same style as the
  existing `-d:zonePaintOff` toggle the fix commit shipped, not a one-off
  debug print.

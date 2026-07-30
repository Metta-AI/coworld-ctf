# Checking that a pack map PLAYS right

Review rejected the pack twice. The second time the footprints really were
measured off the real minimaps, and the verdict was still *"they look like you
just pasted gray walls randomly based on a 2d image — the gameplay wouldn't be
anywhere near the same."*

That is the standard, and it is not what any existing check measures. The
invariant tests (`tests/test_mw2_maps.nim`) prove a map is **legal** —
reachable, no sealed pockets, no free firing row, fair to both halves. None of
them prove it is **played**. A map can pass all of them and still be a corridor
with decorative geometry.

## The loop

```bash
nim c -d:release --hints:off -o:/tmp/mw2playtest tools/mw2_playtest.nim

# Several seeds per map — see "one episode is not a map" below.
for s in 5 11 23; do
  PORT=$((25000 + RANDOM % 500)) tools/record_fixture.sh \
    rust-s$s.bitreplay $s 6000 '{"mapPath":"rust"}' >/dev/null 2>&1
  /tmp/mw2playtest rust-s$s.bitreplay --out /tmp/pt_rust_s$s.json
done

# The default arena is the CONTROL: it is the layout the game was tuned on.
python3 tools/mw2_playtest.py /tmp/pt_arena_s*.json /tmp/pt_rust_s*.json
python3 tools/mw2_gallery_regen.py   # heatmaps land under each map's art
```

Record and analyse from ONE build, and note the sha: both sessions commit to
this branch, so a replay recorded before a layout change will not re-simulate
after it (you get a replay hash mismatch, not a wrong answer — the tool fails
loudly, which is the good case).

`mw2_playtest.nim` re-simulates a recorded episode and dumps where the game
actually happened — per-team occupancy, every death, the flag's own track, and
the objective model in force (home points, capture radius, spawn zones).
`mw2_playtest.py` merges the episodes, renders the heatmap (warm where players
spent time, **pale where nobody went**, rings at deaths, dots along the carry
routes, the capture zone and spawn zones drawn on top), and reports:

- **midfield lanes** — distinct gaps crossing the center band, and how many saw
  traffic. This is the "three-lane" property in measurable form.
- **carry lanes** — which of those lanes the FLAG actually crossed in. Three
  ways across mean nothing if every carry takes the same one.
- **steals → captures** — the conversion rate, against the control's.
- **stand ring** — how open the ground is immediately around each pedestal,
  which is the decisive real estate now that capture happens AT the stand.
- **dead floor %** — open ground no player visited.
- **sightline distribution** — how far an open shot runs before geometry cuts
  the angle.

## Four traps, every one of which produced a confidently wrong number

**One episode is not a map.** Episode length dominates dead space: a match that
ends in a fast wipe leaves most of the field unvisited. Measured on a single
1725-tick episode Rust read as catastrophic — 53% dead floor. Across three it
is 22%. Merge seeds before judging.

**A capture ENDS the episode.** Scoring calls `finishGame`, so episode length is
itself an outcome, and dead space is not comparable between a map whose games
run to the tick limit and one whose games are decided at half that. The report
now prints each episode's length and result, and refuses to call a map
decorative off a short sample.

**When a metric flags your control, the metric is wrong.** Twice.
1. The first lane metric ("find a path, wall it off, find another") reported ONE
   route for every layout including the default arena, because blocking a path
   at cell scale severs the map. Counting distinct midfield gaps scores the
   arena at 5 and is the shape of the actual question.
2. Capture detection read the carrier's `k -> -1` edge — which never arrives,
   because the game ends on the capture tick. It reported 0 captures on every
   map *including the arena*. It now evaluates the engine's own predicate on
   the same state.

**A metric that cannot see its control is worse than one that fails on it.** The
stand metric originally counted distinct open arcs around a pedestal and skipped
maps still on the legacy capture column — which meant it never ran on the arena
at all. It reported "Rust's red stand has 1 approach, a turkey shoot" when that
ring is in fact 81% *open*: a stand in open ground has one enormous unbroken
arc, scoring the same "1" as a stand behind a single doorway. It now reports the
open fraction as the primary number, and runs on every map so the control always
scores.

## Where the layouts stand

Measured on HEAD 1399459, three episodes each, arena as control.

| map | midfield lanes | carry lanes | steals→caps | stand ring (R/B) | dead floor | median sightline |
|---|---|---|---|---|---|---|
| *arena (control)* | *5 (5 used)* | *2* | *17→4* | *86% / 88%* | *6%* | *70px* |
| rust | 3 (3 used) | 2 | 15→2 | 81% / 91% | 10% | 100px |
| terminal | 4 (3 used) | **1** | 9→4 | 77% / 89% | 19% | 80px |
| highrise | 3 (3 used) | 2 | 15→4 | 100% / 100% | 12% | 90px |
| afghan | 3 (3 used) | 2 | **21→0** | 100% / 100% | 5% | 120px |
| **favela** | **1 (1 used)** | **1** | 17→4 | 100% / 100% | 16% | 90px |
| **scrapyard** | **1 (1 used)** | 2 | 16→4 | 96% / 100% | 11% | 110px |

Open, with tasks filed:

- **favela and scrapyard cross midfield through a single gap** where the arena
  has five. Unchanged since the first pass.
- **afghan converts nothing.** 0 of 21 steals, where every other map converts.
  Thieves die at the pedestal they lifted from, and Afghan has 6-7% cover within
  200px of a stand against 10-25% everywhere else. Home-stretch cover and route
  length were both checked and are NOT the cause.
- **terminal's alternates do not carry the objective.** Four midfield lanes, three
  see traffic, and every flag carry crossed in the same one.

Not problems, so they do not need re-litigating: dead space (5-19% against the
arena's 6%), sightlines (80-120px against 70px), and stand exposure — no stand
on any map is sealed, and the two maps already on the capture-radius model sit
within a normal spread of the control.

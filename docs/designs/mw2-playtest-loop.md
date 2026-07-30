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

## The degenerate-count trap, which caught me four times

Three of the metrics here started as a COUNT of openings, and a count alone
cannot tell "one narrow doorway" from "one enormous gap" — they both score 1.
Every time, the wrong reading was confident and plausible:

- the flag-stand ring called Rust "1 approach, a turkey shoot" for a ring that
  is 81% **open**;
- the midfield lane count called Favela "a corridor" for a midfield that is
  73% open in one 486px span;
- and when I replaced that with an absolute openness threshold, it fired on
  the arena, which is itself 73% open.

Report a fraction beside every count, and pick thresholds against the control
rather than out of the air. A fourth variant is worth naming separately: the
architecture audit tried to bridge doorways with a morphological closing so a
building's pierced shell would read as one structure, and at the ~40px needed
to span a door it also merged the arena's ~48px-spaced pickets into a single
328x620 slab — reporting the CONTROL as the most architectural map in the set.

## Where the layouts stand

Measured after the audit-and-fix pass, three episodes each, arena as control.

| map | midfield lanes | mid open | steals→caps | stand ring (R/B) | interior | dead floor |
|---|---|---|---|---|---|---|
| *arena (control)* | *5* | *73%* | *7→6* | *86% / 88%* | *33%* | *20%* |
| rust | 3 | 71% | 14→4 | 81% / 91% | 45% | 9% |
| terminal | 4 (3 used) | 56% | 10→2 | 77% / 89% | 53% | 22% |
| highrise | 3 | 79% | 9→4 | 70% / 70% | 61% | 11% |
| **afghan** | 3 | 38% | **16→2** | **76% / 85%** | **41%** | 11% |
| favela | **1** | 73% | 20→2 | 89% / 97% | 39% | 6% |
| **scrapyard** | 3 | 62% | **9→4** | **85% / 85%** | 40% | 20% |

Afghan and Scrapyard are the two this pass fixed, and both were the same
defect: a flag stand standing in the open. Afghan had 6-7% of the ground
within 200px of a pedestal as cover and Scrapyard 9-12%, against 10-25% on
every map that converted, and neither had ever scored — Afghan 0 of 21 then 0
of 17, Scrapyard 0 of 10. Afghan now has the walled qalats the real map has
and Scrapyard has hull sections shelved around its stands, and both convert.

Still open, with tasks filed:

- **favela crosses midfield in one 486px span** where the arena divides a
  near-identical 73% openness into five ways across. Not a corridor — the
  opposite — and not a lack of buildings either; its blocks simply stop short
  of the centre.
- **terminal leaves 57,100px² of floor unentered**, the pack's largest, while
  measuring well on everything else.

Not problems, so they do not need re-litigating: dead space (5-19% against the
arena's 6%), sightlines (80-120px against 70px), and stand exposure — no stand
on any map is sealed, and the two maps already on the capture-radius model sit
within a normal spread of the control.

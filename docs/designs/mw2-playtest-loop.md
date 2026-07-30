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
python3 tools/mw2_playtest.py /tmp/pt_arena.json /tmp/pt_rust_s*.json
python3 tools/mw2_gallery_regen.py   # heatmaps land under each map's art
```

`mw2_playtest.nim` re-simulates a recorded episode and dumps where the game
actually happened — per-team occupancy and every death position.
`mw2_playtest.py` merges the episodes, renders the heatmap (warm where players
spent time, **pale where nobody went**, rings at deaths), and reports:

- **midfield lanes** — distinct gaps crossing the center band, and how many saw
  traffic. This is the "three-lane" property in measurable form.
- **dead floor %** — open ground no player visited. The clearest sign that
  geometry is decoration.
- **sightline distribution** — how far an open shot runs before geometry cuts
  the angle.

## Two traps, both of which produced confidently wrong numbers

**One episode is not a map.** Episode length dominates dead space: a match that
ends in a fast wipe leaves most of the field unvisited. Measured on a single
1725-tick episode Rust read as catastrophic — 53% dead floor. Across three
episodes it is 22%, *better* than the arena's 28%. Merge seeds before judging.

**When a metric flags your control, the metric is wrong.** The first lane metric
("find a path, wall it off, find another") reported ONE route for every layout
including the default arena, because blocking a path at cell scale severs the
map. Counting distinct midfield gaps scores the arena at 5 and is the shape of
the actual question.

## Where the layouts stood when this was written

Measured over 3 episodes each, arena as control:

| map | midfield lanes | dead floor | median sightline |
|---|---|---|---|
| *arena (control)* | *5 (5 used)* | *28%* | *70px* |
| rust | 3 (3 used) | 22% | 140px |
| highrise | 3 (3 used) | 30% | 90px |
| afghan | 3 (3 used) | 21% | 120px |
| **favela** | **1 (1 used)** | 12% | 90px |
| **scrapyard** | **1 (1 used)** | 7% | 110px |

Favela and scrapyard funnel every route through a single midfield gap. Sightlines
and dead space are fine across the board — those are *not* the problem, so they
do not need re-litigating.

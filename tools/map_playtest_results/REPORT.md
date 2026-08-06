# Do the generated maps PLAY? — 24 measured episodes, arena as control

**Verdict: at 2 teams the generated maps play WORSE than the hand-authored
arena — clearly and on every dimension measured. At 4 teams there is no
verdict available, because no hand-authored 4-team map exists to be the
control; what the 4-team numbers do show is that the objective never
resolved once in 12 episodes.**

Nothing had been played on a generated map since the generator rewrite. Every
number steering the epic so far is static. This is the first dynamic evidence,
and it does not agree with the static score.

Engine GameVersion 38. Base branch `maxwell/mapgen-rebuild` @ 4a013df.
Bot: `players/baseline`, 16 seats, `maxTicks` 5000, config otherwise stock.
All 24 recordings re-simulated cleanly through the hash-validated replay path,
so the recordings are deterministic and these numbers are ground truth rather
than a reconstruction.

---

## 1. The headline: staticScore does not predict play

`gen:1023` scores **1.000** statically — a perfect score, tying the control
exactly — and is the same 1235x659 board size as the arena. Played:

| | arena (control) | gen:1023 |
|---|---|---|
| staticScore | 1.000 | 1.000 |
| dead floor, matched window | **43%** | **62%** |
| largest region nobody entered | 30,800px² | **293,800px²** |
| enemy time at a pedestal | 0.533% of alive time | **0.212%** |
| steals in 3 episodes | 5 | **0** |

A perfect static score, a board the same size as the control, and in three
full episodes **not one player ever took the enemy heart**. The single largest
unvisited region is 293,800px² — a whole wing, ten times the arena's largest.

This is the answer the epic asked for. staticScore is currently saturated: the
arena and 9 of 36 generated 2-team seeds all score 1.000, so at the top of the
range it has no discriminating power at all, and the maps it cannot separate
play very differently.

---

## 2. Two teams — the controlled comparison

Four maps, three episodes each, arena in the same batch. Seeds chosen to span
the static range: gen:1006 and gen:1023 at 1.000, gen:1024 at 0.864 (the
lowest in the sweep).

```
                                         arena*           gen:1006           gen:1023           gen:1024
                                        CONTROL
  staticScore                             1.000              1.000              1.000              0.864
  episode lengths             1941t 1941t 2172t  5121t 5121t 4153t  3599t 1893t 5121t  2649t 2768t 2753t
  won on the objective                   0/3 0%            1/3 33%             0/3 0%             0/3 0%
  won by wipeout                       3/3 100%             0/3 0%            2/3 67%           3/3 100%
  out of clock, no winner                0/3 0%            2/3 67%            1/3 33%             0/3 0%

  open floor (10px cells)                 6,872              4,773              6,768              4,953
  DEAD SPACE                                42%                58%                61%                50%
  largest dead region                 30,800px²         100,800px²         293,800px²         137,900px²
  exposure (seat-t/cell)                   10.2               26.9               13.0               14.8

  pedestals enemy reached              2/2 100%           2/2 100%           2/2 100%            1/2 50%
  enemy time at pedestal             372 0.533%      10,872 8.482%         187 0.212%          12 0.016%
  steals                                      5                  5                  0                  0
  captures                                    0                  1                  0                  0
  CONVERSION grab->cap                       0%                20%                  -                  -

  kills/1000t                              21.3                7.4               12.2               16.5
  contact, close (262px)                    46%                59%                45%                41%
  balance entropy                          0.99               0.96               1.00               0.99
```

**Per-episode lengths, individually, because a capture ends the episode.** The
arena is decisive and consistent: 1941t, 1941t, 2172t, every one of them a
won game. gen:1006 is the opposite — 5121t, 5121t, 4153t, two of three
expiring on the clock with nobody winning. gen:1023 is erratic: 3599t, 1893t,
5121t. A mean of any of these columns would be a lie.

**Dead space, measured at a matched window.** Episode length varied 2.7x
across the batch, which makes raw dead space incomparable — the map watched
for 5121 ticks has more time to cover its floor than the one decided at 1941.
Re-measured over an identical 1890-tick window on every episode (all exposure
ratios then inside the comparable 0.70–1.40x band):

| | arena | gen:1006 | gen:1023 | gen:1024 |
|---|---|---|---|---|
| dead floor | **43%** | 62% | 62% | 51% |
| delta vs control | — | **+19pp** | **+19pp** | **+8pp** |
| exposure ratio | 1.00x | 1.37x | 1.04x | 1.35x |

All three generated maps leave more of their floor untouched than the control,
by 8 to 19 percentage points, at matched exposure. Not one is better.

**The touch.** The standing field finding is that combat sits at parity and the
objective touch is the gap. Here the gap is one step earlier than conversion:
on gen:1023 and gen:1024 the heart is never even taken. gen:1024 is worse
still — an enemy stood at only **1 of its 2 pedestals**, for 12 seat-ticks
total across three episodes, 0.016% of alive time against the arena's 0.533%.
Half that map's objective was, in play, unreachable.

The one generated map that produced a capture is gen:1006, and it did so with
**8.482%** of alive time spent at a pedestal — sixteen times the arena's
share — for 5 steals and 1 capture. Its pedestals are camped, not contested.

**What is at parity.** Kill balance is even everywhere (0.96–1.00), and
combat happens on all four maps. The generated maps are not broken; they are
maps where the fight works and the objective does not.

---

## 3. Four teams — no control exists, and nothing converted

There is **no hand-authored 4-team map**. `loadCtfMapMetadata` offers exactly
`arena` and `arena-large`, both 2-team, and `resolveCtfMapMetadata` raises
outright on a 4-team config pointed at either ("Config asks for 4 teams but
map arena seats 2"). So the 4-team batch has no yardstick and the harness
correctly refuses a dead-space verdict on it. That absence is itself a finding
for the epic: **at 4 teams the generator cannot be evaluated against anything
but itself.**

Four seeds, three episodes each, 16 seats:

```
                                       gen:1001           gen:1003           gen:1009           gen:1024
  staticScore                             0.710              0.861              0.841              0.897
  episode lengths             5124t 5125t 1997t  5121t 2285t 1864t  5125t 5124t 5125t  4244t 3069t 5124t
  won on the objective                   0/3 0%             0/3 0%             0/3 0%             0/3 0%
  won by wipeout                        1/3 33%            2/3 67%             0/3 0%            2/3 67%
  out of clock, no winner               2/3 67%            1/3 33%           3/3 100%            1/3 33%

  DEAD SPACE                                62%                69%                55%                54%
  largest dead region                113,900px²         395,300px²          67,100px²         125,500px²

  pedestals enemy reached               2/4 50%            2/4 50%           4/4 100%           4/4 100%
  enemy time at pedestal             752 0.972%       4,492 7.715%     14,640 14.725%       9,755 9.687%
  steals                                      0                  0                  1                  8
  captures                                    0                  0                  0                  0
  CONVERSION grab->cap                        -                  -                 0%                 0%
```

**0 captures in 12 episodes.** 9 steals across the batch, none converted.
gen:1009 ran out the clock 3/3 with nobody winning anything.

**A symmetry failure that only play can see.** On gen:1001 and gen:1003 an
enemy reached only **2 of 4 pedestals**. These are rot90-symmetric layouts and
they score as fair statically, but in play two of four teams were never
attacked at all. Static symmetry did not produce symmetric play.

Dead space is 54–69% and the largest single unvisited region on gen:1003 is
395,300px². The heatmaps show why: on gen:1001 and gen:1003 all four teams
funnel out of their corner down one corridor into a single central knot where
essentially every death happens, and the entire outer ring of the board is
untouched paper. gen:1009 produces a literal racetrack — the four teams orbit
a completely empty centre.

---

## 4. Travel heatmaps

`tools/map_playtest_results/heatmaps/`, one per map per team count. Ink is
cover, warm graphite is time spent, tinted by which team held the ground, and
**pale paper is open floor nobody ever entered** — the dead space. Death rings
and carry routes are overlaid.

The 2-team sheet reads at a glance: the arena's play covers the full board
height with deaths spread across it, while all three generated maps collapse
into a single band across the middle with whole blank quadrants above and
below it.

---

## 5. Seeds that would not generate

Sweeping seeds 1001–1040 at both team counts (`seed-generation-sweep.txt`):

| team count | seeds that raised | fraction |
|---|---|---|
| 2 | 1015, 1020, 1028, 1038 | **4/40 = 10.0%** |
| 4 | 1002, 1005, 1006, 1012, 1013, 1017, 1018, 1019, 1022, 1025, 1030, 1033, 1036, 1037 | **14/40 = 35.0%** |

The 4-team rate matches the ~32% a sibling session is fixing; the **2-team
10% raise rate** may be less well known. All skipped seeds are listed above;
no measured seed was skipped for any other reason.

Provenance: this sweep was taken at fork point 4a013df. `maxwell/mapgen-rebuild`
has since advanced by 154ecc7 ("the 4-team raise is budget arithmetic, not
connectivity") and bcf8722, so **the 4-team raise rate above may already have
moved** — re-run the sweep against the current tip before acting on it. The
2-team rate and the seed-diversity collapse below are untouched by those two
commits. Every episode in this report was recorded on 4a013df; none of the
gameplay numbers mix engine builds.

A second thing the sweep shows: at 4 teams the generator has very low seed
diversity. Seeds 1003, 1011, 1014, 1015, 1023 and 1031 all produce byte-identical
metrics (score 0.861, interior 9.8%, 4 chokes at 30px), and 1001, 1007, 1020,
1034 likewise (0.710, 18 chokes at 13px). Six seeds, one map.

---

## 6. Read these numbers with the bot in mind

The control's own conversion is **0/5 = 0%**, and all three arena episodes
ended by wipeout, not by a capture. The baseline bot at 16 seats with lives=3
resolves games by attrition on the arena too. So a low capture rate on a
generated map is not by itself a map defect, which is exactly why the control
had to be in the batch.

What survives that caveat, because it is a delta from the control measured the
same way:

- dead floor **+8 to +19pp** worse on all three generated 2-team maps;
- the enemy heart **never taken at all** on two of three, where the control
  was taken 5 times;
- half of gen:1024's objective **never approached** (1 of 2 pedestals, 0.016%
  of alive time).

The two harness metrics that could have caught none of this, and now can:
`fightTimeFrac` read 99–100% on all four maps (GunRange is 1050px, wider than
the board) so its flag was unfirable — a close-contact radius at GunRange/4
separates the same maps 41–59%. And "0 steals" could not be distinguished from
"steals that failed to convert" until pedestal reach was measured.

---

## 7. What this says to the epic

**staticScore is not steering us somewhere good.** It is saturated at the top
of its range, it scores gen:1023 exactly equal to the arena, and gen:1023
leaves 62% of its floor untouched and never has its heart taken. The static
rubric measures architecture and the play measures whether the architecture is
reachable, and on this evidence those have come apart.

Three concrete follow-ups, filed on the board:

1. Add dead-floor and pedestal-reach to the fitness function, or at minimum
   gate on them. Both are now measurable per map from three episodes.
2. Build a hand-authored 4-team control. Until one exists, no 4-team
   generator change can be evaluated.
3. Investigate the 2-team 10% generation-raise rate alongside the 4-team 35%.

## Reproducing

```
nim c -d:release --out:/tmp/map_eval      tools/map_eval.nim
nim c -d:release --out:/tmp/map_playtest  tools/map_playtest.nim

for m in arena gen:1006 gen:1023 gen:1024; do
  /tmp/map_eval play "$m" --episodes 3 --seats 16 --teams 2 --out /tmp/ev/2t &
done; wait

for r in /tmp/ev/2t/*.bitreplay; do
  base=$(basename "$r" .bitreplay)
  name=$(echo "$base" | sed -E 's/-ep[0-9]+$//' | sed 's/^gen-/gen:/')
  /tmp/map_playtest "$r" --name "$name" --out "${r%.bitreplay}.json"
  # matched window, for a comparable dead-space number
  /tmp/map_playtest "$r" --name "$name" --ticks 1890 --out "/tmp/ev/2t-capped/$base.json"
done

CTF_MAP_GALLERY=/tmp/gal/2t        python3 tools/map_playtest.py /tmp/ev/2t/*.json
CTF_MAP_GALLERY=/tmp/gal/2t-capped python3 tools/map_playtest.py /tmp/ev/2t-capped/*.json
```

Set the `--ticks` window to the shortest episode in the batch, and always put
`arena` in the batch — without it every dynamic number here is unscaled.

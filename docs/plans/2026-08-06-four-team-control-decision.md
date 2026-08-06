# The 4-team control decision, and what the 4-team play lens actually scores

Closes the gate blocker on epic 3757029c. Three things are settled here: which
baseline the 4-team play lens is measured against and why, what that lens scores
in the closeout, and the per-objective reachability measure the last handoff
asked for.

Branch `maxwell/mapgen-4team-control` @ `maxwell/mapgen-rebuild` (986abfb).
Engine built `-d:release` with per-build `--nimcache`. 18 episodes recorded:
15 at 4 teams across 5 maps, 3 on the arena at 2 teams. All 18 re-simulated
cleanly through the hash-validated replay path.

---

## 1. The decision

**The 4-team play lens is measured against `gen:1007` as a LABELLED REFERENCE
POINT — a generated map, named as the yardstick, that can only ever say "worse
than the best board of its own kind". It is NOT a control, and the code no
longer lets a writeup pretend otherwise.**

**The epic's "≥ 1 measured PLAY result per team count WITH THE ARENA CONTROL"
bar scores ZERO at 4 teams.** That bar names the arena specifically, no
hand-authored 4-team map exists, and a within-population reference is a
different kind of object. Both statements are true at once and the scorecard
needs both: the *arena-control bar* is unmet and scores zero, and the *4-team
play lens* is nonetheless measured, against a baseline that is honestly
labelled. Scoring the bar as met would be the dishonest move; scoring the whole
lens as unmeasurable would throw away 15 episodes of real evidence.

This is option 2 of the three offered, as recommended. Options 1 and 3 were
checked against evidence first, and both were checked far enough to change what
option 2 looks like — see §5 and §6.

### Why a reference point is a different KIND of thing, enforced in code

A control is hand-authored and **outside** the population under test, so a delta
from it supports an absolute verdict: worse than a board we know plays. A
reference point is **inside** the population, so if the whole population is bad,
the reference is bad too and every delta from it reads zero while the table
looks healthy. That failure mode is silent, which is why the distinction is now
carried in the data (`Baseline`, `tools/map_playtest.py`) rather than left to
prose. A reference point cannot emit the absolute-form dead-floor verdict; it
gets the comparative form plus a standing caveat, every table it heads is
stamped `REFERENCE`, and the one-page header names the baseline it actually ran
against instead of saying "vs arena" over a batch with no arena in it.

### How `gen:1007` was chosen — and why the obvious rule was rejected

The handoff suggested "the best generated 4-team map by staticScore". **That
rule was tried, measured, and it fails.** Two independent reasons:

**staticScore at 4 teams is collinear with board size.** Ranking seeds 1001–1032
at 4 teams on the current tip, the three size classes separate almost perfectly:

| board | seeds | staticScore range |
|---|---|---|
| 816×816 | 11 | 0.987 – 0.999 |
| 960×960 | 11 | 0.957 – 0.997 |
| 1248×1248 | 10 | 0.867 – 0.954 |

"Best by staticScore" therefore means "smallest board", and dead space — the
headline dynamic metric — is mechanically easier on a smaller board. The
reference would have been rigged in favour of the thing being measured.

**And the map that rule picks is the worst board in the batch on the lens it
would be refereeing.** `gen:1020` (rank #2 overall, top of its size class,
staticScore 0.997) was played specifically to test the rule. Its enemy pressure
splits **6.34% / 11.09% / 0.05% / 0.05%** across its four objectives —
`pressureBalance` **0.50**, dead last of the five maps measured. Two of its
pedestals are contested warzones and two are private corners, on a
rot90-symmetric board that scores 0.997 statically. The heatmap shows it
plainly: the whole fight is red-versus-blue in the top half while green and
yellow orbit an empty diagonal.

So the reference is selected **on the primary lens, after measurement**:

> The 4-team reference point is the board in the measured batch with the best
> objective reachability — highest `pressureBalance`, tie-broken on
> `attackPairs`. It is licensed to say "worse than the best 4-team board we
> could produce and measure" and nothing stronger.

Choosing the best-measured board *is* the definition of that claim, not
circularity — the circularity objection applies only to an absolute claim, which
the code structurally forbids a reference point from making. `gen:1007` wins on
both measures (`pressureBalance` 0.89, `attackPairs` 9/12) and, unplanned, its
profile is the closest of the five to the hand-authored control's: even pressure
at a low absolute level (arena: 0.98 balance, 0.76% total enemy time;
`gen:1007`: 0.89, 3.57%).

---

## 2. The re-measurement, and it is a headline

The "0 captures in 12 episodes" figure was recorded on the pre-W0 generator,
where the terrain block emitted nothing and the 4-team board was almost pure row
cover. Re-measured on the current tip, at the same 16 seats and `maxTicks` 5000:

```
                                             gen:1007*             gen:1003             gen:1010             gen:1013             gen:1020
                                             REFERENCE
  episode lengths                    2729t 3690t 2903t    1827t 5121t 5121t    2082t 5121t 3659t    1974t 2545t 5124t    5124t 5121t 1930t
  won on the objective                          0/3 0%               0/3 0%              1/3 33%               0/3 0%               0/3 0%
  won by wipeout                              3/3 100%              1/3 33%              1/3 33%              2/3 67%              1/3 33%
  out of clock, no winner                       0/3 0%              2/3 67%              1/3 33%              1/3 33%              2/3 67%

  DEAD SPACE                                       40%                  59%                  60%                  41%                  42%
  exposure (seat-t/cell)                           9.5                  8.7                  5.8                 11.9                 11.7

  objectives approached                       4/4 100%             4/4 100%             4/4 100%             4/4 100%             4/4 100%
    each, % of alive time      1.78% 0.51% 0.47% 0.81%  0.82% 9.38% 5.66% 2.73%  1.63% 8.79% 8.27% 0.13%  5.80% 0.94% 0.13% 4.21% 6.34% 11.09% 0.05% 0.05%
    each, enemies that came            3/3 3/3 1/3 2/3      3/3 2/3 1/3 1/3      2/3 1/3 1/3 1/3      3/3 3/3 1/3 2/3      3/3 3/3 1/3 1/3
  attack pairs realized                       9/12 75%             7/12 58%             5/12 42%             9/12 75%             8/12 67%
  pressure balance                                0.89                 0.81                 0.69                 0.70                 0.50
  steals                                             3                    0                    3                    2                    3
  captures                                           0                    0                    1                    0                    0
```

**Three findings, in order of how much they change the epic's position.**

**The 4-team objective converts, and it did not before.** `gen:1010` ep2 ended
`WON ON THE OBJECTIVE` — 3 steals → 1 capture, 33% conversion. The prior figure
was 0 captures in 12 episodes and 9 steals none of which converted. One capture
in 15 episodes is not a healthy objective, but it is categorically different
from zero: it retires the hypothesis that the baseline bot simply cannot convert
a 4-way objective, which was one of the two opposite conclusions the old number
could not distinguish between. The other conclusion — that the maps were the
problem — is the one the evidence now supports.

**Every objective was approached on every board: 4/4 on all five maps.** The
pre-W0 failure where an enemy reached only 2 of 4 pedestals on `gen:1001` and
`gen:1003` **is gone**. W0 fixed a real reachability defect, not just a
validation rate. This is the clearest win in the re-measurement.

**But reachability is still not symmetric, and only the new measure sees it.**
`attackPairs` is 42–75% on every board and never 12/12: on all five maps some
teams can reach the objective and some pairings never meet on it. `gen:1010` is
the extreme at 5/12 — every objective approached, yet each one only ever by a
single specific neighbour. "4/4 approached" would have called that board fair.

### The confound the old report flagged is also gone

The old report's most important caveat was that the *control itself* converted
0 of 5 steals and lost all three episodes by wipeout, so a low capture rate
could not be read as a map defect. Re-measured on the current tip, **the arena
converts 9 steals → 2 captures = 22%, and wins 2 of 3 episodes on the
objective.** The hand-authored board now demonstrates the objective loop
working end to end. A 4-team board that produces 1 capture in 15 episodes is
therefore being compared against a bot that demonstrably *can* score — which is
what makes the 4-team numbers readable at all, and it is a cross-team-count
statement about the BOT, not a control comparison.

The arena's reachability profile, for scale: `pressureBalance` **0.98**,
`attackPairs` **2/2**, per-pedestal enemy time **0.44% / 0.32%**. Pressure
balance is entropy base N, so it compares across team counts directly; the five
4-team boards run 0.50–0.89 against it. (`attackPairs` does not compare across
team counts — 2/2 is trivially easier than 12/12 — and is not claimed to.)

---

## 3. The per-pedestal approach measure

`pedestal_reach` returned `(reached, total, seat_ticks)`. The summed form cannot
see the failure it was built to catch, and `tools/test_map_playtest.py` proves
that rather than asserting it: two synthetic 4-team boards with **identical total
enemy seat-ticks**, one evenly contested and one with two objectives never
entered, are indistinguishable in the aggregate. Now, per objective:

- `approached` — did any enemy ever stand on it. **This flag fires with no
  baseline**, unlike every other verdict in the file, because zero is zero at
  any exposure, board size or team count.
- `attackers` — how many of the N−1 possible enemies did, out of N−1.
- `share` — enemy seat-ticks there as a fraction of alive time.

and across the board `pressureBalance` (entropy base N, so team counts compare)
and `attackPairs` (realised / N·(N−1) ordered attacker→target pairs).

Verified three ways: the unit tests above; the one-page table and per-map flags
on 18 real episodes; and by eye against the travel heatmaps — `gen:1020`'s
picture shows exactly the two-warzone / two-empty-corner split its 0.50 balance
claims, and `gen:1007`'s shows deaths spread across all four quadrants.

One flag was asserting the opposite of its own evidence and is fixed here: "ZERO
steals" printed *"near 0 the objective was never approached"* over `gen:1003`,
where enemies had in fact stood on the pedestals for **18.6% of alive time** —
35× the arena's 0.533%. Never-approached and reached-constantly-but-never-taken
are two findings with opposite remedies. It now splits on the reach share, and
`gen:1003` correctly reads as a rules-or-bot question, not a reachability one.

---

## 4. What the closeout scorecard should say

| item | score |
|---|---|
| "≥ 1 measured play result at 2 teams, arena control" | **met** — 3 arena episodes, control path re-verified on this tip |
| "≥ 1 measured play result at 4 teams, **arena control**" | **ZERO** — no hand-authored 4-team map exists; the named bar cannot be met |
| 4-team play lens, against a labelled reference point | **measured** — 15 episodes, 5 maps, `gen:1007` as reference |
| per-objective approach measure | **exists**, tested, and has already changed a verdict |

The zero is not a failure to do the work; it is the honest score for a bar that
names an artefact that does not exist. Do not launder it into a pass by
relabelling `gen:1007`.

---

## 5. Option 1's true cost, checked

The handoff asked whether a real 4-team control is half a day, because if so it
is worth more than every static metric in the epic. Checked against the code:

**What makes it cheaper than it looks.** A 4-team map is `symRot90`, and rot90
replicates ONE QUADRANT — `leftObstacles` is a quarter of the board, not all of
it. `mapFromSpecJson` already exists and `map_eval` already accepts a mapSpec
`.json` path as a map argument, so a candidate can be authored, played and
measured **as a data file, touching no Nim at all** — no collision with the
sibling session that owns `src/ctf/arena.nim`.

**What makes it expensive.** rot90 requires a **square** board (`validateMap`
raises otherwise), so the "rot90 lift of the arena's own half-field geometry"
suggested as an alternative is not available: the arena is 1235×659, and
squaring it means cropping 47% of its width or inventing 87% new floor. Either
one is authoring, not a lift. Trenches also cannot be used (`raiseAssert
"trenches never place on rot90 maps"`). And the arena's quality is ~50
hand-placed shapes across five staggered columns, tuned across many
GameVersions — GV15 and GV16 edits are still visible in its comments. That is
not reproducible in an afternoon.

**Honest split:**

- A **measurable 4-team prototype** as a mapSpec JSON — square board, one
  authored quadrant, played through this same harness — is roughly **half a day
  including a few tuning iterations**, and by the handoff's own standard it is
  worth more than every static metric in this epic. `pressureBalance` and
  `attackPairs` now give that tuning loop a target it did not have before.
- **Promoting it to a first-class control** (`arena4` prepended automatically by
  `map_eval`, pinned by the 402-row validation baseline, known to the pool and
  rotation) touches `arena.nim` and is not a half-day job.

Filed as follow-up with that split, not merged into this branch.

## 6. Why option 3 alone was rejected

Scoring the whole 4-team lens zero was legitimate when the only 4-team evidence
was 0 captures on a generator whose terrain block emitted nothing. It is not
legitimate now: the re-measurement produced a capture, retired the 2-of-4
reachability failure, and found a new asymmetry that no static metric can see.
Discarding that would be throwing away the finding. Option 3 survives only where
it actually applies — the arena-control bar itself, in §4.

## Reproducing

```
nim c -d:release --nimcache:/tmp/nc-server --out:bin/ctf-server src/ctf.nim
nim c -d:release --nimcache:/tmp/nc-eval   --out:/tmp/map_eval     tools/map_eval.nim
nim c -d:release --nimcache:/tmp/nc-pt     --out:/tmp/map_playtest tools/map_playtest.nim
python3 tools/test_map_playtest.py

port=21600
for m in gen:1020 gen:1007 gen:1013 gen:1003 gen:1010; do
  /tmp/map_eval play "$m" --episodes 3 --seats 16 --teams 4 \
    --port $port --out /tmp/ev4 & port=$((port+40))
done; wait
/tmp/map_eval play arena --episodes 3 --seats 16 --teams 2 --out /tmp/ev2

for r in /tmp/ev4/*.bitreplay; do
  base=$(basename "$r" .bitreplay)
  name=$(echo "$base" | sed -E 's/-ep[0-9]+$//' | sed 's/^gen-/gen:/')
  /tmp/map_playtest "$r" --name "$name" --out "${r%.bitreplay}.json"
done
for r in /tmp/ev2/*.bitreplay; do
  /tmp/map_playtest "$r" --name arena --out "${r%.bitreplay}.json"; done

CTF_MAP_GALLERY=/tmp/gal4 python3 tools/map_playtest.py --reference gen:1007 /tmp/ev4/*.json
CTF_MAP_GALLERY=/tmp/gal2 python3 tools/map_playtest.py /tmp/ev2/*.json
```

Use a per-batch `CTF_MAP_GALLERY`: the same seed is a valid map at 2 and at 4
teams, so a shared gallery silently clobbers one board's heatmap with another's.

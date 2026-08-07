# arena4 measured: BEST on objective reach, LOSES on pressure balance. A partial miss.

The epic's ">= 1 measured play result per team count WITH THE ARENA CONTROL"
bar now scores at 4 teams: `maps/arena4.json` is hand-authored, `map_eval`
prepends it as a control for any 4-team batch, and `tools/map_playtest.py`
stamps it `[CONTROL, hand-authored]` rather than `REFERENCE`.

**The board is not better than the generated ones. It wins two of the four
things that matter and loses the other two, and gen:1013 is the better board.**
Scoring it a pass would be the exact move this task exists to prevent.

## The batch

Six boards, 3 episodes each, one invocation, one build — the five committed
4-team seeds re-played alongside the new control, because `map_playtest.py` can
only state deltas between maps measured together. Re-run, so these numbers do
NOT match the committed `4t-report-ref-gen1007.txt`; that report's yardstick was
a generated reference point and this one's is a hand-authored control.

Raw: `tools/map_playtest_results/4team-control/4t-report-arena4-control.txt`.

| | **arena4** | gen:1003 | gen:1007 | gen:1010 | gen:1013 | gen:1020 |
|---|---|---|---|---|---|---|
| objectives approached | **4/4 100%** | 3/4 | 2/4 50% | 3/4 | **4/4** | **4/4** |
| **attack pairs** | **9/12 75%** | 5/12 42% | 5/12 42% | 6/12 50% | 8/12 67% | 8/12 67% |
| **pressure balance** | 0.68 | 0.73 | 0.46 | 0.49 | **0.81** | 0.72 |
| dead space | 43% | 55% | 43% | 64% | **40%** | 45% |
| steals -> captures | 1 -> 0 | 2 -> 0 | 0 | 8 -> 0 | **5 -> 1** | 0 |
| static score | **0.935 (worst)** | 0.960 | 0.991 | 0.948 | 0.989 | **1.000** |
| interiorFrac | **0.341** | 0.220 | 0.293 | 0.215 | **0.402** | 0.272 |

### What it won

**Objective reach, which is what a 4-team board is for.** 4/4 objectives
approached and **9/12 attack pairs, the best in the batch** — above every
generated board and above gen:1013, which beats it nearly everywhere else. The
static fairness is exact rather than approximate: `standCoverSpread 0.000`,
`standRingSpread 0.000`, all four stands identical to the pixel, which no
generated board manages.

**The cover profile it was built to copy.** `interiorFrac 0.341` against the
hand-authored arena's 0.342 and the generated 4-team mean of 0.280, from 21
shapes in the fundamental domain, every one 34-68px, none above 68. The
prediction in `2026-08-06-what-the-cover-is-made-of.md` — that enclosure comes
from arrangement at body scale, not from mass — **held**: this board buys the
arena's enclosure with the arena's cover budget (160pm vs 167pm) and 84 shapes
against the generator's 3441.

### What it lost

**Pressure balance 0.68, 4th of six.** The target was the arena's 0.98. Enemy
seat-time at the four pedestals came out 6.24% / 1.06% / 0.06% / 3.89%: team 2's
pedestal was visited for 47 ticks in three episodes and team 0's for 4,577.

**The objective loop.** 1 steal, 0 captures. gen:1013 managed 5 steals and the
batch's only capture.

**Static score 0.935, the worst of the six**, and the cause is arena4's own
defect rather than a shared one: `sightlineMaxPx` 1261px on a diagonal against
a 1050px gun, where the five generated boards run 548-999px and none breach.
A 1261px lane is 211px longer than either end can shoot down.

## What the heatmap says, and it is the useful part

Looked at, not just generated —
`tools/map_playtest_results/4team-control/heatmaps/heat-arena4.png`.

**The centre plaza is empty.** The rotunda this board was designed around — the
open middle with the four med-kits in it — carries almost no traffic. It is the
single largest piece of the 43% dead floor.

**Every team hugged the EDGES.** Red and Blue ground against each other along
the top strip; Green ran the left edge, Yellow the right. Nobody crossed the
middle. That is the bot's raid rule drawn in colour: it picks the enemy with the
largest horizontal offset, so the shortest route to a target runs along a board
edge, and a scattered-cover board gives it no reason to leave one.

**Red's pedestal is swarmed and Green's is untouched** — exactly the two-target
collapse documented in `2026-08-06-attackpairs-measures-the-bot.md`.

**And this board is the proof of that finding**, which is worth more than the
metric it fails. arena4's terrain is provably D4-symmetric (every quadrant shape
emitted with its transpose, then rot90'd), and `map_eval` confirms the four
stands are identical to the pixel. So a pressure imbalance of 0.68 on THIS board
**cannot be geometric**. Holding geometry exactly symmetric and still measuring
0.68 isolates the bot's contribution in a way no generated board can — which is
what a control is for, and is the first time the 4-team scorecard has had one.

Set against it honestly: gen:1013 reached 0.81 with asymmetric geometry, so the
bot rule is not the whole story. n = 3 episodes per board.

## The design lesson for the next board

Compare the two heatmaps. gen:1013 (best pressure balance) is a warren of long
solid walls that FUNNEL movement into corridors and force teams through each
other. arena4 is evenly scattered 34-68px cover, which is the right answer for
the 2-team arena — one axis of play, cover perpendicular to it — and the wrong
one at four teams, where nothing pushes a team off its edge route.

**The arena's cover PROFILE transferred; its cover ARRANGEMENT did not.** The
next 4-team board should spend the same 160pm budget on shapes that block the
edge routes and open the middle, not on shapes spread evenly over both.

## Follow-ups (addenda, not new tasks)

1. Break the 1261px diagonal — the one unambiguous defect.
2. `standRingOpenMin` reads 1.000: no cover in any pedestal ring. Largely
   structural (the 210x210 protected corner swallows the 70px ring), but
   gen:1007/1013/1020 get 0.914-0.964 from the 5px sliver where the ring
   escapes the corner box, so it is reachable.
3. Promote to `arena4` as a named map in `src/ctf/arena.nim` — the first-class
   control. Deliberately NOT done here: it needs the 402-row validation
   baseline, the pool and the seed-keyed rotation, and it should wait for a
   board that measures better than this one.

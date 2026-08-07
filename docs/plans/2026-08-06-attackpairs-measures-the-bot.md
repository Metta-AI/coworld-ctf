# `attackPairs` at 4 teams measures the BOT, and 12/12 is unreachable

Every 4-team board measured so far fails `attackPairs` — 7/12, 9/12, and so on,
never 12/12 — and each failure has been written up as a property of the board.
It is not. On both 4-team layouts the baseline bot can only ever choose **two**
of the four pedestals as a raid target, and which two is fixed by the layout
before a single obstacle is placed.

## The rule, from the bot's own source

`players/baseline/baseline.nim`, in the multi-team setup that runs once per
episode:

```nim
  for z in EndzoneMarks:
    if z.color == bot.myColor: continue
    let
      c = vec(float(z.x0 + z.x1) * 0.5, float(z.y0 + z.y1) * 0.5)
      dx = abs(c.x - home.x)
    if dx > bestDx:
      bestDx = dx
      target = c
      targetColor = z.color
```

The raid target is the enemy endzone with the largest HORIZONTAL offset from
home, keeping the FIRST strict maximum. The comment above it says why — "so the
engine's east-west advance math never degenerates on a north/south home" — and
that is a sound reason. The consequence is what nobody costed.

## Why it collapses to two targets, on every rot90 board

`tools/t4probe.nim` prints the choice for any board. On `arena4`:

```
  Red      boxCenter=(154.0,154.0)      RAID Red    -> Blue    (|dx|=651.0)
  Blue     boxCenter=(805.0,154.0)      RAID Blue   -> Red     (|dx|=651.0)
  Green    boxCenter=(154.0,805.0)      RAID Green  -> Blue    (|dx|=651.0)
  Yellow   boxCenter=(805.0,805.0)      RAID Yellow -> Red     (|dx|=651.0)
```

Four teams, two targets. Green's and Yellow's pedestals are never chosen by
anybody. And note every `|dx|` is **651.0** — the same number four times. That
is not a coincidence of this board, it is forced:

**`layoutCorners`.** rot90 puts the four zone centers on a square,
`(c,c) (S-c,c) (c,S-c) (S-c,S-c)`. From `(c,c)` the horizontal neighbour is at
`|dx| = S-2c`, the diagonal twin is *also* at `|dx| = S-2c`, and the vertical
neighbour is at `|dx| = 0`. The maximum is a TIE between two enemies, broken by
whichever comes first in `EndzoneMarks`.

**`layoutPlus`.** Centers sit on a diamond, `(c,M) (S-c,M) (M,c) (M,S-c)`. The
team on an arm picks the opposite arm (`S-2c`, the strict maximum). The two
teams on the *other* axis are both at `|dx| = M-c` from either side team — a
tie again, broken the same way. Measured on gen:1003 and gen:1010: Green and
Yellow both raid Red.

Either way exactly two pedestals are ever chosen, so **at most 4 of the 12
ordered (attacker, target) pairs are ever intended**. 4/12 = 33%.

The tie is the mechanism, and the tie is a property of the SYMMETRY GROUP: rot90
places the four homes on an orbit, so from any one of them two others are
equidistant in x. No obstacle can change it — the rule reads
`captureZone`, which is derived from layout, `homeDepth` and `captureClear` and
never from terrain. **A map author has no lever here at all.**

## So where do the observed 42-75% come from?

Two places, neither of them the map:

1. **Incidental traversal.** `pedestal_reach` counts an enemy that merely stood
   inside the 70px ring, not one that came to steal. Bots crossing a pedestal on
   the way somewhere else score pairs.
2. **The 600-tick re-anchor.** Later in the same file, when the target's flag has
   been off the board for 600 ticks, the bot re-picks — excluding its current
   target, and *by the same largest-|dx| rule*. On a corners board that sends Red
   to Yellow, its diagonal twin. So a third target does appear, but only after a
   long stall, and the fourth needs a second stall.

That is why the numbers land between 33% and 100% and drift with episode
length rather than with board quality.

## What this costs, and what to do

`map_playtest.py` currently prints, for any board with more than two homes:

> FLAG: every objective was approached, but only 9/12 = 75% of the (attacker,
> target) pairs the rules allow ever happened — some teams can reach the
> objective and some pairings never meet on it

"the rules allow" is the load-bearing phrase and it is wrong: the RULES allow 12,
the BOT allows 4. The flag reads as a map defect and has been recorded as one on
five boards.

Recommended, in order of cost:

1. **Cheapest, and enough.** Keep measuring `attackPairs`, stop treating it as a
   map gate at >2 homes, and print the 4/12 ceiling beside it so the number is
   read against what is achievable. A board at 9/12 is *above* the intentional
   ceiling, which is information — it says traversal is spreading contact
   around — and it is the opposite of the current reading.
2. **The real fix, and it is a POLICY change, not a map one.** Break the tie by
   something other than `EndzoneMarks` order — round-robin on seat index, or
   pick by true distance rather than `|dx|`. Every team would then raid a
   different neighbour and all 12 pairs would be reachable. This changes bot
   behaviour, so it needs its own A/B; it is not a side effect of a map change.

Filed as an addendum to the 4-team control task rather than as a new board
task: it is the answer to "why does every 4-team board fail this metric", and
the answer is that the metric is not about the boards.

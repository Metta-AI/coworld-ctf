# Anti-line A/B — pricing the SHIPPED grenade-on-fattest-cluster multikill

Date: 2026-07-29 · Base: `maxwell/picasso-medecon` (`a0e8a6e`, the LIVE Picasso:v28 champion)
Budget: redirected from the retired arc-breacher A/B (arc verdict −8.3pp, RETIRE, 2026-07-24).

## The lever under test

`baseline.nim`, the grenade block. When a standing enemy line is classified locally
(`ScLine`) or heard over the comms bus (`RpLine`), a grenade carrier ranks candidate targets
by **cluster size** — fresh enemies inside one 52px blast — and lobs at the **fattest**
cluster instead of the nearest body. It throws **without disarming** (nade goes, gun stays),
which is precisely why the arc breacher was retired as a strictly-worse duplicate: the arc
traded the gun for the cone.

Doctrine: *numbers are the currency*. A lob that kills two costs the enemy double.

**Shipped ON since `4ceec16` (2026-07-22, the v17 lineage) and never isolated.** Every
champion v17 → v28 carries it, uncredited and unpriced. This task was to price it.

## VERDICT: the payload is inert on the real field. Do not spend the hosted budget on it.

Three independent measurements agree, and the field measurement is decisive.

### 1. ⭐ Real field: ZERO grenade multikills, field-wide

28 real GV23 league episodes re-simulated to tier-2 events (`extract_events`), grouping kill
events by (episode, tick, thrower) to reconstruct each lethal blast:

```
TOTAL kills across 28 real GV23 league episodes: 1166
  gun        1124  (96.4% of all kills)
  grenade      27  (2.3% of all kills)
  spray        15  (1.3% of all kills)

grenade lethal blasts: 27  ->  size histogram {1: 27}
spray  lethal cones : 15  ->  size histogram {1: 15}
```

**All 27 grenade kills on the real field were single kills. Not one double. Not one triple.**
(Nor did the spray cone ever multi-kill.) The multikill this lever exists to produce does not
occur in live play at all — for us *or* for any opponent in those episodes.

That sets a hard ceiling on the whole idea: grenades are **2.3% of kills**. Even if *every*
lethal blast were upgraded to a double, that is +27 kills = **+2.3% kills** — and the
realistic conversion rate is a fraction of that. There is no reachable win delta here.

### 2. Differential probe: the lever changes ~1–6% of throw decisions, and never lands one

`-d:ncdiff` computes **both** selectors on the **same** frame state and counts disagreements.
This bounds the lever's entire causal footprint: a lever that picks the body the control
would have picked cannot change an outcome, whatever the episode budget.

| | plain mirror (3g) | `TURTLE=1`, control stands a line (3g) |
|---|---|---|
| carrier frames | 2985 | 1107 |
| line-live frames | 82 | 57 |
| frames either selector throws | 159 | 87 |
| **SAME pick** | **149 (93.7%)** | **86 (98.9%)** |
| **CHANGED** | **10 (6.3%)** | **1 (1.1%)** |
| ...of which fatter cluster | 10 (mean **+1.00** body) | 0 |
| CHANGED *while a line was live* | **0** | 1 lever-only throw |
| **cluster kills landed (`mk2`/`mk3`)** | **0 / 0** | **0 / 0** |

Two things to note. The lever *does* pick a fatter target when it diverges (+1.00 body in
blast, so the ranking logic is correct and live — this is not dead code). But it diverges on
6.3% / 1.1% of throws, it diverges **zero** times while a line is actually live, and across
both configurations it produced **zero** multi-kill blasts. The mechanism is real; its
frequency is ~nil.

### 3. Selector funnel

`-d:ncprobe`: `carry 2985 → AIM 159 → CLUSTER-AIM 21 (13%)`, `chosen cluster mean 2.00,
fattest 2`. Under `TURTLE=1`: `carry 1107 (lineLive 57) → AIM 87 → CLUSTER-AIM 3 (3%)`,
`anti-line cluster lobs 3`. The comms bus itself is healthy (`classify line 674 → EMIT 85 →
HEARD 11499 → ADOPT 5306 → LINE-ARM 35`), so `ScLine` is *not* dead — the callout fires and
mates adopt it. The failure is downstream: a carrier holding a nade with a line up almost
never has a fat cluster in the 72–247px throw window.

## What was built (all compile-clean, all on the champion base)

1. **Retro-gate** `nadeCluster` in `CombatTune`. Default `false` = the *exact* pre-`4ceec16`
   naive-nearest selector (nearest fresh in-range body that is wall-blocked or merely paired,
   nearest-first scan with the old `d >= bestD` early skip, no live-line case). Baked `true`
   in `shippedCombatTune`, so the shipped path is unchanged. Knob `NADECLUSTER`; compile strip
   `-d:noNadeCluster` for a hosted control arm (the env knob reaches only `HUNTER_SLOTS`
   seats, so an uploaded control needs the strip).
2. **`-d:ncprobe`** — selector funnel (carry → line-live → aims → cluster-aims, mean/fattest
   chosen cluster). Separates *"the lever fires"* from *"the lever picks better"*.
3. **`-d:ncdiff`** — the differential probe above. Observation only; never writes the aim.
4. **Cluster-kill accounting** in the harness (`clusterkil`), straight off the sim's per-blast
   `multiKills2/3` — the mechanism metric the task asked to judge on.
5. **`nadeab.sh`** — seat-rotated isolation A/B (champion MINUS lever vs full champion) with
   `TURTLE=1` and the correctly-specified null (`SHIPBASE=1` **and** `CONTROL_SHIPPED=1`).
6. **`nade_field_ab.py` / `nade_ab_poll.py`** — the hosted 4-arm field A/B, seat-rotated, vs
   a field weighting **ctf-h050** (the line-standing h006 lineage) twice. Dry-run verified;
   **not fired** (see below).

## The gate is behaviour-preserving (verified)

Pristine pre-gate build vs the gated build, `HUNTER_SLOTS` Red, `SHIPBASE=1 CONTROL_SHIPPED=1`,
seed 100:

```
pristine  100   2247  true  RED  24 19  0 0  122 112  19.7 17.0
gated     100   2247  true  RED  24 19  0 0  122 112  19.7 17.0
```

Identical across every reported field (ticks, winner, kills, captures, shots, accuracy). The
`-d:ncdiff` build reproduces the same line, confirming the probe is observation-only. The
6-game pristine null scored **RED +0 / BLUE +0** — correctly specified (a champion-vs-champion
null must be ~zero; `CONTROL_SHIPPED` alone is champion-vs-bare-baseline and fakes a large
noise floor that inflates every effect size).

`-d:noNadeCluster` yields a provably distinct binary (`26129af8…` ON vs `417f69c8…` OFF), so
the hosted control arm is buildable — the check that would have caught the v27 wrong-upload.

## Recommendation

**Keep the lever, don't ship a change, don't spend the hosted budget.** Specifically:

- **Keep it ON.** It is free (no disarm, movement/throw-intent only), its ranking is correct
  when it does diverge (+1.00 body), and stripping it has no measured upside. Fix ≠ remove.
- **Do not fire the hosted A/B.** The tooling is ready, but the field measurement already
  bounds the effect below any resolvable delta — hosted CTF scores are binary ±1.0 per episode
  ([[METHOD-binscore]]), and a 2.3%-of-kills lever cannot clear that noise floor at any
  affordable n. Firing it would burn the budget to re-measure a known zero.
- **The redirected budget should go to the gun, not the grenade.** 96.4% of all real-field
  kills are gun kills. Grenades (2.3%) and the spray cone (1.3%) together are under 4% —
  the same conclusion that retired the arc breacher, now with the numbers to back it. Any
  area-weapon work is rearranging <4% of the outcome.

### Follow-up worth doing (cheap, higher leverage)

The one genuinely surprising number here is that **nobody on the field lands multikills
either** — 27/27 blasts and 15/15 cones were singles, across every policy in the sample.
That points at area weapons being mispriced by the *meta*, not just by our policy: 8v8 with
a 52px blast ought to catch a pair sometimes.

The obvious next probe — reconstruct inter-body spacing at each death from the tier-2 events
and compare against `NadeBlast=52` — **is not answerable from this artifact.** The events
JSONL only carries `x,y` for the actors involved in each event, so a position snapshot holds
1–2 players per tick (measured: `{1: 211, 2: 50, 3: 1, 4: 1}` for one episode), never the
roster. A naive 52px-neighbour count over those snapshots returns "99% of deaths are
clustered", which is an artifact of counting the killer standing next to its victim, not a
spacing measurement. Doing this properly needs full per-tick positions, i.e. re-simulating
the replay and sampling `sim.players` directly rather than reading the event stream.

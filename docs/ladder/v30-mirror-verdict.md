# Picasso:v30 — mirror A/B verdict, 2026-07-29

**VERDICT: v30c as bundled is a NULL. Do not submit it. v28 stays champion.**

## The numbers (paired off ONE binary via env knobs — no build variable)
24 games/arm/seed, grabprobe, seeds 100 + 300.

| arm | seed | grabs | caps | accuracy |
|---|---|---|---|---|
| control (=v28) | 100 | 22 | 3 | 0.626 |
| control (=v28) | 300 | 19 | 3 | 0.634 |
| v30c | 100 | 18 | 1 | 0.620 |
| v30c | 300 | 21 | 4 | 0.616 |

Pooled: grabs **39 vs 41 (−2)**, caps **5 vs 6 (−1)**, accuracy **0.618 vs 0.630 (−1.2pp)**.
Per-seed sign test: seed 100 grabs **−4**, seed 300 grabs **+2** — it FLIPS SIGN across
seatings, which the null-calibration rule says is seat noise, not an effect.

## What I got wrong, and the correction
The first reading of the bundle looked like a big win — grabs 35 vs 22, **+59%**. It was an
artifact of `fireOnRealBody`, which I had enabled in the same bundle. Isolating it:

| | shots | hits | accuracy |
|---|---|---|---|
| with fireOnRealBody | 5794 | 3326 | 0.574 |
| without | 5334 | 3337 | 0.626 |

Enabling it bought **460 extra shots for 11 FEWER hits** — marginal accuracy of the extra
shots ≈ 0.0. It re-checks the firing corridor but NOT the 5-tick windup, so the juking body
it aimed at has moved by the time the bullet leaves, and each wasted shot books a 12-tick
cooldown. Reverted to OFF (`REALBODY=1` to re-measure). **The audit ranked this a top-3 fix
on sound reasoning; the measurement refuted it.** Removing it restored accuracy to 62.0%,
which confirms the attribution — and once it was gone the grab "gain" went with it.

## What this does and does not retire
- It does NOT refute the FIELD diagnosis. Touch conversion 71.8% vs the field's 94.9%, the
  20 episodes with a bot 5-39px from a 12px pickup radius, 445-vs-90 deaths in the standoff
  ring — those are ground truth from 123 GV26 league episodes and they stand.
- It DOES say the mirror cannot resolve this lever, which is the expected result for a
  symmetric change: both sides get the same touch latch, so the marginal advantage cancels.
  The latch demonstrably ARMS (310-514 frames/24g) and demonstrably removes the preemptions
  it targeted (engage 4 -> 0 once armedRush got its range floor).
- Therefore the touch latch is a HOSTED-FIELD question, not a mirror question — the same
  category as shieldTank/avoidDisarm/medEcon, whose upside was field-only.

## Ship decision
Submitting a measured null over a standing champion is strictly worse than not submitting,
because Elo is zero-sum and a regression costs rating immediately. So: keep v28 live; take
the touch latch to a hosted asymmetric A/B (xp-request) rather than a champion swap; and
measure `tempoPress = false` as a lone lever, since it is the one change whose premise is
UNOBSERVABLE on this engine (firing is silent, bullets invisible, muzzle bloom
spectator-only) rather than merely unproven.

Image built and pre-upload-verified regardless, so a submit is one command away if the
hosted arm comes back positive: `coworld-ctf-baseline:picasso-v30`, binary sha
`b6b3d0d0…`, PROVABLY DISTINCT from a pristine v28 rebuild at `7d4acf25…` — and that
pristine rebuild reproduced the RECORDED live v28 sha and image `121863132e0c` exactly,
which validates the whole build path.

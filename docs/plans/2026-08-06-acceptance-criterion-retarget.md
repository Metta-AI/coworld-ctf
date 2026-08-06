# The epic's own acceptance criterion is measured, and it points the wrong way

Decision record, 2026-08-06, epic owner, epic 3757029c. **This changes what Lane A optimises.**

## The evidence

Two independent measurements, taken by two sessions that were not talking to each other, agree.

**From the staticScore↔play experiment** (task 945a5b9e; 41 maps, 210 episodes, matched
1238-tick window, split-half reliability 0.92-0.98, load confound clean at
rho = -0.029, p = 0.857):

- `staticScore` predicts pace (+0.462) and close contact (+0.336) and **nothing at all** on the
  objective, on episode resolution, or on fairness.
- `interiorFrac` — the heaviest band in the score *and this epic's stated acceptance criterion* —
  **ranks maps backwards on floor usage**: +0.638 [+0.34, +0.84], p<0.001, against a
  reliability ceiling of 0.97. As a gate it is worse than useless: maps passing >= 0.30 average
  **0.615 dead floor against 0.542 for maps that fail it** (Mann-Whitney p<0.001).
- The arena is out of distribution on exactly one axis — dead floor 0.396 against a generated
  range of 0.480-0.688, with **0 of 40** generated maps coming near it. It is ordinary on contact
  (17 of 40 beat it) and pace (22 of 40).
- The arena's own `interiorFrac` is 0.342, so it **passes** the criterion. Enclosure does not
  cause dead floor; the generator's way of producing enclosure does.
- The three metrics that predict floor usage in the RIGHT direction — `longRunFrac` (-0.654),
  `midOpenFrac` (-0.595), `exposedFrac` (-0.321) — are all saturated to zero influence.

**From the play harness** (task 3811876a; 24 episodes, arena in the same batch): `gen:1023` scores
staticScore **1.000, tying the control exactly on the same board size**, and across three full
episodes the enemy heart was **never taken** — 0 steals against the arena's 5 — with 62% of its
floor never entered. At 4 teams: 0 captures in 12 episodes, and on two maps an enemy reached only
2 of 4 pedestals. Combat is at parity everywhere (balance 0.96-1.00). These are maps where the
fight works and the objective does not.

## The decision

Task b7f44fb5 exists to raise 4-team `interiorFrac` from 0.098 to >= 0.30. **Pursuing that target
as written would spend the epic's remaining Lane A budget making 4-team maps worse on the one axis
where the control is actually better than everything we generate.** It is retargeted:

    WAS:  4-team interiorFrac 0.098 -> >= 0.30
    NOW:  4-team dead floor toward the arena's 0.396, and every pedestal reachable in play

`interiorFrac` stays REPORTED — it is not deleted and not gamed downward — but it stops being the
thing Lane A optimises and stops being a pass/fail gate.

This is not a unilateral reinterpretation. The epic pre-authorised exactly this outcome, in the
task that commissioned the experiment:

> A plausible outcome is that staticScore correlates weakly or not at all... If so, the epic's
> interiorFrac >= 0.30 acceptance criterion is itself unvalidated and should be re-derived from
> play. Better to learn that now than after tuning three more knobs against it.

That is what happened, and this is the re-derivation.

## What this does NOT change

- 2-team `interiorFrac` is 0.300-0.315 and stays there. Nothing here argues for reducing it; the
  argument is only against *spending effort raising it* and against *gating on it*.
- The validity bar (>= 95% both team counts) is untouched and remains the epic's hard gate.
- `staticScore` is not abandoned mid-epic. Re-weighting is free against the stored evidence
  (only a NEW generator needs new episodes), but re-deriving 13 band weights is its own piece of
  work and is filed rather than done inside this epic.

## Consequence for the closeout scorecard

The scorecard must report the epic against BOTH sticks and say plainly that they disagree:
the numeric bar as written (`interiorFrac >= 0.30` both team counts) and the measured bar
(dead floor, objective reachability). Reporting only the first would let the epic pass over a
defect its own instruments proved. Reporting only the second would quietly move the goalposts.
Report both.

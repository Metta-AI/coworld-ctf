# The epic's real position, re-measured under the corrected stick

Epic owner, 2026-08-06, on `maxwell/mapgen-rebuild` after merging W0 (157ce824), small boards
(fcd2e04d), city clipping (377070e8) and the corrected measuring stick (4fb75b77).
All runs with an explicit clean `--nimcache`, arena as control in every batch.

## Validity, staticScore, enclosure

|                    | old stick | CORRECTED stick | bar      |
|--------------------|-----------|-----------------|----------|
| 2-team validity    | 39/40 97% | **39/40 97%**   | >= 95% ✅ |
| 4-team validity    | 32/32 100%| **32/32 100%**  | >= 95% ✅ |
| 2-team staticScore | 0.940     | **0.961**       | >= 0.939 ✅ |
| 4-team staticScore | 0.984     | **0.987**       | >= 0.939 ✅ |
| 2-team interiorFrac| 0.308     | **0.291**       | >= 0.30 ❌ |
| 4-team interiorFrac| 0.252     | **0.240**       | >= 0.30 ❌ |
| distinct maps      | 39/39, 32/32 | —            | no collisions ✅ |
| suite failures     | 5, zero raises | —          | 0 ❌ (all 5 owned) |

`staticScore` went UP under the corrected stick rather than down. That is not the same map scoring
better: correcting the stick changed which candidate wins best-of-K, so these are different maps.

## The feared regression did not happen, and the reason matters

`2026-08-06-two-rulers.md` predicted that making `bandHard` actually reject would take 4-team
validity from 68% to 50%, because three seeds offered only ONE vertex-disjoint route. **It is
100%.** The prediction was correct about the mechanism and wrong about the outcome, because W0
removed the cause in between: those maps were corridors because the 4-team terrain block was
emitting nothing at all and the board was pure row cover. Once terrain emits, the routes exist and
the now-real hard gate has nothing to reject. `0 of 14 rejected`, both controls included.

Two fixes that were sequenced as a risk turned out to be complementary. Worth remembering the next
time a ruler correction and a generator fix are queued against each other.

## The miss, stated with its number

**`interiorFrac` misses the epic's >= 0.30 bar at BOTH team counts: 0.291 and 0.240.**

That criterion is retargeted on evidence (`2026-08-06-acceptance-criterion-retarget.md`): over 210
episodes it ranks maps BACKWARDS on dead floor, and maps passing >= 0.30 average 0.615 dead floor
against 0.542 for maps that fail it. So the miss is against a bar this epic has measured to be
pointing the wrong way — but it IS a miss against the bar as written, and the closeout scorecard
reports it as one rather than quietly substituting the new criterion.

## What the corrected stick can now see, and could not before

The axis-only scan reported a perfect vision score on every 4-team board. Every one of them has a
gun-range sniping lane. Post-W0, on 12 generated 4-team maps plus both controls:

    gen:1010  sightlineMaxPx 1318      gen:1004  sightlineMaxPx 1101, diagLongRunPxFrac 0.215
    gen:1004  sightlineMaxPx 1101      gen:1008  sightlineMaxPx 1063
    CONTROL arena-large  sightlineMaxPx 1149, diagLongRunPxFrac 0.183

4 of 12 (33%) generated 4-team maps carry an unbroken line at or past `GunRange` = 1050px.
**So does the `arena-large` control**, which is exactly the ambiguity the stick task was told to
resolve on evidence rather than by exempting the control: this is a soft band breach on both, the
hard gate rejects neither, and the honest reading is that long diagonals are a real property of
our large boards and not a generator-only defect. Filed as its own task rather than silently
tolerated.

Also stated plainly by the stick work, and worth keeping visible: the `standCoverMin` fraction
floor **does not bite and cannot**, because the fraction is not scale-free. A correction that
moved nothing is still worth reporting as a correction that moved nothing.

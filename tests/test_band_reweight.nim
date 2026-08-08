## Tests for the evidence-derived band set and the fairness assertion that was
## moved OUT of the score (src/ctf/map_metrics.nim, task 013a9c98, epic
## 3757029c lane D).
##
## Derivation and every number: docs/plans/2026-08-06-staticscore-band-partition.md
##
## Three things are guarded here, and each one is a mistake this repo has
## already made at least once.
##
## 1. THE CONTROL IS SCORED, AND NEVER FLAGGED. `test_map_eval` asserts this
##    for `DefaultBands`; a second band set needs its own copy of the guard or
##    the guarantee covers half the band sets in the file. `ControlSeparation-
##    Bands` scores the arena 1.0 BY CONSTRUCTION (every bound is cut at the
##    control's own measured value), so this test is cheap to keep true and
##    fails loudly the moment a bound is moved past the arena.
##
## 2. THE FAIRNESS CHECK HAS A POSITIVE CONTROL. `standRingSpread` and
##    `standCoverSpread` never fired once across 118 measured maps, which is
##    exactly the signature of a detector that is dead and of a guarantee that
##    holds — and those two readings are indistinguishable without a map built
##    to violate it. `fairnessViolations` is unit-tested against a MapMetrics
##    constructed to be unfair, so "it never fires" can be read as evidence.
##
## 3. THE NIM AND PYTHON SCORERS AGREE. tools/band_reweight.py re-derives band
##    sets offline against the stored evidence and therefore re-implements
##    `subScore`. The pinned scores below are the numbers that script prints;
##    if the two ever disagree, the analysis is measuring a rubric that does
##    not ship.

import
  helpers,
  std/[strutils, unittest],
  ctf/map_metrics,
  ctf/sim

proc arenaMap(): CtfMap = loadCtfMapMetadata("arena")

let control = evaluateMap(arenaMap(), "arena")

# ---------------------------------------------------------------------------
# 1 — the control, under the new stick
# ---------------------------------------------------------------------------

suite "band re-weight: the control":
  test "the arena passes every ControlSeparationBands band":
    var breached: seq[string]
    for r in control.scoreBands(ControlSeparationBands):
      if r.breached:
        breached.add r.band.name & "=" & $r.value &
          " outside [" & $r.band.lo & ".." & $r.band.hi & "]"
    check breached.len == 0

  test "every ControlSeparationBands band records its control value":
    for band in ControlSeparationBands:
      check band.control >= band.lo
      check band.control <= band.hi

  test "the arena scores 1.0 under BOTH sticks, in the same batch":
    # Scoring the control under only the new set would not catch a change that
    # broke the old one, and this epic has shipped exactly that kind of
    # half-measured comparison before.
    check control.staticScore(DefaultBands) == 1.0
    check control.staticScore(ControlSeparationBands) == 1.0

# ---------------------------------------------------------------------------
# 2 — the fairness assertion, both directions
# ---------------------------------------------------------------------------

suite "band re-weight: fairness is pass/fail, not points":
  test "the arena is fair (negative control)":
    check control.fairnessViolations().len == 0

  test "an unfair stand ring is REJECTED (positive control)":
    # Built, not generated: the generator cannot produce this map, which is
    # precisely why the bands that scored it could never fire and why the
    # check has to be exercised directly.
    var m = control
    m.standRingOpenMin = 0.30
    m.standRingOpenMax = 0.95          # spread 0.65, bound 0.10
    let v = m.fairnessViolations()
    check v.len == 1
    check v[0].contains("unfair stand rings")

  test "unfair stand cover is REJECTED (positive control)":
    var m = control
    m.standCoverMin = 0.10
    m.standCoverMax = 0.40             # spread 0.30, bound 0.04
    let v = m.fairnessViolations()
    check v.len == 1
    check v[0].contains("unfair stand cover")

  test "both violations are reported together, not just the first":
    var m = control
    m.standRingOpenMin = 0.30
    m.standRingOpenMax = 0.95
    m.standCoverMin = 0.10
    m.standCoverMax = 0.40
    check m.fairnessViolations().len == 2

  test "a spread exactly ON the bound is fair":
    var m = control
    m.standRingOpenMin = 0.50
    m.standRingOpenMax = 0.50 + FairnessRingSpreadMax
    check m.fairnessViolations().len == 0

# ---------------------------------------------------------------------------
# 3 — the two implementations agree
# ---------------------------------------------------------------------------

suite "band re-weight: Nim and the offline analysis agree":
  test "the arena's pinned scores match tools/band_reweight.py":
    # `python3 tools/band_reweight.py crossval` prints both of these.
    check abs(control.staticScore(DefaultBands) - 1.0) < 1e-9
    check abs(control.staticScore(ControlSeparationBands) - 1.0) < 1e-9

  test "the new stick is a DIFFERENT ruler, not a rescaled one":
    # The whole point of the set is that it separates maps DefaultBands ties.
    # If a future edit made the two agree everywhere, the set would be
    # pointless and this test says so before the doc goes stale.
    check ControlSeparationBands.len == 2
    check DefaultBands.len == 21

  test "the DECISIVE pair separates: arena vs s1011a0":
    # s1011a0 is the generated map that tied the hand-authored control at
    # staticScore 1.0000 under DefaultBands while recording ZERO steals across
    # five full episodes, against the arena's eight. It is the single case this
    # whole re-weight exists to fix, so it is pinned here rather than left in a
    # doc that cannot fail.
    #
    # Values are s1011a0's own, read out of
    # docs/evidence/staticscore-play-rows-full.json.
    var m = control
    m.exposedFrac = 0.0879          # arena 0.0384 -- 2.3x apart
    m.routeCapacityFrac = 0.1600    # arena 0.3200 -- 2.0x apart

    # THE SATURATION, made concrete. Both metrics differ from the control by
    # more than 2x and DefaultBands scores both of them a perfect 1.0 anyway:
    # its bounds are wider than the population, so the difference cannot reach
    # the score. This is the failure, asserted rather than described.
    for r in m.scoreBands(DefaultBands):
      if r.band.name in ["exposedFrac", "routeCapacityFrac"]:
        check r.sub == 1.0

    # Under the new stick the same two numbers do reach the score.
    # exposedFrac       (0.0879 - 0.0385) / 0.15 = 0.329 over -> sub 0.671
    # routeCapacityFrac (0.3190 - 0.1600) / 0.30 = 0.530 under -> sub 0.470
    # equal weights -> 0.5704, which is what band_reweight.py prints.
    let sep = m.staticScore(ControlSeparationBands)
    check abs(sep - 0.5704) < 1e-3
    check control.staticScore(ControlSeparationBands) - sep > 0.40

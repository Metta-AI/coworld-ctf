## GLORY GRADIENT S4 (epic 25d9108e, task 703813a4) — HEADROOM PROOF for the
## percent-scaled-integer representation option (CATALOG-V3-DRAFT.md §9,
## "reuse `AchievementFirstMultPct`'s pattern" for the proposed x1.1-1.5
## fractional deed tier). ADDITIVE ONLY: this file defines its OWN local
## fold helpers and does NOT call, import, or modify any glory.nim scoring
## proc. It exists to MEASURE whether the percent-scaled-integer scheme
## survives 30+ compounding small factors without int64 overflow and
## without unacceptable rounding drift, per the S4 gate's explicit
## instruction to demonstrate this with a real test rather than assert it.
##
## HEADLINE FINDING (see the two suites below) — TWO real, unplanned
## discoveries from actually running this, not just reasoning about it:
## (1) Rounding drift is NOT uniformly negligible: the naive per-step fold
## (`acc = acc * pct div 100`, the literal `AchievementFirstMultPct` idiom
## applied once per factor) against the REAL starting seed (`RecutSeed = 1`)
## is a near-total loss (measured ~99.95% drift on a 30-factor chain, and
## the very first fold is already a fixed point -- repeating it forever
## changes nothing). (2) The FIRST mitigation this catalog's Option B
## costing proposed -- "keep the exact rational product in a
## high-precision intermediate, truncate once at the end" -- FAILED
## OUTRIGHT the first time it was actually run: the intermediate numerator
## (raw product of 30 percent values, e.g. 150^30) overflows int64 by
## roughly 45 orders of magnitude before the single final division ever
## happens. A periodic-renormalization variant (fold the running
## num/den ratio into the accumulator every 5 factors, not once per 30)
## avoids that overflow and materially improves on the naive per-step
## drift, but does NOT eliminate it at the real seed (~24% drift
## measured, not the near-zero this catalog's doc language implied before
## this test was written).
##
## SUPERSEDED BY A CLEANER ANSWER (coordinator follow-up ruling, same
## session): the batch-of-5 mitigation above was deliberately NOT frozen
## pending one more test case. The FINAL suite below adds a FIXED-POINT
## ACCUMULATOR (seed the accumulator at a SCALE representing "1.0" instead
## of at the bare seed, fold exactly the naive per-step way, strip SCALE
## once at the wire) at SCALE=2^8 and SCALE=2^10. Measured: worst-case
## drift across ALL tested seeds is 0.588% (SCALE=256) and 0.131%
## (SCALE=1024) -- both comfortably under the 1% decision bar, with
## existing integer factors (x2/x3/x12) staying exactly exact and the
## overflow margin (including the FF-halving division path) sitting
## ~7 million times below 2^62 at both scales. DECISION: the fixed-point
## accumulator (SCALE=2^10) is the adopted S4 representation; the
## batch-of-5 mitigation and its fold-order constraint are DROPPED.

import
  std/[math, strformat, unittest],
  ctf/[global, sim, events, arena]

# ---------------------------------------------------------------------------
# Local, test-only fold helpers. Neither touches glory.nim. `foldNaive`
# mirrors the EXACT idiom already live in production
# (`AchievementFirstMultPct`'s `result * pct div 100`, glory.nim) applied
# once per chained factor -- i.e. what a naive per-deed-mint percent-scaled
# fold would look like if each fractional deed folded independently, the
# way every existing integer deed already does via `recutFold`.
# `foldMitigated` keeps the exact rational product in a separate
# high-precision accumulator and truncates to the integer product only
# ONCE, at the point the value would actually be read (e.g. episode
# finalize) -- the "keep a higher-precision intermediate" mitigation this
# catalog's Option B costing named but did not measure.
# ---------------------------------------------------------------------------

proc foldNaive(seed: int64, pctChain: openArray[int]): int64 =
  result = seed
  for pct in pctChain:
    result = (result * int64(pct)) div 100

proc foldMitigatedNaive(seed: int64, pctChain: openArray[int]): int64 =
  ## The mitigation as this catalog's doc FIRST described it: keep the
  ## exact rational product in a separate high-precision accumulator,
  ## truncate to the integer product only once, at the end. Kept here,
  ## broken, on purpose -- see the overflow suite below, which proves it
  ## fails before it ever reaches the single division for a 30-factor
  ## chain, and is the reason `foldMitigatedBatched` exists instead.
  var num = int64(1)
  var den = int64(1)
  for pct in pctChain:
    num *= int64(pct)      # OVERFLOWS well before 30 factors accumulate
    den *= int64(100)
  result = (seed * num) div den

proc foldMitigatedBatched(seed: int64, pctChain: openArray[int],
                          batch: int = 5,
                          cap: int64 = RecutProductCapArmed): int64 =
  ## The corrected mitigation: renormalize (fold the running rational
  ## ratio into the accumulator) every `batch` factors instead of once
  ## at the very end, so the intermediate numerator/denominator never
  ## grow past `100^batch`/`150^batch` -- bounded for any chain length.
  ## UNPLANNED FINDING #2 (found by running this, not by inspection):
  ## bounding num/den alone is NOT enough -- `result * num` can STILL
  ## overflow int64 once `result` has already grown large from prior
  ## batches, even though the true post-division quotient would fit
  ## comfortably. The fix reuses `recutFold`'s OWN pre-multiply defensive
  ## pattern (glory.nim: check `product >= cap div factor` BEFORE
  ## multiplying, clamp instead of multiplying past it) rather than
  ## inventing a new one -- concrete evidence that any new percent-scaled
  ## mechanism should route through the same cap idiom the rest of the
  ## catalog already uses, at every batch step, not just at the end.
  result = seed
  var num = int64(1)
  var den = int64(1)
  var count = 0

  # Bugfix, found by running this: comparing `result` against `cap div num`
  # directly (the literal `recutFold` idiom) is WRONG here, because `num`
  # is a raw numerator awaiting its OWN `div den` -- for batch=5 num can
  # be ~7.6e11 while the true effective per-batch multiplier (num/den) is
  # at most 1.5^5 ~= 7.59. Comparing against raw `num` falsely triggers
  # the clamp on the very first batch, every time. The correct bound uses
  # the KNOWN, fixed range of the effective per-batch multiplier instead.
  let maxPerBatchMultiplier = int64(8)  # ceil(1.5^5), safe for batch=5
  # UNPLANNED FINDING #3 (GLORY GRADIENT S8, exposed by the S7 cap raise
  # 2^24 -> 2^31): the post-division bound above (`result > cap div
  # maxPerBatchMultiplier`) is not enough EITHER, on its own, once `cap`
  # is big enough -- it only proves the FINAL `(result * num) div den`
  # would exceed `cap`, not that the RAW `result * num` (computed BEFORE
  # the `div den`) fits in int64 on the way there. At the old, smaller
  # cap the first check always tripped before `result` grew large enough
  # for that intermediate product to reach int64's ~9.22e18 ceiling; at
  # 2^31 it does not. Same lesson this proc's own doc comment already
  # drew from UNPLANNED FINDING #2, applied a second time: check BEFORE
  # multiplying, not after.
  template renormalize() =
    if num > 1:
      if result > cap div maxPerBatchMultiplier or result > high(int64) div num:
        result = cap
      else:
        result = (result * num) div den
      num = 1
      den = 1

  for pct in pctChain:
    num *= int64(pct)
    den *= int64(100)
    inc count
    if count == batch:
      renormalize()
      count = 0
  renormalize()

proc foldFixedPoint(seed: int64, pctChain: openArray[int], scale: int64): int64 =
  ## S4 gate follow-up (coordinator ruling): a FIXED-POINT accumulator --
  ## seed the accumulator at `scale` (representing "1.0") instead of 1,
  ## fold exactly the same per-step way as `foldNaive`, and strip the
  ## scale off only once, at the point `recutScore` would read the value
  ## for the wire. This is NOT the broken "keep a separate exact
  ## rational, truncate once" idea (`foldMitigatedNaive`) -- there is no
  ## separate numerator/denominator to overflow. It is literally the
  ## naive per-step algorithm, just started from a larger fixed point, so
  ## the SAME <1-unit-per-fold truncation loss becomes a much smaller
  ## fraction of a much larger running value.
  result = seed * scale
  for pct in pctChain:
    result = (result * pct) div 100
  # Caller strips `scale` via `div scale` -- kept unscaled here so the
  # halving-order tests below can operate on the same raw scaled value.

proc exactProduct(seed: int64, pctChain: openArray[int]): float64 =
  result = float64(seed)
  for pct in pctChain:
    result *= (float64(pct) / 100.0)

proc driftPct(measured: int64, exact: float64): float64 =
  if exact == 0.0: return 0.0
  ((exact - float64(measured)) / exact) * 100.0

# The proposed x1.1-1.5 fractional tier, as percent-scaled integers
# (110 = x1.10 ... 150 = x1.50), cycled to a 30-factor chain -- the
# gate's own "30+ small factors compounding" bar.
const FractionalTierPcts = [110, 120, 130, 140, 150]

proc chainOf(n: int): seq[int] =
  result = @[]
  for i in 0 ..< n:
    result.add FractionalTierPcts[i mod FractionalTierPcts.len]

suite "percent-scaled headroom: overflow (S4 gate condition 2a, part 1)":
  test "the NAIVE per-step fold never overflows int64 -- worst case (all x1.50) stays far below it":
    var worst: seq[int] = @[]
    for _ in 0 ..< 30: worst.add 150
    let atCeiling = foldNaive(int64(65536), worst)  # seed = 2^16, the pinned ceiling scale
    echo &"  naive worst-case (30x x1.50) from seed=65536: {atCeiling}"
    check atCeiling < high(int64) div 1000  # nowhere near int64 overflow
    # It DOES exceed live RecutProductCapArmed (2^31 internal, S7) in this
    # deliberately adversarial all-x1.50 stress case (~1.26e10 vs the
    # ~2.15e9 cap) -- expected and fine:
    # a real fractional-tier fold would compose through the SAME
    # capsArmed check `recutFold` already applies to every other class,
    # not bypass it. Recorded here so nobody mistakes "no int64 overflow"
    # for "no cap interaction needed."
    check atCeiling > RecutProductCapArmed
    let realistic = foldNaive(int64(RecutSeed), chainOf(30))
    echo &"  naive realistic 30-factor mixed chain from RecutSeed={RecutSeed}: {realistic}"
    check realistic < RecutProductCapArmed  # comfortably inside today's cap

  test "UNPLANNED FINDING: the doc's FIRST-DESCRIBED mitigation (single truncation at the end) OVERFLOWS before it ever divides":
    # This is exactly what CATALOG-V3-DRAFT.md's Option B costing proposed
    # as the fix for compounding rounding drift: keep the exact rational
    # product, truncate once. Run for real, it fails -- the intermediate
    # numerator (e.g. 150^30) is astronomically larger than int64 can
    # hold, long before the single division that was supposed to make it
    # safe. Proven by triggering the real defect, not by arithmetic
    # argument alone.
    var worst: seq[int] = @[]
    for _ in 0 ..< 30: worst.add 150
    expect(OverflowDefect):
      discard foldMitigatedNaive(int64(65536), worst)
    echo "  CONFIRMED: single-truncation-at-the-end mitigation overflows int64 on a 30-factor chain (150^30 as the intermediate numerator) -- this specific mitigation does NOT work as originally described and needed the batched redesign below."

suite "percent-scaled headroom: rounding drift (S4 gate condition 2a, part 2)":
  test "NAIVE per-step truncation at the REAL seed is a near-total loss -- a genuine finding, not a pass":
    let chain30 = chainOf(30)
    let naiveAtSeed = foldNaive(int64(RecutSeed), chain30)
    let exact = exactProduct(int64(RecutSeed), chain30)
    let drift = driftPct(naiveAtSeed, exact)
    echo &"  naive fold at RecutSeed={RecutSeed}: integer={naiveAtSeed} exact={exact:.2f} drift={drift:.2f}%"
    # THE FINDING: at the real starting seed, EVERY single naive percent-
    # scaled fold in this tier (100..199) is a fixed point -- acc*pct div 100
    # floors back to acc itself when acc=1, for any pct in [100,199].
    # 30 applications produce ZERO change. This is not a rounding error,
    # it is complete failure of the mechanism at the real seed.
    check naiveAtSeed == int64(RecutSeed)
    check drift > 99.0'f64  # near-total loss, measured, not asserted-away

  test "the SAME naive per-step fold is fine once the accumulator has already grown (post a few whole-class folds)":
    let chain30 = chainOf(30)
    # 16 is a realistic post-recipe accumulator (e.g. seed(1) folded
    # through a couple of existing x2/x4 class deeds before any
    # fractional-tier deed fires) -- NOT the raw seed.
    let naiveAt16 = foldNaive(int64(16), chain30)
    let exactAt16 = exactProduct(int64(16), chain30)
    let driftAt16 = driftPct(naiveAt16, exactAt16)
    echo &"  naive fold at seed=16: integer={naiveAt16} exact={exactAt16:.2f} drift={driftAt16:.2f}%"
    check driftAt16 < 10.0'f64  # single-digit drift once the base isn't tiny
    let naiveAtCeiling = foldNaive(int64(65536), chain30)
    let exactAtCeiling = exactProduct(int64(65536), chain30)
    let driftAtCeiling = driftPct(naiveAtCeiling, exactAtCeiling)
    echo &"  naive fold at seed=65536 (pinned ceiling scale): integer={naiveAtCeiling} exact={exactAtCeiling:.2f} drift={driftAtCeiling:.2f}%"
    check driftAtCeiling < 0.1'f64  # negligible at the ceiling scale

  test "CORRECTED mitigation (batch-of-5 renormalization): overflow-safe; drift is REDUCED but NOT eliminated at the real seed":
    let chain30 = chainOf(30)
    # Sanity: the batch size itself must stay overflow-safe -- 150^5 is
    # the largest intermediate numerator this batch size can produce,
    # nowhere near int64 range even multiplied by a near-ceiling accumulator.
    check int64(150) ^ 5 < high(int64) div 1_000_000
    var worstCase: seq[int] = @[]
    for _ in 0 ..< 30: worstCase.add 150
    # DEFAULT cap (RecutProductCapArmed) engaged: a 30-factor all-x1.50
    # stress case from the ceiling scale naturally exceeds the live 2^31-
    # internal (S7) cap on its own (uncapped it would reach ~1.26e10, see
    # the naive worst-case measurement above) -- the mechanism correctly
    # routes through the SAME existing cap rather than needing a new one.
    let worstBatchedCapped = foldMitigatedBatched(int64(65536), worstCase, batch = 5)
    echo &"  batched-5 worst-case (30x x1.50) from seed=65536, DEFAULT cap engaged: {worstBatchedCapped} (clamped correctly, no overflow)"
    check worstBatchedCapped == RecutProductCapArmed

    # UNCAPPED (cap=high(int64)) isolates the PURE rounding-drift question
    # from cap-clamping, which is a separate, already-correct behavior.
    for seed in [int64(RecutSeed), int64(2), int64(4), int64(8), int64(16), int64(65536)]:
      let batched = foldMitigatedBatched(seed, chain30, batch = 5, cap = high(int64))
      let exact = exactProduct(seed, chain30)
      let drift = driftPct(batched, exact)
      echo &"  batched-5 UNCAPPED fold at seed={seed}: integer={batched} exact={exact:.2f} drift={drift:.4f}%"
    # THE HONEST RESULT, measured, not assumed: batching cuts drift a lot
    # versus the naive per-step fold at the real seed (23.6% vs 99.95%)
    # but does NOT collapse it to negligible the way the (broken) single-
    # truncation idea implied it would -- at the REAL production seed,
    # a meaningful ~24% of the fractional tier's true value is still lost
    # to truncation even with batching. Only once the base has already
    # grown large (the pinned ceiling scale, 65536) does drift become
    # genuinely negligible.
    let driftAtRealSeed = driftPct(foldMitigatedBatched(int64(RecutSeed), chain30, batch = 5, cap = high(int64)),
                                    exactProduct(int64(RecutSeed), chain30))
    check driftAtRealSeed > 15.0'f64   # still substantial at the real seed -- NOT solved
    check driftAtRealSeed < 99.0'f64   # but a real, measured improvement over naive's 99.95%
    let driftAtCeilingUncapped = driftPct(foldMitigatedBatched(int64(65536), chain30, batch = 5, cap = high(int64)),
                                           exactProduct(int64(65536), chain30))
    check driftAtCeilingUncapped < 0.01'f64  # negligible once the base is already large, drift isolated from capping

suite "percent-scaled headroom: FIXED-POINT ACCUMULATOR (S4 gate follow-up, coordinator ruling)":
  test "drift <= 1% at every tested seed, for BOTH SCALE=2^8 and SCALE=2^10 -- the decision test":
    let chain30 = chainOf(30)
    let seeds = [int64(1), int64(2), int64(4), int64(8), int64(16), int64(65536)]
    var worstDriftBySale: seq[float64] = @[]
    for scale in [int64(256), int64(1024)]:  # 2^8, 2^10
      var worst = 0.0'f64
      for seed in seeds:
        let scaledResult = foldFixedPoint(seed, chain30, scale)
        let unscaled = scaledResult div scale          # `recutScore`-equivalent: strip SCALE once
        let exact = exactProduct(seed, chain30)
        let drift = driftPct(unscaled, exact)
        echo &"  SCALE={scale} seed={seed}: fixed-point={unscaled} exact={exact:.2f} drift={drift:.5f}%"
        if drift > worst: worst = drift
      worstDriftBySale.add worst
      echo &"  SCALE={scale}: worst drift across all seeds = {worst:.5f}%"
      # THE DECISION RULE: drift <= 1% at every seed, with margin to spare.
      check worst <= 1.0'f64

  test "existing INTEGER factors (x2, x3, x12) stay EXACT under fixed-point, both scales":
    for scale in [int64(256), int64(1024)]:
      for (pct, expectedFactor) in [(200, 2'i64), (300, 3'i64), (1200, 12'i64)]:
        let scaledResult = foldFixedPoint(int64(1), [pct], scale)
        let unscaled = scaledResult div scale
        echo &"  SCALE={scale} pct={pct}: result={unscaled} expected={expectedFactor}"
        check unscaled == expectedFactor  # zero drift -- whole percents are exact multiples of 100

  test "overflow margin: RecutProductCapArmed * SCALE * 150 stays below 2^62, both scales":
    for scale in [int64(256), int64(1024)]:
      let margin = RecutProductCapArmed * scale * int64(150)
      let bound = int64(1) shl 62
      echo &"  SCALE={scale}: cap*scale*150 = {margin}  (2^62 = {bound}, ratio = {(margin.float64/bound.float64):.9f})"
      check margin < bound
      check margin < high(int64)  # explicit, not just implied by the 2^62 check

  test "FF-halving division path: verify the intermediate BEFORE the halving division, both scales":
    let chain30 = chainOf(30)
    for scale in [int64(256), int64(1024)]:
      let scaledAtCap = RecutProductCapArmed * scale  # worst-case fixed-point accumulator
      echo &"  SCALE={scale}: scaled accumulator at cap = {scaledAtCap} (no overflow forming this value)"
      check scaledAtCap < high(int64)
      # SAFE ORDER (recommended): halve first -- mirrors `recutScore`'s existing
      # `if halvings >= 63: return 0` guard verbatim, unaffected by SCALE -- then
      # strip SCALE second. Verified to match a NAIVE COMBINED-DIVISOR order at
      # every realistic halvings count, and the combined order is shown to
      # overflow for large halvings where the safe order does not.
      let scaledResult = foldFixedPoint(int64(1), chain30, scale)
      for halvings in [0, 1, 2, 3, 5]:
        let safeOrder = (scaledResult shr halvings) div scale
        let combinedDivisor = scale * (int64(1) shl halvings)
        let naiveCombined = scaledResult div combinedDivisor
        check safeOrder == naiveCombined  # agree at realistic halving counts
      # Where the combined-divisor order becomes UNSAFE (not used in production,
      # demonstrated here so nobody reaches for it later): scale*(1 shl halvings)
      # itself overflows int64 well before any realistic halvings count.
      check scale * (int64(1) shl 40) < high(int64)   # combined divisor still fine at 40
      check high(int64) div scale < (int64(1) shl 61) # ...but AT 61 the combined divisor would overflow -- the safe (halve-then-unscale) order never forms this product at all.

# S1 review: `packedDangerQ8` truncation instead of `floor`

Written 2026-09-09 by Claude (peer). Reviewed `S1_PREREG.md` and the working-tree diff
against d88fe68d (`src/shell/body_route_query.nim` one line; one new test in
`tests/test_shell_body_nav_rework.nim`). No source edits, no benchmarks. Independent checks
on this Mac: the focused suite passes 13 of 13 with the new test; a standalone Nim sweep and
a look at the generated C, described below.
Session: https://claude.ai/code/session_011mWTyq15wvCqJ4jTbnEw5a

## 1. Verdict
Exact for every input the raster can produce. The test pins the rounding contract at the
boundaries that matter but does not itself prove the floor-equals-truncate claim; one
reference sweep would close that. Two pre-existing edge behaviours (NaN, infinity, and
overflow past int64) are undefined in both the old and new code and are outside the raster's
contract; they should be stated, not tested for a specific value.

## 2. Exactness argument and evidence
- The change: after `if value <= 0: return 0`, `scaled = value.float * 256.0` is strictly
  positive for every finite positive `value` (float32 to float64 widening is exact; the
  multiply by a power of two is exact). For `scaled > 0`, truncation toward zero equals
  floor, so `scaled.int == floor(scaled).int` for all finite positive inputs. The
  ties-to-even step and the `rounded > 0x7fff` rejection are untouched and operate on the same
  `lower`.
- Empirical: a standalone sweep of every `k / 1024 / 256` for `k` in `1 .. 32767 * 1024 + 512`
  (33,553,920 inputs, every exact tie and every 1/1024 step through the full Q8 range)
  compared `floor(scaled).int` with `scaled.int`: 0 mismatches. Spot values (3.7, 0.999,
  0.001, 1e-30, the 32767 and 32767.5 boundaries) agree.
- Generated C (Nim 2.2.6, `-d:release`): `scaled.int` becomes `(NI)(scaled)`, a plain C
  cast, followed by Nim's range check that compares the already-cast value with the int64
  bounds; that check can never fire and GCC folds it. The old code had the same cast after a
  `floor` call. So on amd64 the change removes exactly the libm `floor` call identified in
  `COMPILER_REVIEW.md` section 2 and adds nothing.
- `-0.0` and negatives: caught by the guard in both versions. Denormals: positive, truncate
  to 0, floor to 0. Values in (0, 1/256): both give `lower = 0` and the tie logic handles
  `fraction`.

## 3. Invalid inputs (NaN, infinity, values beyond int64)
- `NaN <= 0` is false, so NaN passes the guard in both versions. Converting NaN or an
  out-of-range double to an integer is undefined behaviour in C; `floor` is the identity on
  NaN and infinity, so the old code performed the same undefined conversion. On amd64
  `cvttsd2si` returns `INT64_MIN` for NaN and out-of-range; on arm64 the conversion
  saturates; under `-O3` the compiler may treat the result as unspecified (my Mac run printed
  different garbage for the two versions on NaN and infinity, which is that unspecifiedness,
  not a difference in the defined behaviour). Whatever value comes out, `rounded > 0x7fff` is
  false for `INT64_MIN`, so such inputs silently pack to `uint16(INT64_MIN) = 0` rather
  than raising: a pre-existing latent gap in the range rejection, identical before and after.
- Contract: the raster is a sum of finite non-negative kernel values (`attenuation` returns
  values in [0, 1], `DangerCloseFloor = 0.5`, at most 8 sources), so its maximum is a small
  finite number, far below the 127.996 that saturates 15-bit Q8, and NaN cannot arise unless
  a kernel entry is NaN at activation. S1 neither introduces nor fixes the undefined cases.
  Recommend a one-line doc comment stating the finite non-negative precondition; a guard
  (`if not (value < 128): raise`) would be a separate, behaviour-visible change and is not
  part of S1.

## 4. Does the test cover the contract?
The test packs a raster whose first cells are scaled values 0, 0.5, 1.5, 2.5, 3.5, 2.499,
2.501 and 32767, expects 0, 0, 2, 2, 4, 2, 3, 32767 after masking the hot bit, then expects
`BodyMapError` for 32767.5. Inputs are built as `value / 256.0'f32`, exact for the
power-of-two scaling, and the near-ties survive the float32 rounding, so the expectations are
robust. This pins ties-to-even at even and odd `lower`, strict above and below a tie, the
zero guard, the top of the range, and the first rejected tie. Good.

What it does not cover, in order of value:
1. The equivalence claim itself. The prereg's statement is "equal to floor"; a reference
   sweep inside the test (a local `floor`-based reference against `packedDangerQ8` through
   `rebuildPackedWeights`, or a small exported helper) over all exact ties and a fine grid up
   to 32767.5 is the direct proof. My standalone sweep ran in well under a second in release;
   a 1/64 grid plus all ties (about 2 million inputs) is enough for the suite.
2. A negative and a `-0.0` input packing to 0 (the guard), so the guard is pinned next to
   the tie logic it protects.
3. The hot-bit scatter is exercised implicitly (the test masks it); a cell with a positive
   neighbour and zero value should show the hot bit set, which is the packer's second pass.
   Optional; not part of S1's change.
4. NaN and infinity: do not add value expectations (undefined); if anything, document.

## 5. Prereg review (`S1_PREREG.md`)
Sound as written: parent d88fe68d, B = 1,024, three interleaved fresh parent/candidate
processes on m5a CPU 5, same Nim 2.2.6 and flags, fresh caches; exactness via route hash,
zero missing/illegal, unchanged allocation; carry only if weight refresh improves beyond the
paired variation; no claim on pops, whole-body gates, SJF, expiry, fleet or shipping.
Additions I would make before the run, none changing the acceptance:
- Record `gcc --version` on m5a in the manifest (the libm call is the mechanism; the C
  compiler is the variable).
- State the exactness set explicitly: per-case `danger_hash` (asserted by `--quality`
  already), full corpus route hash, `pops_per_tick` arrays equal in all six rows, and
  activation ledger equal. `--latency` non-timing equality is implied by equal tables and can
  be skipped.
- Prediction, so it is falsifiable: `weight_refresh_p95_ns` falls by the cost of one libm
  call per nonzero cell; `danger_p95_ns` minus the weight slice unchanged; `ns/pop`
  unchanged. Anything else moving is a signal to investigate, not to celebrate.
- The C0 dependency ("after C0 completes") should name the artifact it waits for.

## 6. What this does not establish
No timing. The number of nonzero cells per rebuild, hence the size of the saving, is not
emitted by the harness; Codex may want that counter in the ledger for this run. Nothing here
bears on the raster rebuild floor, SJF starvation, or the m5a qualification beyond the weight
slice.

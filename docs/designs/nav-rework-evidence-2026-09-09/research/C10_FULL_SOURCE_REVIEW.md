# C10 full-source candidate: bounded review

Reviewed, read only: the diff `C10/full/parent-body_nav.nim` to
`candidate-body_nav.nim` (frozen hashes a0200d40 and b9d0c020; the
candidate is byte identical to the live nav-deferred-cache source and the
parent to the micro parent and the primary), `C10/full/run_native.sh`
(e95af6d5), `summarize_native.py` (8b7e1110), `check_c10_full_replay.nim`
(44ab3922) with `full-correctness.log`, the cache, navigation and server
shape logs, and `C10_FULL_PLAN.md`. No implementation, no native job.

## 1. Verdict

No blocking defect. The candidate changes exactly four things, the replay
body is the proven prototype, the scalar fallback is the proven grouped
scalar arm, the constant table is accounted, and the runner and evaluator
implement the registered five-pair screen. Two non-blocking notes in
section 5.

## 2. Equivalence to the proven prototype

The diff touches: the guarded `nimsimd` imports; the `DangerReplayLaneMasks`
constant; one ledger line; and the body of `replayVisibleCells`. Nothing
else in `body_nav.nim` changes, so the miss path, recording, slot scan,
victim choice, source order, close floor, scale/max and publish are the
parent's. I normalized the candidate's `replayVisibleCells` against the
frozen tools helper `replayFourCellGroups` (mask constant renamed, the
static flag replaced by the target test): the bodies are line-identical.
The SIMD path is therefore the one the native micro timed and the one the
crafted, border and real-map bitwise checks passed on both hosts.

## 3. Architecture fallback

`when defined(amd64)` imports SSE2, `elif defined(arm64)` imports NEON, and
the replay uses `when not (defined(amd64) or defined(arm64))` for the
grouped scalar path, which is the micro's scalar arm verbatim (same
predicate, same hoisted pointers, four guarded lane adds). SSE2 and NEON
are baseline on those targets, so no runtime dispatch is needed and none
is added. Both explicit server compile shapes build (`server-linked.log`,
`server-stub.log`). The full-source correctness tool now calls the real
`replayVisibleCells` rather than the helper: five crafted cases and 256
border/mask cases pass on this ARM machine; on x86 the same body was
verified through the micro's helper on both hosts, and the full run's
raster chains and fingerprints check the real function against the
parent on real maps.

## 4. Constant-table accounting

`DangerReplayLaneMasks` is `array[16, array[4, uint32]]`, 256 bytes,
declared `const`; the mask is loaded through `unsafeAddr` on both vector
targets, so it must be emitted as static data (root's
`check_const_mask_address` probe covers that). The ledger adds
`sizeof(DangerReplayLaneMasks)` to `sharedDangerSourceCache` once per
system, on every target including scalar ones where the table is unused.
That is conservative in two ways (per system rather than per process, and
counted where unused) and the amount is irrelevant to every cap; no cap
changes. Correct as an accounting statement.

## 5. Runner, evaluator and plan

- Runner: clean tree, tools absent, base compared to the recorded base,
  parent and candidate overlaid in turn with patches recorded, cache
  (regimes) and trace benches built per arm, five repeats with alternating
  arm order, CPU 5, nine traces plus regimes per arm per repeat, then the
  candidate's quality on the old hash, executable hashes, restoration on
  exit. Consistent with the plan's five interleaved pairs.
- Evaluator: 45 trace pairs and 40 regime rows required; exactness is
  ordered inputs and raster chain per trace and map/range/regime/rebuild
  count/fingerprint per regime row; per-trace median total at most 1.01
  and p95 at most 1.03; changing-source median at most 1.01; repeated at
  most 0.90; quality 3,072 scored, zero missing or illegal, old hash
  5a134021..., all 49 strata within 0.5 and 3 percent. Matches the
  registered screen and the C9 evaluator's structure.
- Non-blocking 1: run `check_c10_full_replay` natively on both hosts in
  the same session (it builds in seconds) so the crafted and border cases
  are also recorded against the real function under SSE2, not only under
  NEON here and through the helper there.
- Non-blocking 2: the m5a changing-source rows carry the unexplained C9
  finding (parent spread 0.8 to 2.0 percent over three pairs); five pairs
  were chosen for that reason and the 1.01 limit is unchanged. If the
  candidate fails there again with a Nim-identical miss path, the C9
  diagnostic record applies and no threshold discussion follows.

No whole-body adoption follows from this screen; the plan's later
integrated qualification (76-map memory, configured tick, minimum 5
percent worst configured p95 gain before retention, absolute gates
unchanged, retained H1 hash ee2488d3...) stands as written.

C10 FULL SOURCE REVIEW READY

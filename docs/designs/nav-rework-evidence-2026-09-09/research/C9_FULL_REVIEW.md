# C9 full native result: peer review

Reviewed: `C9_NATIVE_FULL_RESULT.md`, `C9-full-m8i-summary.json`,
`C9-full-m5a-summary.json`, every raw regime file under `C9-full-m5a/` and
`C9-full-m8i/`, the frozen snapshots under `C9/full/snapshots/`, and the
frozen generated-C excerpts under `C9/full/local-mac/generated-c/`.
Documents plus one counts-only run (section 3); no implementation, no native
job, no threshold or gate change.

## 1. Verdict

The screen result stands as root reported it: m8i passes all 17 checks; m5a
passes all 9 trace checks and all 4 repeated-source checks and fails three
changing-source medians (br-gen-5001 1.0140, br-gen-5263 1.0164, colossal
1.0119 against the 1.01 limit; br-gen-5204 passes at 0.9962). No adoption, no
amendment of 1.01, nav-deferred-cache stays frozen. The m5a per-trace
improvements (0.9036 to 0.9866) and the repeated-source improvements are
retained as evidence and do not offset the failed preregistered check.

First-hit conversions are an unlikely explanation of the m5a difference
under the measured cost model. In root's primary changing regime the
candidate performs 6 to 27 conversions per 1,536 lookups; at the micro's
average hot conversion cost those conversions come to 0.01 to 0.03 percent
of the regime total on m5a, against a measured 1.2 to 1.6 percent excess.
That estimate is not a bound: the micro measured warm, repeated
conversions of one origin, and a cold per-origin conversion in the regime
(fresh entries region, cold bitmap) can cost more than the micro average.
Counts and the micro make conversion unlikely; they do not prove it
impossible (correction from `C9_DIAG_DECISION.md`). If the excess is real
and not conversion, it sits on the miss path, whose Nim source is byte
identical to C2. Section 5 says which diagnostic that justifies and which
it does not.

## 2. Source inspection (as asked)

Comparison of `C9/full/snapshots/parent-body_nav.nim` against
`candidate-body_nav.nim`, proc by proc:

- `addVisibleCell`, `castRay`, `nextVisitGeneration`, `sourceCacheSlot`,
  `sourceCacheVictim`: byte identical. The candidate's `addVisibleCell` is
  the C2 one; it records into the bitmap on first visit and nothing else.
- `rebuildDangerFromPoints`: differs only in the hit branch (`listLength < 0`
  chooses `materializeVisibleCells`, otherwise `replayListEntries`) and in the
  miss-path slot constructor gaining `listLength: -1`. The miss path's work
  (cast rays, record bitmap, close floor) is unchanged.
- `replayVisibleCells` exists only in the parent; `materializeVisibleCells`
  and `replayListEntries` exist only in the candidate.
- Slot layout: `key: int32`, `listLength: int32`, `lastUse: uint64`.
  `listLength` occupies the four bytes that were padding between the C2
  slot's `key` and `lastUse`; the slot is still 16 bytes.
- Generated C (Mac excerpts, frozen): `addVisibleCell` is `static N_INLINE`
  in both arms; `rebuildDangerFromPoints` is an out-of-line `N_NIMCALL` in
  both arms. The candidate's body is 339 lines against the parent's 329.

## 3. Exact composition of the changing regime

Root's note in the raw JSON says the changing regime is not assumed to be all
misses and the counters must be inspected. The native timing builds carry no
counters, so I built root's primary tool `tools/bench_body_danger_cache.nim`
with one added output line (`conversions`) in the peer-owned nav-source-cache
tree against the frozen candidate and ran it once on the Mac for counts only.
Tool copy, output, build line and fingerprint check:
`C9/full/review-counts/`. The raster fingerprints of all eight regime rows
equal those recorded in all 48 native rows, so the native runs used exactly
this lookup sequence.

| map | hits / misses / conversions per 1,536 lookups | hit share |
|---|---|---:|
| br-gen-5001 | 27 / 1,509 / 27 | 1.8% |
| br-gen-5204 | 26 / 1,510 / 26 | 1.7% |
| br-gen-5263 | 15 / 1,521 / 15 | 1.0% |
| colossal | 6 / 1,530 / 6 | 0.4% |
| repeated (all maps) | 1,528 / 8 / 8 | 99.5% |

So the primary changing regime is 98.2 to 99.6 percent misses, and every hit
is a first hit (a conversion); the candidate never gets to replay a list in
that regime. This is a different composition from my C7-era regime tool
(`bench_danger_regimes.nim`, 18 percent hits), which is why the two must not
be compared. Root's tool draws each source uniformly at random from the
32-pixel standable lattice, so with 64 slots and a pool of several hundred
keys nearly every key is evicted before it recurs.

## 4. Can conversions explain the measured difference? Unlikely, not excluded.

Estimate of the conversion cost, per map, on m5a, under the micro's cost
model. One bitmap replay is taken as one eighth of the parent's
repeated-source median (that median includes the close floor, scan and
publish, so this part is generous). The conversion increment is the m5a
micro's average over warm, repeated conversions of the same origin; a cold
per-origin conversion in the regime is not bounded by that average, so the
resulting figure is an estimate, not an upper bound.
(`C9_NATIVE_RESULT.md`: 0.0729 to 0.0744 of a bitmap replay at 1300 px); the
m8i increment (0.2369 to 0.2439) is shown as a stress value even though it is
the wrong host.

| map | conversions | parent changing median | replay estimate | conversion estimate (m5a increment) | share of the 192-rebuild total | share at the m8i increment | root's measured m5a median ratio |
|---|---:|---:|---:|---:|---:|---:|---:|
| br-gen-5001 | 27 | 7.914 ms | 0.234 ms | 0.47 ms | 0.031% | 0.101% | 1.0140 |
| br-gen-5204 | 26 | 7.817 ms | 0.216 ms | 0.42 ms | 0.028% | 0.092% | 0.9962 |
| br-gen-5263 | 15 | 7.381 ms | 0.225 ms | 0.25 ms | 0.018% | 0.059% | 1.0164 |
| colossal | 6 | 14.065 ms | 0.780 ms | 0.35 ms | 0.013% | 0.043% | 1.0119 |

The measured excess is 40 to 90 times the conversion estimate, and the map
with the fewest conversions (br-gen-5263, 15) has the largest and most
consistent excess. Under this cost model conversions are an unlikely
explanation; a cold per-origin conversion would have to cost 40 to 90 times
the micro average to account for the excess, which is implausible but not
excluded by these counts. No mechanism diagnostic of the conversion path is
justified on this evidence.

Two further observations from the raw samples (informational, same-index
pairing of the three runs):

- Not front-loaded. Splitting the 192 samples into thirds, the m5a
  candidate/parent ratio on br-gen-5263 is 1.014, 1.018, 1.019 and on
  br-gen-5001 1.006, 1.018, 1.017. A first-touch cost of the 27.7 MB entries
  region (page faults, zeroing) would show in the first third only; it does
  not, and that region is allocated at construction outside timing anyway.
- Uniform across sample positions on br-gen-5263: every one of the 16
  sample-position groups shows ratio 1.014 to 1.028, whether or not the
  parent's own time in that group is high or low. On br-gen-5001, colossal
  and br-gen-5204 the per-position ratios straddle 1.0 (0.992 to 1.032).

Run-to-run spread of the parent alone on m5a (per-run medians): br-gen-5001
1.77 percent, br-gen-5204 1.63 percent, br-gen-5263 0.77 percent, colossal
1.96 percent. Root's per-pair ratios: br-gen-5001 1.0219, 0.9895, 1.0140;
br-gen-5204 1.0128, 0.9864, 0.9962; br-gen-5263 1.0240, 1.0140, 1.0164;
colossal 0.9918, 1.0163, 1.0119. On m8i the parent's spread is under 0.5
percent and all twelve pairs sit within 0.994 to 1.006. On m5a the pair noise
is the same size as the limit, so only br-gen-5263 (three pairs all above
1.01, uniform across positions, smallest parent spread) is clearly outside
the noise. That is an observation about the diagnostic power of a three-pair
design on this host; it is not an argument to relax 1.01, and I do not make
one. The preregistered screen was three pairs and it failed.

## 5. Which mechanism diagnostic is justified

Since the Nim source of the miss path is identical, a real steady-state
miss-path slowdown on one host can only come from the binary: different
inlining, code alignment, or register allocation inside the larger
`rebuildDangerFromPoints` (the cast-ray loop lives in it, and
`addVisibleCell` is inlined into it), or from data placement of the seat
object now that the cache field is larger. Both are host-sensitive and both
are invisible in Nim source. In order of cost and information:

1. Justified, no timing, no build: on m5a, disassemble the two frozen
   binaries (root has the executable hashes) and compare
   `rebuildDangerFromPoints` and the inlined `addVisibleCell` and `castRay`
   machine code: function alignment, whether `castRay` is inlined in one arm
   and not the other, loop alignment, and spill count in the ray loop. If the
   miss-path machine code is instruction-identical apart from the two known
   branches, the layout hypothesis is dead and the result is noise plus a
   possible data-placement effect. If it differs materially, root has the
   mechanism without any timing.
2. Justified, cheap, timing but no candidate change: a null set on m5a with
   the same tool and the same three-pair interleaving, parent against a
   second parent build, to record the pair noise band of this tool on this
   host. It is a control, not a re-screen; whatever it shows, the failed
   screen stays failed and the limit stays 1.01. Its use is deciding whether
   any future changing-regime screen on m5a needs more pairs or a
   per-sample paired statistic, decided before that screen starts.
3. Not justified: a per-tick class split (conversion tick versus miss tick).
   With 6 to 27 conversions per run the conversion class is too small to
   measure and section 4 already bounds it. Not justified: an all-miss
   control regime; the primary regime already is one in effect. Not
   justified: any new optimization, lazier conversion, or slot-count change;
   there is no conversion cost to remove.

If diagnostic 1 shows a layout difference, the only candidate-side response
would be a source change that restores the parent's miss-path code shape
(for example keeping the hit branch out of line), and that would be a new
candidate under the same unchanged gates, not a relaxation. I am not
proposing it now; root decides after the disassembly.

## 6. Standing statements

- No miss-only cost claim: the regime has 6 to 27 hits per run and they are
  estimated above; the excess is not attributed to a specific instruction
  path, and the conversion path is judged unlikely, not excluded.
- 1.01 unchanged; the m5a changing-source screen failed; no adoption.
- m5a trace totals improving on all nine traces is preserved as evidence
  for the record, not as a pass.
- Primary remains C2 with the 32 MiB shared and 256 MiB total caps. (Later
  note: the C9 source in nav-deferred-cache was restored after the
  diagnostic decision; that tree is now the A8 experimental tree.)

C9 FULL REVIEW READY (corrected per C9_DIAG_DECISION.md; see C9_DIAG_REVIEW.md)

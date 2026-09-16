# C10 native micro result: independent recomputation

Reviewed `C10_NATIVE_MICRO_RESULT.md`, `C10/native-summary.json`,
`C10/summarize_native.py`, and every raw file under `C10/m8i/` and
`C10/m5a/` (90 process outputs per host plus `correctness.json`). Documents
only; no native work.

Recomputed from the raw samples with my own script (pair the three arms
by repeat index, each arm's median of five batch values, ratio per repeat,
median of five ratios), without using root's evaluator:

| host | map | scalar/parent 331 | scalar/parent 1300 | SIMD/parent 331 | SIMD/parent 1300 | SIMD/scalar 1300 |
|---|---|---:|---:|---:|---:|---:|
| m8i | br-gen-5120 | 0.7153 | 0.7219 | 0.4083 | 0.4426 | 0.6148 |
| m8i | br-gen-5204 | 0.7039 | 0.7145 | 0.4104 | 0.4398 | 0.6164 |
| m8i | br-gen-5263 | 0.7201 | 0.7278 | 0.4215 | 0.4520 | 0.6222 |
| m5a | br-gen-5120 | 0.7406 | 0.7288 | 0.2824 | 0.2910 | 0.4010 |
| m5a | br-gen-5204 | 0.7405 | 0.7291 | 0.2822 | 0.2905 | 0.3986 |
| m5a | br-gen-5263 | 0.7436 | 0.7310 | 0.2863 | 0.2971 | 0.4063 |

Every value equals root's `native-summary.json` to within 1e-12. Parent
medians per replay: 39 to 48 µs at 1300 px on m8i, 127 to 154 µs on m5a.

Checks I made on the raw files beyond the ratios: five crafted cases and
256 border/mask cases with zero mismatches on both hosts; every process
reports zero reference cell mismatches, 64 origins, stride 97, five
batches, four repeats, and a stored median equal to the median of its
batch values; within every triple the three arms have identical origin
lists and identical accumulated batch raster hashes, so the arms did the
same additions on the same real-map inputs.

Under the rule fixed in `C10_MICRO_DECISION.md`: both grouped arms clear
the 20 percent screen on every 1300 px map on both hosts and no 331 px
row regresses; SIMD improves scalar by far more than 5 percent on every
1300 px map on both hosts (ratios 0.40 to 0.62), so SIMD advances to the
full-source screen. I confirm that reading.

What this does and does not establish, as root states: an isolated
replay-loop improvement on both hosts, with the scalar arm's share
including pointer hoisting and reduced checks; nothing about actual
traces, changing-source regimes, whole-body ticks, quality, activation,
memory or acceptance. The five-pair full-source screen with the unchanged
1 percent limits is the next gate.

C10 MICRO RESULT REVIEW READY

# C10 full screen at park — rejected for adoption

Both already-running five-pair native screens completed before parking.
The fixed evaluator reports m8i PASS and m5a FAIL. No integrated qualification,
adoption, resampling or follow-up experiment was started.

| Host | Trace/regime screen | Strict 3,072-case quality | Decision |
|---|---|---|---|
| m8i-flex | all limits pass | pass, exact frozen pre-H1 hash | host pass |
| m5a | randomized smoke trace total ratio 1.020196 > 1.01 | pass, exact frozen pre-H1 hash | host fail |

The failed row is `parent-smoke_s2_16_randomized`. Its five paired total ratios
are 0.930623923, 0.963932020, 1.020272993, 1.043027304, 1.020196022; the registered
median is 1.020196022. Its median p95 ratio is 1.008800712, within 1.03.
All other trace/regime limits pass. All trace raster chains, ordered inputs,
cache counters and regime fingerprints match. The evaluator checks all 49
quality strata, with zero missing/illegal routes and the unchanged inflation
limits. The paired spread does not establish a causal explanation or a
statistically resolved slowdown; the registered adoption decision is negative.

The earlier micro result remains valid: grouped SIMD substantially improved
hot cached replay on both hosts. That result does not override the failed
actual-trace screen. C10 remains frozen under `C10/full/`, not retained in the
primary research implementation and not active on main. Both runners restored
their source trees and removed their temporary tracked-location tools; root
verified no remaining benchmark process before stopping the instances.

## Reproduce the decision

```sh
python3 docs/designs/nav-rework-evidence-2026-09-09/research/C10/full/summarize_native.py docs/designs/nav-rework-evidence-2026-09-09/research/C10-full-m8i
python3 docs/designs/nav-rework-evidence-2026-09-09/research/C10/full/summarize_native.py docs/designs/nav-rework-evidence-2026-09-09/research/C10-full-m5a
```

Raw JSON, build logs, source/input/executable hashes and DONE markers are in
those host directories; evaluated outputs are the adjacent summary JSON files.
Each host has 45 trace pairs and 40 regime comparisons. The isolated native
base is f9dff753, so quality intentionally uses pre-H1 hash
`5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`;
the retained primary H1 hash is different. Do not conflate those code bases.

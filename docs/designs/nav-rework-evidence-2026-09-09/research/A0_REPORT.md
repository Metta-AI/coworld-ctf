# A0: retain symmetric fine-edge construction

Compute each undirected 4 px legality edge once and set both directional bits. No bridge search, runtime route choice, memory layout, budget or threshold changes. The restriction to unit axis/diagonal segments is essential; this does not claim general arbitrary-slope ray reversal symmetry.

## Exactness and native measurement

Native m8i-flex.4xlarge, CPU 5, Nim 2.2.6/GCC 11.4, source parent 067a4af2. `run_a0.sh` builds separate parent/candidate executables and runs three interleaved activation pairs. All fixed-width graph arrays, dimensions and counts match across all 76 maps (`graph-parent.json`, `graph-candidate.json`). SHA256 covers legality, standability, anchors, cell mappings, wall bands, bridge offsets/lengths/nodes. Graph fingerprints are outside the activation clock.

| Repeat | Parent mixed total ms | Candidate mixed total ms | Parent activation total ms | Candidate activation total ms | Non-colossal ratio failures / 64 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1 | 14275.927 | 11294.523 | 61066.695 | 58056.598 | 54 |
| 2 | 14363.847 | 11216.860 | 61109.128 | 57935.538 | 53 |
| 3 | 14370.606 | 11259.398 | 60940.163 | 58164.647 | 57 |

Mixed-graph construction improves 20.88–21.91% in the repeated 65-map activation workload. All per-map retained ledgers are unchanged. The 53–57 remaining non-colossal failures mean this is an improvement, not activation qualification. Colossal remains below its 3x limit. The single configured 11-map screen has nine activation ratios above 2x; memory passes all 76 maps under the authorized 32 MiB shared non-colossal cap and unchanged 256 MiB total/colossal cap. The harness activation `pass` field checks memory only; ratios here are separately evaluated.

Full quality passes 3072 cases with zero missing/illegal, 37,637,596 pops, maximum 52 route ticks and 77 spans. Route hash remains `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`. Configured whole-body timing still fails on 8/11 maps: worst p95 6.074019 ms, maximum 6.149370 ms. This single candidate screen is not a paired tick-speed claim.

## Validation and documentation audit

Focused navigation tests pass 16/16; server checks pass with and without Wasmtime; the Docker viewer is rebuilt and module evaluation, GV65 and source-stamp checks pass. Native quality exit is 0; configured exit is 1, retained honestly. Source, patches, CPU/compiler details, input/executable hashes and raw JSON/logs are in `A0-m8i/`; independent review is `A0_CODE_REVIEW.md`. `tools/check_body_graph_identity.nim` is the reusable all-array diagnostic, documented by this report and `A0_PREREG.md`.

Main was merged through f789a2f7 during collection. Its changes since the experiment base affect baseline protocol, viewer presentation, stranger-walk tooling and era documentation, not navigation source or measured map/gun-range inputs. Its manifest adds explicit play control slots; the archived measurement retains its original manifest hash. Current viewer checks were run after the viewer merge. No final replay qualification is claimed: all nine fixtures await the selected final budget/version.

The source changes an internal activation implementation only. Existing public configuration and gameplay documentation need no new API description. This report and the scoreboard record the changed algorithm, exactness boundary, measured benefit and remaining gate failures. Next experiment is the separately preregistered exact two-edge bridge shortcut.

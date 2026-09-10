# Peer proof artifacts (Claude, 2026-09-09)

Standalone scripts behind the peer reviews, copied verbatim from the session scratchpad on
2026-09-09 at Codex's request (`PEER_DURABILITY_REQUEST.md`). They are not production code and
are not wired into the build. Provenance note: the scripts' original stdout was NOT retained
as files; each run's printed result was transcribed into the review named below at the time
it was run (visible in the session transcript). No script was rerun to produce this folder.
Re-execution commands are given so the numbers can be reproduced; a rerun should be recorded
as a new, dated output next to the script.

Environment for the Nim scripts: Nim 2.2.6 (macOS arm64), the repo's `nim.cfg` (nimby
package paths) copied next to the script or the repo used as cwd, and for scripts importing
`shell/` modules the runtime-linked flags with `WASMTIME_C_API` set to the fetched wasmtime
(`tools/runtime_spike/fetch_deps.sh`), for example:
`nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on --path:<repo>/src <script>`.
Python scripts need only Python 3.

| file | backs | what it computes | transcribed result |
|---|---|---|---|
| `danger_prefix_counts.py` | `DANGER_PREFIX_REVIEW.md` | ray steps, kind-sequence trie nodes, unique cells, sharing by depth at radii 42, 163, 255 | r163: 924 rays, 188,892 steps, 172,708 nodes, 83,928 cells |
| `danger_wavefront_differential.py` | `DANGER_WAVEFRONT_REVIEW.md` | exact visitor vs Manhattan-shell wavefront on single-wall and random maps; membership, interval and word counts | 740 + 145 trials, 0 mismatches; intervals mean 1.00 max 2 |
| `p1_packer_differential.nim` | `P1_CODE_REVIEW.md` | working-tree `rebuildPackedWeights` vs verbatim parent scatter on real and synthetic rasters | 22 rasters, 0 mismatched cells |
| `giant_map_lattice_census.nim` | `GIANT_MEMORY_PLAN.md`, `BRIDGE_ENCODING_REVIEW.md` | lattice nodes, standable, anchors, wall band, bridge sizes and ledger components for the 11 giant maps | per-map table in the plan |
| `d0a_decision_equivalence.nim` | `D0_CODE_REVIEW.md` | recomputed vs incremental decision branch sequences, all (nx, ny) <= 300 and both perimeters | 90,600 pairs, 0 mismatches |
| `d1_kernel_index_equivalence.py` | `D1_CODE_REVIEW.md` | incremental kernel index vs formula at every add, both radii, three origins | 612,372 adds, 0 mismatches |
| `w1_coordinate_equivalence.nim` | `W1_REVIEW.md` | incremental ray coordinate vs float `pyRound` per sampled point | 176,137,197 coordinates, 0 mismatches |
| `w7_jump_state_equivalence.nim` | `W7_CODE_REVIEW.md` | one jump of k vs k unit advances, incl. bound cases | 1,306,004 comparisons, 0 mismatches |
| `w7_realmap_differential.nim` | `W7_CODE_REVIEW.md` | working-tree `rayClear` vs float reference on real maps | 700,000 pairs, 0 mismatches |
| `s1_trunc_floor_sweep.nim` | `S1_REVIEW.md` | `floor` vs truncation over the Q8 range, NaN/Inf behaviour | 33,553,920 inputs, 0 mismatches |
| `compiler_probe_gcc13.c`, `compiler_probe_gcc12_bookworm.c` | `COMPILER_REVIEW.md` | codegen of floor/round/hypot/sqrt and the Q8 pack loop at candidate flags (run in `gcc:13` and `gcc:12-bookworm` containers, assembly only) | baseline: `call floor` in the pack loop; v2/v3: inline `roundsd` |
| `activation_legality_bridge_check.nim` (+ `.out`) | `ACTIVATION_REVIEW.md` | legality-bit symmetry on all 75 maps; bridge two-hop shortcut vs replicated BFS on every bridge | 91,240,212 edges 0 asymmetric; 22,958,138 bridges 0 mismatches; raw stdout retained |
| `a0_legality_reference_check.nim` (+ `.out`), `a0_identity_tool_candidate_local.json` | `A0_CODE_REVIEW.md` | eight-direction legality reference vs the A0 candidate on 76 maps; local candidate hashes from the identity tool | 16,361,517 nodes, 0 differences; raw stdout retained |
| `wf0_screen_local_mac.json` | `WF0_SCREEN_CODE_REVIEW.md` | full output of `tools/bench_body_danger_wavefront.nim` on this Mac: 14 rows, all rasters bitwise equal; timings informational | 331 px ratios 0.51-0.82, 1,300 px 1.20-1.93 (Mac, not gate evidence) |
| `wf1_work_shape_count.nim` (+ `.out`) | `WF1_PROPOSAL.md` | executed ray steps, unique cells, wavefront cells scanned and active, kernel-cutoff tail, active-interval runs per shell on the 14 screen rows | e.g. pool 0 at 1,300 px: 341,099 steps, 54,162 unique cells, 448,312 scanned; intervals mean 2.6 |
| `wf1_count_gate_model.nim` (+ `.out`) | `WF1_PROPOSAL.md` section 4a | per-source operation model of the interval-narrowed wavefront vs executed ray steps on the 14 screen rows | median events/steps 1.52 at 331 px, 0.86 at 1,300 px; gate failed, WF1 not built |
| `generated_c_castRay_pre_R1.c`, `generated_c_rayClear_pre_W1.c` | `RASTER_REVIEW.md`, `WEAPON_RANGE_REVIEW.md` | extracted Nim-generated C for the two loops before R1 and W1 | call profiles quoted in the reviews |

Not retained: the raw stdout of every run above (transcript only); the Docker container
assembly listings for the compiler probes (only the greps quoted in the review); the
`cache-*` nimcache directories. The activation-row JSON from my one local configured run is
retained separately in `G1-local-peer/`.

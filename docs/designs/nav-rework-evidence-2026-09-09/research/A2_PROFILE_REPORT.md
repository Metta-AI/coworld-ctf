# Remaining map-48 activation cost: Fluffy attribution

A1 leaves only frozen map 48 above the 2x activation requirement on m8i. Five repeated constructor-stage profiles identify where its route index spends time. This is diagnostic attribution, not an ablation or qualification run.

`tools/profile_body_route_index.nim` includes the existing route-index module and invokes its private stages in the same order as newBodyRouteIndex, including validation. It profiles one immutable map through five constructions. The production constructor/source is unchanged. Native m8i CPU 5, Nim 2.2.6; measured checkout 872e5499 has the same body_route_index.nim as A1. Raw Fluffy trace, source hashes, build/run logs, CPU identity and executable hash are in A2-profile-m8i. `run_a2_profile.sh` reproduces the run. The Mac trace is retained separately as informational evidence.

| Stage | Mean ms, five native builds |
| --- | ---: |
| index.complete | 300.175 |
| index.pocketConnectors | 133.170 |
| index.validate | 58.099 |
| index.fieldsAndCountSegments | 51.555 |
| index.legalMoves | 49.324 |
| index.sides | 1.894 |
| index.seedPixelComponents | 1.669 |
| index.graphComponents | 1.536 |
| index.fillSegmentsAndArcs | 1.223 |
| index.roomLayout | 0.855 |
| index.validatorAnchors | 0.698 |
| index.fineAnchorIndex | 0.136 |

The complete stage includes the nested stages, so durations overlap. Pocket connectors dominate, followed by validation, side fields and coarse legal-move construction. This directs further work; it does not prove any stage can be removed or optimized safely.

A small exact candidate is the same undirected-edge symmetry used by A0, applied to 8 px legalNavMove. Its endpoint and diagonal side-cell checks are symmetric, and its restricted axis/diagonal segment samples reverse exactly. Halving constructor calls might save about half the 49 ms stage, but that estimate alone may not close the roughly 30 ms remaining gap. A later validator optimization would need to preserve rejection of malformed/asymmetric/out-of-bounds masks; do not simply omit validation or move it behind a debug flag. Both need separate preregistration and measured results before adoption. No A2 production optimization has been implemented.

Documentation audit: this new standalone profiling tool is documented here and in A2_PROFILE_PREREG.md, with its duplicated orchestration and interpretation limits explicit. It adds no runtime behavior, API, dependency or viewer-source change.

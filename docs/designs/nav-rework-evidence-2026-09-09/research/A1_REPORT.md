# A1: retain exact two-edge bridge shortcut

Regular adjacent cell anchors often differ by exactly two fine steps along one neighbor direction. When both existing legality bits permit the straight path, return its midpoint and target directly. This is the same path the unchanged breadth-first search would find first: cardinal hops precede competing diagonal hops, while a two-step diagonal path is unique. All other cases retain the original search.

## Results

Native m8i CPU 5, Nim 2.2.6/GCC 11.4, parent 872e5499 (A0). Separate binaries, three interleaved 65-map activation pairs. Before timing, every retained graph array on all 76 maps matches, including every bridge node, offset and length; the runner asserts this equality. All retained memory ledgers also match. No budget, memory cap or query behavior changes.

| Repeat | Parent mixed construction total ms | Candidate mixed construction total ms | Map 48 total / BodyMap |
| --- | ---: | ---: | ---: |
| 1 | 11209.060 | 5636.640 | 2.080944 |
| 2 | 11289.506 | 5606.057 | 2.090945 |
| 3 | 11270.742 | 5616.035 | 2.096538 |

Mixed-graph construction improves about 50%. All three pairs now pass the activation ratio on 63/64 non-colossal maps and on colossal. Frozen map 48 remains above its 2x requirement. The configured 11-map diagnostic has 0 activation-ratio failures and 8 timing failures; worst body p95/max is 5.945709/6.081560 ms. This is one candidate screen, not a paired runtime-speed result.

Full quality passes 3,072 cases, zero missing/illegal, 37,637,596 pops, maximum 52 route ticks and 77 spans. Route hash is unchanged: `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`.

## Validation and interpretation

Focused navigation tests pass 16/16; peer also ran the seat suite. Both server compile shapes pass. Viewer rebuilt with Docker, then module evaluation, GameVersion65 and source-stamp checks pass. Raw results, source patches, compiler/CPU/source/binary identity and runner completion are in `A1-m8i/`; `run_a1.sh` reproduces the protocol. Independent source review is `A1_CODE_REVIEW.md`.

These frozen runs use the earlier memory-only activation verdict. Ratios above were checked independently. The reporting bug is fixed separately in bd03d778 and documented in ACTIVATION_GATE_AUDIT.md; its added fields do not retroactively change old JSON. Main merges through 25a8cc30 change viewer presentation and do not alter A1 navigation semantics.

This is a retained activation optimization, not final Phase 10/11 qualification. B1024 remains provisional; the one activation failure, fleet timing, final canonical tests, same-host containment, nine replay fixtures and final documentation remain outstanding.

## Documentation audit

The internal constructor shortcut changes no public API or gameplay contract. This report, the preregistration and scoreboard document its exactness boundary, evidence and remaining failures. The source comment states why the shortcut returns the existing BFS path. Existing final-design budget/replay documentation remains pending selection rather than claiming qualification prematurely.

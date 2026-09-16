# A2: retain symmetric coarse-edge construction; full activation still narrowly fails

Build each undirected8px move once and set its reverse bit. Full constructor/public validation is unchanged. All32,545,936 direction bits on76maps match the original eight-direction legalNavMove reference. Full3072quality remains identical, including route hash and37,637,596pops. Retained memory is unchanged.

## Native paired measurement

m8i CPU5, Nim2.2.6/GCC11.4; parent3aeb0398 includes A1 and the corrected activation verdict. Separate parent/candidate builds, three interleaved map48-plus-colossal activation pairs.

| Repeat | Map | Parent index ms | Candidate index ms | Candidate total / BodyMap |
| --- | --- | ---: | ---: | ---: |
| 1 | published:48:br-gen-24678 | 299.980 | 276.126 | 1.960781 |
| 1 | size:colossal | 4800.973 | 4533.865 | 2.048807 |
| 2 | published:48:br-gen-24678 | 299.816 | 275.556 | 1.950685 |
| 2 | size:colossal | 4798.929 | 4555.726 | 2.039267 |
| 3 | published:48:br-gen-24678 | 299.725 | 276.647 | 1.964269 |
| 3 | size:colossal | 4802.306 | 4655.965 | 2.077695 |

Index construction on map48 improves about24ms. Every candidate targeted pair meets2x/3x. That did not prove the all-map gate: the subsequent full sweep (`A2-full-activation-m8i/`) passes memory on76/76 but time on75/76, with map48 at2.004792788x. This remains a failure. The constructor improvement is retained as a step toward qualification; no variance allowance or threshold relaxation is introduced.

The same full sweep's configured11-map diagnostic passes timing on3/11maps; worstp95/max6.044679/6.143920ms. It is one candidate screen, not a paired runtime-speed claim. Shared non-colossal maximum31,607,620B fits32MiB, total/colossal maximum266,478,979B fits256MiB. No further memory-cap increase is needed here.

## Evidence and validation

`A2-m8i/` contains source/input/executable identities, raw reference-bit checks, paired measurements, quality and runner completion. `run_a2.sh` and `run_a2_full_activation.sh` record commands. `tools/check_body_index_legality.nim` checks all bits independently rather than relying only on existing-edge validation. Focused route-index tests, both server compile shapes, Docker viewer build and module/GV/source-stamp checks pass. A2_CODE_REVIEW.md independently verifies the restricted symmetry and accumulation logic.

Current route hash remains `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`. H1 is a separate isolated heuristic screen and is not in this production source or these results.

## Documentation audit and next question

This internal activation optimization changes no public API, gameplay or configuration. Its source comment, preregistration and this report document the restricted8px symmetry. The new verifier is documented above. Existing design time/memory thresholds remain authoritative; final qualification is incomplete.

A narrower next hypothesis is to inline the existing legalNavMove helper across module boundaries, allowing the compiler to optimize known neighbor arguments without duplicating or skipping its checks. It has no internal callers in body_map.nim, so its primary construction/validation callers are in body_route_index.nim. This is not implemented by A2 and needs its own measured ablation; Fluffy timings alone do not prove a compiler benefit.

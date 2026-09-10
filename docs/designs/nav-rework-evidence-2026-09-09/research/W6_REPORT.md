# W6: specialize the ray sampler by its major axis

Three interleaved native m5a CPU5 pairs, B1,024, range1,300, Nim2.2.6 release/useMalloc/noSignalHandler. Only body_map differs between arms; R1/M3 and the harness are common. Parent worst whole-body p95/max8.201069/8.788592ms; candidate5.960683/6.704114ms. Worst weapon p95 drops6.005851->3.173188ms. All masks and pop arrays match in every row/repeat. These are separate stage maxima, not additive components.

The existing262,144 small-ray and20,000 seeded long/reversed comparisons pass. Both server compile shapes pass locally. Full native m8i quality passes3072 cases, zero missing/illegal,37637596 pops, route hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`. All65 original activation/memory rows pass; configured giant-map shared caps remain failed. Raw evidence: W6-m5a and W6-m8i, including executable hashes, source patches and build logs.

Retain for combined qualification. No wall predicate, endpoint rule, tie rule, compiler check or memory layout changes. The whole-body tick gate still fails; no doubling or Phase10/11 completion claim. Viewer/checkpoint and final fleet qualification remain outstanding.

Subsequent user ruling: MEMORY_CAP_RULING.md authorizes higher non-colossal caps. These raw measurements retain their original16 MiB verdicts; current measured maxima fit the selected32 MiB shared allowance.

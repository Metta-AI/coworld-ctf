# CAP32: fresh memory qualification

The authorized 32 MiB non-colossal shared cap passes all 64 frozen pool maps and all 11 configured maps. Colossal also passes its unchanged total cap. Configured shared maximum is 31,607,620 bytes, leaving 1,946,812 bytes under 32 MiB. Maximum total across all 76 maps is 266,478,979 bytes. These are the existing capacity-based ledger estimates, not a physical RSS upper bound.

Fresh native m8i CPU5 quality retains 3,072 cases, zero missing/illegal, 37,637,596 pops and hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500`. Inputs are the exact archived W7 remote source set plus the cap-only harness update; input hashes, source patch, binary hash, compiler log and raw results are in CAP32-m8i. This is not the final canonical Docker run.

Memory permission does not make the combined gate pass. Configured whole-body worst p95/max is 8.193723/12.828255 ms, so that invocation still exits 1. The inherited total-activation ratios also remain unresolved: 75 of 76 maps exceed 2x BodyMap activation (3x for colossal); see summary.json for each row. The harness activation `pass` field currently checks memory only, so it is not proof of the activation-time requirement. Historical 16 MiB failures remain unchanged.

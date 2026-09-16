# C10 group counts: contiguous lanes cover most replay additions

The unchanged retained C2 replay cache was populated with the same64even-spread origins/stride97 as the corrected C6 micro on each of three maps and both ranges. Counts only, no timing or source optimization. Tool: C10/count_danger_simd_groups.nim; frozen input hashes, build log and six outputs retained under C10/.

Every set-bit raster index was checked against the scalar coordinate formula. Each safe four-cell group stays inside both its kernel row and destination map row. Safe groups contain98.81–99.70%of all replay additions across the six configurations. Roughly3.7set lanes per nonempty group; most additions lie in full four-cell groups even when a64bitword is not full. This is the mechanism C6 full-word specialization did not test. Counts do not predict native speed or changing-source behavior.

A simple implementation option is ctz to the first nonempty nibble, one coordinate division per group, SIMD add for nibble15, masked add/blend for mixed nibbles, scalar fallback only at boundaries. A bitwise blend preserves inactive float bits, including negative zero in crafted tests, without needing a floating-value invariant. Native tools-only micro remains subject to the proposed20%bothhost screen; no implementation or threshold change is claimed by these counts.

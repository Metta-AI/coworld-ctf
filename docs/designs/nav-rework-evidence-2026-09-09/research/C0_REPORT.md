# C0: production build comparison on m5a

Three interleaved fresh process pairs, CPU 5, L1 source at B1024. Native Nim2.2.6/GCC11.4 worst whole-body p95/max: 5.793836/5.857997 ms. Repository Docker build (Nim2.2.4/GCC12) worst: 5.404456/5.496837 ms. All six per-tick pop arrays match between arms in every repeat. The production build is faster in this sample but still fails both ordinary and headroom gates. This comparison changes the complete build environment and does not isolate a compiler version.

Docker explicit quality/activation process exited 0. This is not the final clean-checkout canonical gate. Raw output and compiler/image/source provenance are in C0-m5a. S1 starts only after C0 completion; no concurrent benchmark on m5a.

Accounting correction: pre-M1 danger geometry was copied per seat but counted once. Total-memory numbers understated retained payload; see [GEOMETRY_ACCOUNTING_CORRECTION.md](GEOMETRY_ACCOUNTING_CORRECTION.md). Raw results are preserved.

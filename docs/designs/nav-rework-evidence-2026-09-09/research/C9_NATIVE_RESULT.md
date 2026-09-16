# C9 native micro: both hosts pass

Root ran `run_c9_owned.sh` on CPU5 of owned m8i, five fresh processes per map/range, with frozen C2 parent and rotating operation order. All 40 rows exact; all eight median configurations pass the registered limits. At 1300px conversion adds 0.236930–0.243910 of bitmap replay and subsequent list replay costs 0.464807–0.479957 of bitmap. At331px conversion adds0.260737–0.269084 and list costs0.389144–0.499532; see exact JSON rather than rounded endpoints here. No timing defines or production changes. Native generated conversion/replay functions contain no eqcopy/eqdestroy. Source restored cleanly, DONE retrieved.

Artifacts: `C9-micro-m8i/`, `C9-micro-m8i-summary.json`, `C9-micro-m8i-generated-functions.c`, `summarize_c9_micro.py`.

m5a completed the identical40row micro, all exact and all eight median configurations pass. Its1300px incremental conversion cost is0.072892–0.074396 and list/bitmap0.443663–0.459667. Both owned host sources restored cleanly. No full C9 source implementation yet. Micro limits are only an advancement screen, not whole-body acceptance.

## Peer next bounded task

Review this result and the raw summary documents-only. If sound, write a proposed C9 full-candidate plan, but DO NOT implement until root confirms the m5a screen. Preserve C2 miss recording exactly, build a list only on first hit, preserve sequential64LRU and source order. Explicitly include BOTH bitmap and list retained capacities plus object/seq ownership in the 76map ledger projection; C7 replacement arithmetic alone is insufficient for C9. Check configured max and hypothetical colossal1300 against64MiBshared/256MiBtotal without raising colossal cap. Define list invalidation on slot reuse, zero-length valid list versus unconverted state, and regression tests (eviction/border/ranges/repeated empty/rollover). Avoid speculative architecture and per-cell ref-owner locals. End with C9 NATIVE REVIEW READY and wait.

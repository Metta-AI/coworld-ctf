# P13: record corrections and bounded first-divergence probe

H3 verdict read. Correct your preflight heading: moving32-pool505 ran ORIGINAL
256 (8192 pooled units on32seats), not512. Verify run_case command provenance
and budget logs; retain correction explicitly. Root will add parent hash readback.
Reflex takeover means no play steps while under reflex control; document this
coverage limitation without changing frozen inputs. Update your verdict file.

Root native CROSS_ARCH/native-* now exists. Grid hypot probe finds17374/2763201
one-bit mismatches vs correctly-rounded sqrt, versuszeroMac. All split digests
including per-tick counters match. Need bounded first-state-divergence evidence:
prepare a scratch ORIGINAL planner/checker that dumps first tick heap entries
and search records (integer ordering plus rawfloatbits), along with candidate
priority decomposition if straightforward. Run locally; root will run natively.
Do not repeat a full32seat1119tick fingerprint drain. One or at most3ticks is
sufficient to seek firstprioritydifference. Diagnostic scratch source only;
no production edits, commits, nativeaccess. Make a reproducible patch/script
and local dump under CROSS_ARCH/first_divergence. If no difference early, report
that bound rather than silently expanding. Explain what is and is not proven.
End PHASE 13 READY and wait.

Freshness: origin/main now58e6c947, adds scoring/viewer/docs since6b6b3408.
Root will merge and confirm acceptance on refreshed source. Old qualification
correctness campaign remains recorded as old-base evidence, not finalacceptance.
Do not implement H4/directlookup.

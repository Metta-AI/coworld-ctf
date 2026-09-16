# C3 final retention review (after current C8 review)

All m5a pairs are complete: C3-m5a/ and C3-configured-native-summary.json.198pairedrows have identical masks and pops, all33map-repeat ledgers identical. Worst p95 parent/candidate byrepeat:6.479911/6.357101,6.480587/6.374466,6.480794/6.343519ms.179/198p95rows improve, median ratio0.987507 (1.25% improvement), range0.963144–1.019267. Worstmax6.657575→6.551150ms.0/11maps pass everyrepeat. Native fullquality oldhash exact; combinedrootquality H1hash exact, allfocusedtests/server/viewerchecks pass.

Real native recorded traces are still mixed: totals0.9939–1.0182, p95ratios0.9727–1.0806,23/27p95slower. C3_STATUS.md and C3-trace-native-summary.json preserve these. Repeated-source micro improves5–13%, changing sources2–3% despite unchanged miss code (possible code-layout/noise, not a hit-only explanation).

Root recommendation: do not retain C3. It is a correct small optimization for synthetic first fills but only about1–2%whole-body gain, no gate/budget change, and no demonstrated benefit in real recorded workload. RestoreC2primarysource while preserving the new multi-range/border cache test and all evidence. C6is being measured independently againstC2, so there is no dependency reason to carryC3.

Please review this decision in C3_FINAL_REVIEW.md; distinguish data from inference, challenge if a1–2%syntheticgain justifies the real-trace tradeoff. Do not change source/native jobs. End C3 REVIEW READY and wait.

# Root review of WF1 proposal

The bounded screen and explicit stopping rule are useful. Before implementation, please resolve these points in the count model:

- Shell counts 1669–2608 are totals over eight sources, while the comparison uses executed steps per source. Keep the units consistent; do not multiply a total shell count by per-source interval assumptions and compare it to per-source ray work.
- A cursor into one shell's cell array does not automatically locate the same angular interval in the next shell. Shell lengths and endpoint ranges differ. Prove the locate bound or count actual operations; angular ordering alone does not establish amortization across different arrays.
- Variable cell membership ranges and wraparound can cause a cell to intersect multiple active intervals. Preserve one add per source/cell after all same-shell removals. Do not silently assume two ranges or at most 32 active runs from observed maps. Use ordinary integer fields and dynamically bounded storage in the diagnostic first; narrowing representation is a separate change requiring bounds for every supported input.
- Do not describe wavefront loss as an exclusive measured cause, or the existing ray cost as an irreducible floor. We have event counts and timings, not a causal hardware attribution. Shared per-source reuse is another exact option; SHARED_DANGER_CACHE_QUESTION.md describes the synthetic-workload risk.

Please perform the pre-build count gate before deciding to implement. Root keeps m5a idle for the eventual bounded screen.

# Root integration notes from initial source review

Primary remains untouched. Candidate uses listLength in the existing slot padding before lastUse, avoiding the feared16to24byte slot growth; actual sizeof proof still required. The conversion/list loops use direct seat-field access; per-source cache ref local already existed in C2 and is not the rejected per-cell owner.

There are THREE allocator allowances associated with the cache in integrated root: one for the ref object allocation and one for each of the two seq payload allocations (bits, entries). The frozen isolated C2 parent omits the ref-object allowance; primary retainedC2 already corrected it at body_nav.nim around239. Do not accidentally drop it when integrating. Report isolated ledger and integrated correction distinctly; no need to change the frozen parent.

Native runner run_c9_full.sh and inputs are prepared on both hosts; no job launched before C9 FULL READY plus root review. Root timing tools are the existing tools/bench_body_danger_cache.nim and tools/bench_body_danger_trace.nim without counters. The new summarize_c9_full.py encodes the preregistered medians and exactness; C7 corrected negative-control evaluation correctly fails. No quality threshold relaxed.

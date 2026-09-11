# Phase1 joint decision

PLAN: GO for H1 only initially. Root agrees shared hole-based heap sifting is
a measured, exact-preserving first target. Keep comparator, arity, units,
full active heap layout and positions identical. Implement in peer tree,
root independently validates and owns sequential native runs.

Corrections/decisions:
- Keep the 512 pooled budget including minter unchanged. No mint cap or unit
  repricing to reach the target. We must actually make that work cheaper.
- Do not exclude ladder-burst ticks from whole-frame gates. The requested
  comparison is relative to256, not an absolute41ms maximum. Baseline has the
  same large ladder contribution, so that floor does NOT force every candidate
  to fail. Report split attribution and A/A jitter, but retain all ticks.
- Greater useful work is a valuable benefit, not permission to relax the
  user's no-slowdown target. Report cancelled/wasted work alongside latency.
- Do not narrow generation stamps on a "never wraps" assertion. Any later
  narrowing requires a rollover policy/proof and tests, or retain64bits.
- Leave stackTrace flags unchanged for H1. A later diagnostic-code tradeoff
  must be explicit; it is not a free unchanged-behavior speedup.
- Hardware provenance now refreshed: HARDWARE.md. The common current CTF
  image uses1CPU requests without a limit; m5a is still represented.

PROCEED P2: implement H1 and focused exactness validation. Adapt existing
Nim heapqueue's held-node sift pattern within FixedHeap. Keep oracle immutable.
Prefer a small original-heap oracle plus randomized heap operation comparison
and existing navigation/minter laws; if full planner oracle is needed, preserve
it as clearly-labelled test support. Tests must cover decrease-key, duplicate
priorities/ties, empty/refill, generation reset and suspension boundaries.
Do not add benchmarks, change budget, touch other modules, or run native hosts.
Write H1_IMPLEMENTATION.md and a patch in your research directory, with exact
checks/log paths and limits. End with PHASE 2 READY and wait for PROCEED P3.
Before committing use audit-documentation. Do not rebuild viewer yet; root
will rebuild the final accepted combined source once, before qualification.

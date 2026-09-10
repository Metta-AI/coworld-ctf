# Qualification gap: shared pool cap

Observed full quality/activation at B1024 source20234cc7:3072 scored,0missing/illegal,
route hash5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500.
Largest pool retained total34746735 bytes, mixed_graph16585210, route_index734977,
safety_scratch155696, shared_danger_geometry32676, system_owner432, allocator1968
(includes per-seat allocations, so conservative shared sum). Shared sum17510959 bytes
is16.70MiB>handoff16MiB. Colossal total262713692 bytes=250.5433MiB, below256MiB;
that broad global check does not enforce pool16MiB.

Candidate qualification fix, not start of broad optimization programme: reuse existing
newBodyRouteWorkspace(bucketCount) seam, reduce default Dial buckets262144 to131072,
retain supported maximum262144. Saves1572864 bytes of three arrays, sufficient to meet
shared16MiB. Absolute queuedF is stored; queuePop scans bucket chains for exact currentF,
so modulo collision does not approximate f or change FIFO order at equal f. Must verify
route hash, tie behavior, timing, full memory ledger and focused suites before adopting.

Please pause after your latency code unit and give a bounded source-backed review of this
proposal in MEMORY_REVIEW.md (you own it): verify what shared categories should count,
check queuePush/remove/pop invariants, existing small-bucket tests, and identify whether
reducing default can change any route ordering. No src edits by you. This is required to
close inherited Phase10 acceptance, not permission to start H11/H2. If definition excludes
index/safety justify from ratified contract; do not silently drop fields to claim pass.

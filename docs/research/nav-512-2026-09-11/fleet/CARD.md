# Common-family qualification card

Frozen before fleet timings. Run only after current-main m5a correctness,
training confirmation and every held-out performance cell pass. Preserve all
results if a later family fails; do not replace a slower repetition.

Use the same current-main original256 and candidate512 binary bytes, native
Docker image, guest WASM modules, flags and six-cell input manifest. Select
these two cells before inspecting any held-out candidate timing:

- map5001-s32-edge-r1050: ordinary edge play, normal health, long range.
- scale29-s32-moving-r1050: larger map, moving carrier/hunter goals, high health.

These cover the realistic and replan-stress workloads at32 seats; the m5a
matrix separately covers16 seats and shorter ranges. They do not represent
all maps, policies, hardware contention or deployments.

## Hardware and execution

Use the owned sandbox instance i-08b7fb62b50e0740a, stopping it only between
completed campaigns, changing its type, and preserving the EBS disk. Types:
AMD c6a.4xlarge, then Intel c8i-flex.4xlarge, both16vCPU/32GiB. Both are offered
in its existing us-east-1d zone. No production node or league is changed.
Record instance state/type, lscpu, kernel, image and binary hashes after each
restart. Reuse the existing binaries; baseline compiler flags target portable
x86-64, not an m5a-specific instruction set.

For each family, test both:
- pinned: all server threads on logical CPU5, presence clients on6/7;
- unpinned: server uses the instance's scheduler/available CPUs, clients on6/7.

Four cells per family, in order: edge-pinned, moving-pinned, edge-unpinned,
moving-unpinned. Three paired process repeats:24 games per family,48 total.
For repeat index0..2 and cell index0..3, even sum starts original256, odd sum
starts candidate512. Interleave all cells within each repeat. One game at a
time; no builds, profiles, compression, other games or instance operations
while timing. Every game uses1,200 frames and every frame is retained.

## Gates

For each family/cell independently: median paired total/p50/p95/maximum ratios
must all be <=1.00; candidate's worst deadline-miss count across three repeats
must be <=original's. Require fullframe/guest coverage and no play faults.
No averaging across cells/families, discarded warmups, trimmed tails or slow-run
replacement. Failed/early games make the campaign incomplete and are retained.

Each variant's semantic stream must repeat exactly and equal its same-case,
same-budget m5a reference from the completed current-main campaign. This checks
cross-family and affinity output determinism without requiring512 to have the
same trajectory as256. A mismatch stops acceptance and requires investigation;
the existing same-budget256 candidate/original comparison remains separate.

Report per-family results and limits. Passing this card supports representative
native deployment-family qualification; it is not a claim about every possible
workload or production contention. Publishing and a live budget change remain
outside this research campaign.

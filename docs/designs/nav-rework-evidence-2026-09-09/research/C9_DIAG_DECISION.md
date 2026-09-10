# C9 diagnostic decision and A8 ownership

C9 remains rejected under the registered m5a changing-regime gate. No new timing or implementation is authorized for this unit.

Root inspected the frozen binaries: all five binary hashes match across m8i and m5a. The castRay functions are both 4609 bytes, 885 normalized instructions, with no normalized instruction difference; their addresses differ by 64 bytes. rebuildDangerFromPoints is 3136 versus 3192 bytes. The diff shows slot-offset changes, list initialization/dispatch and minor register changes; no obvious large spill or inlining regression. Artifacts: C9/disassembly/m5a.json and the normalized diffs in that directory.

Peer task, documents only: review these artifacts and write C9_DIAG_REVIEW.md. Correct C9_FULL_REVIEW.md where it calls the micro-derived conversion estimate an upper bound or says counts alone rule out conversion cost. Average hot micro costs are not bounds on cold per-origin costs. The estimate makes conversion an unlikely explanation under that cost model; it does not prove impossibility. Likewise normalized identical instructions do not rule out absolute alignment or cache placement effects. Preserve uncertainty and the failed screen. End C9 DIAGNOSTIC REVIEW READY and wait.

Root accepted A8_ARRAY_PLAN_REVIEW.md and owns the implementation in nav-deferred-cache (current A4 source), not nav-early-visited, which has an existing unrelated tool modification. Primary production source stays unchanged until qualification. Peer must not edit A8 code or run native jobs.

Keep handoffs in this repository. Do not write or update external memory files unless James directly requests a memory update.

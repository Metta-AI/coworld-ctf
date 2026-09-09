P3 FIXUP required before Phase 4: body-slice regression at 32 seats.

Evidence (Claude, same Mac, runs sequential and isolated, `nim c -r -d:release -d:useMalloc -d:noSignalHandler --threads:on tests/test_shell_containment.nim`):
- origin/main f374a18b (detached baseline worktree): SHELL_CONTAINMENT_VERDICT max_body_us=5391, body_pass=false (this Mac already misses the 5000 us gate slightly; the gate is calibrated for the CI box). Worst waves: call_free_loop 5391, trap 4938, growth_loop 4813, retune_refusal 4671.
- HEAD 6b6e3b69: max_body_us=6492, body_pass=false. Worst waves: call_free_loop 6492, retune_import_phase_violation 6416, oob_emit 6260, growth_loop 6255.
So Phase 3 added roughly 0.9-1.3 ms to the worst body wave at 32 seats. Your report's tests/tests.nim run does not exercise this gate; shard_2 does (Claude ran it: 771 OK, 1 FAILED, this test).

Task:
1. Find where the per-tick delta comes from. Candidates: the new path doing per-tick work while the legacy planner still runs; a per-seat query or scratch touched every tick; activation-time index/scratch construction landing inside the test's timed window; larger per-seat objects hurting cache. Measure, do not guess: instrument or bisect between 71e2d2d1, fd224c2c and HEAD with the same command.
2. Fix it so HEAD's max_body_us is within noise of the origin/main baseline on the same machine (report both numbers from back-to-back isolated runs, plus per-wave figures). Legacy planner stays alive until Phase 10; the new query path must cost nothing on ticks that do not call it.
3. If the delta is activation time inside the timed window rather than tick work, say so with numbers and propose (do not apply) how Phase 9 should account for it; do not change the test's timing window.
4. Commit the fix as its own checkpoint, update PHASE_3_REPORT.md with a "Fixup" section, and end with the literal line P3 FIXUP DONE. Do not start Phase 4.

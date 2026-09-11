# P10: next exact mechanism, prepare only

Native H3 correctness is now complete: same full native digest as original,
all suites and diagnostics pass. Registered nine-game timing is running alone
on native host. No native access or code edits/commits for this phase.

Read CROSS_ARCH_REVIEW and the root qualification/PROTOCOL.md. Root will run
native split probe after timings. Do not weaken the original cross-platform
gate yet: sampled route floats plus aggregate counters cannot establish exact
pop ordering or every internal decision. Describe that limitation accurately.

Prepare NEXT_EXACT_PLAN.md comparing the H4_DRAFT minter payload reduction,
primary-lattice record lookup, and exact per-pop mint work hoisting. Read actual
loops. Pick one bounded next candidate only conditional on H3 missing target;
state precisely why, expected affected cost, memory/layout changes, proof and
oracle extensions needed. No implementation. Do not reduce/reprice work units
or cap field minting. Also flag any concrete problem with frozen six-cell
qualification protocol (it deliberately bounds the peer's ten-cell proposal).
End PHASE 10 READY and wait for PROCEED.

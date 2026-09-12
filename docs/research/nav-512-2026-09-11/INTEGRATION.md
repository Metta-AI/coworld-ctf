# Future integration of the qualified navigation candidate

Research source checkpoint c651dec9 keeps the production default at 256.
This document is a handoff, not a completed release or a new authorization to
publish. All registered qualification gates passed; retain their documented limits
when describing the target result.

The three optimizations preserve decisions at a fixed budget and can be
reviewed separately from a budget increase. Preserve the eleven-helper
stack-trace tradeoff and clearance-certificate dependency documented in
QUALIFICATION.md and source comments.

Changing ColdPlanBudgetPerTick from 256 to 512 changes when routes become
available and therefore replay behavior. For an eventual budget-change patch:

1. Fetch and sync current main in an isolated checkout. Compare runtime changes
   since the recorded qualification base; do not silently apply old evidence
   to changed planner behavior.
2. Scan open branch/PR GameVersion claims and take the next free version under
   AGENTS.md. Record the changed budget rule in the prepend-only changelog.
3. Re-derive the explicit budget tests in test_shell_body_nav.nim and
   test_shell_body_seat.nim, including the round-robin golden and work bounds.
   Do not merely replace expected numbers without checking their meaning.
4. Re-record all nine replay fixtures using the documented recipes, verify
   required events and current version, rebuild the committed viewer, and run
   relevant native and viewer checks.
5. Update the shell design, body_nav module documentation and any catalog row
   describing the budget. Audit docs before committing.
6. Review tools/bench_body_port.nim's full-budget assertions: they currently
   compare a pooled spend to the single-seat constant. Fix or retire those
   assertions before using that synthetic tool as evidence; it was not used
   for this campaign's acceptance.

Carry forward the qualification limits: 512 improves relative timing on the
recorded workloads; it does not guarantee every frame meets its deadline on
older m5a cores, arbitrary policies or contended production nodes. No league,
version lock or published Coworld was changed by this research.

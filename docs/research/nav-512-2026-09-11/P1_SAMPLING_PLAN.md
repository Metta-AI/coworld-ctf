# P1: sample remaining planner cost

Diagnostic only, after the unprofiled H1 runs finish. Use the existing native
host's perf CPU-clock sampler at 99 Hz on CPU 5, restricted to userspace,
with DWARF call stacks. Run one separate baseline-512 game through the same
finite real-game runner. Sampling results never enter an acceptance gate.

Purpose: distinguish heap comparisons/stores, legality checks, sparse-record
lookup, and call/stack-frame overhead before choosing the next mechanism.
Keep all production compiler flags. If PMU counters or stack unwinding are
unavailable, record that limitation instead of presenting inferred attribution
as measured. Compare navigation/movement/install counters with baseline 512.
The profile does not authorize disabling stack traces in production.

# W1: exact incremental integer ray sampling

Parent: M1 geometry sharing with otherwise unchanged body_map. Candidate changes only rayClear sampling to integer floor/remainder increments with full-coordinate ties-to-even. Retain wall predicate, out-of-bounds handling, target selection and distance tests. No cache, alternate visibility rule or new dependency. Research and equivalence argument: W1_RESEARCH.md and WEAPON_RANGE_REVIEW.md.

Before timing: compare actual rayClear with an independent copy of the old floating expression on all ordered endpoints in an8x8region, with each of64single-wall positions; test translated region (odd/even parity), degenerate rays and bounds. Add seeded long rays on sparse-wall terrain. Run existing body-map and seat tests as appropriate; compare per-tick output masks and pop arrays using a common instrumented harness built for both arms.

Timing: three interleaved fresh parent/candidate processes on m5a CPU5 at1300px and B1024, same Nim2.2.6/release flags, afterM1 completes. Report per-row weapon and whole-body p95/max with raw samples. Full frozen corpus remains a regression gate, not the proof of weapon pixel equivalence. No regenerated-fixture byte equality claim (external bots are nondeterministic). No gate relaxation or speedup assumption.

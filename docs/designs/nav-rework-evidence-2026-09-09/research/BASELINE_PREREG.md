# B0: inherited Phase 10 corrected baseline (registered before runs)

Source 20234cc7, existing unmodified tick harness; only budget constant changes between fresh builds. m6i.8xlarge Xeon 8375C, CPU5 pin. Budgets 1024, 2048, 3072, 4096 in that order. Three complete fresh-process repeats per build, retain all six 16/32-seat scenario rows, 120 samples each. One additional unpinned process per build is informational. No concurrent benchmarks. Existing live tournament remains running; save load/cpu snapshots and label shared-host limitation. No failure discarded or retried for green.

Choose largest B whose worst row across all pinned repeats p95 <=3.6ms and max <=4.5ms. This is Phase10 headroom selection, not the throughput doubling result. Record request p95 <=100us and actual ns/pop, active pop counts. A failure means rejected on this screen, not presumed code defect. Process currently emits six sequential scenarios, so this is not the older single-row/process protocol; report that limitation and do not relabel.

Important: first_goals resets every seat each tick. This stresses repeated cold admission; it does not measure first-goal completion latency. Obtain separate full-completion latency rows at selected B before qualification. Quality constants in current harness are stricter than handoff summary: preserve existing 0.5%/3% limits (verify full stratum checks) and original corpus.

Before main experiments: negotiate and implement research loop with peer. Capture Fluffy in a separate profiled run; never use profiled numbers as uninstrumented acceptance. B0 uses existing breakdown instrumentation for direct inherited comparison and must be paired with instrumentation-off validation later.

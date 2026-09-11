# Pre-run fleet recording notes

Record lscpu -e=CPU,CORE,SOCKET,NODE and each CPU's thread_siblings_list;
do not assume sibling numbering from the instance name. Record /proc/stat CPU
counters before and after each game, including steal deltas. These cover the
whole game process lifecycle, not just the playing interval. They provide
context, never permission to discard a slow run or change its gate verdict.

A cross-family stream mismatch is an acceptance stop under CARD.md. It is not
a candidate defect until investigated. At most one extra original256 versus
candidate256 pair per family, on the first mismatching case/affinity, may be
run as a separately labelled diagnostic. If that pair matches, report a
baseline/platform finding; it still does not turn the registered cross-family
parity miss into a pass. If it differs, preserve the discrepancy and investigate
the candidate. No timing repetitions are replaced by this diagnostic.

Peer review found no count, order or comparator error. The existing source and
binary pins close the earlier old-base-asset concern; ASSET_PROVENANCE.md gives
the readback. The six-cell m5a protocol and fleet timing thresholds are unchanged.


Before each family, record the actual Docker image ID in the instance record;
run_native.sh uses the frozen m5a image ID directly, and run.py checks the
recorded ID and records getconf GNU_LIBC_VERSION. A cross-family mismatch gets
mismatch.json alongside valid metrics/exit files, not failure.json.

If the permitted diagnostic is needed, use the same run_case.py in the same
container mounts, the mismatching frozen config and affinity mode, with outputs
under `/fleet-results/<family>/diagnostic/parent-256` and `candidate-256`:
`run_case.py <config> /original/server-256 /original/presence <parent-output> --server-cpus <5|all>`
and the same command with `/candidate/server-256` and `<candidate-output>`.
Record the two commands and compare through metrics.inspect. Do not rerun the
failed cross-family performance cell or change its classification.

In unpinned mode the server may share CPUs6/7 with presence clients. That is an
explicit synthetic client placement; production players are separate processes
outside this benchmark host. Report this limit with the family result.

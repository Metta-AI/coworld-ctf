# B0-m5a preregistration

Repeat the unchanged B0 matrix on owned m5a.4xlarge i-08b7fb62b50e0740a.
Source 20234cc7, Nim 2.2.6, original breakdown-on harness, CPU 5 pinned.
Budgets 1024, 2048, 3072, 4096; three fresh processes each, six original
scenarios with 120 measured ticks. One additional unpinned process per budget
is informational. Use the same run_baseline_c6a.sh script and retain all exits
and failed rows. No concurrent benchmark processes on this host.
Selection remains p95 <= 3.6 ms and max <= 4.5 ms for every registered row;
the ordinary 4/5 ms gate is reported separately. This measures an observed
production family, not proof of a fleet-wide worst case.

# I0: instrumentation overhead and A/A

Before optimization, B1024 source 20234cc7 plus harness-only profile toggles.
Compile two independent breakdown-on binaries (separate nimcache paths), one breakdown-off
binary with navGateNoBreakdown, Fluffy disabled for all. Three fresh processes per binary,
interleaved A1,B,A2 each repeat, same CPU5. Record every six-row result, 120 samples per row.
Compare actual pops_per_tick arrays for exact equality across versions and repeats; mismatch
invalidates claimed equivalent work. Report p95 spread and max for each, no selected retry.
Three independent processes are descriptive, not enough to claim tight statistical intervals.
This pair only removes extra navigation-breakdown clocks; normal production body timing stays.
Do not interpret zero-valued breakdown fields in off binaries as zero actual work; metadata
body_nav_breakdown identifies whether fields are measured. No budget changes in this unit.

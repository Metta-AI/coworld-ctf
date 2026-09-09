# Actual shell-demo Fluffy capture

Source: L1 working tree after1aeffbd2; Mac timings are informational only.
Unmodified tools/run_shell_demo.sh, SHELL_DEMO_PORT21894, ProfileTicks240.
Trace records246danger and planning stage events; the configured post-lobby limit is240ticks.
No hosted request or upload. Demo stopped with SIGINT after trace capture;
the script trap cleaned its children and port21894 has no listener.

| Stage | Count | p50 us | p95 us | Total us |
|---|---:|---:|---:|---:|
| invokeInit | 8 | 2.667 | 16.667 | 36.501 |
| invokeStep | 1728 | 6.125 | 18.291 | 17626.905 |
| shell.danger | 246 | 331.666 | 1353.458 | 125669.752 |
| shell.planning | 246 | 292.958 | 532.500 | 66845.002 |
| body.follower | 7040 | 0.084 | 6.792 | 10920.944 |
| body.weapon | 7040 | 0.500 | 9.750 | 15044.740 |

Durations include nested work and must not be added across stages.
Raw Chrome trace: server-trace.json; all25stage summaries: summary.json.
The initial nohup launcher left no live process or run directory; after verifying
its PID was absent, the foreground PTY launch succeeded (launcher2.log).
Compilation/probe and server/presence logs are retained under the run directory.

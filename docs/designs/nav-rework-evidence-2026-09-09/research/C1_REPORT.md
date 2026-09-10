# C1: current production build remains above the configured timing gate

Three interleaved native/Docker pairs at both 331 and 1300 px on m5a CPU 5, B1024, source872e5499 (A0/P1). Docker uses the repository build target, Nim2.2.4/GCC12.2, static Wasmtime, CPU set5 and oneCPU quota. Native uses Nim2.2.6/GCC11.4 and the recorded standard flags. This compares complete build environments, not compiler versions in isolation.

| Range px | Build | Worst p95 ms | Worst maximum ms |
| --- | --- | ---: | ---: |
| 331 | native | 3.890933 | 3.946085 |
| 331 | docker | 3.829202 | 3.866962 |
| 1300 | native | 5.186019 | 5.246860 |
| 1300 | docker | 5.140920 | 5.177941 |

All per-tick mask and pop arrays match between builds in every paired row at both ranges. At331px both pass the ordinary4/5ms criterion, but miss3.6ms selection headroom. At1300px both fail the ordinary gate. Production compilation alone does not solve the current whole-body floor.

Docker full quality passes all3072 cases, zero missing/illegal; route hash `5a1340213fe3046dc119d6f8d5d59d59cbfd379f885b95968f105d3edcbca500` is unchanged. The frozen65-map memory gate passes. Its older activation verdict checks memory only; manually evaluated activation time fails all64 non-colossal maps while colossal passes. A1's later activation improvement is absent from both C1 arms. Configured11-map memory was not rerun in this Docker process, so this is not final canonical all-map qualification.

## Artifacts and setup

`C1-repaired-m5a/` retains all paired rows, raw Docker quality/activation, exit codes, compiler details, image ID, executable hashes and build logs. `run_c1_repaired.sh` reproduces it. C1_SETUP.md and C1-initial-m5a retain the initial pre-timing failure and Buildx installation, without overwriting it. Repaired runner is DONE and m5a is now free for the next owned experiment.

Documentation audit: no production source, flags or dependencies changed in this experiment. The repository's real Docker build was used after installing its missing host plugin. This report and scoreboard distinguish native qualification, production build comparison, memory-only historical verdict and outstanding selection/final gates. No image was published.

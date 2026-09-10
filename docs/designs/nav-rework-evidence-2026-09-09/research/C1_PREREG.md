# C1: current production build environment comparison

Repeat C0 on current retained A0/P1 source, commit 872e5499, B=1024. Native m5a CPU 5, three interleaved fresh-process pairs at 331 and 1300 px. Compare native Nim 2.2.6/GCC 11.4 against the repository Dockerfile build target (Nim 2.2.4/GCC 12), exact repository flags and static Wasmtime. Docker uses CPU set 5 and one CPU quota. Record actual compiler/image/source identities. This changes the full build environment, not only compiler version.

Require all per-tick masks and pop arrays equal; report whole-body p95/max by every row and repeat, with ordinary 4/5 ms and selection 3.6/4.5 ms limits unchanged. Run Docker quality and activation after timing, retaining failures separately. No simultaneous m5a benchmark. No new production source, budget, cap, image publication or runtime configuration change. A1 is activation-only work running on the separate m8i host and is excluded from both C1 arms.

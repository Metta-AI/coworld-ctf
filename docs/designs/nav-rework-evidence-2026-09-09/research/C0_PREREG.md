# C0: exact production-toolchain comparison on m5a

Current L1 source, B1024, same harness and corpus in both arms.
A: native Nim2.2.6/GCC11.4, release/useMalloc/noSignalHandler/threads/opt:speed/stackTrace.
B: repository Docker build stage, Nim2.2.4, DebianBookworm compiler, original
NimFlags and CtfRuntimeFlags (including static Wasmtime), no CPU-target changes.
Record exact compiler versions and image digest. This compares complete build
shapes; do not attribute any difference solely to Nim or GCC.

Build both before measurement. Three interleaved fresh processes per arm,
CPU5 pinned; Docker --cpuset-cpus5 --cpus1. Six original scenarios,120samples.
No other benchmarks on the owned m5a. Same3.6/4.5 headroom and4/5 ordinary gate;
all failures retained. Compare all pop arrays and request/refresh counts; any
work difference must be explained before a speed comparison. No throughput
success claim from a noisy or unmatched result. Follow with production-built
quality/activation if the build works; canonical metadata remains separate.

No extra host is provisioned, no GitHub credential is loaded, and no production
flags or instances are changed. Install Docker only on the owned benchmark host.

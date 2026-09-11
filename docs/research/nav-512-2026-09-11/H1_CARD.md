# H1 experiment card

Registered before candidate timings. Parent6b6b3408, runtime same as83e60c24.
Mechanism and original-library source in H1_PROPOSAL.md. Peer implements only
held-node binary-heap sifts. No changed fields, allocation sizes, comparator,
units, budget, search graph, generation behavior or stacktrace flags.

Correctness before timing: original-heap differential after operations,
existing navigation/minter goldens and suspension laws, then native rerun.
At equal budget the real-game navigation/movement/install log stream must be
identical; any difference is a rejection until understood, not timing success.

Native screen: owned m5a.4xlarge, server all threads on logicalCPU5, clients6–7,
production Nim2.2.4 and release/useMalloc/threads/speed/stackTrace flags,
static Wasmtime, unprofiled. Reuse EXACT saved screen input/runner,32 seats,
1200 ticks, one process at a time. Variants P256 (parent256), P512(parent512),
H512(candidate512). Orders, three full-process repetitions:
P256,H512,P512; P512,H512,P256; H512,P256,P512.
No discarded warmups or replaced slow runs. Record every failure and exit.
Retain raw frame/shell timing lines, semantic logs, build/source/binary hashes.

H1 is eligible as an intermediate optimization only if H512 improves whole
frame total time versus P512 across paired runs (median ratio <=0.98), with
median paired p50/p95 and maximum ratios <=1.00 and no increase in maximum
observed deadline misses, while exactness/memory checks pass. Smaller/noisy
wins are recorded as inconclusive, not automatically retained. This is a
stage screen, not proof of the final512 objective. No resampling to erase miss.

Target512 is reached on this training scenario only if H512 vs P256 has
median paired ratios <=1.00 for total, p50,p95 and maximum, plus no increase
in worst observed deadline misses. All ticks, including ladder bursts, stay.
If missed, retain evidence and pursue another mechanism. Full success still
requires held-out maps/ranges/plays,16/32 seats, current fleet-family checks,
route latency/legality, cross-architecture determinism, retained memory, full
suite/containment/build shapes, then final version/fixtures/viewer/docs as
appropriate. A single scenario cannot qualify the game.

P0 Fluffy artifacts are diagnostic and excluded from all timing gates.

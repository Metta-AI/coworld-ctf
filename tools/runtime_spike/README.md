# Wasmtime runtime spike

This directory is the standalone measurement rig for the Season 2 shell's P0
runtime half. It links Wasmtime's C API without importing or changing gameplay
code. Phase 2 adds the no-WASI hello play, the minimal v48 binding, and the
containment smoke; phases 3 and 4 add memory and compile measurements.

The source of truth for the experiment is
`docs/designs/strategy-play-calling-shell-2026-08-29.md` sections 6.1, 6.2,
7.0, and 10. Contract values come directly from `src/shell/types.nim`; this
tool must not change them.

## Pinned toolchains

- Wasmtime C API v48.0.1, the current 48.x LTS patch.
- wasi-sdk 33.0 / clang 22.1.0 for the Nim hello play.
- Nim 2.2.6 for the hello play.
- Nim 2.2.4 in the Debian host-toolchain stage, matching the production
  Dockerfile.
- Nim 2.2.4 from the currently locked nixpkgs revision. The nearby flake
  comment still says 2.2.10, but commands and reports record the compiler that
  actually runs rather than trusting that stale comment.

`checksums.txt` contains the official release-asset SHA-256 digests for Linux
amd64/arm64 and macOS Intel/Apple Silicon. `fetch_deps.sh` downloads to the
ignored `tools/runtime_spike/.deps/` directory by default, verifies before
extracting, and never installs globally. Override the cache with
`RUNTIME_SPIKE_DEPS_DIR=/absolute/path` when needed.

```sh
tools/runtime_spike/fetch_deps.sh --verify-only
tools/runtime_spike/fetch_deps.sh
tools/runtime_spike/run.sh toolchains
```

The project dependency setup remains mandatory before native compilation:

```sh
nimby --global sync nimby.lock
```

## Nix

The flake fetches the same Wasmtime v48.0.1 C-API archive as the other
environments and exports `WASMTIME_C_API`, the header path, and the library
path. It deliberately does not use `nixpkgs.wasmtime`, whose version can move
when the flake input is updated.

```sh
nix develop --command sh -c \
  'nim --version; test -f "$WASMTIME_C_API/lib/libwasmtime.dylib"'
```

Use `libwasmtime.so` instead of `.dylib` when checking a Linux Nix host.

## Debian image

The spike Dockerfile is separate from the production Dockerfile. It provisions
the Nim 2.2.4 host toolchain, a separate Nim 2.2.6/wasi-sdk 33 hello toolchain,
and the platform-matched Wasmtime archive. The run stage carries the exact
dynamic `libwasmtime.so`; the eventual production static-versus-dynamic choice
is deferred to P3.

```sh
docker build --platform linux/arm64 \
  -f tools/runtime_spike/runtime-spike.Dockerfile \
  -t ctf-runtime-spike:arm64 .
docker run --rm ctf-runtime-spike:arm64

docker build --platform linux/amd64 \
  -f tools/runtime_spike/runtime-spike.Dockerfile \
  -t ctf-runtime-spike:amd64 .
docker run --rm --platform linux/amd64 ctf-runtime-spike:amd64
```

The amd64 image on an Apple Silicon Docker host is emulated and is not a
production performance result.

## Commands and output

`run.sh` owns the stable command names. `smoke` now builds both the Nim
2.2.6 core-Wasm hello play and a native host compiled with
`-d:noSignalHandler --threads:on`, checks dynamic-library resolution, and runs
the containment suite:

```sh
tools/runtime_spike/run.sh smoke
```

The smoke proves that the hello module imports only `play.emit` and exports
`memory`, `play_alloc`, `play_init`, and `play_step`. It exercises five
separate containment rows: fuel exhaustion, epoch interruption from a native
5 ms ticker, store-limiter refusal of `memory.grow`, a real out-of-bounds
linear-memory access under the 64 KiB guard, and stack overflow under the
256 KiB guest-stack cap. `memory.grow` refusal is correctly reported as an
i32 `-1`, not mislabeled as an instruction trap. A fresh hello instance emits
successfully after every row.

The memory mode is implemented in phase 3:

```sh
tools/runtime_spike/run.sh memory --instances 1,32,512 --soak 500
```

It runs in a fresh host process, records cold plus 200-sample steady
instantiation latency, proves that all 514 configured slots can be allocated,
that slot 515 is refused, and that all 514 slots can be reused. Separate RSS
and VSZ series cover initial 128 KiB hello memories and memories grown and
touched to the full 1 MiB cap. The 500-cycle soak drops and recreates all 512
gameplay Stores each cycle while reusing one harness vector. After each drop,
RSS is sampled every 5 ms until four samples fit within a 64 KiB band (up to
100 samples), without allocator or GC forcing. The fixed return tolerance is
`max(8 MiB, 5% of the stable zero-live-instance baseline)`; a miss remains a
reported failure even when all pool slots were reclaimed exactly.

The compile mode is implemented in phase 4:

```sh
tools/runtime_spike/run.sh compile
```

It emits four distinct valid core-Wasm modules of exactly 262,144 bytes in
memory: one enormous function, the wasmparser 0.244.0 maximum of 50,000 locals
in one function, the deepest structured nesting that fits the byte cap, and
the maximum number of empty functions that fits the byte cap. Custom sections
pad shapes whose objective reaches a validator limit before the byte limit;
no generated module is written into Git.

Every measured row runs in a fresh child process with Wasmtime parallel
compilation disabled. A cold child measures immediately; a warm child performs
one unmeasured validation and compile of the same bytes before measuring.
Validation always precedes `wasmtime_module_new`. Each row reports validation
and compilation wall time, serialized bytes and raw-byte ratio, plus stable
baseline RSS, sampled peak RSS, and the delta. The 1 ms RSS observer is a
second thread, but the compiler itself has one worker. RSS remains a
process-scoped approximation of one compiler worker's incremental working set,
not per-thread accounting.

The command defaults to three cold and three warm repeats per shape and fails
if any module is invalid or not exactly sized, any `module_new` exceeds
2,000 ms, or any serialized artifact exceeds 8× its raw bytes. Use
`--repeats N` for a shorter diagnostic probe; it does not change the gates.

The runtime-half worst-tick mode is implemented in phases 5 and 6:

```sh
tools/runtime_spike/run.sh tick --compile-workers 0
```

It requires at least 30 warm samples and keeps all 512 gameplay instances
resident while timing the fixed contract maximum: 160 distinct full-fuel step
faults, four full-fuel init faults, the exact allocation/callback byte caps,
32 defaults, 32 complete 1089-by-8 fallback reflex plans, 64 exact-cap ladder
walks, 32 upload admissions, eight compile-result commits, 104 maximum-size
status entries, and 32 high-water acknowledgments. Reset and the one complete
warm-up tick are outside the samples. Count or fuel drift is fatal. The final
line prints median, p95, p99, unrounded maximum, and the fixed
`max <= 10.400 ms` verdict.

The hostile module and fuel traps, exported allocations, callback crossings,
range checks, and byte copies are real Wasmtime work. Atlas scoring,
goal-table/tie scanning, intent and ladder schema walks, default/reflex work,
and control-plane bookkeeping are conservative deterministic cost models for
host code that does not exist yet. Output labels these boundaries; the result
is not a body/view/world-map measurement and is not a whole-server verdict.
The 64-entry `nearest_reachable` tie scan remains an explicitly unverified
assumption.

Before the aggregate, the mode prints per-component micro rows, compares the
all-cover spatial maximum with a half-cover/half-reachable mix, measures one
identical compute module under fuel/epoch off, fuel only, epoch only, and both,
and compares one identical memory scan with a 64 KiB guard versus an exact
4,294,967,296-byte guard. Both guard cases retain the 1 MiB reservation; the
large guard makes reservation plus guard exceed the 32-bit address space and
therefore permits Cranelift's guard-based bounds-check elision. Absolute VSZ
and execution ratio are reported rather than assuming the large guard wins.

`--compile-workers 0` is mandatory for the isolated phase-5 command. Phase 6
adds `all`, which runs the overhead experiment and then launches fresh child
processes for both the isolated and two-worker compile-saturated tick:

```sh
tools/runtime_spike/run.sh all
```

The overhead experiment launches at least five fresh processes for each of
fuel/epoch off, epoch only, fuel only, and both. It reports total time and the
paired ratio as min/median/max ranges; a single-process ratio is deliberately
not treated as a stable result.

The saturated row creates exactly 32 distinct, validated 262,144-byte modules
(8 MiB total) before timing, then drains them through two real host compiler
threads. It proves both workers overlap, all 32 compiles enter and complete,
and no compile fails. Tick samples are retained only while the queue still has
work; the sample that crosses the drain boundary is discarded.

Run the quota matrix sequentially so concurrent containers do not contaminate
one another. On an Apple Silicon host, the arm64 rows are native Linux and the
amd64 rows are emulated compatibility measurements:

```sh
container_platform=$(docker info --format '{{.OperatingSystem}}')
for platform in arm64 amd64; do
  if [ "$platform" = arm64 ]; then
    emulated=false
    platform_note=native-linux-arm64
  else
    emulated=true
    platform_note=linux-amd64-emulated-on-apple-silicon
  fi
  for cpus in 1 2 4 6; do
    docker run --rm --platform "linux/$platform" --cpus "$cpus" \
      -e "RUNTIME_SPIKE_CONTAINER_PLATFORM=$container_platform" \
      -e "RUNTIME_SPIKE_ENV_LABEL=linux-$platform-cpu$cpus" \
      -e "RUNTIME_SPIKE_EMULATED=$emulated" \
      -e "RUNTIME_SPIKE_PLATFORM_NOTE=$platform_note" \
      "ctf-runtime-spike:$platform" all
  done
done
```

Each environment row prints the observed cgroup `cpu.max`, toolchain and
platform identity, both fixed `max <= 10.400 ms` verdicts, and the queue proof.
Every row continues to identify real Wasmtime work versus a synthetic host
model; no synthetic number is evidence that the future host implementation has
that cost.

# Embedding a WebAssembly runtime in the CTF game server: runtime comparison

> **Historical research report (2026-08-30).** Preserved unchanged as the
> comparison that selected Wasmtime. Package status and “current” claims below
> are point-in-time evidence, not present-day dependency guidance.

Research spike for `docs/designs/strategy-play-calling-shell-2026-08-29.md` (section 7.0, Appendix W). Produced 2026-08-30 by a research subagent with live web verification; James's coding agent edited nothing below the header.

---


Research spike, 2026-08-30. All version numbers, dates, and claims below were
checked against live sources on this date (GitHub API, release pages, official
docs). Where a claim could not be verified it is flagged inline and listed at
the end.

## The use case, restated

- Host: Nim game server (compiles through C), Linux x86_64 in Kubernetes for
  prod, macOS arm64 for dev.
- Workload: up to 32 player-uploaded wasm32 "play" modules, each stepped once
  per tick at 24 Hz. Each step gets a small serialized view buffer and returns
  a small Intent. Modules are tens to a few hundred KB. No WASI; tiny custom
  import surface.
- Hard requirements: per-instance memory cap; per-step execution budget so a
  runaway play cannot stall the tick; traps contained; validation on upload;
  fast instantiation; low per-instance memory; C API callable from Nim;
  permissive license; healthy maintenance; untrusted code so sandbox quality
  matters. Determinism is not required. Bounded worst-case step latency is.

## Comparison table

| | wasmtime | WAMR | wasm3 | wasmer | wasmi (extra candidate) |
|---|---|---|---|---|---|
| Current stable | v48.0.1, 2026-08-24 | WAMR-2.4.5, 2026-06-29 | v0.9.0, 2026-08-24 | v7.3.0, 2026-08-21 | 1.1.0 stable; 2.0.0-beta.10 2026-08-10 |
| License | Apache-2.0 WITH LLVM-exception | Apache-2.0 WITH LLVM-exception | MIT | MIT core; Singlepass backend is BUSL-1.1 | MIT OR Apache-2.0 |
| Maintainer | Bytecode Alliance; monthly majors, LTS patch lines | Bytecode Alliance (Intel-led) | One person (vshymanskyy); burst of activity Aug 2026 after a 2024–2026 near-hiatus | Wasmer Inc. | Wasmi Labs (one core dev, funded by Stellar since 2024) |
| Execution | Cranelift JIT (default), Winch baseline JIT, Pulley interpreter | Classic interp, fast interp, Fast-JIT (x86_64 only), LLVM JIT, AOT via `wamrc` | Interpreter only | Cranelift / Singlepass / LLVM JIT; V8 | Interpreter (register machine) |
| Step budget mechanism | Fuel (deterministic, per-instruction) and epochs (cheap, timer-driven); both in C API | Instruction count limit, interpreters only (not AOT/JIT); `wasm_runtime_terminate` from another thread | None built in; "gas" = pre-instrument the module with `wasm-metering`; `m3_Yield` hook only fires on calls | Metering middleware (unstable C API, works with all three compilers); experimental signal-based interrupt, Rust-only | Fuel metering, resumable calls |
| Infinite loop with no calls | Trapped by fuel or epoch check at loop back-edges | Interp: instruction limit stops it. AOT/JIT: no per-instruction hook; `terminate` relies on suspend-flag checks at branches (thread-mgr build) | Not interruptible unless module was pre-instrumented | Metering traps it | Fuel traps it |
| Memory cap | `wasmtime_store_limiter(memory_size, ...)` plus module max pages; pooling allocator caps | `max_memory_pages` in `InstantiationArgs`; heap pool | `d_m3MaxLinearMemoryPages` compile-time; module max pages | Module max pages; Tunables (Rust) | `StoreLimits` / `ResourceLimiter` |
| Stack overflow | `max_wasm_stack` (default 512 KiB) traps; guard pages + signal handler | Operand-stack overflow exception; native stack via HW guard on Linux/macOS 64-bit | `m3Err_trapStackOverflow`; `d_m3MaxNativeStack` budget added in 0.9.0 | Traps via signal handler | Traps |
| Instantiation | ~5 µs with pooling + CoW (Wasmtime 1.0 article) | Small; not benchmarked here | Very fast (lazy compile) | Cranelift: moderate | Very fast (lazy) |
| C API | Yes: `libwasmtime.{a,so,dylib}`, prebuilt per release, CMake build | Yes: `wasm_export.h` (native API) plus wasm-c-api; build `vmlib` via CMake | Yes: `wasm3.h`, ~10 C files, compile in-tree | Yes: `wasm.h` + `wasmer.h`; `make build-capi` | Yes: `wasmi_c_api_impl`, CMake build |
| Runtime library size | 19 MB release `.so` default; ~2 MB no-compiler; 698 KB minimal | ~60 KB interp core on Cortex-M; a few hundred KB on desktop | ~64 KB code | Full distribution tarball 288 MB (includes LLVM); lib size unverified | Unverified |
| Sandbox track record | Best-documented: fuzzed continuously, 12 advisories Apr 2026 (LLM-assisted audit), core Cranelift x86_64 unaffected; aarch64 Cranelift had one Critical (CVE-2026-34971) | 8 advisories 2025–2026 incl. Critical heap overflow in WASI `poll_oneoff` and High fast-interp overflow (CVE-2026-54912) | No advisory process at all; bugs land in issues; OSS-Fuzz run 2021; "LOTS of security fixes" in 0.9.0 | 2 advisories (2023, 2024), both WASI filesystem | 2 external audits (2023, 2024); Wasmtime's fuzzing oracle |
| Nim bindings | `Nimaoth/nimwasmtime` (Futhark-generated, MIT, active to Mar 2026, pinned v29) | None | `beef331/wasm3` (MIT, vendors wasm3 via `{.compile.}`, last push Dec 2024) | `yglukhov/wasmer` (MIT, 9 commits, dead since Jul 2023) | None |
| macOS arm64 dev | Tier 2 target; Cranelift full; Winch complete for core wasm | Interp works; Fast-JIT is x86_64 only; `wamrc` aarch64 needs `--size-level=3` workaround | Works | Apple Silicon only as of 7.2 | Works |

## Per-runtime notes

### wasmtime

**Version and cadence.** v48.0.1 released 2026-08-24; v48.0.0 on 2026-08-20.
Wasmtime cuts a major every month and back-ports security fixes to LTS lines
(47.0.4, 46.0.3 and 36.0.14 all shipped 2026-08-20 with the same fixes).
https://github.com/bytecodealliance/wasmtime/releases

**License.** Apache-2.0 WITH LLVM-exception (repo LICENSE).

**C API and linking.** `crates/c-api` builds with CMake
(`cmake -S crates/c-api -B target/c-api && cmake --build ... && cmake --install ...`)
producing `libwasmtime.a`, `libwasmtime.{so,dylib}` and headers. Every release
also publishes prebuilt C API tarballs; for v48.0.1:
`wasmtime-v48.0.1-aarch64-macos-c-api.tar.xz` (12.9 MB) and
`wasmtime-v48.0.1-x86_64-linux-c-api.tar.xz` (16.0 MB). From Nim you link
against `libwasmtime` with `{.passL.}` and `{.header.}`/`importc`, or use the
Futhark-generated bindings below.
https://github.com/bytecodealliance/wasmtime/blob/main/crates/c-api/README.md
https://api.github.com/repos/bytecodealliance/wasmtime/releases/tags/v48.0.1

**Step budget: fuel and epochs, both in the C API.**
- Fuel: `wasmtime_config_consume_fuel_set`, `wasmtime_context_set_fuel`,
  `wasmtime_context_get_fuel`. Deterministic; the compiled code keeps a
  precise instruction count and checks it frequently; exhaustion traps. The
  docs say plainly it is "somewhat expensive". v48.0.0 added configurable fuel
  costs for variable-length opcodes.
- Epochs: `wasmtime_config_epoch_interruption_set`,
  `wasmtime_context_set_epoch_deadline`,
  `wasmtime_store_epoch_deadline_callback`, `wasmtime_engine_increment_epoch`.
  Compiled code checks a global atomic counter at function entry and loop
  back-edges. `increment_epoch` is signal-safe (one atomic increment, no
  syscalls). Overhead is a "checking an infrequently-changing counter" cost;
  one third-party measurement puts it around 10 percent, and a 10 ms ticker
  thread costs roughly 100 µs CPU per tick. Epochs are not deterministic and,
  per the Config docs, are **not compatible with Winch**, so epochs mean
  Cranelift (or Pulley).
https://docs.wasmtime.dev/examples-interrupting-wasm.html
https://docs.wasmtime.dev/c-api/config_8h.html
https://docs.wasmtime.dev/c-api/store_8h.html
https://docs.rs/wasmtime/latest/wasmtime/struct.Config.html
https://www.systemshardening.com/articles/wasm/wasmtime-epoch-interruption-security/

For a 24 Hz tick the natural design is: give each step a fuel budget (a hard
per-step CPU bound, independent of wall clock and scheduler noise), and run a
single epoch ticker as a wall-clock backstop. Fuel alone bounds worst-case
latency per step tightly; epochs alone bound it to within one tick of the
ticker.

**Memory limits.** `wasmtime_store_limiter(store, memory_size,
table_elements, instances, tables, memories)` caps growth per store; negative
keeps defaults. Combined with the module's declared max pages and the pooling
allocator's per-slot cap, this gives a hard per-instance ceiling. The pooling
allocator (`wasmtime_pooling_allocation_strategy_set` and
`wasmtime_pooling_allocation_config_*`) pre-reserves slots for N concurrent
instances, so instantiation never mmaps on the hot path. Note the virtual
address cost: by default each linear memory slot reserves ~4 GiB (plus guard)
of virtual, not physical, memory; with 32 instances that is fine on 64-bit
Linux and macOS but worth knowing when reading RSS/VSZ in k8s.
https://docs.wasmtime.dev/api/wasmtime/struct.PoolingAllocationConfig.html
https://docs.wasmtime.dev/examples-fast-instantiation.html

**Traps and stack overflow.** All wasm traps come back as `wasmtime_trap_t`
from the call; the host keeps running. `max_wasm_stack` (default 512 KiB,
`wasmtime_config_max_wasm_stack_set`) limits guest stack; exceeding it raises a
stack-overflow trap. Detection uses guard pages and Wasmtime's signal handler,
which it installs itself; the Nim host must not install competing SIGSEGV
handlers on the wasm threads. Setting `max_wasm_stack` larger than the actual
host thread stack turns overflows into a real segfault, so keep it well under
the thread stack size.
https://docs.wasmtime.dev/api/wasmtime/struct.Config.html#method.max_wasm_stack

**Instantiation and per-instance memory.** With the pooling allocator, CoW
heap images and lazy table init, Wasmtime 1.0 reported ~5 µs to instantiate
SpiderMonkey.wasm and "a few kilobytes" written per instantiation. Compile
once per upload (`wasmtime_module_new` or `wasmtime_module_validate` first);
`wasmtime_module_serialize` lets you cache the compiled artifact, but
`deserialize` is explicitly not safe on untrusted input, so only deserialize
your own cache.
https://bytecodealliance.org/articles/wasmtime-10-performance
https://docs.wasmtime.dev/c-api/module_8h.html

**Compilers per platform.** x86_64 Linux is Tier 1 (continuously fuzzed);
aarch64 macOS is Tier 2 (everything but continuous fuzzing). Cranelift is the
default and is Tier 1 on both. Winch (baseline, faster compile) is complete
for core wasm on aarch64 since Wasmtime 35 and got SIMD on aarch64 in 48, but
it does not support epochs and had four advisories in April 2026 including a
Critical sandbox escape (GHSA-xx5w-cvp6-jv83, fixed 43.0.1). Pulley is a
Tier 2 interpreter, ~10x slower than Cranelift, useful only where JIT is
forbidden. Recommendation: Cranelift everywhere; modules are small so compile
time is a non-issue.
https://docs.wasmtime.dev/stability-tiers.html
https://docs.wasmtime.dev/stability-platform-support.html
https://bytecodealliance.org/articles/winch-aarch64-support
https://github.com/bytecodealliance/wasmtime/security/advisories/GHSA-xx5w-cvp6-jv83
https://docs.wasmtime.dev/examples-pulley.html

**Binary size.** Default release `libwasmtime.so` is 19 MB; disabling default
features (no compiler, precompiled modules only) gives 2.1 MB; with LTO,
panic=abort and strip 1.2 MB; nightly tricks down to 698 KB. For this server
the full 19 MB (or the ~13–16 MB prebuilt tarball) is the realistic number
because you need Cranelift at upload time.
https://docs.wasmtime.dev/examples-minimal.html

**Security track record.** The most transparent of the group. April 9, 2026:
12 advisories at once from a three-week LLM-assisted audit (Mozilla, UCSD,
Akamai, F5): 2 Critical (one Winch, one aarch64 Cranelift lowering bug
CVE-2026-34971 introduced in 32.0, later confirmed by formal verification), 6
Moderate, 2 Low. x86_64 Cranelift was unaffected by both Criticals. Since
then: pooling-allocator data leak between instances (Low, CVE-2026-34988),
table-allocation panic (CVE-2026-44216), two Low core-VM issues in July, and
WASI-only issues in Aug 2026 (irrelevant here: no WASI). 2025 had
CVE-2025-64345 (Rust-API unsoundness), CVE-2025-62711 (component model), and
CVE-2025-61670 (C API leak with externref/anyref, 37.0.x). Takeaway: bugs
exist, they are found by a real process, and they are fixed with back-ports.
https://bytecodealliance.org/articles/wasmtime-security-advisories
https://api.github.com/repos/bytecodealliance/wasmtime/security-advisories

**Nim bindings.** `Nimaoth/nimwasmtime`: "Nim wrapper for wasmtime", MIT,
bindings generated by Futhark from the C headers plus hand-written nicer
wrappers, wasmtime as a git submodule, 104 commits, last push 2026-03-18.
History shows an upgrade to wasmtime 34 (Jul 2025) then a downgrade to
v29.0.0 (Jul 2025) for a build problem, and component-model/WIT work in
Dec 2025. It is one person's project with 4 stars: usable as a starting
point, not as a dependency to rely on. Given the C API is stable and flat,
generating our own bindings for the dozen functions we need (Futhark, or
`c2nim`, or hand-written `importc`) is a small job.
https://github.com/Nimaoth/nimwasmtime
https://api.github.com/search/repositories?q=wasmtime+language:nim

**Infinite loop.** Trapped by fuel exhaustion (deterministic point) or by the
epoch check at the next loop back-edge/function entry after the deadline. Host
function calls are not covered by fuel, but our import surface is tiny and
host-controlled.

### WAMR (wasm-micro-runtime)

**Version.** WAMR-2.4.5, 2026-06-29; 2.4.4 on 2025-11-24. Release binaries
are published for x86_64 macOS/Ubuntu/Windows only; you build the library
from source anyway.
https://api.github.com/repos/bytecodealliance/wasm-micro-runtime/releases

**License.** Apache-2.0 WITH LLVM-exception.
https://github.com/bytecodealliance/wasm-micro-runtime/blob/main/LICENSE

**C API and linking.** Native API in `core/iwasm/include/wasm_export.h`
(`wasm_runtime_full_init`, `wasm_runtime_load`, `wasm_runtime_instantiate`,
`wasm_runtime_call_wasm`, `wasm_runtime_get_exception`, ...), plus a wasm-c-api
implementation. Build via CMake: `include(runtime_lib.cmake)` then
`add_library(vmlib ${WAMR_RUNTIME_LIB_SOURCE})`; everything is compile-time
`WAMR_BUILD_*` switches. Straightforward to link from Nim.
https://github.com/bytecodealliance/wasm-micro-runtime/blob/main/doc/build_wamr.md
https://github.com/bytecodealliance/wasm-micro-runtime/blob/main/doc/embed_wamr.md

**Step budget.** `WAMR_BUILD_INSTRUCTION_METERING` (off by default) enables
`wasm_runtime_set_instruction_count_limit(exec_env, n)`; the interpreter
decrements a counter in `HANDLE_OP_END()` after every opcode and raises the
exception "instruction limit exceeded". PR #4122 (merged 2025-05-26) covers
the classic and fast interpreters; the author explicitly did not implement it
for AOT, and the build doc says classic interpreter only. **There is no
fuel/epoch equivalent for AOT or JIT.** The other tool is
`wasm_runtime_terminate(module_inst)`, which makes the instance "fail as if it
raised a trap"; the interpreter checks suspend flags at `br`/`br_if`, which is
what makes cross-thread termination land inside loops, but that path is tied
to the thread-manager build and its behaviour in AOT is not documented. Open
issue #4047 (Jan 2025) shows `--timeout` cannot stop a start function because
terminate needs an instance handle.
https://github.com/bytecodealliance/wasm-micro-runtime/pull/4122
https://raw.githubusercontent.com/bytecodealliance/wasm-micro-runtime/main/core/iwasm/include/wasm_export.h
https://github.com/bytecodealliance/wasm-micro-runtime/issues/4047

Consequence for us: to get a reliable per-step budget you must run WAMR in
interpreter mode, giving up AOT/JIT speed. Per Frank Denis's 2026 benchmark
WAMR AOT is about 1.57x native; the interpreters are far slower (the fast
interpreter is "~2x faster than classic" and uses ~2x memory per the build
doc). For tiny per-tick modules that may still be plenty, but it is a real
ceiling.
https://00f.net/2026/06/23/webassembly-runtimes-2026/

**Memory limits.** `InstantiationArgs.max_memory_pages` overrides the module's
max; `wasm_runtime_full_init` can confine all runtime allocations to a
caller-supplied pool. With hardware bounds checking (default on Linux/macOS
64-bit) linear memory is mmapped from virtual address space with guard
regions; with it disabled, memory comes from the global heap and bounds are
checked in software.
https://github.com/bytecodealliance/wasm-micro-runtime/blob/main/doc/memory_tune.md

**Traps.** Failed calls return false; `wasm_runtime_get_exception` returns
strings such as "wasm operand stack overflow", "native stack overflow",
"wasm auxiliary stack overflow", "instruction limit exceeded". Native stack
overflow uses a guard page + signal on 64-bit Linux/macOS
(`WAMR_DISABLE_STACK_HW_BOUND_CHECK` to turn off).

**Platforms.** Interpreter and AOT runtime on aarch64 macOS work; Fast-JIT is
x86_64 only; LLVM JIT is heavy (links LLVM). `wamrc` AOT for aarch64 hit an
LLVM "only small, tiny and large code models" error (#3164, Feb 2024) with a
`--size-level=3` workaround. AOT also means running `wamrc` at upload time in
the server pod, which is an extra moving part.
https://github.com/wasm-micro-runtime/wasm-micro-runtime/issues/3164

**Size.** Tiny: ~59 KB fast interp / ~56 KB classic / ~29 KB AOT runtime on
Cortex-M4F per the README. Desktop builds are a few hundred KB.
https://github.com/bytecodealliance/wasm-micro-runtime/blob/main/README.md

**Security.** 8 advisories 2025–2026, including Critical CVE-2026-54914
(heap overflow in WASI `poll_oneoff`, N/A without WASI), High CVE-2026-54912
(fast-interpreter constant-dedup buffer overflow at module load, which *is*
our threat model: malicious uploads), CVE-2025-64713 (fast-interp array
overflow), CVE-2025-64704 (v128.store segfault in interpreter). WAMR's own
build doc warns "WAMR is not a secure sandbox on every platform". The team
does respond and cut fixes, but the interpreters are where the bugs are, and
the interpreters are exactly what we would have to run for metering.
https://api.github.com/repos/bytecodealliance/wasm-micro-runtime/security-advisories

**Nim bindings.** None found (GitHub search for WAMR/wasm-micro-runtime in
Nim: 0 results). Official bindings exist for Go, Python, Rust; a third-party
Zig binding exists.

### wasm3

**Version and maintenance: the picture changed this month.** The README still
carries the 2024 notice that "Wasm3 will enter a minimal maintenance phase"
after the maintainer's house was destroyed in Ukraine, and the previous
release was v0.5.0 on 2021-06-02. But v0.9.0 shipped 2026-08-24 ("Wasm3 now
fully validates WebAssembly modules", Wasm 2.0 conformance plus parts of 3.0,
"LOTS of security and stability fixes", all known OSS-Fuzz findings resolved,
`d_m3MaxFunctionStackHeight` raised to 8000, native stack tracking/limit
added), with 14 more commits by 2026-08-27 (Memory64, multiple memories,
non-global WASI contexts). So: alive again as of this week, but it is one
person, five years between releases, and no security advisory process (the
GitHub advisory list is empty; e.g. the heap overflow in `NewCodePage` was
issue #320). MIT license.
https://api.github.com/repos/wasm3/wasm3/releases?per_page=6
https://api.github.com/repos/wasm3/wasm3/commits?per_page=8
https://github.com/wasm3/wasm3/releases/tag/v0.9.0
https://raw.githubusercontent.com/wasm3/wasm3/main/README.md

**Step budget: this is the disqualifier.** wasm3 has no built-in fuel. The
README's "Gas metering" feature means pre-instrumenting the module with the
`wasm-metering` npm tool and running the metered module (Cookbook). The only
runtime hook is `m3_Yield()`, and in `m3_exec.h` it is called from `op_Call`,
`op_ReturnCall` and `op_ReturnCallRef`, not from loop back-edges. A play whose
step is `loop { }` with no calls cannot be interrupted. We could instrument
uploads ourselves (inject a counter decrement at every loop header and
function entry, which is what `wasm-metering`/`wasm-instrument` do), but then
we own a binary-rewriting security boundary.
https://raw.githubusercontent.com/wasm3/wasm3/main/source/m3_exec.h
https://github.com/wasm3/wasm3/blob/main/docs/Cookbook.md
https://raw.githubusercontent.com/wasm3/wasm3/main/source/wasm3.h

**Memory and stack.** `d_m3MaxLinearMemoryPages` (compile-time, default
65536) and the module's declared max; `m3_NewRuntime(env, stackBytes, ud)`
sets the wasm stack; traps come back as `M3Result` strings
(`m3Err_trapStackOverflow`, `m3Err_trapOutOfBoundsMemoryAccess`, ...).
`d_m3MaxNativeStack` (default 8 MiB − 128 KiB) is new in 0.9.0.
https://raw.githubusercontent.com/wasm3/wasm3/main/source/m3_config.h

**Performance and size.** Interpreter, historically among the fastest; ~64 KB
code. Instantiation is lazy and very fast. Fine for this workload's size.

**Nim bindings.** `beef331/wasm3`: MIT, wasm3 vendored as a submodule and
compiled with `{.compile.}`, high-level wrappers plus raw `wasm3/wasm3c`, 25
stars, last push 2024-12-07, pinned to a pre-0.9.0 wasm3 commit. The nicest
Nim integration story of the four, but it points at an old wasm3.
https://github.com/beef331/wasm3

### wasmer

**Version.** v7.3.0, 2026-08-21 (7.2.1 Jul 2026; 7.2.0 Jun 2026; 7.0 Jan
2026). Release tarballs are enormous (darwin-arm64 288 MB, linux-amd64 306 MB)
because they bundle LLVM; the C library alone will be smaller but I could not
find a published number.
https://api.github.com/repos/wasmerio/wasmer/releases/tags/v7.3.0

**License.** Core is MIT, but the Singlepass compiler was relicensed to
BUSL-1.1 in Wasmer 6.0 ("Singlepass Relicensing" post). Cranelift and LLVM
backends remain MIT. A BUSL component in a game server is an avoidable
headache.
https://wasmer.io/posts/singlepass-relicensing
https://github.com/wasmerio/wasmer/blob/main/LICENSE

**C API.** `lib/c-api` implements the standard `wasm.h` plus `wasmer.h`;
build with `make build-capi`, link flags via `wasmer config --libs/--cflags`.
7.2.1/7.3.0 added externref/funcref to the C API.
https://github.com/wasmerio/wasmer/tree/main/lib/c-api

**Step budget.** Metering is a compiler middleware (`wasmer_metering_new`,
`wasmer_metering_as_middleware`, `wasmer_metering_get/set_remaining_points`,
`wasmer_metering_points_are_exhausted`) that instruments each operator with a
cost and traps at zero. The docs.wasmer.io feature matrix says all three
compilers support it now (the old "Cranelift can't do middleware" limitation
is history). The C API for it lives under `wasm_c_api::unstable::middlewares`,
explicitly marked unstable. Separately, 7.2.0 added "experimental
interruptable WASM computation" (PR #6075, merged 2026-03-31): a
`Store::interrupter()` that sends SIGUSR to the executing thread and converts
it to a `HostInterrupt` trap; it is behind the `experimental-host-interrupt`
feature, Rust-only, `sys` backend, and not in the C API as far as I can find.
https://wasmerio.github.io/wasmer/crates/doc/wasmer_c_api/wasm_c_api/unstable/middlewares/metering/index.html
https://docs.wasmer.io/runtime/features/
https://github.com/wasmerio/wasmer/pull/6075

**Churn signal.** 7.2.0 dropped the WAMR and Wasmi backends and the
x86_64-darwin target; 7.3.0 removed Windows from the sys backends and LLVM
RV32. The project is moving fast in the direction of WASIX, the Wasmer
registry and Edge, not toward stable small embeddings.
https://github.com/wasmerio/wasmer/releases/tag/v7.2.0

**Security.** Only two advisories ever (CVE-2023-51661, CVE-2024-38358), both
WASI filesystem. Fewer advisories than Wasmtime is not evidence of fewer bugs;
Wasmer does not publish continuous-fuzzing results or audits comparable to
Wasmtime's. Treat the record as thin rather than clean.
https://api.github.com/repos/wasmerio/wasmer/security-advisories

**Nim bindings.** `yglukhov/wasmer` (MIT, 9 commits, last push 2023-07-06)
and `beef331/wasmer` (0 stars, 2022). Both dead and target Wasmer 3/4-era C
API.
https://github.com/yglukhov/wasmer

### wasmi (extra candidate worth naming)

Rust interpreter with an official wasm-c-api implementation
(`wasmi_c_api_impl`, CMake build producing `libwasmi.{a,so,dylib}`). Stable
1.1.0 (1.0 released 2025-12-03, 1.0.x patches through Feb 2026); 2.0 is in
beta (beta.10 on 2026-08-10) and just added "stable fuel metering tied to
input Wasm bytecode". Built-in fuel, resumable calls, `StoreLimits`, two
external security audits, and it is Wasmtime's differential-fuzzing oracle.
Dual MIT/Apache-2.0. Funded by Stellar (used as their smart-contract VM).
Benchmarks in its own repo put it on par with or ahead of wasm3 and Stitch.
No Nim bindings. It would be the pick if we decided we wanted an interpreter
(no JIT pages, smallest attack surface) rather than a JIT; it beats wasm3 on
every requirement except "already has a Nim wrapper".
https://github.com/wasmi-labs/wasmi
https://wasmi-labs.github.io/blog/posts/wasmi-v1.0/
https://crates.io/api/v1/crates/wasmi
https://github.com/wasmi-labs/wasmi/blob/main/crates/c_api/README.md
https://api.github.com/repos/wasmi-labs/wasmi/releases?per_page=4

### Others, briefly

- **wazero**: Go-only, no C API. Irrelevant for a Nim host.
- **WasmEdge**: C++ runtime with a C API, AOT ~1.74x native in the 2026
  benchmark; CNCF project. Not evaluated in depth because it is larger than
  Wasmtime and offers nothing the requirements need beyond it.
- **toywasm, Stitch, tinywasm**: small interpreters without the budget /
  limiter / maintenance story we need.
- **wasm2c (WABT)**: compile wasm to C at upload time. Would require a C
  compiler in the server pod and gives no metering; not a fit.

## Recommendation

**Use wasmtime via `libwasmtime` (C API), Cranelift on both platforms, with
fuel as the per-step budget and an epoch ticker as the wall-clock backstop.**

Why it wins for this workload:

1. It is the only candidate where the per-step budget works in the fast
   execution mode. WAMR's instruction metering is interpreter-only; wasm3 has
   no runtime metering at all; wasmer's metering exists but through an API
   its own docs call unstable, on a project that just dropped two backends and
   a target in one release.
2. Both interruption styles are in the C API today: fuel gives a hard,
   deterministic CPU bound per step (exactly the tick-stall guarantee), and
   `wasmtime_engine_increment_epoch` from a ticker thread is signal-safe and
   cheap. A trapping or over-budget play returns a `wasmtime_trap_t`; the
   server keeps running.
3. Memory: `wasmtime_store_limiter` plus the pooling allocator sized for 32
   slots gives a hard per-instance cap, ~µs instantiation, and no mmap on the
   tick path. Copy-on-write heap images mean re-instantiating a play after a
   trap is nearly free.
4. Sandbox: the only runtime here with continuous fuzzing, an LTS back-port
   policy, and an audit that actually finds and publishes bugs. x86_64
   Cranelift (our prod path) was unaffected by the April 2026 Criticals.
5. Integration: stable flat C API, prebuilt static and dynamic libs for
   aarch64-macos and x86_64-linux every release, and a Futhark-generated Nim
   wrapper to crib from. Binding the ~15 functions we need by hand is a day
   of work.

Costs to accept: a 13–19 MB runtime library (irrelevant for a k8s server
image); a JIT that needs executable memory (fine on Linux and macOS);
monthly major versions, so pin one and bump deliberately (LTS lines get
patches); and never deserialize cached compiled modules from anywhere but our
own store.

Concrete config to start from: Cranelift, `consume_fuel=true`, fuel set per
step (calibrate against a reference play; start around 1–10 M units),
`epoch_interruption=true` with a ticker at a few ms and a deadline of one or
two ticks, `max_wasm_stack` 256 KiB, pooling allocator with 32 (or 64)
instance slots and a per-memory cap of a few MiB, `wasmtime_store_limiter`
memory_size matching, `wasmtime_module_validate` on upload followed by a full
compile so upload rejects anything Cranelift refuses.

**Runner-up: WAMR in fast-interpreter mode with `WAMR_BUILD_INSTRUCTION_METERING`.**
Same license family, tiny footprint, per-opcode budget, per-instance
`max_memory_pages`, and a clean C API. It loses because the metered path is
interpreter-only (roughly an order of magnitude slower than AOT), the
interpreter is where its recent High/Medium CVEs were, `wasm_runtime_terminate`
semantics in AOT are undocumented, and there are no Nim bindings. If the
project later decides it wants to forbid JIT entirely, re-evaluate WAMR
against wasmi (which has fuel, limits, audits and a wasm-c-api C library)
rather than defaulting to WAMR.

**Do not pick:** wasm3 (no runtime metering, one maintainer, no advisory
process, despite the welcome 0.9.0 revival this week) or wasmer (BUSL
Singlepass, unstable metering C API, high churn, only dead Nim wrappers).

## Facts I could not verify

- Wasmtime per-store/per-instance RSS in kilobytes for a small module with the
  pooling allocator; only "a few kilobytes written per instantiation" from the
  1.0 article. Measure it.
- Wasmtime fuel overhead as a percentage on this kind of code; docs say
  "somewhat expensive", one blog measured epochs at ~10 percent. Measure both.
- Whether fuel and epochs work under Pulley (only relevant if JIT were banned).
- WAMR `wasm_runtime_terminate` behaviour in AOT/JIT mode and whether the
  suspend-flag checks at `br`/`br_if` exist outside the thread-manager build.
- WAMR fast-interp vs classic-interp support for instruction metering: the PR
  says both, the build doc says classic only. Trust the PR, but test.
- Size of the wasmer C shared library on its own (only whole-distribution
  tarball sizes were available).
- Whether wasmer's metering C API is exercised by CI on Cranelift in 7.x
  (feature matrix says supported; no test evidence located).
- The exact commit `beef331/wasm3` and `Nimaoth/nimwasmtime` pin, beyond
  "pre-0.9.0" and "v29.0.0" from commit messages.
- wasm3's `m3_Yield` default implementation (the `m3_exec.c` file is empty
  and the definition was not located in the files fetched); the call sites in
  `m3_exec.h` are verified.

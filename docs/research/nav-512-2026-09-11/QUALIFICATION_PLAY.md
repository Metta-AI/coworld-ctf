# Qualification play: `nav_research_moving`

Test-only WASM controller for the held-out real-game qualification runs.
Support for qualification, not a benchmark or a league play. No SDK
production API, planner source, budget or manifest of a shipped play was
changed. Nothing is committed (viewer rule still open); the root owns
native installation checks, real-game replan verification and freezing
of qualification inputs.

## Files (all under `docs/research/nav-512-2026-09-11/qualification/`)

| File | Purpose |
|---|---|
| `nav_research_moving.nim` | The play (SHA-256 `860bb0cb01ef430d4b55a36c79b0a3db7de680417388b8b712046b8d0a6339df`) |
| `nav_research_moving.nims` | Build recipe; includes `play_sdk/play.nims` unchanged, adds `-d:danger` like the reference plays, outputs to `.build/` |
| `panicoverride.nim` | Two-line standalone-target panic hook that includes the SDK's `examples/panicoverride.nim`, as every SDK play directory does |
| `test_nav_research_moving.nim` | Focused probe through the production runtime, module validator, emit validator and instance path |
| `.build/nav_research_moving.wasm` | Built module, 6,748 bytes, SHA-256 `d51b9cf843125997dd1523ae2db34d18ef2491ec1dca111c4d76d9e963c251e3` (gitignored; rebuild from source) |

## Behaviour

- Manifest: `{"abi":1,"class":"controller","doc":"...","modes":["br"],
  "name":"nav_research_moving","params":{},"retune":true}`.
  `play_retune` is exported and does nothing, so `retune: true` is honest.
- `play_init` logs level 1 `nav_research_moving initialized` once, so the
  full-game runner can count `SHELL_PLAY_LOG ... phase=init` rows against
  the seat count exactly as it does for `edge_ride`.
- `play_step` decodes the view with the SDK's existing
  `readEdgeRideBinaryViewInto` (tick, self, current and next zone
  rectangles). Interval = `tick div 12`. If the interval equals the last
  one it emits nothing and returns 0. On a new interval it picks the
  interior quarter centre of the current zone rectangle: (1/4, 1/4) of the
  span on even intervals, (3/4, 3/4) on odd, so consecutive goals are far
  apart; validates it with `nearestReachable`; and emits one canonical
  intent:

  ```
  {"arrive_radius":24.0,"kind":"navigate_to","moving_goal":true,
   "point":[x,y],"profile":"carrier"|"hunter",
   "reason":"nav_research_moving:carrier"|"...:hunter","schema":"intent","v":1}
  ```

  Carrier on even intervals, hunter on odd. Keys are byte-sorted as the
  canonical reader requires. The bytes are assembled in a 192-byte local
  buffer with a local non-negative integer formatter and sent through the
  SDK's public `emitRaw(openArray[byte])`; no SDK emit-buffer internals are
  exported and no generalized serializer was added.
- If the view carries no zone the decoder fails; the play then clocks on
  its own step count and uses fixed fallback goals (256,256) and
  (1024,768), still validated through `nearestReachable`.
- If `nearestReachable` fails on a new interval the play emits nothing for
  that interval (the interval is still consumed).
- One spatial call per emitting step, none otherwise; no cover query.
  Fuel and memory limits are the SDK's unchanged ones (`StepFuel` 50,000,
  `InitFuel` 500,000, 1 MiB max memory from `play.nims`).

## Commands (run from the repo root)

Toolchain via the sanctioned script, which fetches and checksum-verifies
wasi-sdk 33 and the wasmtime 48.0.1 C API into
`tools/runtime_spike/.deps` (gitignored):

```sh
sh tools/runtime_spike/fetch_deps.sh          # prints WASI_SDK_PATH= and WASMTIME_C_API=
export WASI_SDK_PATH=tools/runtime_spike/.deps/installed/<host>/wasi-sdk
export WASMTIME_C_API=tools/runtime_spike/.deps/installed/<host>/wasmtime-c-api

# Build the play
nim c -f --hints:off docs/research/nav-512-2026-09-11/qualification/nav_research_moving.nim

# Probe through the production runtime (builds the play itself first)
nim c -r -f -d:release -d:noSignalHandler --threads:on --hints:off \
  docs/research/nav-512-2026-09-11/qualification/test_nav_research_moving.nim
```

Local run record (arm64 macOS, Nim 2.2.6, wasi-sdk 33 arm64-macos,
wasmtime 48.0.1 aarch64-macos, both verified against
`tools/runtime_spike/checksums.txt`): build succeeded; probe 5/5 OK:

1. manifest is the registered name with no params and parses in production
2. init logs once so a full-game runner can prove every seat loaded
3. emits a valid moving-goal intent once per 12-tick interval, alternating
   quarters and profiles (48 ticks: emits exactly at 0, 12, 24, 36 and
   nowhere else; `kind` navigate_to, `moving_goal` true, `arrive_radius`
   24.0, profile carrier/hunter/carrier/hunter, reasons as above, points
   within 16 px of the quarter centres (700,375) and (1300,725) of the
   test zone, consecutive points differ, at most one spatial call per step)
4. a shrinking zone moves the quarter goals with it
5. without a zone the play falls back to fixed goals on its own step clock

The probe validates the emitted bytes with the same `emit_validator`
schema path the server uses (`profile` and `moving_goal` are parsed there),
so a schema break would fault the step rather than pass.

Environment note: this shell carries a stale Nix devshell; Nim and clang
were run with those variables unset so the system CommandLineTools SDK is
used, as in earlier phases.

## For the full-game runner

- Install the module for every seat like `edge_ride`; the init log line
  proves loading. Expect a `SHELL_INSTALL ... rule=nav_research_moving`
  navigate_to row for every seat on every 12th tick, with `profile`
  alternating and `moving_goal` true, and `SHELL_PLAN_BUDGET` replans to
  follow. Because the clock is the shared view tick, all seats replan in
  the same tick, which is the harsher, burst-shaped workload; if a
  staggered pattern is wanted later, an interval offset per seat would
  need a param, which this play deliberately does not have.
- The engine's `PlanMovingReplanTicks` is also 12, so a moving-goal replan
  and the play's own goal change coincide each interval; the root should
  confirm from `SHELL_PLAN_BUDGET`/`SHELL_NAV` that this produces the
  intended replan rate rather than assume it.

## Limits

- Not run in a real game here; no native host use. Install, per-seat
  replan behaviour and interaction with deaths and zone phases are for the
  root to verify before freezing inputs.
- The quarter choice ignores walls; `nearestReachable` snaps into the
  standable component, so on a map whose quarter centre is deep inside a
  wall the goal can land some distance away. That is acceptable for a
  replan-load play but should be visible in the install rows.
- Built and probed with Nim 2.2.6 locally; the native image builds guests
  with its own pinned toolchain per the Dockerfile.

PHASE 6 READY

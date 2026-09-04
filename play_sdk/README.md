# Season 2 play SDK

This SDK is a convenience layer for Nim-authored core-WASM plays. It is not a
security boundary; the server still validates every module, manifest, host call,
and emitted byte stream.

Build a play with Nim 2.2.6 and wasi-sdk 33:

```bash
WASI_SDK_PATH=/path/to/wasi-sdk nim c play_sdk/examples/hello_play.nim
```

The build uses the arena recipe minus WASI: imports must live only in the
`play` namespace. The SDK stubs expose `emit`, `log`, `nearest_reachable`, and
`nearest_cover`.

`play_step` receives `play_view` as a fixed-layout binary frame. Use the SDK's
typed binary accessors (`readBinaryViewInto` or the narrower
`readEdgeRideBinaryViewInto`) instead of parsing JSON. `play_init` and
`play_retune` params are still canonical JSON today; the SDK keeps a small
params-only reader for that path until a binary params encoding exists.

Reference plays live in `play_sdk/reference/` (edge_ride, pact, supply_run,
bodyguard, jackal, crossfire, target_law, and `loot` — the general pickup
fetcher the starters gate on "no enemy tracked, item within reach").

## Play diagnostics

`log(level, bytes)` is legal in `play_manifest`, `play_init`, `play_step`, and
`play_retune`. The level is an opaque signed `int32`; the host preserves it but
does not define an enum or filter by it. The `edge_ride` reference play uses
level `1` for its one-time successful-init message.

Each invocation admits at most four calls of 256 bytes and silently ignores
later calls. The local play harness retains every admitted call as ordered,
reversible `{"level":N,"bytes_hex":"..."}` records. For live ladder entries,
server stdout receives at most four escaped lines per seat per 24 ticks;
suppressed calls are summarized as `dropped_previous=N` on the next window's
first admitted line. Upload-time manifest-probe logs have no seat identity and
do not reach stdout.

Server stdout is public/operator-visible, best effort, and not a private or
durable author channel. Logs do not enter status, replay, game state, or
`gameHash`. Writing is synchronous, so a blocked stdout collector may delay the
server loop.

Read the sections your play actually needs. A full typed decode of every
section measures roughly 17-22 fuel per byte, and the all-section reader
exhausts `StepFuel` near a 4.5 KiB frame. The binary frame makes section access
cheap; it does not make "decode the whole world every step" cheap.

## Testing decoders

Decoder tests must anchor on a landed contract artifact: checked-in golden
bytes, a schema-derived fixture, or production-validator output. Do not prove a
reader against bytes emitted only by the same lane's temporary producer; reader
and writer self-agreement does not prove the contract.

`nearest_cover` is now backed by the engine-side atlas scorer. Its API is stable;
candidate density is governed by the engine's frozen `MaxCoverRadiusPx` and
`MaxCoverPostsExamined` caps.

Authoring envelope: the spatial-call budget is two spatial calls
per step. A play comparing more than two cover candidates per step is doing the
scorer job itself. The engine contract now enforces this with
`MaxSpatialCallsPerStep = 2`.

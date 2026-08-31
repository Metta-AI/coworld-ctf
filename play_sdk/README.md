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

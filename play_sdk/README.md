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

`nearest_cover` is now backed by the engine-side atlas scorer. Its API is stable;
candidate density remains freeze-pending and is governed by the engine's
`MaxCoverRadiusPx` and `MaxCoverPostsExamined` caps.

# Play harness

`tools/play_harness/play_harness.nim` runs one uploaded play module through the
same shell runtime, validation pipeline, schemas, and ABI callbacks used by the
server. The harness is synchronous and has no private acceptance mode.

Build and run:

```bash
WASMTIME_C_API=/path/to/wasmtime-c-api nim c --threads:on -d:noSignalHandler -d:release tools/play_harness/play_harness.nim
tools/play_harness/play_harness tests/fixtures/shell/play_harness/hello_success.case.json
```

Case files are JSON objects with a `module` path and a `frames` list. Payload
fields may be either strings containing exact bytes or JSON values, which the
harness canonicalizes before invoking the guest.

```json
{
  "module": "play_sdk/.build/hello_play.wasm",
  "self": [30, 30],
  "frames": [
    {"op": "manifest"},
    {"op": "init", "params": {}, "context": {}},
    {"op": "step", "view": {}, "tick": 1},
    {"op": "retune", "old_params": {}, "new_params": {"level": 1}}
  ]
}
```

The output is canonical JSON containing module acceptance/rejection, invocation
return codes, fuel remaining, fault/refusal reason, counters, emit return codes,
manifest bytes, and the last accepted canonical emission.

Authoring envelope: the spatial-call budget is two spatial calls
per step. A play comparing more than two cover candidates per step is doing the
scorer job itself. The engine contract now enforces this with
`MaxSpatialCallsPerStep = 2` in `src/shell/types.nim`.

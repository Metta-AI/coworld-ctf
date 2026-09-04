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
harness canonicalizes before invoking the guest. The exception is an object-form
`view`: that is an authoring convenience, and the harness encodes it to the
same fixed-layout binary `play_view` frame the server passes to `play_step`.
String-form `view` values remain exact bytes.

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
manifest bytes, and the last accepted canonical emission. A faulted or refused
frame also carries `code`: the stable engine `FaultCode` (`outOfFuel`,
`epochDeadline`, `unreachable`, `memoryOutOfBounds`, `returnedNonzero`,
`refused`, `abiViolation`, ...), the same value the live server reports in the
seat's `play_faulted` / `retune_refused` status, so a play author can match
what they see locally against the league log. Every frame also carries ordered
`logs`; each admitted log has the exact opaque signed `level` and raw guest
bytes encoded reversibly as lowercase, two-digits-per-byte `bytes_hex`; no UTF-8
decoding is attempted. For example:

```json
{"logs":[{"bytes_hex":"001b7f80ff","level":-2147483648}]}
```

The harness exposes logs from all four legal phases: `manifest`, `init`, `step`,
and `retune`. It keeps every call admitted by the ABI's per-invocation limit
(currently four calls of at most 256 bytes each). Unlike the live server sink,
the finite, explicitly author-run harness has no additional per-seat window.

Live server diagnostics are a different sink: `init`, `step`, and `retune`
records are escaped onto synchronous, public/operator-visible stdout, capped at
four lines per seat per 24 ticks with `dropped_previous=N` reported in the next
window. They are best effort, not private or durable, and never enter status,
replay, game state, or `gameHash`; a blocked stdout collector may delay the
server loop. The upload-time manifest probe has no seat/entry identity and is
therefore intentionally absent from live stdout.

Authoring envelope: the spatial-call budget is two spatial calls
per step. A play comparing more than two cover candidates per step is doing the
scorer job itself. The engine contract now enforces this with
`MaxSpatialCallsPerStep = 2` in `src/shell/types.nim`.

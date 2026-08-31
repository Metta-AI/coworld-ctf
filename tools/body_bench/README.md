# Body benchmark scaffolding

This directory contains measurement-only code for the Season 2 body P0 gate.
It is not production body code and is not imported by the test shards.

`edt_probe.nim` prototypes the exact squared Euclidean distance table and checks
its answers against the bounded ring-scan oracle. `view_frames.nim` constructs
deterministic real-max and explicitly synthetic cap-stress payloads.

The portable cases build and run without the private lab:

```bash
nim c -d:release -o:/tmp/bench_body tools/bench_body.nim
/tmp/bench_body --case smoke --output /tmp/body-bench-smoke.json
```

The stencil-backed measurements are deliberately a separate, local-only
binary. The private stencil source is never copied into this repository. Set
`STENCIL_LAB_DIR` to the directory containing its Nim modules and compile with:

```bash
nim c -d:release --path:"$STENCIL_LAB_DIR" -o:/tmp/bench_body_stencil \
  tools/bench_body_stencil.nim
/tmp/bench_body_stencil --case smoke \
  --stencil-pin 480120c2f5d2a13bc84917b6470b64e67372a752
```

The binary prints the lab's live commit and refuses to run if it differs from
the requested pin. Neither benchmark binary writes into `STENCIL_LAB_DIR`.
`--case smoke` runs every case with one sample and small synthetic maps. The
full P0B run uses both binaries: the portable binary for payload encoding and
the optional binary for the real generated-map/stencil measurements. JSON and
binaries must remain under `/tmp` or the collaboration scratchpad, never in the
repository.

The local adapters and every lab reference must be deleted after Gate 1 passes.

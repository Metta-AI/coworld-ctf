# Body benchmark scaffolding

> **Historical P0 measurement rig.** The commands remain useful for reproducing
> the cited body measurements, but this is not current Season 2 policy or
> runtime guidance; the body port has since landed.

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

# H2 revision: refined entry per H2_REVIEW.md

Applied in the peer working tree on top of the H1 checkpoint `e730021a`.
Uncommitted. No timing, native host, or other mechanism.

## Change

`segmentClear` entry now reads clearance once, refuses an invalid start
before the coordinate subtraction, then tests the certificate:

```nim
let startClearance = map.clearanceAt(start)
if startClearance <= PlayerHalf:
  return false
let dx = goal.x - start.x
let dy = goal.y - start.y
if startClearance > PlayerHalf + max(abs(dx), abs(dy)):
  return true
```

The first test equals the former `canStand(start)` because `clearanceAt`
is 0 out of bounds and `PlayerHalf` is 6. A failed certificate no longer
performs a second clearance lookup through `canStand`. The production
comment is shortened to the certificate, side-pixel coverage and
conservative saturation; the proof stays in `H2_IMPLEMENTATION.md`.
Production diff: 10 insertions, 1 deletion.

## Checks rerun (local arm64, Nim 2.2.6, `-d:release`; logs in `H2/`)

| Check | Result |
|---|---|
| test_shell_body_segment_exact (original-scan differential) | 5/5 OK |
| test_shell_body_heap_exact | 6/6 OK |
| test_shell_body_nav | 21/21 OK |
| test_shell_body_seat | 26/26 OK |
| cross-build fingerprints (`H1/crossbuild_fingerprints.nim`) | `ticks=1119 suspension_digest=5936823674378073636 path_digest=3301525546362550601 points=29546`, identical to baseline and H1 |
| `nim check` runtime-stub shape | passes |
| `H2/H2_production.patch` `patch --dry-run` on baseline `6b6b3408` | applies |

Refreshed artifacts: `H2/H2_production.patch`, `H2/H2.patch`,
`H2/sha256.txt`, `H2/crossbuild-h1-h2.txt`, suite logs,
`H2_IMPLEMENTATION.md` mechanism section. The runtime-linked compile
shape remains unverified locally (no Wasmtime C API); native verification
stays with the root, and the local compiler is 2.2.6, not the pinned
2.2.4.

H2 REVISION READY

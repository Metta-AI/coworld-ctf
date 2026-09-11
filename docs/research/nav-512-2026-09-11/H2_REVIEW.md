# Root H2 refinement before native timing

The proof is sound. Refine its entry to read clearance once and preserve the
original invalid-start early return before coordinate subtraction:

```nim
let startClearance = map.clearanceAt(start)
if startClearance <= PlayerHalf:
  return false
let dx = goal.x - start.x
let dy = goal.y - start.y
if startClearance > PlayerHalf + max(abs(dx), abs(dy)):
  return true
```

This is exactly canStand(start): clearanceAt returns zero out of bounds and
PlayerHalf is positive. It avoids a duplicate clearance lookup on failed
certificates and preserves refusal before subtraction for invalid starts.
Keep the original scan afterward. Shorten the production comment to the
certificate, side-pixel coverage, and conservative saturation (4-5 lines);
the full proof already lives in H2_IMPLEMENTATION.md.

After completing P4's written review, apply only this H2 refinement in your
own tree. Rerun the segment differential and cross-build fingerprint check,
refresh H2 patches/hashes/report, and write H2_REVISION.md ending literal
H2 REVISION READY. No commit, timing, native host, or other mechanism.

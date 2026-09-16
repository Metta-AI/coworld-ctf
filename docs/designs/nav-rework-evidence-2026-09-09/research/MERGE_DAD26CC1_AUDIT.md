# Sync audit: origin/main dad26cc1

Incoming source change enables replay transport while a live episode is held at GameOver; accompanying client/tests/docs arrive from main. The manifest change only describes the deprecated baseline player. Navigation code, map selection, gun range and the measured benchmark inputs are behaviorally unchanged. Existing experiments retain their original source patches and manifest digests; no results are silently relabeled as measurements of this merge.

The only merge conflict was the generated replay WASM. M2 work was saved in stash8dcfb570029db7424b614c2bf3036fd29d54da99 before merging; the viewer was rebuilt from the merged W1 source and passed module, GameVersion and sim-source-stamp checks. No M2 source is included in this merge. Its checkpoint will be restored and rebuilt separately. Final full test/Phase10/11 verification remains outstanding.

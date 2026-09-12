# Restore raw research artifacts

From this directory, restore exact source patches and native perf reports:

```sh
tar -xzf source-and-profile-text.tar.gz
tar -xzf validation-logs.tar.gz
(cd CROSS_ARCH/first_divergence && tar -xzf raw-dumps.tar.gz)
```

The archives preserve exact bytes, including unified-diff context spaces and
perf's aligned trailing columns. Roundtrip content equality was verified before
packing them. Companion SHA256 files pin each archive. H1/H2/H3 raw games and
current-main build evidence remain in their own named archives; extract those
into a scratch directory so their original directory layout is preserved.

Source patches describe intermediate candidate states. The current production
diff is also directly visible in Git; its source checkpoint retains default256.
Raw evidence is historical, including failed and superseded experiments, and
must not be treated as a current qualification verdict.

The two exact guest modules are in `guest-modules.tar.gz`; extract it from
the repository root to restore their original `.build` paths. Their individual
hashes remain in `current-main/assets.json`. `current-main/CARD.md` is a frozen
card: its `production.patch` reference means the copy restored from
`source-and-profile-text.tar.gz`, as does `current-main/ASSET_PROVENANCE.md`.

Completed qualification archives: `current-main/raw-games.tar.gz` contains
54 games (12 correctness,6 training,36 held-out); `fleet/c6a-raw.tar.gz` and
`fleet/c8i-raw.tar.gz` contain24 games each plus host and CPU-lifecycle records.
Each has an adjacent SHA256 sidecar. Extract into scratch directories; the
archives preserve the native result-directory names. The 102 current-base
games are separate from earlier hypothesis screens and superseded diagnostics.

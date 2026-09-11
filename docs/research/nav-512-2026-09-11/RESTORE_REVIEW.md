# Restore review of the local research checkpoint c651dec9

Scope: verify that the local-only checkpoint `c651dec9` and its evidence
are restorable from what is in the tree and its archives. All work was
read-only git and archive extraction into the peer scratchpad; no root or
production edit, no native host use, no build, benchmark or commit.

## 1. Archives: every recorded hash matches its bytes

| Archive | Recorded | Actual |
|---|---|---|
| `source-and-profile-text.tar.gz` | `4dabf3e5...` | match |
| `validation-logs.tar.gz` | `996b9e46...` | match |
| `CROSS_ARCH/first_divergence/raw-dumps.tar.gz` | `8de360d1...` | match |
| `H2/raw-games.tar.gz` | `ed53ce37...` | match |
| `H3/raw-games.tar.gz` | `bdb7a3b1...` | match |
| `current-main/builds.tar.gz` | `99f6a1de...` | match |
| `H1/raw-games.tar.gz` | `117188ab...` in `H1/RESULT.md` prose only | match |

Extracting the three text archives per `RAW_ARTIFACTS.md` restores
`H1/H1.patch`, `H2/H2_production.patch`, `H3/H3_production.patch`,
`current-main/production.patch`, the P0 profile patch, the P1 perf
reports, the suite logs, the four local shard logs and
`checks/at46dd`, and the four first-divergence dumps (native, two local,
one superseded mirror) with their own `sha256.txt`.

## 2. Source provenance: c651dec9 is the built candidate source

- `current-main/production.patch` is **no longer present in the tree**
  (it was there at P15), but it is restorable from
  `source-and-profile-text.tar.gz`, and the restored copy equals
  `git diff 58e6c947 c651dec9 -- src` exactly (ignoring index lines). It
  touches four files: `body_cache`, `body_map`, `body_nav`,
  `body_planner`. Applying it to `58e6c947` reproduces `c651dec9`'s four
  files.
- Stronger than patch application: the build archive's
  `candidate/source-256.sha256` (43 `src/shell/*.nim`, `server.nim`,
  `glory.nim`, `nimby.lock`) matches `c651dec9`'s tracked contents for
  every file except `server.nim`, which carries the timing instrumentation
  from `prepare_native.py`; the pre-instrumentation `server-original.nim`
  is in the archive. `parent/source-256.sha256` matches `58e6c947` the
  same way. So the qualified candidate binaries were built from exactly
  the checkpoint's sources at budget 256 and 512, and the original from
  the merge base.
- `src/` is byte-identical between `58e6c947`, `46ddc845` and
  `81776f79` (the checkpoint's merge parent); the upstream commits in
  between are docs and wiki only. The "current base" language in the
  README therefore covers `c651dec9` for every runtime source.
- `current-main/assets.json` pins agree with `builds.tar.gz`'s
  `server-256.sha256` (parent), `server-256.sha256` and
  `server-512.sha256` (candidate).

## 3. Viewer stamp: verifiable from the commit itself

`c651dec9` commits a rebuilt `static-replay-viewer/ctf_replay.wasm`. The
sim-sources stamp recomputed over `c651dec9`'s tracked
`src/*.nim`, `replay-viewer/*.nim` and `nimby.lock` (the exact recipe in
`tools/sim_sources_stamp.sh`) is
`ed013f98465c0cdcfbad7df34db59e34c35888d6106c8cd3d35d4adeffc702f3`,
and that string is present in the committed wasm. The stamp validated in
`checks/at46dd/viewer-check.log` belongs to the earlier working tree
(HEAD `46ddc845` plus uncommitted H1-H3: its HEAD-only stamp is
`68a7cae0...`), not to `c651dec9`; there is no recorded
`qa_module_eval` run at `c651dec9`. The commit is self-consistent by my
recomputation, but a one-line record (or a rerun of the node QA check,
which needs no build) would make it discoverable without redoing the
arithmetic.

## 4. Frozen inputs, cards, provenance links

- All six frozen qualification configs match `manifest.json` hashes.
- `H1_CARD`, `H2_CARD`, `H3_CARD`, `qualification/PROTOCOL`,
  `current-main/CARD`, `fleet/CARD` and `training-config.json` match
  their sidecar hashes.
- `qualification-maps/sha256.txt` covers `br-scale29`, `map-scale29`,
  `pool-505`, `pool-5001`.
- `H3/parent-binaries.sha256` records the parent 256 (`802389df...`,
  the original) and parent 512 (`d5bf19a2...`, the H2 candidate)
  binaries, closing the readback gap I raised in P12.
- Native check and memory records: `H3/NATIVE_CHECKS.md`,
  `current-main/memory.json` (activation RSS 2.57 GB scale-2.9, per-seat
  payload bytes, object sizes), `checks/at46dd/RESULT.md` (four shards,
  2,301 checks, zero failures, linked and stub checks, viewer rebuild).
  The README's counts match the logs.
- Old and superseded results stay negative: the stale 301/14005
  preflight failure, the H1 and H1+H2 target misses, the rejected
  scale-2.9 seeds, the superseded mirror dumps and the synthetic harness
  are each labelled as such where they live.
- Qualification status in the README does not overclaim: it says
  current-base correctness is running before training and the 36
  held-out games, and that a training pass is not qualification. It is
  one step behind (12 correctness and 6 training now passed, held-out
  performance started) and should say so when next edited.

## 5. Concrete gaps (small, durable)

1. **Guest module bytes are not archived.** `edge_ride.wasm` and
   `nav_research_moving.wasm` are pinned by hash in `assets.json` but no
   archive contains the bytes (`builds.tar.gz`, the text archive, the
   validation archive and the H3 raw archive have zero `.wasm` entries),
   and both are gitignored build outputs. Rebuilding with wasi-sdk 33
   should reproduce them, but that is not shown. Add the two files
   (about 7 KB and the edge_ride size) to a named archive with a sidecar
   hash.
2. **`current-main/production.patch` is missing from the tree** while
   `CARD.md` and `ASSET_PROVENANCE.md` cite it by that path. Either
   restore the file beside the card or change the two references to
   "restored from `source-and-profile-text.tar.gz`".
3. **`H1/raw-games.tar.gz` has no sidecar hash file** (H2 and H3 have
   `raw-games.sha256`); the hash lives only in `H1/RESULT.md` prose.
4. **No stamp record at `c651dec9`** (section 3): add the stamp value
   or a QA-check log for the checkpoint.
5. **README status line** is one step behind the campaign (section 4).

Nothing found is misleading; items 1-4 are missing links or bytes that a
future restorer would otherwise have to regenerate or infer.

PHASE 18 READY

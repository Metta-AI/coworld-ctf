# Fleet runner review (read-only)

Reviewed: `fleet/run.py`, `fleet/run_native.sh`, `fleet/CARD.md` (hash
unchanged since P16, `338c9a9e...`), `fleet/RECORDING_NOTES.md`, and the
shared `qualification/metrics.py` and `run_case.py` (content as read in
P15). No host use, experiment, production edit or commit.

## 1. Cases, order, affinity, budget: correct

- **Cells.** `cells` is built mode-major over the two selected cases, so
  the order is edge-pinned, moving-pinned, edge-unpinned, moving-unpinned,
  exactly the card's list. Both case configs are re-hashed against the
  frozen manifest before use.
- **Pair order.** `(index + repeat - 1) % 2` with cell index 0..3 and
  repeat 1..3 reproduces the card's zero-based sum rule; cells are
  interleaved within each repeat.
- **Affinity.** Pinned passes `{5}` to `run_case.run`, which applies it
  as the server's `preexec_fn`; unpinned passes `None`, so the server
  inherits the container's full CPU set (no `--cpuset` on the `docker
  run`), while presence clients stay on `{6, 7}` in both modes, as the
  card specifies. The runner records its own effective affinity in
  `host.json`.
- **Budget.** Parent always `/original/server-256`, candidate always
  `/candidate/server-512`, presence always `/original/presence`; the
  same bytes as the m5a campaign, verified against `/reference/
  assets.json` before any game.

## 2. No warmup, no discard, nothing overwritten

There is no warmup loop, no filtering of frames or runs, and no
replacement path. `results.mkdir(exist_ok=False)` and the per-directory
`refusing to overwrite` check make a rerun into a fresh tree impossible
to confuse with the original. `rows.json` is rewritten cumulatively after
every completed game, before any mismatch check, so a stopped family
leaves every completed row on disk. `cpu-lifecycle.json` is written in
`finally`, so the snapshots exist for failed games too. Gates in the
verdict are the m5a gates unchanged (median paired ratios <= 1.00, worst
misses, repeat-exactness per variant), computed per cell and mode.

## 3. m5a reference: valid

The runner refuses to start unless `/reference/performance-verdict.json`
passed, derives each (case, variant) semantic reference from
`performance-rows.json` and requires exactly one hash per pair (which
holds only if the m5a campaign was repeat-exact, so an invalid reference
cannot be silently used), and verifies the reference `assets.json`
against the binaries and modules it is about to run. The candidate
reference is the 512 stream, matching the fleet candidate budget.

## 4. Provenance recorded

`host.json` carries the instance record (id, type, state checked
against the requested family and the owned instance id), kernel,
scheduler affinity, full `lscpu -J`, the CPU/core/socket/node topology,
every CPU's `thread_siblings_list`, and the asset pins. `/proc/stat`
counters, including steal, are captured before and after each game;
the notes correctly say these cover the process lifecycle, not the
playing interval only, and grant no discard.

## 5. Findings

1. **A cross-family mismatch is filed as a failed run.** On a semantic
   mismatch the runner raises inside the `try`, so the completed,
   fully-covered game gets a `failure.json` saying "cross-family
   semantic mismatch". That directory also holds a valid `metrics.json`
   and `exit.json` with code 0. Any later `inspect` of it will report
   "failed run", and a reader may count it as a coverage failure. The
   card's stop is right; the label is not. Write the stop to a
   differently named file (for example `mismatch.json`, with both
   hashes and the reference row) and keep `failure.json` for games that
   did not complete. Script-only, no gate change.
2. **Image and libc provenance.** `host.json` does not record the Docker
   image digest or the image's glibc version. The image tag
   `coworld-nav-budget:20260911` could be rebuilt without a tag change,
   and the cross-family determinism question is precisely about the
   libc the binaries call. Have the root-side step that writes
   `<family>-instance.json` add `docker image inspect --format
   '{{.Id}}'` for the tag, and let `run.py` add `getconf
   GNU_LIBC_VERSION` (or `ldd --version` first line) to `host.json`.
   Cheap, and it makes a platform finding attributable.
3. **The optional diagnostic pair is manual.** `RECORDING_NOTES.md`
   allows at most one original-256 versus candidate-256 pair per family
   on the first mismatching cell; `run.py` does not implement it, which
   is fine, but the note should name the exact invocation
   (`run_case.py` with `/candidate/server-256`, same config, same
   affinity mode, a `diagnostic/` subtree) so it is not improvised
   under a different lifecycle. The `/candidate/server-256` pin is
   already in `assets.json`, so the bytes are covered.
4. **Unpinned mode still pins the clients.** The server floats while
   presence clients sit on 6 and 7, so the server can share those CPUs
   with the clients. That matches the card and is a reasonable stand-in
   for the 1-CPU-request-no-limit shape, but it is a choice worth one
   sentence in the report, since production has no co-located presence
   processes.
5. Minor: the family verdict is written only when all 24 games
   complete; an earlier stop leaves `rows.json` without `verdict.json`,
   which is the intended "incomplete" state and should be reported as
   such.

No wrong case, order, affinity or budget; no accidental warmup or
discard; the m5a reference is valid and pinned; provenance is adequate
with the two cheap additions in finding 2. Finding 1 is the only item
that changes how a result reads.

PHASE 17 READY

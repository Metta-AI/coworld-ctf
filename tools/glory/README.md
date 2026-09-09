# GLORY GRADIENT — step 1 CENSUS tooling

Scripts used to produce `~/.ctf/knowledge/glory-gradient/01-census-2026-09-08.md`
(era: GloryVersion 15, coworld_version 0.7.361-0.7.367, rounds r4515-r4539 on
the Paintbot Season 2 ladder). Read-only against the live API; these scripts
never touch sim/scoring code.

## Pipeline

1. **`discover_cohort.py`** — walks `/v2/rounds` for a division backward
   (paged via `cursor`, NOT `next_cursor` — the field name that actually
   works; see script), fetches each round's episodes to read
   `coworld_version`, then resolves each distinct version's coworld_id to
   `manifest.game.runnable.source_url` (the exact git commit that build was
   compiled from). This is how a coworld_version buckets into a GloryVersion/
   GameVersion era: diff `src/ctf/glory.nim`+`src/ctf/sim_types.nim`+
   `src/ctf/sim.nim` between two candidate commits with `git diff`; if it's
   empty, they're the same scoring era even if the build number differs.
   Cohort boundaries must be OBSERVED this way, never inferred from the
   build-number sequence alone (GameVersion and GloryVersion each bump on
   their own schedule, independently of coworld_version).

2. **Build a matching `extract_events` per wire GameVersion the cohort
   spans.** A replay's wire format is source-baked; an extractor built at
   the wrong commit either refuses (GameVersion mismatch, caught by
   `ReplayCompatibleGameVersions`) or — more dangerously — RE-SIMULATES the
   replay through its OWN compiled economy and silently produces the WRONG
   glory reconstruction for an episode from a different GloryVersion era,
   even when the wire format is compatible. Build one extractor per
   (GameVersion, GloryVersion) pair the cohort spans, at a PERMANENT
   location (Nim bakes the source directory path into the binary at compile
   time — never build in `/tmp`, it can be swept mid-session and silently
   kill every future extraction):

   ```
   mkdir -p ~/.ctf/pipeline-loop/tools/census_<label>_build
   git -C <repo> archive <commit> | tar -x -C ~/.ctf/pipeline-loop/tools/census_<label>_build
   cd ~/.ctf/pipeline-loop/tools/census_<label>_build
   nimby sync nimby.lock -g
   nim c -d:release --hints:off -o:bin/extract_events tools/extract_events.nim
   ```

3. **`census_decode.py`** — downloads each episode's replay, extracts it
   with the version-appropriate binary, and reconstructs the recut product
   score per seat exactly as `sim.nim`/`glory.nim` fold it: seed 1, fold
   every `glory_deed` AND `achievement` event's `amount` field when it's
   `>1` (achievements fold into the SAME product — a bug that first pass
   dropped, caught by the reconciliation check below), divide by
   `2^(friendly-fire halvings)`, multiply by the win factor at finalize,
   cap at `2^24`. **Always validate against `participant_scores` before
   trusting anything else** — this run reconciled 4880/4880 (100%) seat
   episodes exactly; anything less means the extractor or the fold logic
   doesn't match the replay's real era.

4. **`census_analyze.py`** — reads the seat-episode rows and answers the
   five census questions (deed mint census, glory percentiles, cap-hit
   share, recipe share, LONGSHOT/ACETAG/WIPE/TAGBACK + heat rung
   occupancy).

## Heat reconstruction note

`sim.heatEmbers[team]` is TEAM state, not per-player, and in 16-solo BR a
team is one seat — but a downed-mode kill credit can mint AFTER its own
killer has already died (finalizeDowned prices the kill at the VICTIM's
bleed-out/splat tick, which can post-date the killer's own death tick).
Cutting the heat-occupancy window at the killer's own death silently drops
these delayed-finalize heat updates; `census_decode.py` uses the FULL
episode length as the occupancy denominator for exactly this reason
(verified directly: seat 2 of episode `ereq_b19bc577` died at tick 1754 but
minted a `dLongshotKill` — a heat-paying deed — at tick 1883).

## Rebuilding for a new era

`GloryVersion` moved to 16 / `GameVersion` to 61 on origin/main via PR #477
(merge 62fa0146, 2026-09-09 05:26:42Z) but was NOT live on any paintbot-v*
build as of this census (latest completed round confirmed still on
GloryVersion 15 / 0.7.367). Re-run `discover_cohort.py` before reusing any
of this against a later build — do not assume the extractors here still
match.

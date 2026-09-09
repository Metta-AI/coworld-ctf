# GLORY GRADIENT — step 1 CENSUS tooling

Scripts used to produce the census findings, landed in this repo at
[`docs/designs/glory/CENSUS-2026-09.md`](../../docs/designs/glory/CENSUS-2026-09.md)
(lane ledger copy: `~/.ctf/knowledge/glory-gradient/01-census-2026-09-08.md`)
(era: GloryVersion 15, coworld_version 0.7.361-0.7.367, rounds r4515-r4539 on
the Paintbot Season 2 ladder). Read-only against the live API; these scripts
never touch sim/scoring code.

## TRAP: a 0/N reconciliation means you dropped achievement events, not that the extractor is broken

**Symptom**: `census_decode.py`'s reconciliation check against the platform's
own `participant_scores` reports **0 of N seat-episodes matching** — every
single one, not a noisy subset. It looks like a totally broken extractor or
a wrong game version.

**Cause**: the recut product score is folded from **two separate event
catalogs into the SAME running product** — `glory_deed` events AND
`achievement` events (e.g. `treeSquad`'s "Clean Sheet", which mints
`amount=2` for every seat in every episode). A decode that only multiplies
`glory_deed` amounts into the product silently omits every achievement
factor. It does not error or warn — it just produces a per-seat total that
is wrong by a large, systematic multiplicative factor, so it fails to match
`participant_scores` for every seat-episode at once (hence 0/N, not a
partial mismatch).

**Fix**: fold `amount` from **both** `glory_deed` AND `achievement` events
into the same running product (see `census_decode.py`), whenever
`amount > 1`. This is what took this census's own first pass from 0/4,880
to 4,880/4,880 (100.00%) reconciled. **Never trust a decode's downstream
numbers until the reconciliation check passes at (or extremely near) 100%.**
A 0/N result is diagnostic, not just a failure — it is the specific
signature of this achievement-events omission, and the fastest way to
confirm it is to check whether achievement-catalog events are present in
the replay's event stream and being folded.

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

## S1 addendum — achievements (`census_achievements.py` / `_analyze.py`)

Re-walks the SAME cached replay extractions (no new download, no new
extractor) to split the census's single combined product into a
`deed_product` factor and an `ach_product` factor per seat-episode, and
tallies every `(tree, tier)` achievement mint. Full findings:
`docs/designs/glory/ACHIEVEMENTS-2026-09.md` (lane copy:
`~/.ctf/knowledge/glory-gradient/01b-achievements-addendum-2026-09-09.md`).
Headline: achievements supply ~60.3%/50.0% (mean/median) of log2-magnitude
population-wide but only ~18.0%/9.8% at the top decile — they dominate the
FLOOR (Clean Sheet mints for free in 100% of episodes), not the ceiling.

## S1b addendum — TOP-DECILE ATTRIBUTION (`attribution_decompose.py` / `_analyze.py`)

Full findings: `docs/designs/glory/TOP-ATTRIBUTION.md` (lane copy:
`~/.ctf/knowledge/glory-gradient/01c-top-attribution-2026-09-09.md`).

The census's own recipe/achievement figures answer "how much of the score
came from these NAMED deeds" but cannot answer "how much came from HEAT,
CARRY, ALLY-STACK or TERRITORY" — those are cross-cutting multipliers
folded INSIDE a deed's `amount` at mint time
(`glory.nim recutFactor` = `shiftedClass × heatMult × carryMult ×
stackMult`), not separable from the wire's `amount` field alone. Reading
them back out requires the live sim state at mint time (heat ember count,
territory site, carry flag, ally-stack k) — none of which is independently
recoverable from the replay wire by observation, and guessing at it risks
exactly the kind of confident-wrong attribution this investigation exists
to avoid.

**Method**: `attribution_decompose.py` reads an extra per-event field this
population's existing `.jsonl` extractions do NOT have: a
`"shiftedClass|heatMult|carryMult|stackMult"` breakdown string riding the
tier-2 `GloryDeed` event's existing (always `""` on the live path, never in
gameHash) `content` field. Producing it requires one ANALYSIS-ONLY,
NEVER-SHIPPED, NEVER-MERGED instrumentation line at the exact
`recutFactor` call site in a **private local copy** of `src/ctf/sim.nim`
(`awardDeed`, armed non-`dTeamKill` branch) — it stashes the sub-factors
that already produced `factor` into `content` before the existing
`emitEvent(GloryDeed, ...)` call. Zero sim/scoring behavior change (the
score math is untouched; only a debug string is added to an already-inert
analysis field), and it is never landed in this repo — built at a
permanent local path exactly like the census's own extractor binaries:

```
cp -R ~/.ctf/pipeline-loop/tools/census_gv59_gv15_build ~/.ctf/pipeline-loop/tools/attr_gv59_build
cp -R ~/.ctf/pipeline-loop/tools/census_gv60_build      ~/.ctf/pipeline-loop/tools/attr_gv60_build
# patch src/ctf/sim.nim's awardDeed (armed branch) to compute and stash:
#   attrShiftedClass = recutShiftedClass(deed, sitePct, sim.config.winAsMultiplier)
#   attrHeatMult/attrCarryMult/attrStackMult, mirroring recutFactor's own
#   control flow EXACTLY (a shiftedClass<=1 commons takes NO live-state
#   factor, matching recutFactor's early return) -- then pass
#   content = mintNote ("shiftedClass|heat|carry|stack") into the existing
#   emitEvent(GloryDeed, ...) call.
cd ~/.ctf/pipeline-loop/tools/attr_gv59_build && nim c -d:release --hints:off -o:bin/extract_events tools/extract_events.nim
cd ~/.ctf/pipeline-loop/tools/attr_gv60_build && nim c -d:release --hints:off -o:bin/extract_events tools/extract_events.nim
```

Then re-extract the SAME cached `.replay` files (no re-download) with the
instrumented binaries, and run:

```
python3 tools/glory/attribution_decompose.py \
    --rows seat_episode_rows_final.json \
    --attr-dir ~/.ctf/scout/glory_attr_replays \
    --out attribution_rows.json
python3 tools/glory/attribution_analyze.py --rows attribution_rows.json
```

**Validation**: per-event, `shiftedClass × heatMult × carryMult × stackMult`
is checked against the event's own `amount` (0 mismatches observed, 0
`UNRESOLVED`-bucket events across 4,880 seat-episodes); per seat-episode,
the SAME integer recombination method `census_decode.py` uses (fold
`amount`s, halve by FF incidents, multiply the win factor, cap at 2^24)
reconciles to the census's own already-validated `recon_final` for
**4,880/4,880 (100.00%)**. The resulting log2-magnitude bucket shares sum
to the row's own log2(final) with a **0.000% mean/median residual**
(ground-truth instrumentation, not statistical inference — there is
nothing left over to be uncertain about).

**`tests/test_zero_mint_reachability.nim`** (repo root, unmodified shipped
source, no private build needed): a standalone reachability probe against
the PURE `killDeed(ctx: KillContext): Deed` classifier
(`src/ctf/glory.nim`). Confirms `dSprayKill`/`dGrenadeKill`/`dEscortKill`
are all classifier-reachable at a real BR map's scaled point-blank/longshot
thresholds (`gunRange=331`, the live `br-golden-map.json` value) — their
zero-mint status in the census is BEHAVIOURAL (nobody landed that kill
shape), not a precedence dead-zone. Run with `nim r
tests/test_zero_mint_reachability.nim` from the repo root (needs
`tests/config.nims`'s `--path:"../src"`, already committed).

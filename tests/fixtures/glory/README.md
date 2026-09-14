# GV62 attribution replay cache (S6 gate fixture)

`gv62-attr-cache.tar.zst` is the CONTENT-populated GV62 attribution replay
cache `tools/glory/test_cohort_reconciliation.py`'s `test_s6_harness_proof`
needs to run the "S6 gate" — the harness reproducing the GLORY GRADIENT S6
re-measure exactly (`docs designs`/lane doc
`01e-gv62-cohort-attribution-2026-09-09.md`): **154 capped, top-decile
CHOSEN mean 72.26% / median 78.28%**, 5,456/5,456 reconciliation. Before
this fixture, that test **skipped** on a fresh checkout (no CI machine has
the private, never-committed cache it originally read from) — see
`tools/glory/README.md` §S1b and §"S1b addendum" for why that cache is
never committed as-is, and `tools/glory/README.md` "ERA KEYING" for why
GLORY GRADIENT S8 (#538) broke this gate once already by moving a
ported constant without era-keying it.

## What's inside

```
gv62_episodes.json      -- the 341 GV62 episodes' public API metadata
                            (episode_id, coworld_version, replay_url,
                            participant_scores, round_number) -- the exact
                            shape census_decode.py / cap_sweep.py expect.
attr_replays/*.jsonl     -- 341 per-episode wire-event extracts, ONE per
                            episode_id, with every glory_deed event's
                            `content` field populated
                            "classPct|heatPct|carryPct|stackPct"
                            (see tools/glory/era-patches/, below).
```

## Chosen sha, tag, and equivalence class

Regenerated at **`c90c7418`** (tag **`paintbot-v0.7.378`**), one named
representative of the equivalence class **`c90c7418`..`4fb7af8c`**
(`paintbot-v0.7.378`..`paintbot-v0.7.383`, GLORYVERSION 17 / GameVersion
62, glory catalog v3 default ON). `src/ctf/sim.nim`, `src/ctf/glory.nim`,
and `src/ctf/sim_types.nim` are **byte-identical across the whole class** —
verified directly:

```
git diff c90c7418 4fb7af8c -- src/ctf/sim.nim src/ctf/glory.nim src/ctf/sim_types.nim
# (empty)
```

— so any sha in the class scores identically; `c90c7418` was picked
because it is the earliest tagged commit in the class (closest, in the
repo's history, to `e6807465`/`paintbot-v0.7.377`, the actual build the
original S6 live re-measure ran against — see
`~/.ctf/knowledge/glory-gradient/00v-s6-remeasure-runbook.md`), and its
own tag (`paintbot-v0.7.378`) is directly citable from
`tools/glory/README.md` §S1b without any further disambiguation.

The equivalence class does NOT mean every file is unchanged between
`c90c7418` and `4fb7af8c` — PR #512 (`c90c7418` itself, "S4b achievements
-> lightable modes") added `achievementLightableModes`/`recutModeLitBonus`
to `glory.nim`/`sim.nim`/`sim_types.nim` relative to `e6807465`, but DARK
by default (config flag off, no GLORYVERSION bump), so the actual scoring
behavior on this cohort (which never armed that flag) is unaffected —
confirmed by this fixture's own reconciliation below.

## Instrumentation: a committed define + a committed per-era patch, never a private build dir

The `content` field is populated by
[`tools/glory/era-patches/c90c7418.patch`](../../../tools/glory/era-patches/c90c7418.patch),
re-targeted at `c90c7418` from the same ANALYSIS-ONLY instrumentation
`tools/glory/README.md`'s "S1b addendum" already documents for the
pre-v3/GV59-GV60 call path — recovered here by diffing two private local
build dirs from an earlier run of this same recipe (targeted one commit
earlier, at `e6807465`):

```
diff -u ~/.ctf/pipeline-loop/tools/s6_gv62_build/src/ctf/sim.nim \
        ~/.ctf/pipeline-loop/tools/s6_gv62_attr_build/src/ctf/sim.nim
```

The patch stashes the v3 percent-scaled sub-factors
(`classPct|heatPct|carryPct|stackPct`) into `GloryDeed`'s always-`""`
`content` field at the `awardDeed` call site, targeting the CATALOG-V3 path
(`recutShiftedClassV3Pct`/`heatMultV3Pct`/`recutStackMultV3Pct`/
`CarrierHoldMultPct`) — zero sim/scoring behavior change, read-only. It is
never committed to `src/ctf/` itself; the patch file is the shipped
artifact, applied at build time against a throwaway `git archive` checkout,
never against this repo's own worktree.

## Exact regeneration command

```
mkdir -p /tmp/cr/build
git archive c90c7418 | tar -x -C /tmp/cr/build
git -C /tmp/cr/build apply --check tools/glory/era-patches/c90c7418.patch   # must be clean
git -C /tmp/cr/build apply tools/glory/era-patches/c90c7418.patch
cd /tmp/cr/build
nimby sync nimby.lock -g
nim c -d:release --hints:off -o:bin/extract_events tools/extract_events.nim

# re-extract the 341 GV62 episodes' cached .replay bytes (episode_id list +
# participant_scores from gv62_episodes.json above; the .replay bytes
# themselves are immutable once an episode completes and were already
# fetched by this pipeline's earlier S6 run via the public,
# read-only `replay_url` per episode -- no re-download was needed here) --
# for each episode_id:
/tmp/cr/build/bin/extract_events <cache>/<episode_id>.replay --out attr_replays/<episode_id>.jsonl

tar -cf - gv62_episodes.json attr_replays | zstd -19 -T0 -o gv62-attr-cache.tar.zst
```

## Provenance: the cross-check IS the statement

The regenerated cache is verified against the OLD, never-committed private
artifact (`~/.ctf/knowledge/glory-gradient/00w-s6-remeasure-raw/attr_replays`,
341 `.jsonl`, 34 MB — a CROSS-CHECK ONLY, never itself committed) via
`tools/glory/census_decode.py --catalog v3` (reconciliation) and
`tools/glory/cap_sweep.py --harness-proof` (the packaged, byte-for-byte
equivalent of the original `attribution_decompose.py --catalog v3` +
manual HANDED/CONSTANT/CHOSEN reclassification `01e-gv62-cohort-
attribution-2026-09-09.md` used — see that script's own docstring for the
byte-for-byte equivalence claim). **Every number matches exactly:**

| check | old artifact (private) | this fixture (regenerated at `c90c7418`) |
|---|---:|---:|
| reconciliation (`census_decode.py --catalog v3`) | 5,456/5,456 | 5,456/5,456 |
| capped rows (cap=2^24 internal) | 154 | 154 |
| top-decile n (p90 threshold=24) | 555 | 555 |
| top-decile CHOSEN mean | 72.26% | 72.26% |
| top-decile CHOSEN median | 78.28% | 78.28% |
| top-decile CHOSEN (clean) mean / median | 84.89% / 98.83% | 84.89% / 98.83% |
| mid-band [4,256] CHOSEN mean / median | 62.06% / 67.01% | 62.06% / 67.01% |

That exact agreement, reproduced from a NAMED, re-buildable commit plus a
committed patch file — not from the private build dir the original S6
measurement used — **is the provenance statement**: this fixture is not a
new measurement, it is a reproduction of an already-measured, already-
published result, now independent of any one machine's `~/.ctf/` state.

## Compression

`zstd -19` (the CI runner, `ubuntu-latest`, ships `zstd` — confirmed
against the `actions/runner-images` Ubuntu 24.04 software manifest, and
`.github/workflows/build.yml` needs no extra install step): 34.1 MiB ->
1.47 MiB. This roughly doubles `tests/fixtures/`'s prior total (~1.4-1.5
MB before this fixture) — accepted, per the lead's ruling, as the cost of
running the S6 gate in CI instead of skipping it on every checkout that
lacks a private `~/.ctf/` cache.

- File: `tests/fixtures/glory/gv62-attr-cache.tar.zst`
- Size: 1,540,577 bytes (1.47 MiB)
- sha256: `251aea20a730a1fc7bb7c1f8f2333e08107eabd11c71f56138ef7014b6438f01`

## Consumer

`tools/glory/test_cohort_reconciliation.py`'s `test_s6_harness_proof`
decompresses this archive to a temp directory (`zstd -dc | tar -x`,
cleaned up automatically) and runs the same `cap_sweep.py` harness-proof
checks against it whenever the private, never-committed cache
(`~/.ctf/knowledge/glory-gradient/00w-s6-remeasure-raw/attr_replays`) is
absent — which is always true in CI, and true on any dev machine that
hasn't run the S6 pipeline by hand. See `tools/glory/README.md` §S1b for
the general instrumentation recipe this fixture is one frozen instance of.

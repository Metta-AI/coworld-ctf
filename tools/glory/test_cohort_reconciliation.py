#!/usr/bin/env python3
"""GLORY GRADIENT — THE ERA-KEYING GATE: re-fold three real cohorts,
spanning the GLORYVERSION 17 -> 18 boundary, and pin each one's
reconciliation count exactly.

WHY THIS FILE EXISTS. `catalog_fold.py` is a LIVE PORT of
`src/ctf/glory.nim` and, at the same time, the BACKWARD DECODER for every
cohort already recorded. GLORY GRADIENT S8 (#538, sha 1b92ec46) moved two
ported constants -- `RecutProductCapArmed` 2**24 -> 2**31 and
`RecutPlacementRampPct` 100/100/130 -> 115/130/160 -- by repointing the
literals, which silently broke the backward decode: the GV62 (S6) census
fell from 5,456/5,456 to 5,302/5,456, because the 154 rows the S6-era
engine had actually SATURATED at the old ceiling (16,384 reported) no
longer saturate under the new one. The S6 gate ("the harness must reproduce
S6 exactly: 154 capped, top-decile CHOSEN 72.26%") could not be run from
main at all between #538 and the era-keying fix.

`test_catalog_fold.py` holds the fast, self-contained unit form of that
regression (and the glory.nim<->HEAD-alias tripwire). THIS file is the
end-to-end form: real recorded wire data, three eras, exact counts.

  GV61  11,984 / 11,984  (v2 fold, rounds r4552-r4609)
  GV62   5,456 /  5,456  (v3 fold, GLORYVERSION 17, rounds r4611-r4635)
                          -- 5,302/5,456 on main between #538 and the fix
  GV63   1,439 /  1,440  (v3 fold, GLORYVERSION 18, rounds r4828-r4833)

The ONE GV63 residual is NOT this file's bug and NOT era-related: episode
`ereq_1d480c9f-7939-44be-bd6f-774dbb3c9cb3` slot 14, reported 2,472 vs
recon 1,545 (ratio 0.625), no `achModeLit` on the seat, isolated. It is a
separate open investigation; it is pinned BY NAME below so it cannot
quietly become two.

DATA. Local-only caches, same convention `test_cap_sweep.py`'s harness-proof
golden already documents for this directory: each cohort SKIPS (never
fails) when its cache is absent, so a fresh checkout without the replay
cache still runs this file clean. No tools/glory test is wired into CI
except the stdlib-only `test_catalog_fold.py`; this one is a local,
on-demand gate. Rebuild a missing cohort cache with
`tools/glory/census_decode.py` (see tools/glory/README.md) -- the GV63 one
needs an `extract_events` built at a GameVersion-63 commit:
  nim c -d:release --hints:off -o:bin/extract_events tools/extract_events.nim

Run: python3 tools/glory/test_cohort_reconciliation.py
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import catalog_fold  # noqa: E402
import census_decode  # noqa: E402

FAILURES = []
SKIPPED = []

DATA = os.path.expanduser("~/.ctf/knowledge/glory-gradient/data")
SCOUT = os.path.expanduser("~/.ctf/scout")

# (name, episodes json, jsonl cache dir, catalog label, expected ok,
#  expected total, expected residual episode/slot rows)
COHORTS = (
    ("GV61", f"{DATA}/gv61/gv61_episodes.json", f"{SCOUT}/glory_gv61_replays",
     "v2", 11984, 11984, ()),
    ("GV62", f"{DATA}/gv62/gv62_episodes.json", f"{SCOUT}/glory_census_replays",
     "v3", 5456, 5456, ()),
    ("GV63", f"{DATA}/gv63/gv63_episodes.json", f"{SCOUT}/glory_gv63_replays",
     "v3", 1439, 1440,
     (("ereq_1d480c9f-7939-44be-bd6f-774dbb3c9cb3", 14),)),
)

# The S6 harness proof's own cohort + the CONTENT-populated replay cache
# its HANDED/CONSTANT/CHOSEN decomposition needs (see cap_sweep.py's
# docstring: the plain extract cache gives correct reported/capped but
# every deed leg lands in UNRESOLVED).
S6_EPISODES = f"{DATA}/gv62/gv62_episodes.json"
S6_ATTR_DIR = os.path.expanduser(
    "~/.ctf/knowledge/glory-gradient/00w-s6-remeasure-raw/attr_replays")


def check(name, cond):
    print(f"  [{'ok' if cond else 'FAIL'}] {name}")
    if not cond:
        FAILURES.append(name)


def skip(name, why):
    print(f"  [skip] {name}: {why}")
    SKIPPED.append(name)


def reconcile(episodes_path, cache_dir, catalog):
    """recon_final == reported, per seat-episode, over a whole cohort.

    Note what is NOT passed: no era, no cap, no `--glory-version`. Each
    episode's era is derived from its OWN `coworld_version`
    (catalog_fold.glory_version_for_build) inside `analyze_episode` -- that
    derivation is the thing under test."""
    with open(episodes_path) as f:
        episodes = json.load(f)
    n = ok = 0
    misses = []
    for ep in episodes:
        jp = os.path.join(cache_dir, ep["episode_id"] + ".jsonl")
        if not os.path.exists(jp):
            continue
        rows, _summary = census_decode.analyze_episode(ep, jp, catalog=catalog)
        for r in rows:
            n += 1
            if r["reported"] == r["recon_final"]:
                ok += 1
            else:
                misses.append(r)
    return n, ok, misses


def test_cohort(name, episodes_path, cache_dir, catalog, want_ok, want_n,
                 want_residual):
    print(f"test_cohort_{name}")
    if not os.path.exists(episodes_path) or not os.path.isdir(cache_dir):
        skip(name, f"local cohort cache absent ({episodes_path} / {cache_dir})")
        return
    n, ok, misses = reconcile(episodes_path, cache_dir, catalog)
    check(f"{name}: {want_n} seat-episode rows decoded (got {n})", n == want_n)
    check(f"{name}: recon == reported on {want_ok}/{want_n} (got {ok}/{n})",
          ok == want_ok and n == want_n)
    residual = tuple(sorted((m["episode_id"], m["slot"]) for m in misses))
    check(f"{name}: the ONLY unreconciled rows are the known, named ones "
          f"{want_residual} (got {residual})",
          residual == tuple(sorted(want_residual)))
    # Every era this cohort spans must resolve -- a cohort that straddles a
    # boundary is exactly where a HEAD-keyed constant hides.
    with open(episodes_path) as f:
        eras = sorted({catalog_fold.glory_version_for_build(e["coworld_version"])
                       for e in json.load(f)})
    print(f"  [info] {name} spans GLORYVERSION {eras}")


def test_s6_harness_proof():
    """The gate #538 took away: the harness reproducing S6 EXACTLY.

    Kept in this file (not `test_catalog_fold.py`) because it needs the
    content-populated GV62 attribution cache. Manual equivalent:
      python3 tools/glory/cap_sweep.py --harness-proof \\
        --episodes ~/.ctf/knowledge/glory-gradient/data/gv62/gv62_episodes.json \\
        --jsonl-dir ~/.ctf/knowledge/glory-gradient/00w-s6-remeasure-raw/attr_replays
    """
    print("test_s6_harness_proof")
    if not os.path.exists(S6_EPISODES) or not os.path.isdir(S6_ATTR_DIR):
        skip("S6 harness proof", "content-populated GV62 attr cache absent")
        return
    import cap_sweep  # noqa: E402  (only needed on this path)
    with open(S6_EPISODES) as f:
        episodes = json.load(f)
    rows = cap_sweep.run_cell(episodes, S6_ATTR_DIR,
                               cap_sweep.cap_bits_to_internal(14), s4b_armed=False)
    check("S6: 5,456 rows", len(rows) == 5456)
    check("S6: 154 capped", sum(1 for r in rows if r["capped"]) == 154)
    scores = sorted(r["reported"] for r in rows if r["reported"])
    p90 = cap_sweep.percentile(scores, 0.90)
    top = [r for r in rows if r["reported"] and r["reported"] >= p90]
    check("S6: top decile n=555 at threshold 24", p90 == 24 and len(top) == 555)
    stats = cap_sweep.bucket_share_stats(top)
    check(f"S6: top-decile CHOSEN mean 72.26% (got {stats['chosen_mean']:.2f}%)",
          abs(stats["chosen_mean"] - 72.26) < 0.01)
    check(f"S6: top-decile CHOSEN median 78.28% (got {stats['chosen_median']:.2f}%)",
          abs(stats["chosen_median"] - 78.28) < 0.01)


def main():
    for cohort in COHORTS:
        test_cohort(*cohort)
    test_s6_harness_proof()

    if SKIPPED:
        print(f"\n{len(SKIPPED)} skipped (cache absent): {SKIPPED}")
    if FAILURES:
        print(f"\n{len(FAILURES)} FAILURE(S): {FAILURES}")
        sys.exit(1)
    print("\nall checks passed")


if __name__ == "__main__":
    main()

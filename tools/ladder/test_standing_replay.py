#!/usr/bin/env python3
"""Fixture tests for standing_replay.py (stdlib + pytest, no network).

Run: python3 -m pytest tools/ladder/test_standing_replay.py -q
(or directly: python3 tools/ladder/test_standing_replay.py)

`testdata/standing_fixture.json` is the first 15 rounds (r4257-r4271) of the
real Paintbot S2 ledger pulled 2026-09-08 (`standing_replay.py pull --since
4257`, cached via /v2/rounds + /v2/rounds/{id}/episodes). The golden values
below were produced by replaying that exact fixture under the CURRENT served
config (rated_k=0.05, rated_clamp_multiple=150, sum_top_k=12, raw transform)
and pinned so a change to the replay math shows up as a failing assert
instead of a silent drift.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import standing_replay as sr  # noqa: E402

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "testdata", "standing_fixture.json")


def _load_fixture():
    with open(FIXTURE) as f:
        return json.load(f)


def _current_history(rounds):
    return sr.replay_setting(rounds, **{k: sr.CURRENT[k] for k in
                                         ("rated_k", "clamp_M", "top_k",
                                          "transform", "episode_mode")})


def test_fixture_shape():
    fx = _load_fixture()
    assert len(fx["rounds"]) == 15
    assert fx["rounds"][0]["round_number"] == 4257
    assert fx["rounds"][-1]["round_number"] == 4271
    # every round in this fixture must actually carry legs, or the replay
    # is trivially testing nothing
    assert all(r["legs"] for r in fx["rounds"])


def test_replay_reproduces_fixture_standings_exactly():
    """Pinned golden values from the CURRENT served config, replayed on the
    real 15-round fixture. A change to the EMA/clamp/top-k math must change
    these numbers — if it doesn't, the change didn't touch the hot path."""
    fx = _load_fixture()
    history, _ = _current_history(fx["rounds"])
    rnum, final = history[-1]
    assert rnum == 4271

    golden = {
        "ply_5b832230-f519-4af8-adda-bb3e02349b7d": 7350679.691830576,
        "ply_0efb1bf5-a940-40d8-bd04-710b24bb115a": 5991088.830960647,
        "ply_44ae9048-3242-4654-881f-6d9d43347fa3": 1867475.9915811645,
        "ply_176e1e1a-7af8-40f7-9ee3-a67b96690ad6": 1506085.3080379954,
        "ply_93209bc9-3d3d-4235-8ff4-89f10d82a3c2": 1137767.857856915,
        "ply_423c2b89-dcbe-4cf4-bb9f-f38c025762cd": 729519.2782128792,
    }
    for pid, expected in golden.items():
        assert pid in final, f"{pid} missing from replayed standings"
        rel_err = abs(final[pid] - expected) / expected
        assert rel_err < 1e-9, f"{pid}: {final[pid]} != {expected} (rel_err {rel_err})"

    # order matters too, not just magnitude
    order = [pid for pid, _ in sorted(final.items(), key=lambda kv: -kv[1])]
    assert order[:6] == list(golden.keys())


def test_clamp_bounds_the_single_round_move():
    """r4258 in the fixture carries a real 2^24 (16,777,216) capped leg for
    `ply_bac48eb1...` — the single biggest leg in the 253-round pull this
    fixture is sliced from (docs/designs/STANDING_SWEEP.md). The clamp bounds
    that ONE round's multiple on standing to `1 + k*(M-1)`
    (ctf-k-retune-cannot-bound-a-ratings-spike.md); confirm the live code
    matches the closed form, and that a tighter M gives a tighter bound —
    NOT that a tighter M ends up lower after many more rounds (a tight clamp
    also floors round-over-round *drops*, so which side wins after 15 rounds
    of mixed swings is not monotonic in M — that was this test's original,
    wrong assumption, caught by the fixture)."""
    fx = _load_fixture()
    pid = "ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"
    k = 0.05

    for M in (2, 10, 150):
        history, _ = sr.replay_setting(fx["rounds"], rated_k=k, clamp_M=M,
                                        top_k=12, transform="raw",
                                        episode_mode="current")
        before = dict(history[0][1])  # standing after r4257 (index 0)
        after = dict(history[1][1])   # standing after r4258 (the cap round)
        multiple = after[pid] / before[pid]
        bound = 1 + k * (M - 1)
        assert multiple <= bound + 1e-9, f"M={M}: multiple {multiple} > bound {bound}"

    # and the bound itself must actually tighten as M shrinks
    assert (1 + k * (2 - 1)) < (1 + k * (10 - 1)) < (1 + k * (150 - 1))


def test_rank_points_transform_is_bounded():
    """rank_points caps every entrant's per-round contribution at 25 points,
    however large the raw legs are — sanity-checks the F1-style table doesn't
    leak raw magnitude through."""
    fx = _load_fixture()
    history, contributions = sr.replay_setting(fx["rounds"], rated_k=0.05,
                                                clamp_M=150, top_k=12,
                                                transform="rank_points",
                                                episode_mode="current")
    for pid, points in contributions.items():
        for _, clipped in points:
            assert 0 <= clipped <= 25


if __name__ == "__main__":
    test_fixture_shape()
    test_replay_reproduces_fixture_standings_exactly()
    test_clamp_bounds_the_single_round_move()
    test_rank_points_transform_is_bounded()
    print("all standing_replay.py fixture tests passed "
          f"({FIXTURE}: 15-round real ledger slice, r4257-r4271)")

#!/usr/bin/env python3
"""R3 = win gate on the RAW rule (2026-09-15) -- today's R0 exactly (raw
legs, sum-of-top-12, clip(s/150, s*150) except first round, EMA) with the
win gate applied to the raw legs BEFORE any transform (loser leg = 0, draws
bank in full) and NO log transform. Same window as R2
(r4828-r5077, GameVersion 63/GLORYVERSION 18). Answers the owner's
revertibility question: R3 needs no season_leg_transform migration (stays
"none"), unlike R2 -- this quantifies what that trade costs in stability.

Also instruments "the clamp leak": `rated_clamp_multiple=150` floors a
zeroed (fully-lost) round score UP to `standing/150` for any subject past
its first round, rather than letting it hit 0 -- `replay()`'s own clamp
branch (tools/ladder/standing_replay.py, the `elif clamp_M:` branch) does
this unconditionally; this script does not change that function, it just
mirrors its exact math locally to additionally COUNT how often the floor
binds (`replay()` itself only returns the post-clip `clipped` value, not
whether the floor was the active bound).

Usage: `python3 standing_sweep_r3_raw_gate.py` (reads
/tmp/standing-sweep/{ledger_gated,winner_map}.json; writes
/tmp/standing-sweep/r3_raw_gate_results.json).
"""
import json
import random
import statistics
import sys

sys.path.insert(0, ".")
import standing_replay as sr
import standing_sweep_win_gated as swg

LEDGER_PATH = "/tmp/standing-sweep/ledger_gated.json"
WINNER_MAP_PATH = "/tmp/standing-sweep/winner_map.json"
OUT_PATH = "/tmp/standing-sweep/r3_raw_gate_results.json"

KS = [0.02, 0.025, 0.05]


def replay_with_clamp_diagnostics(rounds, rated_k, clamp_M, top_k, transform, episode_mode):
    """Exact mirror of standing_replay.replay()'s update loop (unchanged
    math, verified line-for-line against tools/ladder/standing_replay.py's
    `replay()`), instrumented to also count how often the clamp's LOWER
    bound (`lo = s/clamp_M`) is the active constraint -- i.e. the round
    score itself (post-gate, pre-clip) was BELOW the floor."""
    rng = random.Random(0)
    standing = {}
    history = []
    contributions = {}
    total_clamp_eligible = 0
    floor_binds = 0
    floor_ratios = []
    for r in rounds:
        round_scores = sr._round_scores_for_round(r, top_k, transform, episode_mode, rng)
        for pid, score in round_scores.items():
            s = standing.get(pid)
            if s is None or s == 0.0:
                clipped = score
            elif clamp_M:
                lo, hi = s / clamp_M, s * clamp_M
                if lo > hi:
                    lo, hi = hi, lo
                clipped = min(max(score, lo), hi)
                total_clamp_eligible += 1
                if score < lo:
                    floor_binds += 1
                    floor_ratios.append(clipped / s)
            else:
                clipped = score
            new_s = (clipped if s is None else s + rated_k * (clipped - s))
            standing[pid] = new_s
            contributions.setdefault(pid, []).append((r["round_number"], clipped))
        history.append((r["round_number"], dict(standing)))
    return history, contributions, {
        "total_clamp_eligible": total_clamp_eligible, "floor_binds": floor_binds,
        "floor_bind_frac": (floor_binds / total_clamp_eligible) if total_clamp_eligible else None,
        "floor_ratio_median": statistics.median(floor_ratios) if floor_ratios else None,
        "floor_ratio_min": min(floor_ratios) if floor_ratios else None,
        "floor_ratio_max": max(floor_ratios) if floor_ratios else None,
    }


def rank1_rank5_ratio_series(history, transform):
    ratios = []
    for _, standing in history:
        vals = sorted(standing.values(), reverse=True)
        if len(vals) >= 5:
            r1 = sr.inverse_transform(vals[0], transform)
            r5 = sr.inverse_transform(vals[4], transform)
            if r5 > 0:
                ratios.append(r1 / r5)
    return ratios


def run(rounds, k, clamp_M, names, win_counts):
    setting = dict(rated_k=k, clamp_M=clamp_M, top_k=12, transform="raw", episode_mode="current")
    history, contributions, clamp_diag = replay_with_clamp_diagnostics(rounds, **setting)
    stab = sr.stability_metrics(history)
    share = sr.leader_best_round_share(history, contributions, rated_k=k)
    _, final = history[-1]
    vals = sorted(final.values())
    ratios = rank1_rank5_ratio_series(history, "raw")
    table = swg.top16_table(history, contributions, "raw", names, win_counts)[:5]
    return {
        "k": k, "clamp_M": clamp_M,
        "tau_mean": stab["tau_mean"], "tau_p10": stab["tau_p10"],
        "leader_changes_per_50": stab["leader_changes_per_50"],
        "leader_best_round_share": share,
        "standing_scale": {"median": vals[len(vals) // 2] if vals else None,
                            "top": vals[-1] if vals else None, "n_players": len(vals)},
        "rank1_rank5_ratio_raw": {
            "median": statistics.median(ratios) if ratios else None,
            "p10": sorted(ratios)[max(0, int(len(ratios) * 0.10) - 1)] if ratios else None,
            "p90": sorted(ratios)[min(len(ratios) - 1, int(len(ratios) * 0.90))] if ratios else None,
            "final": (sorted(final.values(), reverse=True)[0] / sorted(final.values(), reverse=True)[4])
                     if len(final) >= 5 else None,
        },
        "clamp_diagnostics": clamp_diag,
        "top5": table,
    }


def main():
    ledger = sr.load_ledger(LEDGER_PATH)
    rounds = ledger["rounds"]
    with open(WINNER_MAP_PATH) as f:
        winner_map = json.load(f)["winner_map"]
    gated_ledger, gate_stats = sr.gate_ledger_by_win(ledger, winner_map)
    gated_rounds = gated_ledger["rounds"]
    names = swg.name_map(rounds)
    win_counts = swg.compute_win_counts(rounds, winner_map)

    results = {"window": {"since": rounds[0]["round_number"], "until": rounds[-1]["round_number"],
                           "n_rounds": len(rounds)},
               "gate_stats": gate_stats, "with_clamp": {}, "no_clamp": {}}

    for k in KS:
        results["with_clamp"][str(k)] = run(gated_rounds, k, 150.0, names, win_counts)
        results["no_clamp"][str(k)] = run(gated_rounds, k, None, names, win_counts)

    # R2 comparison point (signed_log2 + gate, k=0.02) for the "does the
    # gate alone deliver stability, or does the log still do the work"
    # question -- same gated_rounds, same window, transform swapped.
    r2_hist, r2_contrib = sr.replay_setting(gated_rounds, rated_k=0.02, clamp_M=150.0,
                                             top_k=12, transform="signed_log2", episode_mode="current")
    r2_stab = sr.stability_metrics(r2_hist)
    r2_share = sr.leader_best_round_share(r2_hist, r2_contrib, rated_k=0.02)
    r2_ratios = rank1_rank5_ratio_series(r2_hist, "signed_log2")
    results["R2_comparison_k0.02"] = {
        "tau_mean": r2_stab["tau_mean"], "leader_changes_per_50": r2_stab["leader_changes_per_50"],
        "leader_best_round_share": r2_share,
        "rank1_rank5_ratio_raw": {
            "median": statistics.median(r2_ratios) if r2_ratios else None,
            "p10": sorted(r2_ratios)[max(0, int(len(r2_ratios) * 0.10) - 1)] if r2_ratios else None,
            "p90": sorted(r2_ratios)[min(len(r2_ratios) - 1, int(len(r2_ratios) * 0.90))] if r2_ratios else None,
        },
    }

    with open(OUT_PATH, "w") as f:
        json.dump(results, f, indent=2, default=str)

    for cond in ("with_clamp", "no_clamp"):
        for k in KS:
            m = results[cond][str(k)]
            cd = m["clamp_diagnostics"]
            r15 = m["rank1_rank5_ratio_raw"]
            print(f"{cond} k={k}: tau={m['tau_mean']:.4f} chg/50={m['leader_changes_per_50']:.2f} "
                  f"share={m['leader_best_round_share']:.4f} "
                  f"median_raw={m['standing_scale']['median']:.2f} top_raw={m['standing_scale']['top']:.2f} "
                  f"rank1/5 ratio median={r15['median']:.2f} [{r15['p10']:.2f},{r15['p90']:.2f}] "
                  f"floor_bind_frac={cd['floor_bind_frac']} floor_ratio_median={cd['floor_ratio_median']}")
    r2c = results["R2_comparison_k0.02"]
    print(f"\nR2 k=0.02 (signed_log2+gate): tau={r2c['tau_mean']:.4f} "
          f"chg/50={r2c['leader_changes_per_50']:.2f} share={r2c['leader_best_round_share']:.4f} "
          f"rank1/5 ratio median={r2c['rank1_rank5_ratio_raw']['median']:.2f} "
          f"[{r2c['rank1_rank5_ratio_raw']['p10']:.2f},{r2c['rank1_rank5_ratio_raw']['p90']:.2f}]")
    print(f"\nwrote {OUT_PATH}")


if __name__ == "__main__":
    main()

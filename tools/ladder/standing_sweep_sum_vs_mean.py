#!/usr/bin/env python3
"""Sum-vs-mean close-out for arming flag (a) (2026-09-15).

`docs/designs/STANDING_SWEEP.md`'s "Win-gated extension" section flagged,
without resolving: under a log-domain transform, `round_scoring_rule:
"sum"` sums log2-bits legs, which is equivalent to taking log2 of the
PRODUCT of the underlying raw legs -- not a typical leg's size. This script
re-runs R2 (signed_log2, k=0.02, win-gated) with `agg="mean"` (divide by
the number of legs kept) instead of `agg="sum"` on the SAME win-gate
window and reports both side by side, plus the number that decides it: the
median rank1-vs-rank5 standing gap in bits, and how often a subject wins
>=2 episodes in one round (the ONLY case sum and mean can disagree on).

Usage: `python3 standing_sweep_sum_vs_mean.py` (reads
/tmp/standing-sweep/{ledger_gated,winner_map}.json; writes
/tmp/standing-sweep/sum_vs_mean_results.json).
"""
import json
import statistics
import sys

sys.path.insert(0, ".")
import standing_replay as sr
import standing_sweep_win_gated as swg

LEDGER_PATH = "/tmp/standing-sweep/ledger_gated.json"
WINNER_MAP_PATH = "/tmp/standing-sweep/winner_map.json"
OUT_PATH = "/tmp/standing-sweep/sum_vs_mean_results.json"

R2_SETTING = dict(sr.CURRENT, transform="signed_log2", rated_k=0.02)


def rank1_rank5_gap_series(history):
    """Per-round (rank1_standing - rank5_standing), skipping rounds with
    fewer than 5 standings (early cold-start)."""
    gaps = []
    for _, standing in history:
        vals = sorted(standing.values(), reverse=True)
        if len(vals) >= 5:
            gaps.append(vals[0] - vals[4])
    return gaps


def multi_win_round_count(rounds, winner_map):
    """How many (player, round) pairs have that player winning >=2
    episodes in the SAME round -- exactly the case sum (adds every log2'd
    win) and mean (divides by legs kept) can disagree on."""
    count = 0
    total_player_rounds = 0
    for r in rounds:
        wins_this_round = {}
        for ep in sr._cached_episodes(r["round_id"]):
            if ep.get("status") != "completed":
                continue
            summ = winner_map.get(ep.get("episode_id"))
            if summ is None:
                continue
            winner_team = summ.get("winner")
            draw = bool(summ.get("draw"))
            if draw or not winner_team:
                continue
            slot_team = summ.get("slot_team") or []
            for p in ep.get("participants") or []:
                if p.get("is_filler"):
                    continue
                pos = p.get("position")
                pid = p.get("player_id")
                if pos is None or pid is None or pos >= len(slot_team):
                    continue
                if slot_team[pos] == winner_team:
                    wins_this_round[pid] = wins_this_round.get(pid, 0) + 1
        total_player_rounds += len(r["legs"])
        count += sum(1 for v in wins_this_round.values() if v >= 2)
    return count, total_player_rounds


def run(rounds, agg, names, win_counts):
    setting = dict(R2_SETTING)
    history, contributions = sr.replay_setting(rounds, agg=agg, **setting)
    stab = sr.stability_metrics(history)
    share = sr.leader_best_round_share(history, contributions, rated_k=setting["rated_k"])
    gaps = rank1_rank5_gap_series(history)
    _, final = history[-1]
    vals = sorted(final.values())
    median_disp, top_disp = statistics.median(vals), vals[-1]
    table = swg.top16_table(history, contributions, setting["transform"], names, win_counts)[:5]
    return {
        "agg": agg, "tau_mean": stab["tau_mean"], "tau_p10": stab["tau_p10"],
        "leader_changes_per_50": stab["leader_changes_per_50"],
        "leader_best_round_share": share,
        "standing_scale": {
            "median_displayed": median_disp, "top_displayed": top_disp,
            "median_unlogged": sr.inverse_transform(median_disp, setting["transform"]),
            "top_unlogged": sr.inverse_transform(top_disp, setting["transform"]),
        },
        "rank1_rank5_gap_bits": {
            "median": statistics.median(gaps) if gaps else None,
            "p10": sorted(gaps)[max(0, int(len(gaps) * 0.10) - 1)] if gaps else None,
            "p90": sorted(gaps)[min(len(gaps) - 1, int(len(gaps) * 0.90))] if gaps else None,
            "n_rounds": len(gaps),
            "final_round_gap": (sorted(final.values(), reverse=True)[0] -
                                 sorted(final.values(), reverse=True)[4]) if len(final) >= 5 else None,
        },
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

    sum_result = run(gated_rounds, "sum", names, win_counts)
    mean_result = run(gated_rounds, "mean", names, win_counts)
    multi_count, total_pr = multi_win_round_count(rounds, winner_map)

    out = {
        "window": {"since": rounds[0]["round_number"], "until": rounds[-1]["round_number"],
                   "n_rounds": len(rounds)},
        "setting": R2_SETTING, "gate_stats": gate_stats,
        "sum": sum_result, "mean": mean_result,
        "multi_win_round_count": multi_count,
        "total_player_round_pairs": total_pr,
        "multi_win_round_frac": multi_count / total_pr if total_pr else None,
    }
    with open(OUT_PATH, "w") as f:
        json.dump(out, f, indent=2, default=str)

    print(f"multi-win rounds: {multi_count}/{total_pr} player-round pairs "
          f"({100*multi_count/total_pr:.3f}%)")
    for label, r in (("sum", sum_result), ("mean", mean_result)):
        g = r["rank1_rank5_gap_bits"]
        print(f"{label}: tau={r['tau_mean']:.4f} chg/50={r['leader_changes_per_50']:.2f} "
              f"share={r['leader_best_round_share']:.4f} "
              f"median_disp={r['standing_scale']['median_displayed']:.3f} "
              f"top_disp={r['standing_scale']['top_displayed']:.3f} "
              f"rank1-5 gap median={g['median']:.3f} [{g['p10']:.3f},{g['p90']:.3f}] "
              f"final={g['final_round_gap']:.3f}")
    print(f"wrote {OUT_PATH}")


if __name__ == "__main__":
    main()

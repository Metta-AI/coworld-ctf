#!/usr/bin/env python3
"""R0/R1 reproduction check (2026-09-14 win-gate sweep, step 1 of the task).

Before trusting any win-gated (R2) number, this replays the ORIGINAL
253-round doc ledger (r4257-r4526, `docs/designs/STANDING_SWEEP.md`) under
two rules and diffs the result against that doc's own published numbers:

  R0 -- TODAY: raw legs, EMA k=0.05 (`standing_replay.CURRENT`) -- must
        match the doc's "Current-setting metrics" table.
  R1 -- STEP A AS DECIDED: per-leg `signed_log2`, EMA k=0.025 -- must match
        the doc's "Rate sweep extension" `log2 + rated_k=0.025` row. Also
        confirms `signed_log2` is numerically IDENTICAL to the doc's plain
        `log2` transform on THIS ledger (true iff no leg is negative here,
        checked directly rather than assumed).

Usage: `python3 standing_sweep_reproduction_check.py` (reads
/tmp/standing-sweep/ledger.json, written by
`standing_replay.py pull --since 4257 --until 4526`; writes
/tmp/standing-sweep/reproduction_check.json).
"""
import json
import sys

sys.path.insert(0, ".")
import standing_replay as sr

LEDGER_PATH = "/tmp/standing-sweep/ledger.json"
OUT_PATH = "/tmp/standing-sweep/reproduction_check.json"

# Doc's published numbers being reproduced (docs/designs/STANDING_SWEEP.md).
DOC_R0 = {"tau_mean": 0.954, "leader_changes_per_50": 6.92,
          "leader_best_round_share": 0.314, "up": 103, "down": 0}
DOC_R1 = {"tau_mean": 0.979, "leader_changes_per_50": 4.74,
          "leader_best_round_share": 0.0319, "up": 96}


def main():
    ledger = sr.load_ledger(LEDGER_PATH)
    rounds = ledger["rounds"]
    print(f"loaded {len(rounds)} rounds, r{rounds[0]['round_number']}-r{rounds[-1]['round_number']}")

    base_history, _ = sr.replay_setting(rounds, **{k: sr.CURRENT[k] for k in
                                        ("rated_k", "clamp_M", "top_k", "transform", "episode_mode")})
    _, final = base_history[-1]
    order = [pid for pid, _ in sorted(final.items(), key=lambda kv: -kv[1])]
    mid_subject = order[min(7, len(order) - 1)]
    top_subject = order[min(1, len(order) - 1)]
    from_idx = len(rounds) // 2
    print(f"mid_subject rank {order.index(mid_subject)+1}, "
          f"top_subject rank {order.index(top_subject)+1}, from_idx {from_idx}")

    r0 = sr._metrics_for_setting(rounds, {}, mid_subject, top_subject, from_idx)
    r0.pop("final_history", None)
    print("\n=== R0 (raw, k=0.05) vs doc's Current-setting metrics ===")
    print(f"tau_mean : {r0['tau_mean']:.3f}  (doc: {DOC_R0['tau_mean']})")
    print(f"chg/50   : {r0['leader_changes_per_50']:.2f}  (doc: {DOC_R0['leader_changes_per_50']})")
    print(f"share    : {r0['leader_best_round_share']:.3f}  (doc: {DOC_R0['leader_best_round_share']})")
    print(f"up       : {r0['rounds_to_top3_on_1.5x']}  (doc: {DOC_R0['up']})")
    print(f"down     : {r0['rounds_to_fall_out_of_top3_on_0.5x']}  (doc: {DOC_R0['down']})")

    r1 = sr._metrics_for_setting(rounds, {"transform": "signed_log2", "rated_k": 0.025},
                                  mid_subject, top_subject, from_idx)
    r1.pop("final_history", None)
    print("\n=== R1 (signed_log2, k=0.025) vs doc's 'log2 + rated_k=0.025' row ===")
    print(f"tau_mean : {r1['tau_mean']:.4f}  (doc: {DOC_R1['tau_mean']})")
    print(f"chg/50   : {r1['leader_changes_per_50']:.2f}  (doc: {DOC_R1['leader_changes_per_50']})")
    print(f"share    : {r1['leader_best_round_share']:.4f}  (doc: {DOC_R1['leader_best_round_share']})")
    print(f"up       : {r1['rounds_to_top3_on_1.5x']}  (doc: {DOC_R1['up']})")

    r1_plain_log2 = sr._metrics_for_setting(rounds, {"transform": "log2", "rated_k": 0.025},
                                             mid_subject, top_subject, from_idx)
    r1_plain_log2.pop("final_history", None)
    print("\n=== signed_log2 vs plain log2 @ k=0.025 (should match exactly on this ledger) ===")
    print(f"signed_log2: tau={r1['tau_mean']:.10f} chg={r1['leader_changes_per_50']:.10f} "
          f"share={r1['leader_best_round_share']:.10f}")
    print(f"log2       : tau={r1_plain_log2['tau_mean']:.10f} "
          f"chg={r1_plain_log2['leader_changes_per_50']:.10f} "
          f"share={r1_plain_log2['leader_best_round_share']:.10f}")

    neg = tot = 0
    for r in rounds:
        for legs in r["legs"].values():
            for v in legs:
                tot += 1
                if v is not None and v < 0:
                    neg += 1
    print(f"\nnegative legs in ledger: {neg}/{tot}")

    with open(OUT_PATH, "w") as f:
        json.dump({"r0": r0, "r1": r1, "r1_plain_log2": r1_plain_log2,
                   "doc_r0": DOC_R0, "doc_r1": DOC_R1,
                   "mid_subject": mid_subject, "top_subject": top_subject,
                   "from_idx": from_idx, "neg_legs": neg, "total_legs": tot},
                  f, indent=2, default=str)
    print(f"\nwrote {OUT_PATH}")


if __name__ == "__main__":
    main()

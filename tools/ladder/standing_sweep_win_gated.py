#!/usr/bin/env python3
"""GLORY GRADIENT win-gate sweep driver (2026-09-14).

Owner ask: replay the Paintbot S2 ladder under three rules on the SAME
window and produce ranked standings tables -- see
~/.ctf/knowledge/glory-gradient/01h-win-gated-standing-sweep-2026-09-14.md
for the write-up this script's output feeds.

  R0 -- TODAY: raw legs, EMA k=0.05 (the served config, `CURRENT` in
        standing_replay.py).
  R1 -- STEP A AS DECIDED: per-leg signed_log2, EMA k=0.025 (the doc's
        picked rate on the log2 transform).
  R2 -- STEP A + WIN GATE: as R1, but a leg is zeroed BEFORE the log unless
        that entrant's team won the episode (draws bank in full). Swept over
        k in {0.02, 0.025, 0.03, 0.035, 0.05}.

Inputs (already produced by standing_replay.py `pull`/`pull-winners`, not
re-fetched here):
  /tmp/standing-sweep/ledger_gated.json  -- r4828-r5077 (GameVersion 63 /
      GLORYVERSION 18, coworld_version 0.7.397-0.7.406), the largest window
      this task could get per-episode WINNER data for (see doc for why the
      original r4257-r4526 doc ledger predates decodability).
  /tmp/standing-sweep/winner_map.json    -- episode_id -> decoded `summary`
      event (winner/slot_team/draw), one entry per successfully-decoded
      episode in that window.

Writes /tmp/standing-sweep/gated_results.json (everything downstream --
the doc and the charts -- reads numbers out of THIS file, never recomputes).
"""
import json
import statistics
import sys

sys.path.insert(0, ".")
import standing_replay as sr

LEDGER_PATH = "/tmp/standing-sweep/ledger_gated.json"
WINNER_MAP_PATH = "/tmp/standing-sweep/winner_map.json"
OUT_PATH = "/tmp/standing-sweep/gated_results.json"

R2_KS = [0.02, 0.025, 0.03, 0.035, 0.05]


def name_map(rounds):
    m = {}
    for r in rounds:
        for pid, info in r["reported"].items():
            if info.get("player_name"):
                m[pid] = info["player_name"]
    return m


def top16_table(history, contributions, transform, names, win_counts):
    _, final = history[-1]
    order = sorted(final.items(), key=lambda kv: -kv[1])[:16]
    rows = []
    for pid, displayed in order:
        unlogged = sr.inverse_transform(displayed, transform)
        rows.append({
            "player_id": pid, "player_name": names.get(pid, pid[:12]),
            "displayed": displayed, "unlogged": unlogged,
            "n_legs": len(contributions.get(pid, [])),
            "wins": win_counts.get(pid, 0),
        })
    return rows


def compute_win_counts(rounds, winner_map):
    """Strict win counts (team == winner, non-draw) per player over the
    whole window, independent of any gating -- used only for the reporting
    table's 'win count' column."""
    wins = {}
    for r in rounds:
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
                    wins[pid] = wins.get(pid, 0) + 1
    return wins


def run_rule(rounds, setting, mid_subject, top_subject, from_idx, names, win_counts,
             bootstrap_window=100, bootstrap_draws=30):
    history, contributions = sr.replay_setting(rounds, **setting)
    stab = sr.stability_metrics(history)
    share = sr.leader_best_round_share(history, contributions, rated_k=setting["rated_k"])
    up = sr.responsiveness(rounds, setting["rated_k"], setting["clamp_M"], setting["top_k"],
                            setting["transform"], setting["episode_mode"], mid_subject, 1.5,
                            from_idx, target="top3")
    down = sr.responsiveness(rounds, setting["rated_k"], setting["clamp_M"], setting["top_k"],
                              setting["transform"], setting["episode_mode"], top_subject, 0.5,
                              from_idx, target="out_of_top3")
    boot_stab = sr.bootstrap_stability(rounds, setting, n_draws=bootstrap_draws,
                                        window=bootstrap_window)
    n = len(rounds)
    lo, hi = max(0, n // 5), max(0, n - bootstrap_window // 2 - 1)
    if hi <= lo:
        lo, hi = 0, max(0, n - 2)
    boot_up = sr.bootstrap_responsiveness(rounds, setting, mid_subject, 1.5, "top3", lo, hi,
                                           n_draws=bootstrap_draws, seed=2)
    boot_down = sr.bootstrap_responsiveness(rounds, setting, top_subject, 0.5, "out_of_top3",
                                             lo, hi, n_draws=bootstrap_draws, seed=3)
    table = top16_table(history, contributions, setting["transform"], names, win_counts)

    # "standings SCALE" (task deliverable item 2): median + top standing
    # across the WHOLE final-round board, displayed (the EMA's own units --
    # bits for log2/signed_log2, raw score for raw) and un-logged (inverse_
    # transform), so the doc can show how gating compresses the displayed
    # number without re-deriving it from the top16 table alone (top16 only
    # shows the top of the board, not the median).
    _, final_standing = history[-1]
    vals = sorted(final_standing.values())
    median_disp = statistics.median(vals) if vals else None
    top_disp = vals[-1] if vals else None
    scale = {
        "n_players": len(vals),
        "median_displayed": median_disp, "top_displayed": top_disp,
        "median_unlogged": (sr.inverse_transform(median_disp, setting["transform"])
                             if median_disp is not None else None),
        "top_unlogged": (sr.inverse_transform(top_disp, setting["transform"])
                          if top_disp is not None else None),
    }

    return {
        "setting": setting, "tau_mean": stab["tau_mean"], "tau_p10": stab["tau_p10"],
        "leader_changes_per_50": stab["leader_changes_per_50"],
        "leader_best_round_share": share,
        "up": up, "down": down,
        "bootstrap_stability": boot_stab,
        "bootstrap_up": boot_up, "bootstrap_down": boot_down,
        "standing_scale": scale,
        "top16": table,
    }


def main():
    ledger = sr.load_ledger(LEDGER_PATH)
    rounds = ledger["rounds"]
    print(f"[gated-sweep] loaded {len(rounds)} rounds "
          f"r{rounds[0]['round_number']}-r{rounds[-1]['round_number']}", file=sys.stderr)

    with open(WINNER_MAP_PATH) as f:
        wm = json.load(f)
    winner_map = wm["winner_map"]
    decode_errors = wm["errors"]
    print(f"[gated-sweep] winner_map: {len(winner_map)} decoded, "
          f"{len(decode_errors)} errors", file=sys.stderr)

    gated_ledger, gate_stats = sr.gate_ledger_by_win(ledger, winner_map)
    gated_rounds = gated_ledger["rounds"]
    print(f"[gated-sweep] gate stats: {gate_stats}", file=sys.stderr)

    names = name_map(rounds)
    win_counts = compute_win_counts(rounds, winner_map)

    # subject selection off R0's own final ranking (same convention as
    # standing_replay.run_sweep), shared across R0/R1/R2 for comparability.
    base_history, _ = sr.replay_setting(rounds, **{k: sr.CURRENT[k] for k in
                                        ("rated_k", "clamp_M", "top_k", "transform", "episode_mode")})
    _, final = base_history[-1]
    order = [pid for pid, _ in sorted(final.items(), key=lambda kv: -kv[1])]
    mid_subject = order[min(7, len(order) - 1)]
    top_subject = order[min(1, len(order) - 1)]
    from_idx = len(rounds) // 2
    print(f"[gated-sweep] mid_subject={names.get(mid_subject)} rank {order.index(mid_subject)+1}, "
          f"top_subject={names.get(top_subject)} rank {order.index(top_subject)+1}, "
          f"from_idx={from_idx}/{len(rounds)}", file=sys.stderr)

    results = {"window": {"since": rounds[0]["round_number"], "until": rounds[-1]["round_number"],
                           "n_rounds": len(rounds)},
               "gate_stats": gate_stats, "decode_errors_n": len(decode_errors),
               "mid_subject": mid_subject, "top_subject": top_subject, "from_idx": from_idx,
               "mid_subject_name": names.get(mid_subject), "top_subject_name": names.get(top_subject)}

    print("[gated-sweep] R0 (raw, k=0.05) ...", file=sys.stderr)
    r0_setting = dict(sr.CURRENT)
    results["R0"] = run_rule(rounds, r0_setting, mid_subject, top_subject, from_idx, names, win_counts)

    print("[gated-sweep] R1 (signed_log2, k=0.025) ...", file=sys.stderr)
    r1_setting = dict(sr.CURRENT, transform="signed_log2", rated_k=0.025)
    results["R1"] = run_rule(rounds, r1_setting, mid_subject, top_subject, from_idx, names, win_counts)

    print("[gated-sweep] R2 sweep over k ...", file=sys.stderr)
    results["R2_sweep"] = {}
    for k in R2_KS:
        print(f"[gated-sweep]   R2 k={k}", file=sys.stderr)
        setting = dict(sr.CURRENT, transform="signed_log2", rated_k=k)
        results["R2_sweep"][str(k)] = run_rule(gated_rounds, setting, mid_subject, top_subject,
                                                from_idx, names, win_counts)

    with open(OUT_PATH, "w") as f:
        json.dump(results, f, indent=2, default=str)
    print(f"[gated-sweep] wrote {OUT_PATH}", file=sys.stderr)


if __name__ == "__main__":
    main()

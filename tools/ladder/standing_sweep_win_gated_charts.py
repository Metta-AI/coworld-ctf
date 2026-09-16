#!/usr/bin/env python3
"""Two charts for the win-gate sweep (see standing_sweep_win_gated.py).

Reads /tmp/standing-sweep/{ledger_gated,winner_map,gated_results}.json and
writes PNGs to .harness/screenshots/standing-sweep-gated/. Mirrors
standing_sweep_charts.py's structure and palette (dataviz skill's validated
default categorical order); OUT_DIR is computed relative to this file
instead of hardcoded to a worktree path.
"""
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import standing_replay as sr  # noqa: E402

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))
OUT_DIR = os.path.join(REPO_ROOT, ".harness", "screenshots", "standing-sweep-gated")

PALETTE = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7"]
TEXT_PRIMARY = "#0b0b0b"
TEXT_SECONDARY = "#52514e"
SURFACE = "#fcfcfb"


def chart_a(results):
    """tau (stability) vs leader_best_round_share (spike-dependence) --
    R0, R1, and every swept R2 k, so the owner sees the whole family at a
    glance (the R2 k-sweep is the point of this study; R0/R1 are the
    anchors from the already-decided rules)."""
    fig, ax = plt.subplots(figsize=(8, 6), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)

    def plot_point(label, m, color, marker="o", size=90, z=2):
        x = m["leader_best_round_share"]
        y = m["tau_mean"]
        ax.scatter([x], [y], s=size, color=color, marker=marker,
                   edgecolors="white", linewidths=0.7, zorder=z)
        ax.annotate(label, (x, y), textcoords="offset points", xytext=(7, 4),
                    fontsize=8, color=TEXT_SECONDARY)

    plot_point("R0 today (raw, k=0.05)", results["R0"], TEXT_PRIMARY, marker="*", size=260, z=5)
    plot_point("R1 step A (signed_log2, k=0.025)", results["R1"], PALETTE[0], marker="s", size=110, z=4)
    for i, (k, m) in enumerate(sorted(results["R2_sweep"].items(), key=lambda kv: float(kv[0]))):
        plot_point(f"R2 win-gate k={k}", m, PALETTE[2], marker="D", size=90, z=3)

    ax.set_xlabel("Leader's single-round standing share\n(lower = less spike-dependent)",
                  color=TEXT_PRIMARY)
    ax.set_ylabel("Mean Kendall tau, consecutive-round top-16\n(higher = more stable)",
                  color=TEXT_PRIMARY)
    ax.set_title("Win-gate sweep: stability vs. leader spike-dependence\n"
                 f"Paintbot S2, r{results['window']['since']}–r{results['window']['until']} "
                 f"({results['window']['n_rounds']} rounds, GameVersion 63 / GLORYVERSION 18)",
                 color=TEXT_PRIMARY, fontsize=10.5)
    ax.tick_params(colors=TEXT_SECONDARY)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    for spine in ("left", "bottom"):
        ax.spines[spine].set_color(TEXT_SECONDARY)

    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "stability_vs_leader_share_gated.png")
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)
    print(f"[chart a] wrote {path}")
    return path


def chart_b(ledger_path, results, best_k):
    ledger = sr.load_ledger(ledger_path)
    rounds = ledger["rounds"]
    with open("/tmp/standing-sweep/winner_map.json") as f:
        winner_map = json.load(f)["winner_map"]
    gated_ledger, _ = sr.gate_ledger_by_win(ledger, winner_map)
    gated_rounds = gated_ledger["rounds"]

    r0_hist, _ = sr.replay_setting(rounds, **{k: sr.CURRENT[k] for k in
                                    ("rated_k", "clamp_M", "top_k", "transform", "episode_mode")})
    r2_setting = dict(sr.CURRENT, transform="signed_log2", rated_k=best_k)
    r2_hist, _ = sr.replay_setting(gated_rounds, **r2_setting)

    _, final_r0 = r0_hist[-1]
    top5 = [pid for pid, _ in sorted(final_r0.items(), key=lambda kv: -kv[1])[:5]]

    name_by_pid = {}
    for r in rounds:
        for pid, info in r["reported"].items():
            name_by_pid[pid] = info.get("player_name")

    fig, axes = plt.subplots(1, 2, figsize=(12, 5.5), dpi=150, sharey=False)
    fig.patch.set_facecolor(SURFACE)

    for ax, hist, title, transform in (
            (axes[0], r0_hist, "R0 TODAY (raw, k=0.05)", "raw"),
            (axes[1], r2_hist, f"R2 WIN-GATE (signed_log2, k={best_k})", "signed_log2")):
        ax.set_facecolor(SURFACE)
        xs = [rnum for rnum, _ in hist]
        for i, pid in enumerate(top5):
            ys = [standing.get(pid, 0.0) for _, standing in hist]
            ax.plot(xs, ys, color=PALETTE[i % len(PALETTE)], linewidth=1.6,
                    label=name_by_pid.get(pid, pid[:8]))
        ax.set_title(title, color=TEXT_PRIMARY, fontsize=10)
        ax.set_xlabel("round_number", color=TEXT_PRIMARY)
        ax.set_ylabel("standing (raw score)" if transform == "raw" else "standing (log2 bits)",
                      color=TEXT_PRIMARY)
        ax.tick_params(colors=TEXT_SECONDARY)
        for spine in ("top", "right"):
            ax.spines[spine].set_visible(False)
        for spine in ("left", "bottom"):
            ax.spines[spine].set_color(TEXT_SECONDARY)

    axes[1].legend(loc="upper left", frameon=False, fontsize=8)
    fig.suptitle("Top-5 standing over rounds: R0 (today) vs. R2 (win-gated, best k)\n"
                 "same window, same 5 policies (ranked under R0's own final order)",
                 color=TEXT_PRIMARY, fontsize=11)

    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "top5_standing_r0_vs_r2_gated.png")
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)
    print(f"[chart b] wrote {path}")
    return path


def main():
    with open("/tmp/standing-sweep/gated_results.json") as f:
        results = json.load(f)
    best_k = sys.argv[1] if len(sys.argv) > 1 else "0.025"
    a = chart_a(results)
    b = chart_b("/tmp/standing-sweep/ledger_gated.json", results, float(best_k))
    for p in (a, b):
        out = f"/tmp/standing-sweep/owner-gated/{os.path.basename(p)}"
        os.makedirs(os.path.dirname(out), exist_ok=True)
        os.system(f'sips -Z 900 "{p}" --out "{out}" >/dev/null 2>&1')


if __name__ == "__main__":
    main()

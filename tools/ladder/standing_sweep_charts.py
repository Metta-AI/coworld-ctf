#!/usr/bin/env python3
"""Two charts for the standing stability sweep (see standing_replay.py).

Reads /tmp/standing-sweep/{ledger,sweep_results}.json (produced by
`standing_replay.py pull|sweep`) and writes PNGs to
.harness/screenshots/standing-sweep/. Requires matplotlib (not a dependency
of standing_replay.py itself, kept isolated here).

Palette: dataviz skill's validated default categorical order (fixed hue
order, never cycled): blue #2a78d6, orange #eb6834, aqua #1baf7a,
yellow #eda100, magenta #e87ba4. The 5-slot adjacent-pair set passes CVD/
normal-vision checks with a contrast WARN on aqua/yellow/magenta needing
visible direct labels — every point/line below carries one.
"""
import json
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import standing_replay as sr  # noqa: E402

OUT_DIR = "/Users/maxwellstarr/projects/coworld-ctf/.claude/worktrees/agent-a6a0f6ab4303bcc07/.harness/screenshots/standing-sweep"

PALETTE = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#4a3aa7"]
TEXT_PRIMARY = "#0b0b0b"
TEXT_SECONDARY = "#52514e"
SURFACE = "#fcfcfb"


def _label(s):
    parts = []
    if s["rated_k"] != sr.CURRENT["rated_k"]:
        parts.append(f"k={s['rated_k']}")
    if s["clamp_M"] != sr.CURRENT["clamp_M"]:
        parts.append(f"M={s['clamp_M']}")
    if s["top_k"] != sr.CURRENT["top_k"]:
        parts.append(f"topk={s['top_k']}")
    if s["transform"] != sr.CURRENT["transform"]:
        parts.append(s["transform"])
    if s["episode_mode"] != sr.CURRENT["episode_mode"]:
        parts.append(s["episode_mode"])
    return "+".join(parts) if parts else "current"


def chart_a(results):
    fig, ax = plt.subplots(figsize=(8, 6), dpi=150)
    fig.patch.set_facecolor(SURFACE)
    ax.set_facecolor(SURFACE)

    window = results["current"].get("tau_mean") and 127  # remaining-rounds cap
    axis_colors = {"rated_k": PALETTE[0], "clamp_M": PALETTE[1],
                   "transform": PALETTE[2], "episode_mode": PALETTE[3],
                   "combos": PALETTE[4]}

    def plot_point(m, color, marker="o", size=60, z=2, offset=(6, 4), label=None):
        up = m["rounds_to_top3_on_1.5x"]
        x = up if up is not None else 130  # off-scale marker for "never reached"
        y = m["tau_mean"]
        ax.scatter([x], [y], s=size, color=color, marker=marker,
                   edgecolors="white", linewidths=0.6, zorder=z)
        lbl = _label(m["setting"]) if label is None else label
        if lbl is not None:
            ax.annotate(lbl, (x, y), textcoords="offset points", xytext=offset,
                        fontsize=7.5, color=TEXT_SECONDARY)
        return x, y

    # M=30/60/150/None cluster sits almost on top of each other around
    # (103, 0.954) — stagger the labels vertically so they stay legible.
    _m_offsets = {10.0: (6, 4), 30.0: (6, 16), 60.0: (6, -12), 150.0: (6, 4),
                  None: (-46, -12)}

    for axis, rows in results["axes"].items():
        if axis == "top_k":
            continue  # inert on this ledger (sum_top_k never trims) — noted in doc
        color = axis_colors.get(axis, PALETTE[5])
        for m in rows:
            if axis == "clamp_M":
                plot_point(m, color, offset=_m_offsets.get(m["setting"]["clamp_M"], (6, 4)))
            else:
                plot_point(m, color)

    for name, m in results["combos"].items():
        # log2_clamp60 lands EXACTLY on log2_only (log2 compresses magnitudes
        # enough that M=60 never binds) — skip its duplicate marker/label and
        # say so in prose instead of overplotting two identical points.
        if name == "log2_clamp60":
            continue
        plot_point(m, axis_colors["combos"], marker="D", size=70, z=3)

    cx, cy = plot_point(results["current"], TEXT_PRIMARY, marker="*", size=260, z=5)
    ax.annotate("CURRENT (k=0.05, M=150, top12, raw)", (cx, cy),
                textcoords="offset points", xytext=(8, -12), fontsize=8.5,
                color=TEXT_PRIMARY, fontweight="bold")

    ax.axvline(130, color=TEXT_SECONDARY, linestyle=":", linewidth=1, alpha=0.4)
    ax.text(131, ax.get_ylim()[0] + 0.001, "never reached\nwithin window",
            fontsize=7, color=TEXT_SECONDARY, va="bottom")

    ax.set_xlabel("Rounds for a genuinely-better (1.5x) mid-table policy\n"
                  "to reach top-3  (lower = more responsive)", color=TEXT_PRIMARY)
    ax.set_ylabel("Mean Kendall tau, consecutive-round top-16\n"
                  "(higher = more stable)", color=TEXT_PRIMARY)
    ax.set_title("Standing stability vs. responsiveness by setting\n"
                 "Paintbot S2, r4257–r4524 (253 rounds, post-winAsMultiplier era)",
                 color=TEXT_PRIMARY, fontsize=11)
    ax.tick_params(colors=TEXT_SECONDARY)
    for spine in ("top", "right"):
        ax.spines[spine].set_visible(False)
    for spine in ("left", "bottom"):
        ax.spines[spine].set_color(TEXT_SECONDARY)

    legend_handles = [plt.Line2D([0], [0], marker="o", color="w",
                                  markerfacecolor=axis_colors[a], markersize=8,
                                  label=a)
                       for a in ("rated_k", "clamp_M", "transform", "episode_mode")]
    legend_handles.append(plt.Line2D([0], [0], marker="D", color="w",
                                      markerfacecolor=axis_colors["combos"],
                                      markersize=8, label="combo"))
    legend_handles.append(plt.Line2D([0], [0], marker="*", color="w",
                                      markerfacecolor=TEXT_PRIMARY, markersize=14,
                                      label="current (served)"))
    ax.legend(handles=legend_handles, loc="lower left", frameon=False, fontsize=8)

    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "stability_vs_responsiveness.png")
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)
    print(f"[chart a] wrote {path}")
    return path


def chart_b(ledger, results):
    rounds = ledger["rounds"]
    current_hist, _ = sr.replay_setting(rounds, **{k: sr.CURRENT[k] for k in
                                                    ("rated_k", "clamp_M", "top_k",
                                                     "transform", "episode_mode")})
    rec_setting = results["combos"]["log2_k035"]["setting"]
    rec_hist, _ = sr.replay_setting(rounds, rated_k=rec_setting["rated_k"],
                                     clamp_M=rec_setting["clamp_M"],
                                     top_k=rec_setting["top_k"],
                                     transform=rec_setting["transform"],
                                     episode_mode=rec_setting["episode_mode"])

    _, final_current = current_hist[-1]
    top5 = [pid for pid, _ in sorted(final_current.items(), key=lambda kv: -kv[1])[:5]]

    name_by_pid = {}
    for r in rounds:
        for pid, info in r["reported"].items():
            name_by_pid[pid] = info.get("player_name")

    fig, axes = plt.subplots(1, 2, figsize=(12, 5.5), dpi=150, sharey=False)
    fig.patch.set_facecolor(SURFACE)

    for ax, hist, title in ((axes[0], current_hist, "CURRENT (k=0.05, M=150, raw)"),
                             (axes[1], rec_hist, "RECOMMENDED (log2, k=0.035)")):
        ax.set_facecolor(SURFACE)
        xs = [rnum for rnum, _ in hist]
        for i, pid in enumerate(top5):
            ys = [standing.get(pid, 0.0) for _, standing in hist]
            ax.plot(xs, ys, color=PALETTE[i % len(PALETTE)], linewidth=1.6,
                    label=name_by_pid.get(pid, pid[:8]))
        ax.set_title(title, color=TEXT_PRIMARY, fontsize=10)
        ax.set_xlabel("round_number", color=TEXT_PRIMARY)
        ax.tick_params(colors=TEXT_SECONDARY)
        for spine in ("top", "right"):
            ax.spines[spine].set_visible(False)
        for spine in ("left", "bottom"):
            ax.spines[spine].set_color(TEXT_SECONDARY)

    axes[0].set_ylabel("standing", color=TEXT_PRIMARY)
    axes[1].legend(loc="upper left", frameon=False, fontsize=8)
    fig.suptitle("Top-5 standing over rounds: current vs. recommended setting\n"
                 "(same ledger, same 5 policies identified under CURRENT's final ranking)",
                 color=TEXT_PRIMARY, fontsize=11)

    os.makedirs(OUT_DIR, exist_ok=True)
    path = os.path.join(OUT_DIR, "top5_standing_current_vs_recommended.png")
    fig.tight_layout()
    fig.savefig(path, facecolor=SURFACE)
    plt.close(fig)
    print(f"[chart b] wrote {path}")
    return path


def main():
    ledger = sr.load_ledger()
    with open("/tmp/standing-sweep/sweep_results.json") as f:
        results = json.load(f)
    a = chart_a(results)
    b = chart_b(ledger, results)
    for p in (a, b):
        out = f"/tmp/standing-sweep/owner/{os.path.basename(p)}"
        os.makedirs(os.path.dirname(out), exist_ok=True)
        os.system(f'sips -Z 900 "{p}" --out "{out}" >/dev/null 2>&1')


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Win-injection close-out for arming flag (b) (2026-09-15).

The win-gate's climb-time flag (docs/designs/STANDING_SWEEP.md, "Win-gated
extension") was left unmeasured: the doc's own score-scaling injection is
inert on gated legs (`1.5 * 0 == 0`). This tests climb time properly by
injecting WINS, not bigger scores, two ways, and compares the SAME
injection under R0 (raw, k=0.05), R1 (signed_log2 ungated, k=0.025), and
R2 (signed_log2 win-gated, k=0.02):

  Design 1 -- SYNTHETIC ENTRANT: a 17th subject appears at round N0 with no
    prior history (cold-start, like a real first-round entrant). From N0
    on it "plays" 12 episodes/round (matching this ladder's own
    min_episodes_per_entrant=12), winning each independently with
    probability p in {q3 (this window's real top-quartile per-episode win
    rate), 1.5x q3, 2x q3}. Its raw leg on a WON episode = this window's
    median winning raw leg; on a LOST episode = this window's median
    NON-winning raw leg (an explicit modeling choice, stated here since
    the task only pins the win-episode magnitude: this makes the entity
    behave like a real, middling player who sometimes wins, not a
    degenerate all-or-nothing one -- and is what lets R0/R1 vs R2 actually
    differ for the SAME entity: under R0/R1 (ungated) both magnitudes
    count every round; under R2 only the win-episode magnitude survives
    the gate).
  Design 2 -- UPLIFT AN EXISTING SUBJECT: pick the real player ranked ~8th
    under R2@0.02 AT round-index N0. From N0 on, keep every recorded raw
    leg exactly as played ("keeping everything else recorded" per the
    task) but REDRAW the win/loss flag each episode at
    baseline_win_rate * {1.5, 2} (baseline measured on that subject's real
    episodes strictly before N0) instead of the real recorded outcome.
    Since R0/R1 do not gate on win/loss at all, this manipulation is
    PROVABLY A NO-OP under R0/R1 (the raw legs are untouched) -- reported,
    not re-simulated, once per draw as a sanity confirmation.

Both bootstrapped over >=30 (N0, seed) draws; reports median/p10/p90
rounds-to-top5 and rounds-to-#1, plus "never" fraction.

Usage: `python3 standing_sweep_win_injection.py` (reads
/tmp/standing-sweep/{ledger_gated,winner_map}.json; writes
/tmp/standing-sweep/win_injection_results.json).
"""
import copy
import json
import random
import statistics
import sys
import zlib


def _stable_seed(label, draw):
    """`hash(str)` is salted per-process (PYTHONHASHSEED) -- use a stable
    crc32 instead so bootstrap draws are reproducible run-to-run."""
    return zlib.crc32(f"{label}:{draw}".encode()) & 0xFFFFFFFF

sys.path.insert(0, ".")
import standing_replay as sr

LEDGER_PATH = "/tmp/standing-sweep/ledger_gated.json"
WINNER_MAP_PATH = "/tmp/standing-sweep/winner_map.json"
OUT_PATH = "/tmp/standing-sweep/win_injection_results.json"

R0_SETTING = dict(sr.CURRENT)
R1_SETTING = dict(sr.CURRENT, transform="signed_log2", rated_k=0.025)
R2_SETTING = dict(sr.CURRENT, transform="signed_log2", rated_k=0.02)

N_DRAWS = 30
N_EPISODES_PER_ROUND = 12
SYNTH_PID = "SYNTHETIC_17TH"


# --------------------------------------------------------------------------
# Shared real-data stats
# --------------------------------------------------------------------------

def per_episode_win_flags(rounds, winner_map):
    """{round_idx: {pid: [True/False, ...]}} -- one bool per episode the
    player actually appeared in that round (strict win: team==winner,
    non-draw counts as a "pass" per the task's own gate rule, but here we
    want the STRICT win rate specifically for calibrating win probability,
    so draws are excluded from the numerator and denominator alike)."""
    out = []
    for r in rounds:
        round_flags = {}
        for ep in sr._cached_episodes(r["round_id"]):
            if ep.get("status") != "completed":
                continue
            summ = winner_map.get(ep.get("episode_id"))
            if summ is None:
                continue
            winner_team = summ.get("winner")
            draw = bool(summ.get("draw"))
            slot_team = summ.get("slot_team") or []
            for p in ep.get("participants") or []:
                if p.get("is_filler"):
                    continue
                pos, pid = p.get("position"), p.get("player_id")
                if pos is None or pid is None:
                    continue
                if draw:
                    continue  # excluded from strict win-rate calibration
                team = slot_team[pos] if pos < len(slot_team) else None
                won = bool(winner_team) and team == winner_team
                round_flags.setdefault(pid, []).append(won)
        out.append(round_flags)
    return out


def global_win_loss_magnitudes(rounds, winner_map):
    """Median raw leg among WINNING legs and among NON-winning (lost, not
    draw) legs, pooled across the whole window -- the two magnitudes
    Design 1's synthetic entity draws from."""
    wins, losses = [], []
    for r in rounds:
        pos_to_player = {}
        for ep in sr._cached_episodes(r["round_id"]):
            if ep.get("status") != "completed":
                continue
            summ = winner_map.get(ep.get("episode_id"))
            if summ is None:
                continue
            winner_team = summ.get("winner")
            draw = bool(summ.get("draw"))
            if draw:
                continue
            slot_team = summ.get("slot_team") or []
            pos_to_player = {p.get("position"): p.get("player_id")
                              for p in (ep.get("participants") or [])
                              if not p.get("is_filler")}
            for ps in ep.get("participant_scores") or []:
                pos = ps.get("position")
                pid = pos_to_player.get(pos)
                score = ps.get("score")
                if pid is None or score is None or pos is None or pos >= len(slot_team):
                    continue
                if slot_team[pos] == winner_team and winner_team:
                    wins.append(score)
                else:
                    losses.append(score)
    return statistics.median(wins), statistics.median(losses), len(wins), len(losses)


def per_player_win_rate(round_flags, upto_idx=None):
    """{pid: (wins, episodes)} pooled over round_flags[:upto_idx] (or all)."""
    agg = {}
    for rf in (round_flags if upto_idx is None else round_flags[:upto_idx]):
        for pid, flags in rf.items():
            w, n = agg.get(pid, (0, 0))
            agg[pid] = (w + sum(flags), n + len(flags))
    return agg


# --------------------------------------------------------------------------
# Climb-time measurement
# --------------------------------------------------------------------------

def rounds_to_targets(history, subject_pid, n0_idx):
    """First i>=n0_idx (as an offset from n0_idx) where subject reaches
    top-5 / #1. None if never within the remaining window."""
    top5 = top1 = None
    for i in range(n0_idx, len(history)):
        _, standing = history[i]
        if subject_pid not in standing:
            continue
        order = [pid for pid, _ in sorted(standing.items(), key=lambda kv: -kv[1])]
        rank = order.index(subject_pid) + 1
        if top5 is None and rank <= 5:
            top5 = i - n0_idx
        if top1 is None and rank == 1:
            top1 = i - n0_idx
        if top5 is not None and top1 is not None:
            break
    return top5, top1


def summarize(vals):
    finite = sorted(v for v in vals if v is not None)
    never = len(vals) - len(finite)
    return {
        "median": statistics.median(finite) if finite else None,
        "p10": finite[max(0, int(len(finite) * 0.10) - 1)] if finite else None,
        "p90": finite[min(len(finite) - 1, int(len(finite) * 0.90))] if finite else None,
        "never_frac": (never / len(vals)) if vals else None, "n": len(vals),
    }


# --------------------------------------------------------------------------
# Design 1: synthetic entrant
# --------------------------------------------------------------------------

def build_synthetic_rounds(rounds, gated_rounds, n0_idx, p, win_mag, loss_mag, rng):
    r0r1_rounds = copy.deepcopy(rounds)
    r2_rounds = copy.deepcopy(gated_rounds)
    for i in range(n0_idx, len(rounds)):
        draws = [rng.random() < p for _ in range(N_EPISODES_PER_ROUND)]
        legs_ungated = [win_mag if w else loss_mag for w in draws]
        legs_gated = [win_mag if w else 0.0 for w in draws]
        r0r1_rounds[i]["legs"][SYNTH_PID] = legs_ungated
        r2_rounds[i]["legs"][SYNTH_PID] = legs_gated
    return r0r1_rounds, r2_rounds


def design1(rounds, gated_rounds, q3_rate, win_mag, loss_mag, n0_range):
    results = {}
    for label, p in (("q3", q3_rate), ("1.5x_q3", 1.5 * q3_rate), ("2x_q3", 2 * q3_rate)):
        p = min(p, 1.0)
        top5s = {"R0": [], "R1": [], "R2": []}
        top1s = {"R0": [], "R1": [], "R2": []}
        for draw in range(N_DRAWS):
            rng = random.Random(_stable_seed(label, draw))
            n0 = rng.randrange(n0_range[0], n0_range[1])
            r0r1_rounds, r2_rounds = build_synthetic_rounds(
                rounds, gated_rounds, n0, p, win_mag, loss_mag, rng)
            h0, _ = sr.replay_setting(r0r1_rounds, **R0_SETTING)
            h1, _ = sr.replay_setting(r0r1_rounds, **R1_SETTING)
            h2, _ = sr.replay_setting(r2_rounds, **R2_SETTING)
            for rule, h in (("R0", h0), ("R1", h1), ("R2", h2)):
                t5, t1 = rounds_to_targets(h, SYNTH_PID, n0)
                top5s[rule].append(t5)
                top1s[rule].append(t1)
        results[label] = {
            "p": p,
            "top5": {rule: summarize(v) for rule, v in top5s.items()},
            "top1": {rule: summarize(v) for rule, v in top1s.items()},
        }
    return results


# --------------------------------------------------------------------------
# Design 2: uplift an existing mid-table subject
# --------------------------------------------------------------------------

def design2(rounds, gated_rounds, round_flags, n0_range):
    # Baseline R2 replay (real data) to pick "rank ~8 at N0" per draw and to
    # report R0/R1's (unchanged) climb time for the SAME subject/N0.
    base_r2_hist, _ = sr.replay_setting(gated_rounds, **R2_SETTING)
    base_r0_hist, _ = sr.replay_setting(rounds, **R0_SETTING)
    base_r1_hist, _ = sr.replay_setting(rounds, **R1_SETTING)

    results = {}
    for mult in (1.5, 2.0):
        top5s = {"R0": [], "R1": [], "R2": []}
        top1s = {"R0": [], "R1": [], "R2": []}
        for draw in range(N_DRAWS):
            rng = random.Random(_stable_seed(f"uplift_{mult}", draw))
            n0 = rng.randrange(n0_range[0], n0_range[1])
            _, standing_at_n0 = base_r2_hist[n0]
            order = [pid for pid, _ in sorted(standing_at_n0.items(), key=lambda kv: -kv[1])]
            subject = order[min(7, len(order) - 1)]

            wins, episodes = per_player_win_rate(round_flags, upto_idx=n0).get(subject, (0, 0))
            baseline_p = (wins / episodes) if episodes else 0.0
            uplifted_p = min(baseline_p * mult, 1.0)

            r2_rounds2 = copy.deepcopy(gated_rounds)
            for i in range(n0, len(rounds)):
                real_raw = rounds[i]["legs"].get(subject, [])
                new_legs = [raw if rng.random() < uplifted_p else 0.0 for raw in real_raw]
                r2_rounds2[i]["legs"][subject] = new_legs
            h2, _ = sr.replay_setting(r2_rounds2, **R2_SETTING)

            t5_2, t1_2 = rounds_to_targets(h2, subject, n0)
            t5_0, t1_0 = rounds_to_targets(base_r0_hist, subject, n0)
            t5_1, t1_1 = rounds_to_targets(base_r1_hist, subject, n0)
            top5s["R0"].append(t5_0); top1s["R0"].append(t1_0)
            top5s["R1"].append(t5_1); top1s["R1"].append(t1_1)
            top5s["R2"].append(t5_2); top1s["R2"].append(t1_2)
        results[f"{mult}x_baseline"] = {
            "top5": {rule: summarize(v) for rule, v in top5s.items()},
            "top1": {rule: summarize(v) for rule, v in top1s.items()},
        }
    return results


def main():
    ledger = sr.load_ledger(LEDGER_PATH)
    rounds = ledger["rounds"]
    with open(WINNER_MAP_PATH) as f:
        winner_map = json.load(f)["winner_map"]
    gated_ledger, _ = sr.gate_ledger_by_win(ledger, winner_map)
    gated_rounds = gated_ledger["rounds"]

    round_flags = per_episode_win_flags(rounds, winner_map)
    win_rates = per_player_win_rate(round_flags)
    rates = sorted((w / n) for w, n in win_rates.values() if n > 0)
    q3_rate = rates[int(len(rates) * 0.75)] if rates else 0.1
    win_mag, loss_mag, n_wins, n_losses = global_win_loss_magnitudes(rounds, winner_map)
    print(f"top-quartile per-episode win rate: {q3_rate:.4f} (n_players={len(rates)})",
          file=sys.stderr)
    print(f"median winning raw leg: {win_mag} (n={n_wins}); "
          f"median non-winning raw leg: {loss_mag} (n={n_losses})", file=sys.stderr)

    n = len(rounds)
    n0_range = (n // 4, n - 30)  # keep >=30 rounds of runway after N0

    print("[design 1] synthetic entrant ...", file=sys.stderr)
    d1 = design1(rounds, gated_rounds, q3_rate, win_mag, loss_mag, n0_range)

    print("[design 2] uplift existing subject ...", file=sys.stderr)
    d2 = design2(rounds, gated_rounds, round_flags, n0_range)

    out = {
        "window": {"since": rounds[0]["round_number"], "until": rounds[-1]["round_number"],
                   "n_rounds": n},
        "q3_rate": q3_rate, "win_mag": win_mag, "loss_mag": loss_mag,
        "n0_range": n0_range, "n_draws": N_DRAWS,
        "design1_synthetic_entrant": d1,
        "design2_uplift_existing": d2,
    }
    with open(OUT_PATH, "w") as f:
        json.dump(out, f, indent=2, default=str)
    print(f"wrote {OUT_PATH}", file=sys.stderr)

    for label, res in d1.items():
        print(f"\nD1 {label} (p={res['p']:.4f}):")
        for rule in ("R0", "R1", "R2"):
            t5, t1 = res["top5"][rule], res["top1"][rule]
            print(f"  {rule}: top5 median={t5['median']} [{t5['p10']},{t5['p90']}] "
                  f"never={t5['never_frac']:.2f} | "
                  f"#1 median={t1['median']} [{t1['p10']},{t1['p90']}] never={t1['never_frac']:.2f}")

    for label, res in d2.items():
        print(f"\nD2 {label}:")
        for rule in ("R0", "R1", "R2"):
            t5, t1 = res["top5"][rule], res["top1"][rule]
            print(f"  {rule}: top5 median={t5['median']} [{t5['p10']},{t5['p90']}] "
                  f"never={t5['never_frac']:.2f} | "
                  f"#1 median={t1['median']} [{t1['p10']},{t1['p90']}] never={t1['never_frac']:.2f}")


if __name__ == "__main__":
    main()

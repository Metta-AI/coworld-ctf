#!/usr/bin/env python3
"""score_play_corr — does staticScore predict how a map actually PLAYS?

staticScore is a hand-written weighted mean of 15 banded metrics. It ranks
every candidate the generator draws, it gates the epic's acceptance criterion
(interiorFrac >= 0.30), and it has never been compared against a played
episode. This script runs that comparison.

THE DESIGN, and why each piece is the way it is:

* SPREAD. A correlation needs variance on both axes. The shipped generator has
  none left — it runs best-of-K and ships the winner, so the shipped population
  piles up near 1.0. `tools/score_spread.nim` recovers the spread by sweeping
  the ATTEMPT index, which redraws terrain/cover/pickups while `map_seed`'s
  `seedStream` holds the board SHELL fixed. Same board, built differently.

* THE CONTROL IS A POINT, NOT A FOOTNOTE. The hand-authored arena is played
  under the identical protocol and lands in the same scatter as everything
  else. map_eval's Rule 1 says a metric that flags the control is wrong; that
  can only be checked if the control is measured on the same axis.

* PAIRED EPISODE SEEDS. `map_eval play` uses seed = 1 + episode, so every map
  is played on the SAME episode seeds. Cross-map differences therefore cannot
  be an artefact of one map drawing luckier seeds than another.

* RANK, NOT LINEAR. staticScore is a bounded, saturating, hand-weighted
  composite; its spacing is not meaningful, only its ordering is. Spearman is
  the honest test of the claim actually being made, which is "higher score
  ranks better".

* THE INTERVAL IS THE RESULT. A bare rho over ~20 maps is indistinguishable
  from noise, so every coefficient here is reported with n and a BCa-free
  percentile bootstrap CI over maps (the resampling unit is the MAP, because
  episodes within a map are not independent).

Usage:
  score_play_corr.py select  --manifest M.json --n 20 --out plan.json
  score_play_corr.py run     --plan plan.json --episodes 5 --jobs 3
  score_play_corr.py analyze --plan plan.json
"""

import argparse
import json
import os
import random
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MAP_EVAL = os.environ.get("MAP_EVAL", "/tmp/mapeval")
MAP_PLAYTEST = os.environ.get("MAP_PLAYTEST", "/tmp/mapplaytest")


# --------------------------------------------------------------------------
# select
# --------------------------------------------------------------------------

def cmd_select(args):
    manifest = json.load(open(args.manifest))
    maps = manifest["maps"]
    control = [m for m in maps if m["label"] == "arena"]
    valid = [m for m in maps if m["valid"] and m["label"] != "arena"]
    valid.sort(key=lambda m: m["staticScore"])
    if not valid:
        sys.exit("no valid non-control maps in manifest")

    # Extending an existing sample rather than replacing it. n = 20 maps only
    # resolves |rho| >= ~0.45 (the null SD of Spearman is 1/sqrt(n-1)), so the
    # honest move when the first batch comes back inconclusive is to buy more
    # MAPS, not more episodes — the resampling unit is the map. Excluding the
    # seeds already used keeps the second batch on fresh board shells.
    if args.exclude:
        prior = json.load(open(args.exclude))
        seen = {m["label"] for m in prior["maps"]}
        seen_seeds = {m["seed"] for m in prior["maps"]}
        valid = [m for m in valid
                 if m["label"] not in seen and m["seed"] not in seen_seeds]
        print(f"excluding {len(seen)} already-planned maps on "
              f"{len(seen_seeds)} seeds; {len(valid)} candidates left")

    # Stratified across the score range, and within a stratum preferring a seed
    # we have not used yet. Two attempts of one seed share a board shell, so a
    # sample that clustered on a few seeds would measure that shell as much as
    # the score. Strata are equal-COUNT (quantile) rather than equal-WIDTH: the
    # population is dense at the top and thin at the bottom, and equal-width
    # bins would spend most of the budget on empty ground.
    want = args.n
    picked, used_seeds = [], set()
    strata = [valid[i * len(valid) // want:(i + 1) * len(valid) // want]
              for i in range(want)]
    for stratum in strata:
        if not stratum:
            continue
        fresh = [m for m in stratum if m["seed"] not in used_seeds]
        pool = fresh if fresh else stratum
        # Deterministic pick: the median of the pool, so re-running select on
        # the same manifest reproduces the same sample.
        choice = pool[len(pool) // 2]
        picked.append(choice)
        used_seeds.add(choice["seed"])

    picked.sort(key=lambda m: m["staticScore"])
    plan = {
        "base_sha": manifest.get("base_sha", ""),
        "size": manifest.get("size"),
        "teams": manifest.get("teams"),
        "control": control,
        "maps": picked,
        "seeds_used": sorted(used_seeds),
    }
    json.dump(plan, open(args.out, "w"), indent=2)
    lo, hi = picked[0]["staticScore"], picked[-1]["staticScore"]
    print(f"selected {len(picked)} maps over {len(used_seeds)} distinct seeds, "
          f"staticScore {lo:.3f}..{hi:.3f} (spread {hi - lo:.3f})")
    print(f"plus the arena control at {control[0]['staticScore']:.3f}"
          if control else "NO CONTROL IN MANIFEST")
    print("plan -> " + args.out)


# --------------------------------------------------------------------------
# run
# --------------------------------------------------------------------------

def play_one(entry, episodes, outroot, port):
    """Record N episodes of one map, then extract play evidence from each."""
    label = entry["label"]
    outdir = os.path.join(outroot, label)
    os.makedirs(outdir, exist_ok=True)
    done = [f for f in os.listdir(outdir) if f.endswith(".play.json")]
    if len(done) >= episodes:
        return label, "cached", len(done)
    log = open(os.path.join(outdir, "play.log"), "w")
    rc = subprocess.call(
        [MAP_EVAL, "play", entry["spec"], "--episodes", str(episodes),
         "--out", outdir, "--port", str(port)],
        cwd=REPO, stdout=log, stderr=subprocess.STDOUT)
    log.close()
    if rc != 0:
        return label, f"map_eval play FAILED rc={rc}", 0
    made = 0
    for f in sorted(os.listdir(outdir)):
        if not f.endswith(".bitreplay"):
            continue
        src = os.path.join(outdir, f)
        dst = src.replace(".bitreplay", ".play.json")
        r = subprocess.call([MAP_PLAYTEST, src, "--name", label, "--out", dst],
                            cwd=REPO, stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
        if r == 0:
            made += 1
    return label, "ok", made


def cmd_run(args):
    plan = json.load(open(args.plan))
    entries = list(plan["control"]) + list(plan["maps"])
    os.makedirs(args.out, exist_ok=True)
    print(f"playing {len(entries)} maps x {args.episodes} episodes "
          f"= {len(entries) * args.episodes} episodes, {args.jobs} at a time")
    results = []
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [
            pool.submit(play_one, e, args.episodes, args.out,
                        args.port + 40 * i)
            for i, e in enumerate(entries)]
        for f in futures:
            label, status, n = f.result()
            print(f"  {label:<12} {status:<10} {n} episode(s)", flush=True)
            results.append((label, status, n))
    bad = [r for r in results if r[1] not in ("ok", "cached")]
    if bad:
        print(f"\n{len(bad)} map(s) FAILED: {[b[0] for b in bad]}")
    plan["evidence_root"] = os.path.abspath(args.out)
    plan["episodes"] = args.episodes
    json.dump(plan, open(args.plan, "w"), indent=2)


# --------------------------------------------------------------------------
# analyze
# --------------------------------------------------------------------------

def load_evidence(root, label):
    d = os.path.join(root, label)
    if not os.path.isdir(d):
        return []
    out = []
    for f in sorted(os.listdir(d)):
        if f.endswith(".play.json"):
            out.append(json.load(open(os.path.join(d, f))))
    return out


def aggregate(eps):
    """One map's play outcomes, merged across its episodes.

    Rule 4: a capture ENDS the episode, so episode length is an outcome and a
    mean over episodes hides it — `ticks_all` keeps the whole distribution.
    Dead floor is merged as a UNION over episodes, not a mean of per-episode
    fractions: 'floor no episode ever touched' is the map defect, while a mean
    mostly re-measures episode length (map_eval's own banner makes this point
    about the arena reading 24% dead at one long episode and 51% at three
    short ones).
    """
    if not eps:
        return None
    gw, gh = eps[0]["gw"], eps[0]["gh"]
    wall = eps[0]["wall"]
    union = [0] * (gw * gh)
    for e in eps:
        for i, v in enumerate(e["occupancy"]):
            if v > 0:
                union[i] = 1
    open_cells = sum(1 for i in range(gw * gh) if wall[i] == 0)
    visited = sum(1 for i in range(gw * gh) if wall[i] == 0 and union[i])
    ticks = [e["ticks"] for e in eps]
    caps = [e["captures"] for e in eps]
    steals = [e["steals"] for e in eps]
    return {
        "episodes": len(eps),
        "ticks_all": ticks,
        "ticks_mean": sum(ticks) / len(ticks),
        "captures_total": sum(caps),
        "captures_per_ep": sum(caps) / len(eps),
        "capture_rate": sum(1 for c in caps if c > 0) / len(eps),
        "steals_per_ep": sum(steals) / len(eps),
        "conversion": (sum(caps) / sum(steals)) if sum(steals) else 0.0,
        "deadFloorFrac": 1.0 - visited / max(1, open_cells),
        "fightTimeFrac": sum(e["play"]["fightTimeFrac"] for e in eps) / len(eps),
        "pace": sum(e["play"]["pace"] for e in eps) / len(eps),
        "balanceEntropy": sum(e["play"]["balanceEntropy"] for e in eps) / len(eps),
        "deadFloor_perEp": sum(e["play"]["deadFloorFrac"] for e in eps) / len(eps),
    }


def spearman(xs, ys):
    from scipy import stats
    r = stats.spearmanr(xs, ys)
    return float(r.statistic), float(r.pvalue)


def boot_ci(xs, ys, iters=10000, seed=20260806):
    """Percentile bootstrap over MAPS — the unit that is independent.

    Episodes inside a map share its geometry, so resampling episodes would
    understate the interval. Resampling maps is the honest unit and is why the
    interval below is as wide as it is: n is small because each point costs
    `episodes` full games.
    """
    from scipy import stats
    rng = random.Random(seed)
    n = len(xs)
    out = []
    for _ in range(iters):
        idx = [rng.randrange(n) for _ in range(n)]
        bx = [xs[i] for i in idx]
        by = [ys[i] for i in idx]
        if len(set(bx)) < 3 or len(set(by)) < 3:
            continue
        rho = stats.spearmanr(bx, by).statistic
        if rho == rho:  # not NaN
            out.append(float(rho))
    out.sort()
    if len(out) < 100:
        return None, None
    return out[int(0.025 * len(out))], out[int(0.975 * len(out))]


OUTCOMES = [
    # (key, human name, sign: +1 if HIGHER is a better map, -1 if lower is)
    ("deadFloorFrac", "dead floor (union over episodes)", -1),
    ("fightTimeFrac", "fight time / alive time", +1),
    ("captures_per_ep", "captures per episode", +1),
    ("capture_rate", "episodes that converted", +1),
    ("conversion", "captures / steals", +1),
    ("ticks_mean", "episode length (ticks)", -1),
    ("pace", "kills per 1000 ticks", +1),
    ("balanceEntropy", "kill balance across teams", +1),
    ("steals_per_ep", "steals per episode", +1),
]


def cmd_repeat(args):
    """Replay maps we already played, on the SAME episode seeds, and diff.

    This is the noise floor of the whole instrument, and it is NOT optional
    here. `server.runFrameLimiter` advances a frame when the wall-clock budget
    elapses OR when every player reports ready, so a bot that misses its
    budget under fleet load hands the sim a stale command and the episode
    forks. This machine runs 20+ agents at once and the load average sat above
    30 for the whole batch, so "same map, same seed, same outcome" has to be
    measured rather than assumed. Whatever this prints is the resolution below
    which no per-map difference in the main table means anything.
    """
    plan = json.load(open(args.plan))
    root = plan["evidence_root"]
    targets = (list(plan["control"]) + list(plan["maps"]))[:args.maps]
    repeat_root = root + "-repeat"
    os.makedirs(repeat_root, exist_ok=True)
    print(f"re-playing {len(targets)} map(s) x {plan['episodes']} episodes "
          f"on identical seeds")
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        list(pool.map(
            lambda ie: play_one(ie[1], plan["episodes"], repeat_root,
                                args.port + 40 * ie[0]),
            enumerate(targets)))

    print(f"\n{'map':<10} {'ep':>3} {'ticks A':>8} {'ticks B':>8} "
          f"{'dead A':>7} {'dead B':>7} {'cap A':>6} {'cap B':>6}")
    exact = total = 0
    for entry in targets:
        a = load_evidence(root, entry["label"])
        b = load_evidence(repeat_root, entry["label"])
        for i in range(min(len(a), len(b))):
            total += 1
            same = (a[i]["ticks"] == b[i]["ticks"]
                    and a[i]["captures"] == b[i]["captures"])
            if same:
                exact += 1
            print(f"{entry['label']:<10} {i:>3} {a[i]['ticks']:>8} "
                  f"{b[i]['ticks']:>8} "
                  f"{a[i]['play']['deadFloorFrac']:>7.3f} "
                  f"{b[i]['play']['deadFloorFrac']:>7.3f} "
                  f"{a[i]['captures']:>6} {b[i]['captures']:>6}"
                  f"{'' if same else '   <-- FORKED'}")
    print(f"\n{exact}/{total} episode(s) reproduced exactly "
          f"(ticks AND captures identical)")
    if total and exact == total:
        print("The episode loop is deterministic under load: every per-map "
              "difference in the main table is geometry, not scheduling.")
    else:
        print("The episode loop FORKS under load. Per-map outcomes carry "
              "scheduling noise, so treat the per-map means as estimates with "
              "this much slop and lean on the bootstrap interval, not on any "
              "single map's position.")


def cmd_analyze(args):
    plans = [json.load(open(p)) for p in args.plan]
    plan = plans[0]
    # Batches are POOLED, not averaged: they are the same protocol on the same
    # board scale with the same episode seeds, differing only in which maps the
    # stratifier drew. The control is played once and belongs to the pool once.
    entries, seen = [], set()
    for p in plans:
        for e in list(p["control"]) + list(p["maps"]):
            if e["label"] in seen:
                continue
            seen.add(e["label"])
            e["_root"] = p["evidence_root"]
            entries.append(e)
    rows = []
    for entry in entries:
        root = entry["_root"]
        eps = load_evidence(root, entry["label"])
        agg = aggregate(eps)
        if not agg:
            print(f"  (no evidence for {entry['label']}, dropped)")
            continue
        agg["label"] = entry["label"]
        agg["staticScore"] = entry["staticScore"]
        agg["interiorFrac"] = entry["interiorFrac"]
        agg["is_control"] = entry["label"] == "arena"
        agg["bands"] = entry["bands"]
        rows.append(agg)

    gen = [r for r in rows if not r["is_control"]]
    ctrl = next((r for r in rows if r["is_control"]), None)

    print("=" * 78)
    print(f"staticScore vs PLAY   base {plan.get('base_sha','?')[:12]}   "
          f"{plan['episodes']} episodes/map   size={plan.get('size')}")
    print("=" * 78)
    print(f"{'map':<10} {'score':>6} {'intr':>6} {'dead':>6} {'fight':>6} "
          f"{'cap/ep':>7} {'conv':>6} {'ticks':>7} {'pace':>6}")
    for r in sorted(rows, key=lambda r: r["staticScore"]):
        mark = "*" if r["is_control"] else " "
        print(f"{mark}{r['label']:<9} {r['staticScore']:>6.3f} "
              f"{r['interiorFrac']:>6.3f} {r['deadFloorFrac']:>6.3f} "
              f"{r['fightTimeFrac']:>6.3f} {r['captures_per_ep']:>7.2f} "
              f"{r['conversion']:>6.2f} {r['ticks_mean']:>7.0f} "
              f"{r['pace']:>6.2f}")

    if ctrl:
        worse = sum(1 for r in gen if r["deadFloorFrac"] < ctrl["deadFloorFrac"])
        print(f"\ncontrol (arena): staticScore {ctrl['staticScore']:.3f} "
              f"(rank {sum(1 for r in gen if r['staticScore'] > ctrl['staticScore']) + 1}"
              f"/{len(gen) + 1}), dead floor {ctrl['deadFloorFrac']:.3f} "
              f"({worse} generated map(s) use MORE of their floor)")

    def report(rows_, title):
        print(f"\n--- {title}  (n = {len(rows_)} maps) ---")
        xs = [r["staticScore"] for r in rows_]
        print(f"{'outcome':<34} {'rho':>7} {'95% CI':>18} {'p':>8}  reading")
        for key, name, sign in OUTCOMES:
            ys = [r[key] for r in rows_]
            if len(set(ys)) < 3:
                print(f"{name:<34}   (outcome is near-constant, skipped)")
                continue
            rho, p = spearman(xs, ys)
            lo, hi = boot_ci(xs, ys)
            ci = f"[{lo:+.2f}, {hi:+.2f}]" if lo is not None else "  (undefined)"
            # "aligned" = the score's ordering agrees with the direction we
            # would call better. The sign flip is applied to the READING, never
            # to the coefficient, so the printed rho is always the raw one.
            aligned = "aligned" if rho * sign > 0 else "OPPOSITE"
            if lo is not None and lo <= 0 <= hi:
                aligned = "no signal"
            print(f"{name:<34} {rho:>+7.3f} {ci:>18} {p:>8.3f}  {aligned}")

    report(rows, "ALL MAPS, control included")
    report(gen, "GENERATED ONLY (control excluded)")

    # The score is a weighted mean, so a null on the whole can still hide a
    # band that works. Per-band rank correlations against the primary outcome
    # say which bands, if any, carry play signal — that is the re-weighting
    # evidence the epic needs.
    print(f"\n--- per-BAND vs dead floor, generated maps (n = {len(gen)}) ---")
    print("a band with no VARIANCE cannot discriminate no matter its weight")
    band_names = list(gen[0]["bands"].keys())
    print(f"{'band':<22} {'w':>4} {'distinct':>9} {'rho(sub,dead)':>14} "
          f"{'rho(value,dead)':>16}")
    for b in band_names:
        subs = [r["bands"][b]["sub"] for r in gen]
        vals = [r["bands"][b]["value"] for r in gen]
        dead = [r["deadFloorFrac"] for r in gen]
        w = gen[0]["bands"][b]["weight"]
        nd = len(set(round(s, 6) for s in subs))
        rs = f"{spearman(subs, dead)[0]:+.3f}" if nd >= 3 else "  saturated"
        rv = (f"{spearman(vals, dead)[0]:+.3f}"
              if len(set(round(v, 6) for v in vals)) >= 3 else "  constant")
        print(f"{b:<22} {w:>4.1f} {nd:>9} {rs:>14} {rv:>16}")

    json.dump(rows, open(args.out, "w"), indent=2, default=str)
    print(f"\nrows -> {args.out}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("select")
    s.add_argument("--manifest", required=True)
    s.add_argument("--n", type=int, default=20)
    s.add_argument("--exclude", help="a prior plan.json whose maps/seeds to skip")
    s.add_argument("--out", required=True)
    s.set_defaults(func=cmd_select)

    r = sub.add_parser("run")
    r.add_argument("--plan", required=True)
    r.add_argument("--episodes", type=int, default=5)
    r.add_argument("--jobs", type=int, default=3)
    r.add_argument("--port", type=int, default=23000)
    r.add_argument("--out", default="/tmp/ctf-score-play")
    r.set_defaults(func=cmd_run)

    p = sub.add_parser("repeat")
    p.add_argument("--plan", required=True)
    p.add_argument("--maps", type=int, default=3)
    p.add_argument("--jobs", type=int, default=3)
    p.add_argument("--port", type=int, default=25000)
    p.set_defaults(func=cmd_repeat)

    a = sub.add_parser("analyze")
    a.add_argument("--plan", required=True, nargs="+")
    a.add_argument("--out", default="/tmp/ctf-score-play/rows.json")
    a.set_defaults(func=cmd_analyze)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

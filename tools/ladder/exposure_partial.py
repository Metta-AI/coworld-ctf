#!/usr/bin/env python3
"""The decisive test for the exposure lane: does VISIBILITY add anything over
PROXIMITY?

Exposure is, mechanically, "an enemy is near AND has a clear line AND is
pointed at me". Contact volume is already a known, owned finding (86% of the
ffa4 gap). If exposure's link to the attrition margin vanishes once distance
to the nearest live enemy is partialled out, then this whole lane is a
re-measurement of contact volume wearing a visibility label, and there is no
new lever here.

Three tests, in increasing strictness:
  1. Partial correlation of each metric with margin @T=1200, controlling for
     mean distance to the nearest live enemy.
  2. The same inside CONTACT BINS: policies compared only against team-Eps
     that ran at the same proximity, so the contact level is held fixed by
     construction rather than by a linear control.
  3. The cross-policy scatter over all 42 entrants, printed raw, so a single
     counterexample policy is visible rather than averaged away.

Also: a DEDUPLICATED futility bound. One death is preceded by several damage
events, so counting cower rows over-counts deaths several-fold; rows are
grouped back into distinct death events before anything is divided by them.
"""
import json, math, sys, collections, statistics

PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/expcensus/all2.jsonl"
OURS = "softmaxwell"
FORK = "FJM Picasso v47"
FILLER = "Baseline"


def base_name(a):
    i = a.rfind(" (")
    return a[:i] if i > 0 and a.endswith(")") else a


def pearson(xs, ys):
    n = len(xs)
    if n < 4:
        return float("nan"), None
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    if sxx <= 0 or syy <= 0:
        return float("nan"), None
    r = sxy / math.sqrt(sxx * syy)
    if abs(r) >= 0.9999:
        return r, None
    se = 1 / math.sqrt(n - 3)
    return r, (math.tanh(math.atanh(r) - 1.96 * se),
               math.tanh(math.atanh(r) + 1.96 * se))


def partial(xs, ys, zs):
    """corr(x, y | z) via the standard three-correlation identity."""
    rxy, _ = pearson(xs, ys)
    rxz, _ = pearson(xs, zs)
    ryz, _ = pearson(ys, zs)
    d = math.sqrt(max(1e-12, (1 - rxz ** 2) * (1 - ryz ** 2)))
    r = (rxy - rxz * ryz) / d
    n = len(xs)
    se = 1 / math.sqrt(max(1, n - 4))
    if abs(r) >= 0.9999:
        return r, None
    return r, (math.tanh(math.atanh(r) - 1.96 * se),
               math.tanh(math.atanh(r) + 1.96 * se))


rows = []
deaths_ev = collections.defaultdict(list)   # (ep, policy) -> [death tick]
for line in open(PATH):
    d = json.loads(line)
    if "error" in d or d.get("teams") != 4 or len(d["seats"]) != 16:
        continue
    pol = {s["seat"]: base_name(s["addr"]) for s in d["seats"]}
    byTeam = collections.defaultdict(list)
    for s in d["seats"]:
        byTeam[s["team"]].append(s)
    spent = {t: sum(s["ns_deaths"] for s in ss) for t, ss in byTeam.items()}
    for t, ss in byTeam.items():
        names = {base_name(s["addr"]) for s in ss}
        if len(names) != 1:
            continue
        alive = sum(s["alive_ticks"] for s in ss)
        ea = sum(s["early_alive_ticks"] for s in ss)
        rt = sum(s["ring_ticks"] for s in ss)
        if not alive or not ea:
            continue
        rv = [v for k, v in spent.items() if k != t]
        rows.append(dict(
            ep=d["replay"], policy=names.pop(), team=t,
            win=1 if d.get("winner") == t else 0,
            margin=sum(rv) / len(rv) - spent[t],
            near=sum(s["near_enemy_sum"] for s in ss) / alive,
            exp_see=sum(s["exp_see_sum"] for s in ss) / alive,
            multi=sum(sum(s["exp_see_hist"][2:]) for s in ss) / alive,
            early_see=sum(s["early_exp_see"] for s in ss) / ea,
            early_budget=sum(s["early_exp_see"] for s in ss) / (4 * d["early_win"]),
            ring=sum(s["cover_ring_sum"] for s in ss) / alive,
            ring_seen=(sum(s["ring_seen_ticks"] for s in ss) / rt) if rt else None,
            aim_free=sum(s["aim_free_sum"] for s in ss) / alive,
            turn_rate=sum(s["turn_brads"] for s in ss) / alive,
            dmg=sum(s["dmg_taken"] for s in ss),
            deaths=sum(s["deaths"] for s in ss),
        ))
    # distinct death events per (ep, policy), from the cower rows
    for c in d["cower_rows"]:
        if c["lag"] != 60 or not c["los0"] or c["out"] != "v_dead":
            continue
        deaths_ev[(d["replay"], pol.get(c["v"]))].append((c["t"], c["brk0"], c["brkd0"]))

FIELDROWS = [r for r in rows if r["policy"] not in (FORK, FILLER)]
print(f"team-episodes {len(FIELDROWS)}  policies {len({r['policy'] for r in FIELDROWS})}")
print()

METRICS = ["exp_see", "multi", "early_see", "early_budget", "ring_seen",
           "ring", "aim_free", "turn_rate"]

print("=" * 92)
print("TEST 1  PARTIAL CORRELATION with margin@1200, controlling for PROXIMITY")
print("        (`near` = mean px to the nearest live enemy, per alive tick)")
print("=" * 92)
print(f"  {'metric':<14} {'raw r':>18}   {'r | near':>18}   shrinkage")
base = [r["near"] for r in FIELDROWS]
mar = [r["margin"] for r in FIELDROWS]
r0, ci0 = pearson(base, mar)
print(f"  {'near (control)':<14} {r0:+.3f} [{ci0[0]:+.3f},{ci0[1]:+.3f}]        —")
for m in METRICS:
    sub = [r for r in FIELDROWS if r[m] is not None]
    xs = [r[m] for r in sub]
    ys = [r["margin"] for r in sub]
    zs = [r["near"] for r in sub]
    ra, cia = pearson(xs, ys)
    rp, cip = partial(xs, ys, zs)
    shrink = 100 * (1 - abs(rp) / abs(ra)) if ra == ra and abs(ra) > 1e-9 else float("nan")
    f = lambda r, c: f"{r:+.3f} [{c[0]:+.3f},{c[1]:+.3f}]" if c else f"{r:+.3f}"
    print(f"  {m:<14} {f(ra,cia):>18}   {f(rp,cip):>18}   {shrink:5.1f}%")
print()

print("=" * 92)
print("TEST 2  INSIDE CONTACT BINS — team-Eps grouped by proximity quintile,")
print("        each metric re-correlated with margin INSIDE the bin only.")
print("=" * 92)
qs = sorted(r["near"] for r in FIELDROWS)
cuts = [qs[int(len(qs) * f)] for f in (0.2, 0.4, 0.6, 0.8)]
print(f"  proximity quintile cuts (px): {[round(c) for c in cuts]}")
for m in METRICS[:5]:
    out = []
    for i in range(5):
        lo = cuts[i - 1] if i > 0 else -1e9
        hi = cuts[i] if i < 4 else 1e9
        sub = [r for r in FIELDROWS if r[m] is not None and lo <= r["near"] < hi]
        if len(sub) < 50:
            out.append("   n/a ")
            continue
        rr, _ = pearson([r[m] for r in sub], [r["margin"] for r in sub])
        out.append(f"{rr:+.3f}")
    print(f"  {m:<14} " + "  ".join(f"{o:>7}" for o in out))
print()

print("=" * 92)
print("TEST 3  THE CROSS-POLICY SCATTER, RAW — 42 entrants, >=20 team-Eps")
print("        sorted by ffa4 win rate. Look for a policy that wins WITHOUT")
print("        the exposure discipline: one is enough to break the lane.")
print("=" * 92)
byp = collections.defaultdict(list)
for r in FIELDROWS:
    byp[r["policy"]].append(r)
print(f"  {'policy':<26}{'win%':>6}{'margin':>8}{'exp_see':>9}{'multi%':>8}"
      f"{'ring':>7}{'ringSeen%':>10}{'near':>7}{'turn':>6}{'n':>5}")
tab = []
for p, v in sorted(byp.items(), key=lambda kv: -sum(x["win"] for x in kv[1]) / len(kv[1])):
    if len(v) < 20:
        continue
    g = lambda k: sum(x[k] for x in v if x[k] is not None) / max(1, len([x for x in v if x[k] is not None]))
    tab.append((p, 100 * g("win"), g("margin"), g("exp_see"), 100 * g("multi"),
                g("ring"), 100 * g("ring_seen"), g("near"), g("turn_rate"), len(v)))
for t in tab:
    mark = "  <== US" if t[0] == OURS else ""
    print(f"  {t[0]:<26}{t[1]:6.1f}{t[2]:8.2f}{t[3]:9.3f}{t[4]:8.2f}"
          f"{t[5]:7.2f}{t[6]:10.1f}{t[7]:7.0f}{t[8]:6.2f}{t[9]:5d}{mark}")
print()
for k, i in [("exp_see", 3), ("multi", 4), ("ring", 5), ("ring_seen", 6),
             ("near", 7), ("turn_rate", 8), ("margin", 2)]:
    rr, cc = pearson([t[i] for t in tab], [t[1] for t in tab])
    print(f"    corr({k:<10}, win rate) over {len(tab)} policies = {rr:+.3f}"
          + (f" [{cc[0]:+.3f},{cc[1]:+.3f}]" if cc else ""))
print()

print("=" * 92)
print("TEST 4  DEDUPLICATED FUTILITY BOUND")
print("        Several damage events precede one death; rows are grouped back")
print("        into distinct death events before anything is divided by them.")
print("=" * 92)
for pol in [OURS, "relh", "richard", "daveey", "Ron @ SWGY"]:
    eps = {r["ep"] for r in rows if r["policy"] == pol}
    if not eps:
        continue
    nDeathEv = 0
    nWithCover = 0
    nDuck = 0
    nBank = 0
    for (ep, p), evs in deaths_ev.items():
        if p != pol or ep not in eps:
            continue
        evs.sort()
        groups = []
        for t, brk, bd in evs:
            if groups and t - groups[-1][0] <= 60:
                # same death: keep the LAST (closest to the death) geometry
                groups[-1] = (groups[-1][0], brk, bd)
                continue
            groups.append((t, brk, bd))
        nDeathEv += len(groups)
        for _, brk, bd in groups:
            if brk:
                nWithCover += 1
                if bd <= 24:
                    nDuck += 1
                elif bd <= 80:
                    nBank += 1
    tot = sum(r["deaths"] for r in rows if r["policy"] == pol)
    n = len(eps)
    print(f"  {pol:<14} team-Eps {n:4d}  total deaths {tot/n:5.2f}/Ep"
          f"  | deaths preceded by a seen hit {nDeathEv/n:5.2f}/Ep"
          f"  with a LOS-break reachable {nWithCover/n:5.2f}/Ep"
          f"  (<=24px {nDuck/n:4.2f}, 25-80px {nBank/n:4.2f})")

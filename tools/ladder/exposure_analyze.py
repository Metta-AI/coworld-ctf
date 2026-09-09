#!/usr/bin/env python3
"""Analyse the exposure_census JSONL over the Elite ffa4 corpus.

Unit of clustering is the TEAM-EPISODE (one policy's 4 seats in one episode).
Identity is the replay `addr` (player.address == slot_address), never the API
player_name and never a seat-parity rule. "FJM Picasso v47" is OUR OWN FORK and
is excluded from every "field" aggregate. "Baseline" is the scripted filler and
is reported separately as a CONTROL, never inside the field.

Every headline is reported twice: as an absolute, and as a WITHIN-EPISODE PAIRED
contrast (our value minus the mean of the 3 rival teams on the same map, same
tick budget). Only the paired form survives the 7.7x seed-block spread.
"""
import json, math, sys, collections, statistics

PATH = sys.argv[1] if len(sys.argv) > 1 else "/tmp/expcensus/all.jsonl"
OURS = "softmaxwell"
FORK = "FJM Picasso v47"
FILLER = "Baseline"
RIVALS = ["relh", "richard", "daveey", "Ron @ SWGY"]
NS = 1200


def base_name(addr):
    """'daveey (3)' -> 'daveey'. The suffix is a seat, not a policy."""
    i = addr.rfind(" (")
    return addr[:i] if i > 0 and addr.endswith(")") else addr


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (p, c - h, c + h)


def mean_ci(xs):
    n = len(xs)
    if n == 0:
        return (float("nan"), float("nan"), float("nan"), 0)
    m = sum(xs) / n
    if n < 2:
        return (m, m, m, n)
    sd = statistics.stdev(xs)
    se = sd / math.sqrt(n)
    return (m, m - 1.96 * se, m + 1.96 * se, n)


def pearson(xs, ys):
    n = len(xs)
    if n < 3:
        return float("nan"), float("nan")
    mx, my = sum(xs) / n, sum(ys) / n
    sxx = sum((x - mx) ** 2 for x in xs)
    syy = sum((y - my) ** 2 for y in ys)
    sxy = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    if sxx <= 0 or syy <= 0:
        return float("nan"), float("nan")
    r = sxy / math.sqrt(sxx * syy)
    # Fisher z 95% CI half-width
    if abs(r) >= 0.9999:
        return r, float("nan")
    se = 1 / math.sqrt(n - 3)
    lo = math.tanh(math.atanh(r) - 1.96 * se)
    hi = math.tanh(math.atanh(r) + 1.96 * se)
    return r, (lo, hi)


# ---------------------------------------------------------------- ingest ----
teamEps = []          # one record per (episode, policy team)
cower = []            # one record per cower row, tagged with the victim policy
nEp = 0
skipped = collections.Counter()

for line in open(PATH):
    line = line.strip()
    if not line:
        continue
    d = json.loads(line)
    if "error" in d:
        skipped["tool_error"] += 1
        continue
    if d.get("teams") != 4:
        skipped["not_4team"] += 1
        continue
    seats = d["seats"]
    if len(seats) != 16:
        skipped["not_16_seats"] += 1
        continue
    nEp += 1
    # seat -> policy, seat -> team colour
    pol = {s["seat"]: base_name(s["addr"]) for s in seats}
    byTeam = collections.defaultdict(list)
    for s in seats:
        byTeam[s["team"]].append(s)
    # lives spent by T=1200 per team colour (for the attrition margin)
    spent = {t: sum(s["ns_deaths"] for s in ss) for t, ss in byTeam.items()}
    recs = {}
    for t, ss in byTeam.items():
        names = {base_name(s["addr"]) for s in ss}
        if len(names) != 1:
            skipped["mixed_team"] += 1
            continue
        name = names.pop()
        alive = sum(s["alive_ticks"] for s in ss)
        nsAlive = sum(s["ns_alive_ticks"] for s in ss)
        uf = sum(s["uf_ticks"] for s in ss)
        turn = sum(s["turn_brads"] for s in ss)
        rivals = [v for k, v in spent.items() if k != t]
        r = dict(
            ep=d["replay"], team=t, policy=name,
            win=1 if d.get("winner") == t else 0,
            alive=alive, ns_alive=nsAlive, uf=uf,
            exp_los=sum(s["exp_los_sum"] for s in ss) / alive if alive else None,
            exp_see=sum(s["exp_see_sum"] for s in ss) / alive if alive else None,
            ns_exp_see=sum(s["ns_exp_see_sum"] for s in ss) / nsAlive if nsAlive else None,
            ns_exp_los=sum(s["ns_exp_los_sum"] for s in ss) / nsAlive if nsAlive else None,
            see0=sum(s["see0_ticks"] for s in ss) / alive if alive else None,
            los0=sum(s["los0_ticks"] for s in ss) / alive if alive else None,
            multi=sum(sum(s["exp_see_hist"][2:]) for s in ss) / alive if alive else None,
            aim_free=sum(s["aim_free_sum"] for s in ss) / alive if alive else None,
            aim_short=sum(s["aim_short_ticks"] for s in ss) / alive if alive else None,
            turn_short=(sum(s["turn_short_brads"] for s in ss) / turn) if turn else None,
            turn_rate=turn / alive if alive else None,
            ring=sum(s["cover_ring_sum"] for s in ss) / alive if alive else None,
            uf_ring=sum(s["uf_cover_ring_sum"] for s in ss) / uf if uf else None,
            uf_exp_see=sum(s["uf_exp_see_sum"] for s in ss) / uf if uf else None,
            uf_near=sum(s["uf_near_enemy_sum"] for s in ss) / uf if uf else None,
            near=sum(s["near_enemy_sum"] for s in ss) / alive if alive else None,
            early_alive=sum(s["early_alive_ticks"] for s in ss),
            early_sat=sum(s["early_alive_ticks"] for s in ss) / (4 * d["early_win"]),
            early_see=(sum(s["early_exp_see"] for s in ss) /
                       sum(s["early_alive_ticks"] for s in ss)) if sum(s["early_alive_ticks"] for s in ss) else None,
            early_los=(sum(s["early_exp_los"] for s in ss) /
                       sum(s["early_alive_ticks"] for s in ss)) if sum(s["early_alive_ticks"] for s in ss) else None,
            early_multi=(sum(s["early_multi"] for s in ss) /
                         sum(s["early_alive_ticks"] for s in ss)) if sum(s["early_alive_ticks"] for s in ss) else None,
            # FIXED denominator: seeing-ticks per SEAT-TICK BUDGET, not per
            # alive tick. Dying makes this go DOWN, the opposite bias to the
            # per-alive-tick rate, so a sign that survives both is not the
            # survival tautology.
            early_budget=sum(s["early_exp_see"] for s in ss) / (4 * d["early_win"]),
            ring_seen=(sum(s["ring_seen_ticks"] for s in ss) /
                       sum(s["ring_ticks"] for s in ss)) if sum(s["ring_ticks"] for s in ss) else None,
            ring_frac=sum(s["ring_ticks"] for s in ss) / alive if alive else None,
            spent=spent[t],
            margin=(sum(rivals) / len(rivals) - spent[t]) if rivals else None,
            deaths=sum(s["deaths"] for s in ss),
            kills=sum(s["kills"] for s in ss),
        )
        recs[t] = r
    # within-episode paired contrast: each team vs the mean of the other three
    keys = ["exp_los", "exp_see", "ns_exp_see", "see0", "multi", "aim_free",
            "aim_short", "turn_short", "turn_rate", "ring", "uf_ring",
            "uf_exp_see", "uf_near", "near", "margin", "spent", "win",
            "early_see", "early_los", "early_multi", "early_budget",
            "early_sat", "ring_seen", "ring_frac"]
    for t, r in recs.items():
        others = [o for k, o in recs.items() if k != t]
        for k in keys:
            vals = [o[k] for o in others if o[k] is not None]
            r["p_" + k] = (r[k] - sum(vals) / len(vals)) if (r[k] is not None and vals) else None
        teamEps.append(r)
    for row in d["cower_rows"]:
        v = pol.get(row["v"])
        a = pol.get(row["a"])
        if v is None:
            continue
        cower.append(dict(row, vpol=v, apol=a, ep=d["replay"]))

print(f"episodes {nEp}  team-episodes {len(teamEps)}  cower rows {len(cower)}  skipped {dict(skipped)}")

FIELD = sorted({r["policy"] for r in teamEps} - {FORK, FILLER})
COUNTS = collections.Counter(r["policy"] for r in teamEps)
FOCUS = [OURS] + [x for x in RIVALS if x in COUNTS] + [FILLER]
print("field policies:", len(FIELD), " ours n=", COUNTS[OURS],
      {k: COUNTS[k] for k in FOCUS})
print()


def sel(pol=None):
    if pol is None:
        return [r for r in teamEps if r["policy"] not in (FORK, FILLER)]
    return [r for r in teamEps if r["policy"] == pol]


def table(key, label, pct=False, hi_is=""):
    print(f"--- {label}  [{key}] {hi_is}")
    rows = []
    for p in FOCUS:
        xs = [r[key] for r in sel(p) if r[key] is not None]
        px = [r["p_" + key] for r in sel(p) if r.get("p_" + key) is not None]
        m, lo, hi, n = mean_ci(xs)
        pm, plo, phi, pn = mean_ci(px)
        rows.append((p, m, lo, hi, n, pm, plo, phi))
    xs = [r[key] for r in sel() if r[key] is not None]
    m, lo, hi, n = mean_ci(xs)
    rows.append(("FIELD(-fork,-filler)", m, lo, hi, n, float("nan"), float("nan"), float("nan")))
    f = (lambda v: f"{100*v:6.2f}%") if pct else (lambda v: f"{v:8.3f}")
    for p, m, lo, hi, n, pm, plo, phi in rows:
        pr = "" if pm != pm else f"   paired {f(pm)} [{f(plo)},{f(phi)}]"
        print(f"  {p:<22} {f(m)} [{f(lo)},{f(hi)}]  n={n:5d}{pr}")
    print()


print("=" * 78)
print("M4  EXPOSURE — how many live enemies can SEE each seat, per alive tick")
print("=" * 78)
table("exp_see", "enemies SEEING us / alive tick (LOS AND cone)")
table("exp_los", "enemies with LOS to us / alive tick (geometry only)")
table("multi", "share of alive ticks with >=2 enemies seeing us", pct=True)
table("see0", "share of alive ticks seen by NOBODY", pct=True)
table("ns_exp_see", "enemies seeing us / alive tick, ticks<=1200 only")

print("=" * 78)
print("M2  COVER — blocked compass directions within 48px (0=open, 8=boxed)")
print("=" * 78)
table("ring", "cover ring, all alive ticks")
table("uf_ring", "cover ring, UNDER FIRE ticks only")
table("near", "px to nearest live enemy, all alive ticks")
table("uf_near", "px to nearest live enemy, UNDER FIRE ticks")

print("=" * 78)
print("M3  SIGHTLINE ECONOMY — where the seat is actually looking")
print("=" * 78)
table("aim_free", "free px along own aim ray before a wall (cap=visionRange)")
table("aim_short", "share of alive ticks aiming into a wall <250px", pct=True)
table("turn_short", "share of ALL turning done while the view is <250px", pct=True)
table("turn_rate", "brads turned / alive tick")

print("=" * 78)
print("M1  THE COWER TEST — outcome 60/120 ticks after taking a hit")
print("=" * 78)
for lag in (60, 120):
    print(f"--- lag {lag} ticks ({lag/30:.1f}s) — victim policy rows, los0=True only")
    for p in FOCUS + ["__FIELD__"]:
        if p == "__FIELD__":
            rows = [c for c in cower if c["lag"] == lag and c["los0"]
                    and c["vpol"] not in (FORK, FILLER)]
            name = "FIELD(-fork,-filler)"
        else:
            rows = [c for c in cower if c["lag"] == lag and c["los0"] and c["vpol"] == p]
            name = p
        n = len(rows)
        if n == 0:
            continue
        dead = sum(1 for c in rows if c["out"] == "v_dead")
        adead = sum(1 for c in rows if c["out"] == "a_dead")
        live = [c for c in rows if c["out"] == "live"]
        broke = sum(1 for c in live if not c["los1"])
        stay = len(live) - broke
        unseen = sum(1 for c in live if not c["see1"])
        dd = [c["d1"] - c["d0"] for c in live]
        m, lo, hi, _ = mean_ci(dd)
        pb, pbl, pbh = wilson(broke, len(live)) if live else (0, 0, 0)
        # counterfactual: a LOS-breaking spot was reachable at the hit tick
        avail = [c for c in live if c["brk0"]]
        pa, pal, pah = wilson(sum(1 for c in avail if not c["los1"]), len(avail)) if avail else (0, 0, 0)
        availAll = sum(1 for c in rows if c["brk0"])
        print(f"  {name:<22} n={n:5d}  died {100*dead/n:5.1f}%  killer-died {100*adead/n:5.1f}%"
              f"  | of {len(live):5d} live:  BROKE LOS {100*pb:5.1f}% [{100*pbl:.1f},{100*pbh:.1f}]"
              f"  still-LOS {100*stay/len(live) if live else 0:5.1f}%"
              f"  unseen {100*unseen/len(live) if live else 0:5.1f}%"
              f"  dRange {m:+6.1f}px"
              f"  | cover reachable {100*availAll/n:5.1f}%  ->broke {100*pa:5.1f}%")
    print()

print("=" * 78)
print("CALIBRATION — is each comparison policy actually good?")
print("=" * 78)
table("win", "ffa4 win rate (this team finishes first)", pct=True)
table("margin", "attrition margin @T=1200 (mean rival lives spent - ours)")
table("spent", "own lives spent by T=1200 (of 12)")
print()

print("=" * 78)
print("M2b THE WRONG-SIDE-OF-THE-WALL TEST")
print("    Of the alive ticks WITH cover adjacent (>=2 of 8 dirs blocked at")
print("    48px), what share does an enemy still SEE us on? Hugging geometry")
print("    is not the same as breaking a line.")
print("=" * 78)
table("ring_frac", "share of alive ticks with cover adjacent", pct=True)
table("ring_seen", "of THOSE, share an enemy still sees us", pct=True)

print("=" * 78)
print("M4b DECONFOUNDED EXPOSURE — first 400 ticks of Playing only")
print("=" * 78)
table("early_sat", "alive-tick saturation in the window (1.0 = nobody died)", pct=True)
table("early_see", "enemies seeing us / alive tick, EARLY window")
table("early_budget", "enemies-seeing-ticks / SEAT-TICK BUDGET, EARLY window")
table("early_multi", "share of EARLY alive ticks with >=2 enemies seeing us", pct=True)

print("=" * 78)
print("M5  DOES EXPOSURE PREDICT THE OBJECTIVE?  attrition margin @T=1200")
print("=" * 78)
print("  NOTE: any *rate per alive tick* is confounded by survival. `early_budget`")
print("  has a FIXED denominator (4 seats x 400 ticks) so dying LOWERS it — the")
print("  opposite bias. A sign that holds for both is not the tautology.")
for xk in ["early_budget", "early_see", "early_multi", "ns_exp_see", "exp_see",
           "multi", "ring", "uf_ring", "ring_seen", "aim_free", "aim_short",
           "turn_rate", "near"]:
    pts = [(r[xk], r["margin"], r["policy"]) for r in teamEps
           if r[xk] is not None and r["margin"] is not None
           and r["policy"] not in (FORK, FILLER)]
    if len(pts) < 20:
        continue
    # BETWEEN policy: one point per policy (its means)
    byp = collections.defaultdict(list)
    for x, y, p in pts:
        byp[p].append((x, y))
    bx = [sum(a for a, _ in v) / len(v) for v in byp.values() if len(v) >= 20]
    by = [sum(b for _, b in v) / len(v) for v in byp.values() if len(v) >= 20]
    rb, cib = pearson(bx, by)
    # WITHIN policy: centre each policy on its own mean
    wx, wy = [], []
    for p, v in byp.items():
        if len(v) < 20:
            continue
        mx = sum(a for a, _ in v) / len(v)
        my = sum(b for _, b in v) / len(v)
        for a, b in v:
            wx.append(a - mx)
            wy.append(b - my)
    rw, ciw = pearson(wx, wy)
    fmt = lambda ci: "n/a" if ci != ci else f"[{ci[0]:+.3f},{ci[1]:+.3f}]"
    print(f"  {xk:<12} BETWEEN r={rb:+.3f} {fmt(cib)} n={len(bx):3d} policies "
          f"| WITHIN r={rw:+.3f} {fmt(ciw)} n={len(wx):5d} team-Eps")
print()

print("=" * 78)
print("M5b PAIRED WITHIN-EPISODE — both sides differenced against the same map")
print("    x = our exposure minus the mean of the 3 rival teams THAT EPISODE")
print("    y = our margin, likewise. Map, seed and tick budget all cancel.")
print("=" * 78)
for xk in ["early_budget", "early_see", "exp_see", "multi", "ring_seen", "uf_ring"]:
    for pol in [None, OURS]:
        pts = [(r["p_" + xk], r["margin"]) for r in teamEps
               if r.get("p_" + xk) is not None and r["margin"] is not None
               and r["policy"] not in (FORK, FILLER)
               and (pol is None or r["policy"] == pol)]
        if len(pts) < 30:
            continue
        r0, ci = pearson([a for a, _ in pts], [b for _, b in pts])
        fmt = "n/a" if ci != ci else f"[{ci[0]:+.3f},{ci[1]:+.3f}]"
        who = "ALL POLICIES" if pol is None else pol
        print(f"  {xk:<14} {who:<14} r={r0:+.3f} {fmt} n={len(pts):5d}")
print()

print("=" * 78)
print("FUTILITY BOUND — realized coverage of an exposure primitive")
print("=" * 78)
for lag in (60,):
    ours = [c for c in cower if c["lag"] == lag and c["los0"] and c["vpol"] == OURS]
    n = len(ours)
    avail = [c for c in ours if c["brk0"]]
    missed = [c for c in avail if c["out"] == "live" and c["los1"]]
    diedAvail = [c for c in avail if c["out"] == "v_dead"]
    print(f"  our hits taken with LOS, lag {lag}: n={n}")
    print(f"    LOS-breaking spot reachable within 100px:  {len(avail)} ({100*len(avail)/n:.1f}%)")
    print(f"      ... and we were still in LOS {lag} ticks later: {len(missed)} ({100*len(missed)/n:.1f}% of all)")
    print(f"      ... and we DIED inside the window:           {len(diedAvail)} ({100*len(diedAvail)/n:.1f}% of all)")
    # WHICH SEARCH RADIUS would have reached it? findDuckCell (LIVE) searches
    # DuckSearchCells=3 at NavCell=8 -> 24px. findBankCell (ENV-GATED OFF)
    # searches BankSearchCells=10 -> 80px. Splitting the reachable spots by
    # distance prices the two levers separately.
    import collections as _c
    for lab, lo, hi in [("<=24px  (findDuckCell reach, LIVE)", 0, 24),
                        ("25-80px (findBankCell reach, ENV-OFF)", 25, 80),
                        (">80px   (neither)", 81, 10**9)]:
        band = [c for c in avail if lo <= c["brkd0"] <= hi]
        bl = [c for c in band if c["out"] == "live"]
        bm = [c for c in bl if c["los1"]]
        bd = [c for c in band if c["out"] == "v_dead"]
        if not band:
            continue
        print(f"      {lab:<40} n={len(band):5d} ({100*len(band)/n:4.1f}% of hits)"
              f"  still-LOS {len(bm):5d}  died {len(bd):5d}")
    eps = len({c["ep"] for c in ours})
    print(f"    episodes contributing: {eps};  missed-cover events per team-Ep: {len(missed)/eps:.2f}")
    print(f"    deaths-with-cover-available per team-Ep:     {len(diedAvail)/eps:.2f}   <-- the CEILING")

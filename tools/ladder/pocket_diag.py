"""pocket_diag — re-measure the CARRIER-DEATH premise on the CURRENT engine.

The pocketThreat/hpGate design rests on a diagnosis taken over 207 **GV27**
episodes: 48/69 of our carrier-killers stood >150px from the pedestal (39 of
them solo), and 44% of steals were taken at 1 HP. GV40 restored continuous
turret aim, which is exactly the physics that sets engagement range — so per
the standing rule that econ/tuning verdicts expire on a physics change, both
numbers are hypotheses again until re-measured here.

What this reads
---------------
The free public league corpus, re-simulated to the tier-2 event sink by
`extract_events` built at the SAME GameVersion as the replays (GV40 /
coworld 0.7.207+). Nothing here is hosted-A/B gated.

Geometry is not assumed. The league's "CTF Default" variant on the `paintbot`
coworld still runs the fixed classic arena: across the corpus, `flag_steal`
lands on exactly TWO distinct points, (186,329) and (1049,329), so the
pedestal a steal happened at is read off the steal event itself rather than
hard-coded. If that census ever shows more than a handful of points the map
went random and this tool says so instead of quietly averaging over maps.

Schema truths honored (verified against this corpus, not inherited)
-------------------------------------------------------------------
- `flag_steal.hp` is -1 ("never read"), so carrier HP at the steal is
  RECONSTRUCTED from the slot's `damage`/`heal`/`respawn` timeline.
- `damage.hp` IS populated at GV40 and is the victim's hp AFTER the hit;
  hp==0 co-occurs with death (2135 zero-hp damages vs 2195 deaths over 60
  episodes), so 0 means dead here. This CONTRADICTS the older
  touch_metrics note that hp==0 means "never read" — that note predates GV40.
- `kill`/`damage` x,y is the VICTIM's body; `death.source` is the victim and
  `death.target` the killer. `shot`/`flag_steal`/`capture` x,y is the
  SOURCE's own body. Only source-positioned events are used to place a killer.

Killer placement is explicit about its own error: a killer's position is the
nearest SOURCE-positioned sample of that slot in time, and every distance is
reported with the staleness (in ticks) of the sample behind it. Samples
staler than --max-stale are dropped rather than guessed at.

Usage:
    pocket_diag.py [--events '/tmp/pt_ev/*.jsonl'] [--max-stale 40]
"""
import argparse
import collections
import glob
import json
import math
import statistics

MAX_HP = 3

# Events whose x,y is the SOURCE slot's own body.
SOURCE_POS_KINDS = ("shot", "flag_steal", "capture", "grenade_throw",
                    "spray_use", "item_pickup", "flag_return")


def load(path):
    events, summary = [], None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if row.get("type") == "summary":
                summary = row
            else:
                events.append(row)
    return events, summary


def kind(r):
    return r.get("kind") or r.get("type")


def slot_tracks(events):
    """slot -> sorted [(tick, x, y)] from SOURCE-positioned events only."""
    t = collections.defaultdict(list)
    for r in events:
        k = kind(r)
        if k in SOURCE_POS_KINDS and r.get("source", -1) >= 0:
            t[r["source"]].append((r["tick"], r["x"], r["y"]))
        elif k == "death" and r.get("source", -1) >= 0:
            # death.source is the VICTIM and x,y is that victim's body.
            t[r["source"]].append((r["tick"], r["x"], r["y"]))
    for v in t.values():
        v.sort()
    return t


def pos_at(track, tick):
    """(x, y, staleness_ticks) of the nearest sample, or None."""
    if not track:
        return None
    best = min(track, key=lambda s: abs(s[0] - tick))
    return best[1], best[2], abs(best[0] - tick)


def hp_timeline(events):
    """slot -> sorted [(tick, hp_after)] from damage/heal/respawn."""
    t = collections.defaultdict(list)
    for r in events:
        k = kind(r)
        if k == "damage" and r.get("target", -1) >= 0 and r.get("hp", -1) >= 0:
            t[r["target"]].append((r["tick"], r["hp"]))
        elif k == "heal" and r.get("source", -1) >= 0 and r.get("hp", -1) >= 0:
            # Heal records the HEALED player in `source`.
            t[r["source"]].append((r["tick"], r["hp"]))
        elif k == "respawn" and r.get("source", -1) >= 0:
            t[r["source"]].append((r["tick"], MAX_HP))
    for v in t.values():
        v.sort()
    return t


def hp_at(tl, tick):
    """HP entering `tick`: the last recorded value strictly before it."""
    hp = MAX_HP
    for t, v in tl:
        if t < tick:
            hp = v
        else:
            break
    return hp


def analyse(paths, max_stale=40):
    steals = []
    ped_census = collections.Counter()
    used = 0
    for p in paths:
        events, summary = load(p)
        if not summary:
            continue
        used += 1
        team = summary.get("slot_team") or []
        tracks = slot_tracks(events)
        hps = hp_timeline(events)
        by_kind = collections.defaultdict(list)
        for r in events:
            by_kind[kind(r)].append(r)

        for st in by_kind["flag_steal"]:
            s, t0 = st["source"], st["tick"]
            ped = (st["x"], st["y"])
            ped_census[ped] += 1
            myteam = team[s] if s < len(team) else "?"

            # Outcome: first terminal event for this carry.
            cap = next((c for c in by_kind["capture"]
                        if c["source"] == s and c["tick"] > t0), None)
            dth = next((d for d in by_kind["death"]
                        if d["source"] == s and d["tick"] > t0), None)
            cap_t = cap["tick"] if cap else math.inf
            dth_t = dth["tick"] if dth else math.inf
            if cap_t < dth_t:
                outcome, life = "capture", cap_t - t0
            elif dth_t < math.inf:
                outcome, life = "killed", dth_t - t0
            else:
                outcome, life = "unresolved", None

            rec = {
                "ep": p, "carrier": s, "team": myteam, "tick": t0,
                "ped": ped, "hp": hp_at(hps.get(s, []), t0),
                "outcome": outcome, "life": life,
                "killer_dist": None, "killer_stale": None, "solo": None,
            }

            if outcome == "killed":
                killer = dth.get("target", -1)
                kp = pos_at(tracks.get(killer, []), dth["tick"])
                if kp and kp[2] <= max_stale:
                    rec["killer_dist"] = math.dist((kp[0], kp[1]), ped)
                    rec["killer_stale"] = kp[2]

            # ⭐ The DECISION point is the steal, not the death: the bot gates
            # its dive on what the pocket looks like as it touches. Counting
            # bodies at the death tick would score the gate on information it
            # cannot have, which flatters every threshold.
            for label, at in (("steal", t0), ("death", dth["tick"] if dth else None)):
                if at is None:
                    continue
                for rad in (150.0, 300.0):
                    n = 0
                    for slot, tr in tracks.items():
                        if slot >= len(team) or team[slot] == myteam:
                            continue
                        q = pos_at(tr, at)
                        if not q or q[2] > max_stale:
                            continue
                        if math.dist((q[0], q[1]), ped) <= rad:
                            n += 1
                    rec[f"{label}{int(rad)}"] = n
            steals.append(rec)
    return steals, ped_census, used


def pct(n, d):
    return f"{100.0*n/d:5.1f}%" if d else "    - "


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--events", default="/tmp/pt_ev/*.jsonl")
    ap.add_argument("--max-stale", type=int, default=40)
    a = ap.parse_args()
    paths = sorted(glob.glob(a.events))
    steals, ped, used = analyse(paths, a.max_stale)

    print(f"=== pocket_diag: {used} episodes, {len(steals)} steals "
          f"(max-stale {a.max_stale}t) ===\n")

    print(f"MAP GEOMETRY: {len(ped)} distinct pedestal points")
    for p, n in ped.most_common(6):
        print(f"   {p}  {n}")
    if len(ped) > 4:
        print("   ⚠️  map looks RANDOM — per-episode geometry, not a fixed arena")
    print()

    oc = collections.Counter(s["outcome"] for s in steals)
    print("STEAL OUTCOME")
    for k in ("capture", "killed", "unresolved"):
        print(f"   {k:<11} {oc[k]:4d}  {pct(oc[k], len(steals))}")
    print()

    # --- premise A: how far from the pedestal do carrier-killers stand? ---
    ds = [s["killer_dist"] for s in steals
          if s["outcome"] == "killed" and s["killer_dist"] is not None]
    print(f"PREMISE A — carrier-killer distance from the pedestal (n={len(ds)})")
    if ds:
        ds.sort()
        over150 = sum(1 for d in ds if d > 150.0)
        over300 = sum(1 for d in ds if d > 300.0)
        print(f"   median {statistics.median(ds):6.0f}px   "
              f"mean {statistics.mean(ds):6.0f}px")
        for q in (25, 50, 75, 90):
            print(f"   p{q:<3d}   {ds[min(len(ds)-1, q*len(ds)//100)]:6.0f}px")
        print(f"   >150px (invisible to GrabStackRange today): "
              f"{over150}/{len(ds)}  {pct(over150, len(ds))}")
        print(f"   >300px (still invisible at the proposed 300):  "
              f"{over300}/{len(ds)}  {pct(over300, len(ds))}")
        gain = over150 - over300
        print(f"   → widening 150→300 newly covers {gain}/{len(ds)} "
              f"{pct(gain, len(ds))} of carrier-killers")
    print()

    # --- premise B: HP at the steal, and does it predict conversion? ---
    print("PREMISE B — HP at the steal vs conversion")
    byhp = collections.defaultdict(collections.Counter)
    for s in steals:
        byhp[s["hp"]][s["outcome"]] += 1
    tot = len(steals)
    print(f"   {'hp':>3} {'steals':>7} {'share':>7} {'capture':>8} {'conv':>7} "
          f"{'killed':>7} {'medlife':>8}")
    for hp in sorted(byhp):
        c = byhp[hp]
        n = sum(c.values())
        lives = [s["life"] for s in steals
                 if s["hp"] == hp and s["outcome"] == "killed" and s["life"]]
        ml = f"{statistics.median(lives):.0f}t" if lives else "-"
        print(f"   {hp:>3} {n:>7} {pct(n, tot)} {c['capture']:>8} "
              f"{pct(c['capture'], n)} {c['killed']:>7} {ml:>8}")
    print()

    # --- PREMISE C: does a body-count gate DISCRIMINATE? -------------------
    # A gate that flags 74% of fatal pockets is worthless if it also flags 74%
    # of the steals that captured — that is not a threat model, it is just
    # refusing to grab. Score every candidate (radius, threshold) on the SPREAD
    # between its flag rate on killed steals and on captured ones.
    fatal = [s for s in steals if s["outcome"] == "killed"
             and s.get("steal300") is not None]
    good = [s for s in steals if s["outcome"] == "capture"
            and s.get("steal300") is not None]
    print(f"PREMISE C — does a pocket body-count gate discriminate? "
          f"(fatal n={len(fatal)}, capture n={len(good)}) — counted AT THE STEAL")
    if fatal and good:
        for rad in (150, 300):
            f_d = collections.Counter(s[f"steal{rad}"] for s in fatal)
            g_d = collections.Counter(s[f"steal{rad}"] for s in good)
            print(f"   bodies within {rad}px  fatal={dict(sorted(f_d.items()))}"
                  f"  capture={dict(sorted(g_d.items()))}")
        print(f"\n   {'gate (flag the dive when...)':<34} {'fatal':>12} "
              f"{'capture':>12} {'spread':>8}")
        for rad in (150, 300):
            for thr in (1, 2):
                fr = sum(1 for s in fatal if s[f"steal{rad}"] >= thr)
                gr = sum(1 for s in good if s[f"steal{rad}"] >= thr)
                spread = 100.0*fr/len(fatal) - 100.0*gr/len(good)
                tag = f">={thr} enemy within {rad}px"
                star = "  <= today" if (rad, thr) == (150, 2) else ""
                print(f"   {tag:<34} {fr:>4}/{len(fatal)} {pct(fr,len(fatal))}"
                      f" {gr:>4}/{len(good)} {pct(gr,len(good))}"
                      f" {spread:>+7.1f}pp{star}")
        print("\n   spread ≈ 0 means the gate cannot tell a fatal pocket from a "
              "winning one:\n   it would suppress good dives at the same rate "
              "as bad ones.")
    print()

    stale = [s["killer_stale"] for s in steals if s["killer_stale"] is not None]
    if stale:
        print(f"placement error: median killer-sample staleness "
              f"{statistics.median(stale):.0f}t, p90 "
              f"{sorted(stale)[9*len(stale)//10]:.0f}t")
    drop = sum(1 for s in steals
               if s["outcome"] == "killed" and s["killer_dist"] is None)
    print(f"dropped (no killer sample within {a.max_stale}t): {drop}")


if __name__ == "__main__":
    main()

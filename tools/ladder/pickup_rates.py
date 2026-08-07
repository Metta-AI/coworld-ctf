"""pickup_rates — ours vs the FIELD on item pickups, per engine version.

The perception check that a win-rate can never give you. `item_pickup` events
carry the item name and the picking slot, and the episode summary maps each
slot to its policy address — so a re-simulated league replay states outright
how often we collect each item versus how often everyone else in the SAME
episodes does. No hosted A/B, no self-play proxy, no attribution guesswork.

Read a row against the OTHER rows, never on its own. Being below the field on
one item is a priority choice; being 5x below on exactly the item whose wire
label was renamed is a blind scan. That is how the 0.7.x `plasma arc` ->
`spray can` rename was caught: spray cans at 0.20x the field rate while every
other item sat at 0.66-1.53x (docs/reports/2026-08-07-policy-label-scan-audit.md).

And note the difference between 0.20x and 0.00x. Pickup is a TOUCH radius, so
a bot that cannot see an item still collects one occasionally by walking over
it. A blind scan reads as "only by accident", not as zero.

Requires the extracted event sink scout.py builds. IMPORTANT: extract with a
binary built from the engine the replays were RECORDED on — a re-sim on a
different GameVersion is not ground truth (see tools/ladder/README.md).

Usage:
  pickup_rates.py [EVENT_DIR ...]      # default: ~/.ctf/scout/events
"""
import json, glob, collections, sys, os

OURS = "softmaxwell"
def base(addr):  # "softmaxwell (3)" -> "softmaxwell"
    return addr.split(" (")[0].strip()

dirs = sys.argv[1:] or [os.path.expanduser("~/.ctf/scout/events")]
# gv -> item -> {"ours": n, "field": n};  gv -> {"ourSlots": n, "fieldSlots": n, "eps": n}
picks = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
seats = collections.defaultdict(collections.Counter)
weap  = collections.defaultdict(lambda: collections.defaultdict(collections.Counter))
files = []
for d in dirs: files += sorted(glob.glob(f"{d}/*.jsonl"))

for f in files:
    meta = None; evs = []
    for l in open(f):
        try: e = json.loads(l)
        except: continue
        if e.get("type") == "summary": meta = e
        else: evs.append(e)
    if not meta: continue
    gv = meta.get("gameVersion", "?")
    addrs = meta.get("slot_address") or []
    if not addrs: continue
    mine = {i for i, a in enumerate(addrs) if base(a) == OURS}
    if not mine: continue                      # only episodes we actually played
    seats[gv]["eps"] += 1
    seats[gv]["ourSlots"]   += len(mine)
    seats[gv]["fieldSlots"] += len(addrs) - len(mine)
    for e in evs:
        s = e.get("source", -1)
        who = "ours" if s in mine else "field"
        if e.get("kind") == "item_pickup":
            picks[gv][e.get("item", "?")][who] += 1
        elif e.get("kind") == "kill":
            weap[gv][e.get("weapon", "?")][who] += 1

for gv in sorted(picks, key=lambda g: (len(g), g)):
    s = seats[gv]
    print(f"\n=== GameVersion {gv}   episodes={s['eps']}  our seats={s['ourSlots']}  field seats={s['fieldSlots']} ===")
    print(f"{'item':<12} {'ours/seat':>10} {'field/seat':>11} {'ratio':>7}   (raw ours / field)")
    for item in sorted(picks[gv], key=lambda i: -sum(picks[gv][i].values())):
        o, fl = picks[gv][item]["ours"], picks[gv][item]["field"]
        op = o / s["ourSlots"] if s["ourSlots"] else 0
        fp = fl / s["fieldSlots"] if s["fieldSlots"] else 0
        r = f"{op/fp:.2f}x" if fp else "  n/a"
        print(f"{item:<12} {op:>10.3f} {fp:>11.3f} {r:>7}   ({o} / {fl})")
    tk = sum(sum(c.values()) for c in weap[gv].values())
    if tk:
        parts = []
        for w in sorted(weap[gv], key=lambda w: -sum(weap[gv][w].values())):
            n = sum(weap[gv][w].values())
            parts.append(f"{w or '(none)'}={n} ({100*n/tk:.1f}%)")
        print("  kills by weapon (all seats): " + ", ".join(parts))

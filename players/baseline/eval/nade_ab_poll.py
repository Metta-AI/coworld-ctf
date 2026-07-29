#!/usr/bin/env python3
"""Poll the 4-arm anti-line grenade A/B; tally pooled clusterON vs clusterOFF win% by scores.

Fill ARMS with the four xreq ids that nade_field_ab.py printed, then run. Hosted CTF scores
are BINARY +-1.0 per episode (no grab/cap partial credit — see METHOD-binscore), so wins are
the only hosted metric; the mechanism (cluster kills) has to come from the local probe or
from re-simulating replays.

Decision rule: candidate ahead of base on BOTH seatings = real. One-sided = seat artifact.
"""
import time
from coworld.api_client import CoworldApiClient

SERVER = "https://softmax.com/api"
ARMS = {
    "on_red":   "xreq_REPLACE_ME",
    "on_blue":  "xreq_REPLACE_ME",
    "off_red":  "xreq_REPLACE_ME",
    "off_blue": "xreq_REPLACE_ME",
}
CAND = "d1755958-dfdc-4f1c-9f9a-8a8d93f47802"   # Picasso:v28, nadeCluster ON
BASE = "REPLACE_ME"                              # the -d:noNadeCluster control pv id


def score_arm(c, xid, pv):
    d = c.get_experience_request(xid).model_dump()
    w = l = t = 0
    for ep in d.get("episodes") or []:
        if ep.get("status") != "completed":
            continue
        sc = {str(s["policy_version_id"]): s["score"] for s in (ep.get("scores") or [])}
        v = sc.get(pv)
        if v is None:
            continue
        if v > 0: w += 1
        elif v < 0: l += 1
        else: t += 1
    return d.get("status"), d.get("completed_count", 0), d.get("episode_count", 0), w, l, t


def main():
    with CoworldApiClient.from_login(server_url=SERVER) as c:
        for _ in range(180):
            agg = {"on": [0, 0, 0], "off": [0, 0, 0]}
            allterm = True
            for name, xid in ARMS.items():
                pv = CAND if name.startswith("on") else BASE
                st, done, tot, w, l, t = score_arm(c, xid, pv)
                print(f"  {name:9} {st:10} {done}/{tot}  W{w} L{l} T{t}")
                if st not in ("completed", "failed", "cancelled"):
                    allterm = False
                k = "on" if name.startswith("on") else "off"
                agg[k][0] += w; agg[k][1] += l; agg[k][2] += t
            ow, ol, ot = agg["on"]; fw, fl, ft = agg["off"]
            on_n, off_n = ow + ol + ot, fw + fl + ft
            orate = 100 * ow / on_n if on_n else 0
            frate = 100 * fw / off_n if off_n else 0
            print(f"  ==== clusterON {ow}/{on_n} ({orate:.0f}%)  vs  clusterOFF {fw}/{off_n} "
                  f"({frate:.0f}%)  delta {orate - frate:+.0f}pp ====")
            if allterm:
                print("ALL TERMINAL"); return
            time.sleep(20)


if __name__ == "__main__":
    main()

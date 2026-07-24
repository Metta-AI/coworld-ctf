#!/usr/bin/env python3
"""Poll the 4-arm full-upgrade A/B, tally pooled candidate(v25) vs base(v23) win% by scores."""
import time
from coworld.api_client import CoworldApiClient
SERVER = "https://softmax.com/api"
ARMS = {
    "cand_red":  "xreq_0223770e-0859-44c8-977e-7badb39a90ef",
    "cand_blue": "xreq_da13b921-1e61-4b1e-a4d4-2cc029be12a6",
    "base_red":  "xreq_8ca7ef20-0f6d-4d81-a68d-bd273955f0b7",
    "base_blue": "xreq_5a697352-57ad-416c-a845-0ef401eed393",
}
CAND = "785a2d0e-2c9f-4124-8863-a3ef77d150bb"
BASE = "50e64932-14fc-4dee-a59c-13ecba569f77"

def score_arm(c, xid, pv):
    d = c.get_experience_request(xid).model_dump()
    w = l = t = 0
    for ep in d.get("episodes") or []:
        if ep.get("status") != "completed": continue
        sc = {str(s["policy_version_id"]): s["score"] for s in (ep.get("scores") or [])}
        v = sc.get(pv)
        if v is None: continue
        if v > 0: w += 1
        elif v < 0: l += 1
        else: t += 1
    return d.get("status"), d.get("completed_count", 0), d.get("episode_count", 0), w, l, t

def main():
    with CoworldApiClient.from_login(server_url=SERVER) as c:
        for _ in range(180):
            agg = {"cand": [0,0,0], "base": [0,0,0]}; allterm = True
            for name, xid in ARMS.items():
                pv = CAND if name.startswith("cand") else BASE
                st, done, tot, w, l, t = score_arm(c, xid, pv)
                print(f"  {name:10} {st:10} {done}/{tot}  W{w} L{l} T{t}")
                if st not in ("completed","failed","cancelled"): allterm = False
                k = "cand" if name.startswith("cand") else "base"
                agg[k][0]+=w; agg[k][1]+=l; agg[k][2]+=t
            cw,cl,ct = agg["cand"]; bw,bl,bt = agg["base"]
            cn, bn = cw+cl+ct, bw+bl+bt
            cr = 100*cw/cn if cn else 0; br = 100*bw/bn if bn else 0
            print(f"  ==== v25 FULL {cw}/{cn} ({cr:.0f}%)  vs  v23 base {bw}/{bn} ({br:.0f}%)  delta {cr-br:+.0f}pp ====")
            if allterm: print("ALL TERMINAL"); return
            time.sleep(20)

if __name__ == "__main__":
    main()

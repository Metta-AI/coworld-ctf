#!/usr/bin/env python3
"""Poll the 4-arm full-upgrade A/B, tally pooled candidate(v25) vs base(v23) win% by scores."""
import time
from coworld.api_client import CoworldApiClient
SERVER = "https://softmax.com/api"
ARMS = {
    "cand_red":  "xreq_2f17b5af-91bd-44c1-96f6-66043b0a6bf1",
    "cand_blue": "xreq_714e7c14-6754-4d88-9257-9f474fb7e417",
    "base_red":  "xreq_5c00de1a-5c4a-4b74-9ca3-05e354286463",
    "base_blue": "xreq_7588deff-548e-4706-9828-40c3802fa321",
}
CAND = "4875e53d-464f-4cb1-bed6-0bfa71c2cf52"
BASE = "785a2d0e-2c9f-4124-8863-a3ef77d150bb"

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
            print(f"  ==== v27 pickedge {cw}/{cn} ({cr:.0f}%)  vs  v25 base {bw}/{bn} ({br:.0f}%)  delta {cr-br:+.0f}pp ====")
            if allterm: print("ALL TERMINAL"); return
            time.sleep(20)

if __name__ == "__main__":
    main()

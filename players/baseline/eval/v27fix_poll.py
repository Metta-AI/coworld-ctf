#!/usr/bin/env python3
"""v27 (pickEdge broadcast) vs v25 (placed champion) — corrected: new v27 arms + reused v25 base arms."""
import time
from coworld.api_client import CoworldApiClient
SERVER = "https://softmax.com/api"
V27 = "4875e53d-464f-4cb1-bed6-0bfa71c2cf52"
V25 = "785a2d0e-2c9f-4124-8863-a3ef77d150bb"
ARMS = {
    "v27_red":  ("xreq_d1b82fc2-91b5-4cc6-8ead-b0a3f97f946b", V27),
    "v27_blue": ("xreq_ecbf8e57-5062-4ff9-82b7-a145056a12de", V27),
    "v25_red":  ("xreq_5c00de1a-5c4a-4b74-9ca3-05e354286463", V25),  # reused from prior run
    "v25_blue": ("xreq_7588deff-548e-4706-9828-40c3802fa321", V25),
}
def tally(c, xid, pv):
    d = c.get_experience_request(xid).model_dump()
    w=l=t=0
    for ep in d.get("episodes") or []:
        if ep.get("status") != "completed": continue
        sc={str(s["policy_version_id"]):s["score"] for s in (ep.get("scores") or [])}
        v=sc.get(pv)
        if v is None: continue
        if v>0: w+=1
        elif v<0: l+=1
        else: t+=1
    return d.get("status"), d.get("completed_count",0), d.get("episode_count",0), w, l, t
def main():
    with CoworldApiClient.from_login(server_url=SERVER) as c:
        for _ in range(180):
            agg={"v27":[0,0],"v25":[0,0]}; allterm=True
            for name,(xid,pv) in ARMS.items():
                st,done,tot,w,l,t=tally(c,xid,pv)
                print(f"  {name:9} {st:10} {done}/{tot}  W{w} L{l}")
                if st not in ("completed","failed","cancelled"): allterm=False
                k="v27" if name.startswith("v27") else "v25"
                agg[k][0]+=w; agg[k][1]+=l
            cw,cl=agg["v27"]; bw,bl=agg["v25"]
            cn,bn=cw+cl,bw+bl
            cr=100*cw/cn if cn else 0; br=100*bw/bn if bn else 0
            print(f"  ==== v27 pickEdge {cw}/{cn} ({cr:.0f}%)  vs  v25 base {bw}/{bn} ({br:.0f}%)  delta {cr-br:+.0f}pp ====")
            if allterm: print("ALL TERMINAL"); return
            time.sleep(20)
if __name__=="__main__": main()

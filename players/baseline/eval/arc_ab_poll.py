#!/usr/bin/env python3
"""Poll the 4-arm arc A/B until terminal, then print the win/grab/cap tally.

Scores from episodes[].scores + participants: our-team win rate, grabs, caps, K/D.
Candidate (v24 arcON) vs base (v23 arcOFF), pooled across both seatings.
"""
import time, json
from coworld.api_client import CoworldApiClient

SERVER = "https://softmax.com/api"
ARMS = {
    "cand_red":  "xreq_d47663b3-bc53-4f2c-849e-83efe513515e",
    "cand_blue": "xreq_d44aa113-d3eb-437d-b586-9b0bca22b298",
    "base_red":  "xreq_eadbcb73-2b27-4cdd-a653-18ac9c963805",
    "base_blue": "xreq_a2034c1c-989a-4f73-9704-970781245bc8",
}
CAND = "a2cd2f1f-afab-41ce-a333-ac9cb604b028"
BASE = "50e64932-14fc-4dee-a59c-13ecba569f77"


def tally(c, xid, our_pvid):
    d = c.get_experience_request(xid).model_dump()
    st = d.get("status")
    done = d.get("completed_count", 0)
    tot = d.get("episode_count", 0)
    wins = ours = 0
    for ep in d.get("episodes") or []:
        if ep.get("status") != "completed":
            continue
        parts = ep.get("participants") or []
        scores = ep.get("scores")
        our_pos = [p.get("position") for p in parts if p.get("policy_version_id") == our_pvid]
        if not our_pos or not scores:
            continue
        # our-team win = our seats' mean score > the rest (CTF score is +1 win / -1 loss/draw)
        try:
            our_mean = sum(scores[i] for i in our_pos) / len(our_pos)
        except (IndexError, TypeError):
            continue
        ours += 1
        if our_mean > 0:
            wins += 1
    return st, done, tot, wins, ours


def main():
    with CoworldApiClient.from_login(server_url=SERVER) as c:
        for _ in range(120):  # up to ~40 min
            lines, all_term = [], True
            agg = {"cand": [0, 0], "base": [0, 0]}
            for name, xid in ARMS.items():
                pv = CAND if name.startswith("cand") else BASE
                st, done, tot, wins, ours = tally(c, xid, pv)
                lines.append(f"  {name:10} {st:10} {done}/{tot}  wins {wins}/{ours}")
                if st not in ("completed", "failed", "cancelled"):
                    all_term = False
                k = "cand" if name.startswith("cand") else "base"
                agg[k][0] += wins
                agg[k][1] += ours
            print("\n".join(lines))
            cw, cn = agg["cand"]; bw, bn = agg["base"]
            cr = 100 * cw / cn if cn else 0
            br = 100 * bw / bn if bn else 0
            print(f"  ---- POOLED: candidate(arcON) {cw}/{cn} ({cr:.0f}%)  base(arcOFF) {bw}/{bn} ({br:.0f}%)  delta {cr-br:+.0f}pp ----")
            if all_term:
                print("ALL TERMINAL")
                return
            time.sleep(20)


if __name__ == "__main__":
    main()

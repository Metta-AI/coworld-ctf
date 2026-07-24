#!/usr/bin/env python3
"""Build + submit the arcBreach-ON vs -OFF field A/B on the live Ctf league.

Four arms (seat-rotated): candidate (Picasso:v24, arc ON) and base (Picasso:v23,
arc OFF), each as our 8 seats vs the SAME field mix, in both seatings. The A-vs-B
delta on matched seatings isolates arcBreach. Field opponents fill the other 8.

Usage: uv run python arc_field_ab.py [--episodes N] [--dry]
Run from ~/metta/packages/coworld (needs the coworld venv + login).
"""
import json, sys, argparse

from coworld.api_client import CoworldApiClient

SERVER = "https://softmax.com/api"
LEAGUE = "league_3243d905-d32d-4ec6-978b-fa94751d4a37"

CAND = "a2cd2f1f-afab-41ce-a333-ac9cb604b028"   # Picasso:v24  arcBreach ON  (candidate)
BASE = "50e64932-14fc-4dee-a59c-13ecba569f77"   # Picasso:v23  arcBreach OFF (base = v21 champ on GV22)

# The live Ctf field (distinct champions, excl. our own Picasso), by pvid — resolved
# 2026-07-24. Re-resolve right before launch (the league rolls versions).
FIELD = [
    ("ctf-focusfire:v56", "f4ff0495-1141-4270-a19f-3a6530e2f83c"),
    ("beacon:v25",        "45268809-2ca5-4976-9a66-ade1d7329b7b"),
    ("ctf-h022:v1",       "26a91381-95ce-4711-9635-ea6dd080ef06"),
    ("nancy-ctf:v1",      "a5e0421e-bf61-413b-a6c9-00846c853bf0"),
    ("ctf-autoresearch:v47","9235eccc-f70c-4018-8864-05d12ddd6ceb"),
    ("co-gas-relh:v25",   "6c3764e1-28b4-4369-ab78-91368756ea90"),
    ("co-gas-richard:v24","a06aa51c-6814-47d9-a33e-54b1bef570b2"),
]

# 8 field seats (one team). Use a fixed spread of 7 distinct opponents (one repeats)
# so both arms + both seatings face the SAME field — the A/B delta is clean.
FIELD8 = [FIELD[i % len(FIELD)][1] for i in range(8)]


def roster(our_pvid: str, our_is_blue: bool):
    """16-seat roster: our 8 on one parity, the field 8 on the other."""
    entries = []
    fi = 0
    for slot in range(16):
        our_slot = (slot % 2 == 1) if our_is_blue else (slot % 2 == 0)
        if our_slot:
            entries.append({"player": {"policy_ref": our_pvid}, "slot": slot})
        else:
            entries.append({"player": {"policy_ref": FIELD8[fi]}, "slot": slot})
            fi += 1
    return entries


def body(our_pvid: str, our_is_blue: bool, episodes: int, note: str):
    return {
        "target": {"league_id": LEAGUE, "division_id": None, "coworld_id": None,
                   "variant_id": None, "league_name": None, "division_name": None},
        "roster": roster(our_pvid, our_is_blue),
        "num_episodes": episodes,
        "execution_backend": "k8s",
        "game_config_overrides": {"maxTicks": 5000},
        "notes": note,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--episodes", type=int, default=30)
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()

    arms = [
        (CAND, False, "arc-AB candidate v24 arcON  seat=Red  vs field"),
        (CAND, True,  "arc-AB candidate v24 arcON  seat=Blue vs field"),
        (BASE, False, "arc-AB base v23 arcOFF seat=Red  vs field"),
        (BASE, True,  "arc-AB base v23 arcOFF seat=Blue vs field"),
    ]
    bodies = [body(p, b, args.episodes, n) for (p, b, n) in arms]

    if args.dry:
        print(json.dumps(bodies[0], indent=2))
        print(f"\n[dry] {len(bodies)} arms x {args.episodes} ep. Field8: {FIELD8}")
        return

    with CoworldApiClient.from_login(server_url=SERVER) as c:
        http, hdr = c._http_client, c._headers()
        for (p, b, n), bd in zip(arms, bodies):
            r = http.post("/v2/experience-requests", json=bd, headers=hdr)
            if r.status_code >= 300:
                print(f"FAIL {n}: {r.status_code} {r.text[:400]}")
                continue
            xid = r.json().get("id")
            print(f"OK   {n}: {xid}")


if __name__ == "__main__":
    main()

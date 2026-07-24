#!/usr/bin/env python3
"""Hosted field A/B: the FULL GV22 upgrade (Picasso:v25) vs the pre-upgrade base (v23), vs the live field.

v25 = dive-death fix (smartGrab/armedRush) + focus-fire fix (holdVsGun/stickyCommit v2) +
      carrier-run survival (carrierFlee/carrierSerpentine/escortRun/carrierScreen).
v23 = the v21 champion architecture on GV22 (none of those levers) — the control.

Four seat-rotated arms (candidate + base, each seating) vs the SAME 8-opponent field mix, so the
candidate-vs-base delta on matched fields isolates the whole upgrade. The mirror could NOT resolve
these levers (seed bias swamps it, and coordination/escort levers mirror-cancel) — the field is the test.

Usage: cd ~/metta/packages/coworld && uv run python <this> [--episodes N] [--dry]
"""
import json, argparse
from coworld.api_client import CoworldApiClient

SERVER = "https://softmax.com/api"
LEAGUE = "league_3243d905-d32d-4ec6-978b-fa94751d4a37"

CAND = "785a2d0e-2c9f-4124-8863-a3ef77d150bb"   # Picasso:v25  FULL upgrade  (candidate)
BASE = "50e64932-14fc-4dee-a59c-13ecba569f77"   # Picasso:v23  pre-upgrade   (base/control)

# Live Ctf field champions (distinct, excl. our Picasso) — re-resolved 2026-07-24 just before launch.
FIELD = [
    "f4ff0495-1141-4270-a19f-3a6530e2f83c",  # ctf-focusfire:v56 (daveey)
    "45268809-2ca5-4976-9a66-ade1d7329b7b",  # beacon:v25 (James Boggs)
    "26a91381-95ce-4711-9635-ea6dd080ef06",  # ctf-h022:v1 (Alex Smith — the LINE opponent)
    "a5e0421e-bf61-413b-a6c9-00846c853bf0",  # nancy-ctf:v1
    "9235eccc-f70c-4018-8864-05d12ddd6ceb",  # ctf-autoresearch:v47 (Aaron)
    "ae0dfa8c-6b1c-40ed-a51f-30fd1a7b60a4",  # co-gas-relh:v26
    "e465a45d-70e4-41ac-9d49-dba1b3e280d4",  # co-gas-richard:v33
]
FIELD8 = [FIELD[i % len(FIELD)] for i in range(8)]


def roster(our_pvid, our_is_blue):
    entries, fi = [], 0
    for slot in range(16):
        ours = (slot % 2 == 1) if our_is_blue else (slot % 2 == 0)
        if ours:
            entries.append({"player": {"policy_ref": our_pvid}, "slot": slot})
        else:
            entries.append({"player": {"policy_ref": FIELD8[fi]}, "slot": slot}); fi += 1
    return entries


def body(our_pvid, our_is_blue, episodes, note):
    return {
        "target": {"league_id": LEAGUE, "division_id": None, "coworld_id": None,
                   "variant_id": None, "league_name": None, "division_name": None},
        "roster": roster(our_pvid, our_is_blue),
        "num_episodes": episodes, "execution_backend": "k8s",
        "game_config_overrides": {"maxTicks": 5000}, "notes": note,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--episodes", type=int, default=30)
    ap.add_argument("--dry", action="store_true")
    args = ap.parse_args()
    arms = [
        (CAND, False, "upgrade-AB v25 FULL seat=Red  vs field"),
        (CAND, True,  "upgrade-AB v25 FULL seat=Blue vs field"),
        (BASE, False, "upgrade-AB v23 base seat=Red  vs field"),
        (BASE, True,  "upgrade-AB v23 base seat=Blue vs field"),
    ]
    if args.dry:
        print(json.dumps(body(*arms[0][:2], args.episodes, arms[0][2]), indent=2)[:900]); return
    with CoworldApiClient.from_login(server_url=SERVER) as c:
        http, hdr = c._http_client, c._headers()
        for p, b, n in arms:
            r = http.post("/v2/experience-requests", json=body(p, b, args.episodes, n), headers=hdr)
            if r.status_code >= 300:
                print(f"FAIL {n}: {r.status_code} {r.text[:300]}"); continue
            print(f"OK   {n}: {r.json().get('id')}")


if __name__ == "__main__":
    main()

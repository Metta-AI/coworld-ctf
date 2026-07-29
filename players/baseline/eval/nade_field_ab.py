#!/usr/bin/env python3
"""Hosted field A/B: the SHIPPED anti-line grenade multikill (nadeCluster) ON vs OFF.

THE LEVER (baseline.nim, the grenade block). When a standing enemy line is classified
(ScLine) or heard over the comms bus (RpLine), a grenade carrier ranks candidates by
CLUSTER SIZE — fresh enemies inside one 52px blast — and lobs at the FATTEST one instead
of the nearest. It throws WITHOUT disarming (keeps the gun), which is exactly why the
arc breacher was RETIRED as a strictly-worse duplicate: the arc traded the gun for a cone.
Doctrine: "numbers are the currency" — a lob that kills two costs the enemy double.

WHY HOSTED. Shipped ON since 4ceec16 (2026-07-22, the v17 lineage) and NEVER isolated.
The self-play mirror structurally cannot score it: both teams attack, so no team ever
STANDS a line, and the lever's whole premise (lineLive) never arms. Only a real field
with line-standing opponents can price it.

ARMS (seat-rotated; the seat matters, the map is Red-favored):
  CAND = Picasso:v28 unchanged (nadeCluster ON — this IS the live champion)
  BASE = the same build with -d:noNadeCluster (naive-nearest grenade targeting)
Both play the SAME 8-opponent field mix, so the CAND-vs-BASE delta on matched fields
isolates cluster prioritisation alone. BOTH-POSITIVE (candidate ahead on both seatings)
= real, per the seat-rotation rule.

⚠️ BASE MUST BE UPLOADED FIRST and its pv id pasted below. Build it with:
     docker buildx build --platform=linux/amd64 \
       --build-arg NIM_DEFINES="-d:noNadeCluster" \
       -f players/baseline/Dockerfile -t picasso:vNN-nonade --load .
   then VERIFY the binary sha differs from a freshly-built pristine v28 image (the v27
   wrong-upload lesson) before `coworld upload-policy`.

Usage: cd ~/metta/packages/coworld && uv run python <this> [--episodes N] [--dry]
"""
import json, argparse
from coworld.api_client import CoworldApiClient

SERVER = "https://softmax.com/api"
LEAGUE = "league_3243d905-d32d-4ec6-978b-fa94751d4a37"

# CAND = the LIVE champion, nadeCluster ON (no rebuild needed — this is v28 as shipped).
CAND = "d1755958-dfdc-4f1c-9f9a-8a8d93f47802"   # Picasso:v28
# BASE = same build, -d:noNadeCluster. FILL THIS IN after uploading the control image.
BASE = None                                      # e.g. "xxxxxxxx-...."

# Live Ctf field champions (competing/active, excl. our Picasso) — resolved 2026-07-29.
# ⭐ ctf-h050 is the LINE-STANDING opponent this lever was written to punish (the h006
# lineage: hold a defensive front and farm the push), so it is weighted into the mix.
FIELD = [
    "3e088d11-388f-46fc-82c9-c83e0e3a042b",  # ctf-h050:v1        ⭐ the LINE opponent
    "75c11891-692d-4e6f-872d-2ac0364ac245",  # alphashot:v180     (field #1)
    "360b6fe2-1695-431e-9a47-c50d63064241",  # ctf-focusfire:v62  (daveey)
    "00414876-552f-4d82-8d6c-9529c95c8e38",  # beacon:v33
    "234a788f-cdd9-44dd-9147-3bc6e7b4a1d9",  # co-gas-ctf-simple-richard:v36
    "34154c0c-2fd4-4a44-bfcc-77f75de70dba",  # co-gas-ctf-simple-relhalpha:v27
    "0bb2ef65-03ea-44ea-b8ba-168498bd7497",  # ctf-autoresearch:v28
    "9a2aed0c-4092-43cc-8479-ab16ebcbab66",  # osprey:v3
]
# h050 twice: the anti-line claim needs line-standing games in the sample to be testable.
FIELD8 = [FIELD[0]] + FIELD[:7]


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
    if BASE is None and not args.dry:
        raise SystemExit(
            "BASE is unset: upload the -d:noNadeCluster control image first, paste its "
            "pv id into BASE, and re-run. (--dry works without it.)")
    arms = [
        (CAND, False, "nadecluster-AB v28 clusterON  seat=Red  vs field(+h050 line)"),
        (CAND, True,  "nadecluster-AB v28 clusterON  seat=Blue vs field(+h050 line)"),
        (BASE, False, "nadecluster-AB     clusterOFF seat=Red  vs field(+h050 line)"),
        (BASE, True,  "nadecluster-AB     clusterOFF seat=Blue vs field(+h050 line)"),
    ]
    if args.dry:
        print(json.dumps(body(arms[0][0], arms[0][1], args.episodes, arms[0][2]),
                         indent=2)[:1200]); return
    with CoworldApiClient.from_login(server_url=SERVER) as c:
        http, hdr = c._http_client, c._headers()
        for p, b, n in arms:
            r = http.post("/v2/experience-requests",
                          json=body(p, b, args.episodes, n), headers=hdr)
            if r.status_code >= 300:
                print(f"FAIL {n}: {r.status_code} {r.text[:300]}"); continue
            print(f"OK   {n}: {r.json().get('id')}")


if __name__ == "__main__":
    main()

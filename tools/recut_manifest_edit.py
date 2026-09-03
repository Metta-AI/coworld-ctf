#!/usr/bin/env python3
"""One-shot manifest edit for the multiplier-recut increment (v13).

Adds the three RECUT config_schema keys (gloryMultiplierRecut,
stampRealizedConfig, variantId), self-labels the battle-royale-s2 variant
with its variantId, and publishes the two per-flag STAGING variants that
split the baked lootStart+downedMode coupling (recut contract Amendment 2
paragraph 1: every S2 flag must stage independently; activating on coupled
flags is prohibited).

Deliberately a committed tool, not a throwaway: the conformance reviewer can
re-run it against a clean manifest and diff.
"""
import copy
import json
import sys

PATH = "coworld_manifest_paintbot.json"

with open(PATH) as f:
    m = json.load(f)

props = m["game"]["config_schema"]["properties"]

assert "gloryMultiplierRecut" not in props, "already applied"

props["gloryMultiplierRecut"] = {
    "description": (
        "GLORY v13 multiplier recut (frozen 2026-09-02 contract): the "
        "pure-multiplier economy — no base points; episode score = seed(1) "
        "x the product of integer act multipliers, divided by 2 per "
        "friendly-fire step (BR: every incident; CTF: every second "
        "incident). Applies to BOTH modes (does not require brMode). Off "
        "by default everywhere: merged+deployed is NOT armed — arming is "
        "an explicit, separate manifest publish of this one key on the "
        "chosen variant."
    ),
    "type": "boolean",
    "default": False,
}
props["stampRealizedConfig"] = {
    "description": (
        "Realized-config stamp (recut contract Amendment 2): when true the "
        "engine emits, at episode finalize, a stamp of the build and flag "
        "set that ACTUALLY ran — {stampVersion, realizedBuild "
        "{gameVersion, gloryVersion, engineStamp}, variantId, flagSet as "
        "sorted key=value pairs} — into the events summary row and the "
        "episode log. Observability only; independent of every other flag. "
        "Off by default."
    ),
    "type": "boolean",
    "default": False,
}
props["variantId"] = {
    "description": (
        "Self-label: the manifest variant id this game_config was "
        "published under, echoed verbatim into the realized-config stamp "
        "and the replay header so replay-only audits can name the variant "
        "without platform access. The engine only reports it."
    ),
    "type": "string",
    "default": "",
}

variants = m["variants"]
s2 = next(v for v in variants if v.get("id") == "battle-royale-s2")
s2_idx = variants.index(s2)

# Self-label the S2 variant (and keep its flag set otherwise UNTOUCHED —
# the recut key is deliberately NOT added here; that is the activation
# step, a separate publish).
s2["game_config"]["variantId"] = "battle-royale-s2"

def staged(vid, name, drop_key, desc):
    v = copy.deepcopy(s2)
    v["id"] = vid
    v["name"] = name
    v["description"] = desc
    del v["game_config"][drop_key]
    v["game_config"]["variantId"] = vid
    return v

loot_only = staged(
    "battle-royale-s2-lootstart",
    "Battle Royale — Season 2 (loot-start only)",
    "downedMode",
    "STAGING variant (recut contract Amendment 2 §1 — per-flag activation): "
    "identical to battle-royale-s2 with ONLY lootStart armed; downedMode "
    "stays dark. Exists so the S2 flags can be staged/bisected one at a "
    "time instead of riding one coupled variant switch.",
)
downed_only = staged(
    "battle-royale-s2-downed",
    "Battle Royale — Season 2 (downed-state only)",
    "lootStart",
    "STAGING variant (recut contract Amendment 2 §1 — per-flag activation): "
    "identical to battle-royale-s2 with ONLY downedMode armed; lootStart "
    "stays dark. Exists so the S2 flags can be staged/bisected one at a "
    "time instead of riding one coupled variant switch.",
)

for v in (loot_only, downed_only):
    assert not any(x.get("id") == v["id"] for x in variants), v["id"]

variants.insert(s2_idx + 1, loot_only)
variants.insert(s2_idx + 2, downed_only)

with open(PATH, "w") as f:
    json.dump(m, f, indent=2, ensure_ascii=False)
    f.write("\n")

print("applied: 3 schema keys, s2 self-label, 2 staging variants")

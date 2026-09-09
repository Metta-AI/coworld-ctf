#!/usr/bin/env python3
"""GLORY GRADIENT S6 — catalog detection CLI (DO item 1): per coworld_version,
read the S6 switches from that build's OWN source commit -> flagship
manifest (`battle-royale-s2` variant in `coworld_manifest_paintbot.json`),
and label the version "v2" (classic flat-integer fold) or "v3"
(percent-scaled fixed-point fold, `catalogV3Reprice`/`placementRampV3`
armed). A LOCAL git-object read (`git show <sha>:<path>`) against a repo
that already has the commit -- no live network.

Usage:
  python3 tools/glory/catalog_detect.py \\
      --repo . --version-sha data/gv62/version_to_sha_gv62.json \\
      --out /tmp/catalog_map_gv62.json
"""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from catalog_fold import build_catalog_map  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", default=".", help="path to the coworld-ctf checkout")
    ap.add_argument("--version-sha", required=True,
                     help="JSON file: coworld_version -> commit sha")
    ap.add_argument("--manifest-path", default="coworld_manifest_paintbot.json")
    ap.add_argument("--variant-id", default="battle-royale-s2")
    ap.add_argument("--out", default="/tmp/glory-catalog/catalog_map.json")
    args = ap.parse_args()

    with open(args.version_sha) as f:
        version_to_sha = json.load(f)

    catalog_map = build_catalog_map(args.repo, version_to_sha,
                                     args.manifest_path, args.variant_id)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(catalog_map, f, indent=2, sort_keys=True)

    counts = {}
    for v, label in catalog_map.items():
        counts[label] = counts.get(label, 0) + 1
    print(f"resolved {len(catalog_map)} coworld_versions: {counts}", file=sys.stderr)
    for v in sorted(catalog_map):
        print(f"  {v}: {catalog_map[v]}", file=sys.stderr)
    print(f"wrote {args.out}", file=sys.stderr)


if __name__ == "__main__":
    main()

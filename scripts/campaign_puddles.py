#!/usr/bin/env python3
"""Patch a paint-puddle GRADIENT into the Paintbot campaign's cell maps — HEX.

Puddles only place on 2-team maps: the sim raises
`puddles never place on 4-team maps` (src/ctf/arena.nim) rather than placing
them. And they cannot be a per-cell game_config knob either — `mapPuddles` and
`puddleDamagePct` are NOT declared in the coworld manifest's config_schema,
which sets `additionalProperties: false`, so the cell-config endpoint refuses
them. Both facts force the same route daveey used: patch the SPLATS into each
arena's map_spec with `mapkit puddles` and pin the patched spec.

THE GRADIENT
    origin arenas:        12 puddles
    then -STEP per HEX ring, floored at 0
    4-team (ffa4) arenas:  0, always

Origins are the hexagon's NW and NE vertices — the same two upper landmarks
the square used, one per 2-team zone. Counts stay EVEN on purpose: an odd
request anchors a splat dead centre, and the gradient reads better as
scattered pairs.

WHY STEP HALVED (2, not the square's 4). The square walked CHEBYSHEV rings
across two SOLID 2-team zones and puddled 32 of its 52 two-team cells (62%)
with 176 splats. The live hex board has no 2-team zone at all: it is a
tic-tac-toe layout whose 1v1 corridors thread the whole hexagon, so a 2-ring
reach touches only 7 arenas (12%). STEP=2 keeps the design's shape — a peak at
each origin, falling by ring, always even — and restores its reach: 23 arenas,
40%, 146 splats. `--step 4` reproduces the square's literal constant.

Placement is deterministic per arena (seeded from the arena's coordinates) and
patched into a COPY of the base spec, so base terrain stays byte-identical.

Usage (each step is idempotent):
    nim c -d:release -o:/tmp/mapkit tools/mapkit.nim
    export MAPKIT=/tmp/mapkit CAMPAIGN_MAPS_OUT=/tmp/campaign_maps \
           CAMPAIGN_PUDDLES_OUT=/tmp/campaign_puddles

    python3 scripts/campaign_puddles.py plan     # print the gradient board
    python3 scripts/campaign_puddles.py patch    # place + validate + render (DRY)
    python3 scripts/campaign_puddles.py upload --apply   # the only write
    python3 scripts/campaign_puddles.py verify   # count puddled cells on prod

`patch` reads the specs `gen_campaign_maps.py generate` produced. Use
`--from-prod` to patch the specs already pinned on the live league instead
(the original workflow — it needs the league to be pinned already).
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import hexboard as hb  # noqa: E402

MAPKIT = Path(os.environ.get("MAPKIT", "mapkit"))
MAPS = Path(os.environ.get("CAMPAIGN_MAPS_OUT", "campaign_maps"))
OUT = Path(os.environ.get("CAMPAIGN_PUDDLES_OUT", "campaign_puddles"))
SNAPSHOT = Path(os.environ.get("CAMPAIGN_BOARD_SNAPSHOT", str(MAPS / "board.json")))


def load_board() -> hb.Board:
    if not SNAPSHOT.exists():
        sys.exit(f"no board snapshot at {SNAPSHOT} — run "
                 "`gen_campaign_maps.py snapshot` first (read-only)")
    raw = json.loads(SNAPSHOT.read_text())
    return hb.Board(width=raw["width"], height=raw["height"],
                    shape=raw.get("shape", "hex"), cells=raw.get("cells", {}))


def targets(board: hb.Board, args) -> list[tuple[str, int]]:
    """(arena anchor, puddle count) for every arena the gradient reaches."""
    out = []
    for cid in board.anchors():
        x, y = hb.parse_cell(cid)
        mode = board.mode_for(cid, args.zones)
        n = hb.puddle_count(board, x, y, mode, peak=args.peak, step=args.step)
        if n > 0:
            out.append((cid, n))
    return out


# --- commands ---------------------------------------------------------------


def cmd_plan(args) -> None:
    board = load_board()
    origins = hb.puddle_origins(board)
    print(f"origins: {origins}   PEAK={args.peak} STEP={args.step} "
          f"(per hex ring)   zones={args.zones}")
    for o in origins:
        m = board.board_mode(hb.cell_id(*o))
        print(f"  origin {o}: live mode {m}"
              + ("" if m and m not in hb.FOUR_TEAM_MODES
                 else "   <-- WARNING: 4-team, its peak will be dropped"))

    def glyph(x, y):
        cid = hb.cell_id(x, y)
        anchor = board.anchor_of(cid)
        ax, ay = hb.parse_cell(anchor)
        n = hb.puddle_count(board, ax, ay, board.mode_for(anchor, args.zones),
                            peak=args.peak, step=args.step)
        return str(n) if n else ""

    print("\npuddle gradient (per cell; blank = none, . = off-board):")
    print(hb.render_board(board, glyph, width=2))

    tg = targets(board, args)
    cells = sum(len(board.members_of(c)) for c, _ in tg)
    two = [c for c in board.anchors()
           if board.mode_for(c, args.zones) not in hb.FOUR_TEAM_MODES]
    hist = collections.Counter(n for _, n in tg)
    print(f"\n{len(tg)} of {len(board.anchors())} arenas get puddles "
          f"({len(tg)}/{len(two)} = {len(tg)/max(len(two),1):.0%} of 2-team arenas)")
    print(f"{cells} of {len(board.coords())} cells covered, "
          f"{sum(n for _, n in tg)} puddles requested in total")
    print("counts -> arenas: " + ", ".join(
        f"{n}:{k}" for n, k in sorted(hist.items(), reverse=True)))


def cmd_patch(args) -> None:
    board = load_board()
    OUT.mkdir(parents=True, exist_ok=True)
    tg = targets(board, args)
    if args.from_prod:
        import campaign_api
        specs = campaign_api.fetch_pinned_specs([c for c, _ in tg])
        for cid, _ in tg:
            if cid not in specs:
                sys.exit(f"arena {cid} has no pinned map_spec on prod — "
                         "generate and upload the base maps first")
            x, y = hb.parse_cell(cid)
            (OUT / f"cell_{x}_{y}.json").write_text(json.dumps(specs[cid]))
        print(f"fetched {len(specs)} pinned specs from prod")
    else:
        for cid, _ in tg:
            x, y = hb.parse_cell(cid)
            src = MAPS / f"cell_{x}_{y}.json"
            if not src.exists():
                sys.exit(f"missing {src} — run `gen_campaign_maps.py generate all`")
            # Copy, never patch in place: base terrain must stay byte-identical.
            shutil.copyfile(src, OUT / f"cell_{x}_{y}.json")

    for cid, count in tg:
        x, y = hb.parse_cell(cid)
        mode = board.mode_for(cid, args.zones)
        assert mode not in hb.FOUR_TEAM_MODES, (
            f"arena {cid} is {mode}: the sim refuses puddles on 4-team maps")
        spec = OUT / f"cell_{x}_{y}.json"
        seed = hb.puddle_seed(x, y)
        subprocess.run(
            [str(MAPKIT), "puddles", str(spec),
             "--count", str(count), "--seed", str(seed)],
            check=True, capture_output=True, text=True,
        )
        subprocess.run([str(MAPKIT), "validate", str(spec)],
                       check=True, capture_output=True)
        subprocess.run(
            [str(MAPKIT), "render", str(spec), "-o", str(OUT / f"cell_{x}_{y}.png")],
            check=True, capture_output=True,
        )
        placed = len(json.loads(spec.read_text()).get("puddles", []))
        note = "" if placed == count else f"  (WANTED {count})"
        print(f"{cid}: {placed} puddles seed={seed} "
              f"members={len(board.members_of(cid))}{note}", flush=True)
    print(f"\npatched {len(tg)} arenas into {OUT} — nothing sent to production")


def cmd_upload(args) -> None:
    import campaign_api

    board = load_board()
    tg = targets(board, args)
    uploads = []
    for cid, count in tg:
        x, y = hb.parse_cell(cid)
        spec_path = OUT / f"cell_{x}_{y}.json"
        if not spec_path.exists():
            sys.exit(f"missing {spec_path} — run patch first")
        loaded = json.loads(spec_path.read_text())
        if not loaded.get("puddles"):
            sys.exit(f"{spec_path} has no puddles — run patch first")
        png = (OUT / f"cell_{x}_{y}.png").read_bytes()
        for member in board.members_of(cid):
            uploads.append((member, cid, loaded, png))
    print(f"{len(tg)} puddled arenas -> {len(uploads)} cell pins")
    if not args.apply:
        print("DRY RUN — nothing was sent. Re-run with --apply to write to "
              f"league {campaign_api.LEAGUE}.")
        return
    for member, anchor, spec, png in uploads:
        resp = campaign_api.upload_cell_map(member, spec, png)
        print(f"{member}: uploaded from arena {anchor}, "
              f"preview={resp.get('preview_url')}", flush=True)


def cmd_verify(args) -> None:
    import campaign_api

    board = load_board()
    want = {c: n for c, n in targets(board, args)}
    rows = campaign_api.sql(
        "SELECT key, jsonb_array_length(value->'map_spec'->'puddles') "
        "FROM leagues, jsonb_each(commissioner_state->'cells') AS c(key, value) "
        f"WHERE id = '{campaign_api.LEAGUE}' AND value->'map_spec' ? 'puddles' "
        "ORDER BY key"
    )
    print(f"{len(rows)} cells carry puddles on prod:")
    for key, n in rows:
        anchor = board.anchor_of(key)
        w = want.get(anchor, 0)
        note = "" if n <= w and w > 0 else "  UNEXPECTED"
        print(f"  {key}: {n} (arena {anchor} wants {w}){note}")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--zones", choices=["board", "voronoi"], default="board")
    p.add_argument("--peak", type=int, default=hb.PUDDLE_PEAK)
    p.add_argument("--step", type=int, default=hb.PUDDLE_STEP,
                   help="puddles removed per hex ring (4 = the square's constant)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan").set_defaults(fn=cmd_plan)
    pa = sub.add_parser("patch")
    pa.add_argument("--from-prod", action="store_true",
                    help="patch the specs already pinned on the live league")
    pa.set_defaults(fn=cmd_patch)
    u = sub.add_parser("upload")
    u.add_argument("--apply", action="store_true",
                   help="actually write to the live league")
    u.set_defaults(fn=cmd_upload)
    sub.add_parser("verify").set_defaults(fn=cmd_verify)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()

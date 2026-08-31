#!/usr/bin/env python3
"""Generate the Paintbot campaign map set with mapkit — HEX board edition.

The 10x10 square board this script was written for is gone; the live board is
a HEXAGON of 169 cells in a 16x16 bounding grid (pointy-top, odd-r offset,
6-way adjacency). What changed, and what did not:

CARRIED OVER UNCHANGED
- Organic `caves` terrain everywhere.
- Symmetry per mode: 1v1 -> mirror, 2v2 -> rot180, ffa4 -> quadmirror.
- A DENSITY GRADIENT: obstacle fill peaks at the board's centre and falls to
  the edge (0.31 centre .. 0.17 rim).
- NEIGHBOUR SIMILARITY: fill from the density field, blobScale drifting with
  the cell's coordinates, so adjacent cells read as relatives.
- PER-CELL DETERMINISM: every seed is a hash of the cell's coordinates.
- The retry-until-the-validator-passes loop, and the quad-mirror best-of-5
  probe that keeps the most ORGANIC passing candidate.

RE-DERIVED FOR THE HEXAGON (see hexboard.py)
- Distances are HEX (cube) distances, not Euclidean/Chebyshev.
- The density field normalises by the hexagon's RADIUS, so every rim cell is
  exactly 1.0 (on the square only the corners reached it).
- The Voronoi zone anchors move to the hexagon's NW vertex, NE vertex and
  bottom-edge midpoint — the same three landmarks the square used.

CHANGED BECAUSE THE BOARD CHANGED
- ONE MAP PER ARENA, NOT PER CELL. A hex territory is a multi-hex FOOTPRINT
  (a "blob") whose hexes all play the SAME arena, so a map is generated once
  per blob anchor and pinned to every member cell. 169 cells, 86 arenas.
- THE MODE COMES FROM THE BOARD, NOT FROM THE ZONE SCHEME. The live board
  assigns each cell's mode itself (a tic-tac-toe layout of 1v1 corridors with
  ffa4/2v2 filling the boxes) and the cell's VARIANT sets its team count.
  Generating a 2-team map for a 4-team cell would shift seats under the
  geometry, so `--zones board` (the default) reads the live mode. The
  original Voronoi scheme is kept as `--zones voronoi`, a design proposal you
  can look at with `plan` — it agrees with the live board on only ~36% of
  cells, so it must NOT be used to pin maps on the running league.
- Each arena is generated at the SIZE CLASS the cell already carries, because
  a pinned spec freezes geometry and the endpoint drops `map_size`.

Usage:
    nim c -d:release -o:/tmp/mapkit tools/mapkit.nim
    export MAPKIT=/tmp/mapkit CAMPAIGN_MAPS_OUT=/tmp/campaign_maps

    python3 scripts/gen_campaign_maps.py plan          # design fields, no io
    python3 scripts/gen_campaign_maps.py snapshot      # read prod board (read-only)
    python3 scripts/gen_campaign_maps.py generate all  # DRY RUN: build + validate + render
    python3 scripts/gen_campaign_maps.py report        # distribution of what was built
    python3 scripts/gen_campaign_maps.py upload --apply  # the only step that writes

`generate` is idempotent: an arena with an existing spec+info file is skipped,
so shards can run in parallel over disjoint lists and a killed run resumes.
NOTHING before `upload --apply` touches production.
"""

from __future__ import annotations

import argparse
import collections
import json
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import hexboard as hb  # noqa: E402

# Restoring a zone means setting the cell's VARIANT as well as its geometry:
# the variant is what fixes seats/teams, and the cell-map endpoint writes it
# alongside the spec. 4ffa8 is the 32-seat giant; 4ffa is the 16-seat quad.
MODE_VARIANT = {"1v1": "1v1", "2v2": "2v2", "ffa4": "4ffa"}

MAPKIT = Path(os.environ.get("MAPKIT", "mapkit"))
OUT = Path(os.environ.get("CAMPAIGN_MAPS_OUT", "campaign_maps"))
SNAPSHOT = Path(os.environ.get("CAMPAIGN_BOARD_SNAPSHOT", str(OUT / "board.json")))


def load_board(args) -> hb.Board:
    """The board we are restoring TO — 12x12 / 91 cells by default.

    A snapshot only supplies per-cell metadata (size class, current variant),
    and only when its geometry matches the target. The live league is still
    the retired 16x16 board until the operator migrates it down, so a
    mismatched snapshot is expected and is NOT an error.
    """
    target = hb.Board(width=args.width, height=args.height, shape="hex")
    if not SNAPSHOT.exists():
        if args.zones == "board":
            sys.exit(f"--zones board needs a snapshot at {SNAPSHOT} — run "
                     "`gen_campaign_maps.py snapshot` first (read-only)")
        return target
    raw = json.loads(SNAPSHOT.read_text())
    if (raw["width"], raw["height"]) != (target.width, target.height):
        print(f"note: snapshot is {raw['width']}x{raw['height']}, target is "
              f"{target.width}x{target.height} — using target geometry, "
              "ignoring snapshot cells", file=sys.stderr)
        if args.zones == "board":
            sys.exit("--zones board needs a snapshot matching the target board")
        return target
    return hb.Board(width=target.width, height=target.height, shape="hex",
                    cells=raw.get("cells", {}))


def polygon_count(path: Path) -> int:
    spec = json.loads(path.read_text())
    return sum(1 for o in spec["leftObstacles"] if o.get("kind") == "polygon")


def generate_cell(
    board: hb.Board, cid: str, mode: str, size: str, max_tries: int = 80
) -> dict:
    """Retry seeds until the validator passes. Quad-mirror cells keep probing
    for several passing candidates and keep the most ORGANIC one (most blob
    polygons): their pass band is much tighter, and many passing seeds carry
    few or no caves blobs."""
    x, y = hb.parse_cell(cid)
    params = hb.params_for(board, x, y, mode)
    spec_path = OUT / f"cell_{x}_{y}.json"
    tmp_path = OUT / f"cell_{x}_{y}.tmp.json"
    want_candidates = 5 if mode == "ffa4" else 1
    best: tuple[int, int, int] | None = None  # (blobs, -tries, seed)
    found = 0
    for k in range(max_tries):
        seed = hb.base_seed(x, y) + k * 7919
        cmd = [
            str(MAPKIT), "generate", "--style", "caves",
            "--seed", str(seed), "--size", size,
            "--symmetry", hb.SYMMETRY[mode], "--endzone", "column",
            "-o", str(tmp_path),
        ]
        if mode == "ffa4":
            cmd += ["--layout", "corners"]
        cmd += hb.features_for(board, x, y, mode)
        for key, val in params.items():
            cmd += ["--param", f"{key}={val}"]
        subprocess.run(cmd, check=True, capture_output=True)
        ok = subprocess.run(
            [str(MAPKIT), "validate", str(tmp_path)], capture_output=True
        )
        if ok.returncode != 0:
            continue
        found += 1
        blobs = polygon_count(tmp_path)
        if best is None or (blobs, -k, seed) > best:
            best = (blobs, -k, seed)
            tmp_path.replace(spec_path)
        else:
            tmp_path.unlink()
        if found >= want_candidates:
            break
    if best is None:
        raise RuntimeError(f"cell {cid}: no passing seed in {max_tries} tries")
    subprocess.run(
        [str(MAPKIT), "render", str(spec_path), "-o", str(OUT / f"cell_{x}_{y}.png")],
        check=True, capture_output=True,
    )
    return {
        "cell": cid, "mode": mode, "size": size, "seed": best[2],
        "tries": -best[1] + 1, "blobs": best[0], "params": params,
        "members": board.members_of(cid),
    }


# --- commands ---------------------------------------------------------------


def cmd_plan(args) -> None:
    board = load_board(args)
    print(f"board: {board.width}x{board.height} {board.shape}, "
          f"{len(board.coords())} cells, radius {board.radius}, "
          f"centre {board.centre}")
    anchors = hb.zone_anchors(board)
    print(f"zone anchors (design scheme): "
          + ", ".join(f"{m}={anchors[m]}" for m in hb.MODES))

    def zone_glyph(x, y):
        return hb.mode_glyph(hb.zone_mode(board, x, y))

    print("\nVORONOI zone proposal (hex distance to nearest anchor):")
    print(hb.render_board(board, zone_glyph, width=1))
    counts = collections.Counter(
        hb.zone_mode(board, x, y) for x, y in board.coords()
    )
    total = len(board.coords())
    print("  zone sizes: " + ", ".join(
        f"{m}={counts[m]} ({counts[m]/total:.1%})" for m in hb.MODES))

    if board.cells:
        live = collections.Counter(
            board.board_mode(c) for c in board.ids() if board.board_mode(c)
        )
        print("\nLIVE board modes (what the league actually has):")
        print(hb.render_board(
            board, lambda x, y: hb.mode_glyph(board.board_mode(hb.cell_id(x, y)) or "?"),
            width=1))
        print("  live mode counts: " + ", ".join(
            f"{m}={live[m]} ({live[m]/total:.1%})" for m in hb.MODES))
        agree = sum(
            1 for x, y in board.coords()
            if hb.zone_mode(board, x, y) == board.board_mode(hb.cell_id(x, y))
        )
        print(f"  voronoi vs live agreement: {agree}/{total} = {agree/total:.1%}"
              "  <- why --zones board is the default")
        print(f"  arenas (blob anchors): {len(board.anchors())}")

    print("\nDENSITY gradient (obstacle fill x100; peaks at the centre):")
    print(hb.render_board(
        board,
        lambda x, y: int(round(100 * (0.17 + (1 - hb.density_norm(board, x, y)) * 0.14))),
        width=2))
    fills = collections.Counter(
        round(0.17 + (1 - hb.density_norm(board, x, y)) * 0.14, 3)
        for x, y in board.coords()
    )
    print("  fill -> cells: " + ", ".join(
        f"{f}:{n}" for f, n in sorted(fills.items(), reverse=True)))


def cmd_snapshot(args) -> None:
    import campaign_api

    OUT.mkdir(parents=True, exist_ok=True)
    raw = campaign_api.fetch_board()
    SNAPSHOT.write_text(json.dumps(raw, indent=2, sort_keys=True))
    board = hb.Board(width=raw["width"], height=raw["height"],
                     shape=raw["shape"], cells=raw["cells"])
    pinned = sum(1 for c in raw["cells"].values() if c.get("pinned"))
    print(f"snapshot -> {SNAPSHOT}")
    print(f"  {raw['width']}x{raw['height']} {raw['shape']}, "
          f"mode_layout={raw.get('mode_layout')}, mode_mix={raw.get('mode_mix')}")
    print(f"  {len(raw['cells'])} cells, {len(board.anchors())} arenas, "
          f"{pinned} already pinned")
    modes = collections.Counter(c["mode"] for c in raw["cells"].values())
    print(f"  modes: {dict(modes)}")


def cmd_generate(args) -> None:
    board = load_board(args)
    OUT.mkdir(parents=True, exist_ok=True)
    if args.cells == ["all"]:
        targets = board.anchors()
    else:
        targets = args.cells
    print(f"generating {len(targets)} arenas (zones={args.zones}) into {OUT}")
    failures: list[tuple[str, str, str]] = []
    for cid in targets:
        x, y = hb.parse_cell(cid)
        if not board.on_board(x, y):
            sys.exit(f"cell {cid} is not on this board")
        info_path = OUT / f"cell_{x}_{y}.info.json"
        if info_path.exists() and (OUT / f"cell_{x}_{y}.json").exists():
            print(f"{cid}: already done, skipping", flush=True)
            continue
        mode = board.mode_for(cid, args.zones)
        size = args.size or board.map_size(cid)
        try:
            info = generate_cell(board, cid, mode, size, max_tries=args.tries)
        except RuntimeError as e:
            # A dry run REPORTS what it could not build instead of dying on the
            # first hard cell: quad-mirror boards have a much tighter pass band
            # and some size classes have none at all.
            print(f"{cid}: FAILED ({mode} {size}) — {e}", flush=True)
            failures.append((cid, mode, size))
            continue
        info_path.write_text(json.dumps(info, indent=2))
        print(f"{cid}: {info['mode']} {info['size']} seed={info['seed']} "
              f"tries={info['tries']} blobs={info['blobs']} "
              f"members={len(info['members'])} params={info['params']}",
              flush=True)
    if failures:
        print(f"\n{len(failures)} arenas had NO passing seed in {args.tries} tries:")
        for cid, mode, size in failures:
            print(f"  {cid}  {mode} {size}")


def _infos() -> list[dict]:
    return [json.loads(p.read_text()) for p in sorted(OUT.glob("*.info.json"))]


def cmd_report(args) -> None:
    board = load_board(args)
    infos = _infos()
    if not infos:
        sys.exit(f"nothing generated in {OUT} — run `generate all` first")
    print(f"{len(infos)} arenas generated in {OUT}")
    by_mode = collections.Counter(i["mode"] for i in infos)
    cells = sum(len(i["members"]) for i in infos)
    print(f"  covering {cells} cells of {len(board.coords())}")
    print("  arenas per mode: " + ", ".join(
        f"{m}={by_mode[m]}" for m in hb.MODES if by_mode[m]))
    cells_mode = collections.Counter()
    for i in infos:
        cells_mode[i["mode"]] += len(i["members"])
    print("  cells per mode:  " + ", ".join(
        f"{m}={cells_mode[m]}" for m in hb.MODES if cells_mode[m]))
    print("  sizes: " + str(dict(collections.Counter(i["size"] for i in infos))))
    fills = collections.Counter(i["params"]["fillProb"] for i in infos)
    print("  fillProb -> arenas: " + ", ".join(
        f"{f}:{n}" for f, n in sorted(fills.items(), reverse=True)))
    tries = [i["tries"] for i in infos]
    print(f"  seed tries: min={min(tries)} max={max(tries)} "
          f"mean={sum(tries)/len(tries):.1f}")
    missing = [c for c in board.anchors()
               if not (OUT / f"cell_{c.replace(',', '_')}.json").exists()]
    if missing:
        print(f"  MISSING {len(missing)} arenas: {missing[:12]}")
    else:
        print("  every arena on the board has a spec")

    blank = [i["cell"] for i in infos if i["blobs"] == 0]
    if blank:
        print(f"  NO organic terrain (0 caves polygons) in {len(blank)} arenas: "
              f"{blank}  <- mapkit's fixed 230px quad centre strip clips every "
              "style shape out of a small quad-mirror board")

    # Neighbour similarity: how much obstacle fill changes across one edge.
    # Reported within a mode as well as overall, because ffa4 runs a different
    # fill band (0.26..0.34) than the 2-team modes (0.17..0.31) — a 1v1 cell
    # beside an ffa4 cell is SUPPOSED to differ.
    fill_of, mode_of = {}, {}
    for i in infos:
        for m in i["members"]:
            fill_of[m] = i["params"]["fillProb"]
            mode_of[m] = i["mode"]
    every, same = [], []
    for x, y in board.coords():
        cid = hb.cell_id(x, y)
        a = fill_of.get(cid)
        if a is None:
            continue
        for nx, ny in board.neighbors(x, y):
            nid = hb.cell_id(nx, ny)
            b = fill_of.get(nid)
            if b is None:
                continue
            every.append(abs(a - b))
            if mode_of[nid] == mode_of[cid]:
                same.append(abs(a - b))
    if every:
        print(f"  neighbour fill delta: all-pairs mean={sum(every)/len(every):.4f} "
              f"max={max(every):.3f}")
    if same:
        print(f"                        same-mode mean={sum(same)/len(same):.4f} "
              f"max={max(same):.3f}  (density band spans 0.140)")


def cmd_mapping(args) -> None:
    """Which authored map each restored cell inherits — no io, no generation."""
    board = load_board(args)
    old = hb.square_board(args.old_width, args.old_height)
    mapping, orphans, spare = hb.correspondence(board, old)
    print(f"carrying {old.width}x{old.height} ({len(old.coords())} authored "
          f"cells) onto {board.width}x{board.height} ({len(board.coords())} "
          "hex cells)")
    print(f"  {len(mapping)} restored cells inherit an authored map")
    print(f"  {len(orphans)} have NO ancestor and must be generated: "
          f"{orphans if orphans else 'none'}")
    print(f"  {len(spare)} authored cells have nowhere to go: {spare}")
    per = collections.Counter(hb.zone_mode(board, *hb.parse_cell(c))
                              for c in mapping)
    print("  placed per mode: " + ", ".join(
        f"{m}={per[m]}" for m in hb.MODES if per[m]))
    if args.verbose:
        for cid in sorted(mapping, key=hb.parse_cell):
            print(f"    {cid:>6s} <- {mapping[cid]:>5s}  "
                  f"{hb.zone_mode(board, *hb.parse_cell(cid))}")


def cmd_place(args) -> None:
    """Place RECOVERED authored specs onto the restored board.

    Exact recovery beats regeneration, so this runs first: whatever daveey
    actually authored is carried across, and `generate` afterwards fills only
    what is genuinely left over (its idempotent skip does the rest)."""
    board = load_board(args)
    old = hb.square_board(args.old_width, args.old_height)
    mapping, orphans, _ = hb.correspondence(board, old)
    src = Path(args.recovered)
    if not src.is_dir():
        sys.exit(f"no recovered-spec directory at {src}")
    OUT.mkdir(parents=True, exist_ok=True)
    placed, absent = 0, []
    for cid in sorted(mapping, key=hb.parse_cell):
        ox, oy = hb.parse_cell(mapping[cid])
        found = next((c for c in (src / f"cell_{ox}_{oy}.json",
                                  src / f"old_{ox}_{oy}.json",
                                  src / f"{ox},{oy}.json") if c.exists()), None)
        if found is None:
            absent.append(cid)
            continue
        x, y = hb.parse_cell(cid)
        spec_path = OUT / f"cell_{x}_{y}.json"
        spec_path.write_text(found.read_text())
        subprocess.run([str(MAPKIT), "validate", str(spec_path)],
                       check=True, capture_output=True)
        subprocess.run([str(MAPKIT), "render", str(spec_path),
                        "-o", str(OUT / f"cell_{x}_{y}.png")],
                       check=True, capture_output=True)
        (OUT / f"cell_{x}_{y}.info.json").write_text(json.dumps({
            "cell": cid, "mode": hb.zone_mode(board, x, y),
            "size": "authored", "seed": None, "tries": 0,
            "blobs": polygon_count(spec_path),
            "params": {"fillProb": None},
            "members": [cid], "provenance": "recovered",
            "source_cell": mapping[cid], "source_file": str(found),
        }, indent=2))
        placed += 1
        print(f"{cid}: placed authored map from {mapping[cid]}", flush=True)
    todo = sorted(set(orphans) | set(absent), key=hb.parse_cell)
    print(f"\nplaced {placed} authored maps; {len(todo)} cells still need "
          f"generating: {todo if todo else 'none'}")
    print("run `generate all` next — it skips everything already placed")


def cmd_upload(args) -> None:
    import campaign_api

    board = load_board(args)
    infos = _infos()
    if not infos:
        sys.exit(f"nothing generated in {OUT} — run `generate all` first")
    uploads = []
    for info in infos:
        x, y = hb.parse_cell(info["cell"])
        spec = json.loads((OUT / f"cell_{x}_{y}.json").read_text())
        png = (OUT / f"cell_{x}_{y}.png").read_bytes()
        for member in info["members"]:
            uploads.append((member, info["cell"], spec, png))
    print(f"{len(infos)} arenas -> {len(uploads)} cell pins "
          f"(each also sets map_ref, which is what restores the zone)")
    if not args.apply:
        print("DRY RUN — nothing was sent. Re-run with --apply to write to "
              f"league {campaign_api.LEAGUE}.")
        for member, anchor, _, _ in uploads[:10]:
            print(f"  would pin {member} (arena {anchor})")
        print(f"  ... {len(uploads)} total")
        return
    for member, anchor, spec, png in uploads:
        mode = board.mode_for(anchor, args.zones)
        resp = campaign_api.upload_cell_map(
            member, spec, png, map_ref=MODE_VARIANT[mode])
        print(f"{member}: pinned {mode} -> variant {MODE_VARIANT[mode]}, "
              f"preview={resp.get('preview_url')}", flush=True)


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--zones", choices=["voronoi", "board"], default="voronoi",
                   help="where each cell's MODE comes from. DEFAULT 'voronoi' "
                        "is daveey's design and the restoration target; "
                        "'board' reads the live snapshot, which currently "
                        "carries the tic-tac-toe damage, not a design")
    p.add_argument("--old-width", type=int, default=10)
    p.add_argument("--old-height", type=int, default=10)
    p.add_argument("--width", type=int, default=12)
    p.add_argument("--height", type=int, default=12)
    p.add_argument("--size", default=None,
                   help="force one size class for every arena (default: each "
                        "cell's own map_size)")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("plan").set_defaults(fn=cmd_plan)
    sub.add_parser("snapshot").set_defaults(fn=cmd_snapshot)
    g = sub.add_parser("generate")
    g.add_argument("cells", nargs="*", default=["all"])
    g.add_argument("--tries", type=int, default=80,
                   help="seeds to probe per arena before giving up")
    g.set_defaults(fn=cmd_generate)
    sub.add_parser("report").set_defaults(fn=cmd_report)
    m = sub.add_parser("mapping")
    m.add_argument("--verbose", action="store_true")
    m.set_defaults(fn=cmd_mapping)
    pl = sub.add_parser("place")
    pl.add_argument("--recovered", required=True,
                    help="directory of recovered authored specs, named "
                         "cell_X_Y.json by their OLD square cell")
    pl.set_defaults(fn=cmd_place)
    u = sub.add_parser("upload")
    u.add_argument("--apply", action="store_true",
                   help="actually write to the live league")
    u.set_defaults(fn=cmd_upload)
    args = p.parse_args()
    if args.cmd == "generate" and not args.cells:
        args.cells = ["all"]
    args.fn(args)


if __name__ == "__main__":
    main()

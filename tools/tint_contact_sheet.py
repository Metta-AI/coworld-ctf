#!/usr/bin/env python3
"""tint_contact_sheet.py — build a look-at-it-like-a-viewer montage of every
team identity, for eyeballing whether N teams stay visually distinguishable
at a glance and at thumbnail size.

Companion to tools/tint_team_art.py: run this after generating new team
sets to sanity-check the result the way a player actually sees it (a wall
of small sprites at HUD scale), not as a pixel-diff number.

Usage:
  python3 tools/tint_contact_sheet.py --data-dir data \\
      --colors red,blue,green,yellow,violet,amber,... \\
      --out /tmp/contact_sheet.png [--thumb 140]

If --colors is omitted, it's inferred by scanning data/soldier_*.png.
"""
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image


def row(paths, size, bg=(90, 90, 90)):
    imgs = []
    for p in paths:
        if p.exists():
            im = Image.open(p).convert("RGBA")
            im.thumbnail((size, size))
        else:
            # Missing asset: flag it loudly rather than silently skip.
            im = Image.new("RGBA", (size, size), (255, 0, 255, 255))
        imgs.append(im)
    max_h = max(i.height for i in imgs)
    w = sum(i.width for i in imgs) + 4 * (len(imgs) + 1)
    h = max_h + 8
    canvas = Image.new("RGBA", (w, h), (*bg, 255))
    x = 4
    for i in imgs:
        canvas.paste(i, (x, 4 + (max_h - i.height) // 2), i)
        x += i.width + 4
    return canvas.convert("RGB")


def stack(rows, bg=(255, 255, 255)):
    w = max(r.width for r in rows)
    h = sum(r.height for r in rows) + 4 * (len(rows) + 1)
    canvas = Image.new("RGB", (w, h), bg)
    y = 4
    for r in rows:
        canvas.paste(r, (4, y))
        y += r.height + 4
    return canvas


def infer_colors(data_dir: Path) -> list[str]:
    colors = []
    for f in sorted(data_dir.glob("soldier_*.png")):
        stem = f.stem  # soldier_{color}[_suffix]
        rest = stem[len("soldier_"):]
        if rest.endswith("_crown") or rest.endswith("_front_gun") or rest.endswith("_front"):
            continue
        colors.append(rest)
    return colors


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--data-dir", default="data")
    ap.add_argument("--colors", help="comma-separated color words; default = infer from data/soldier_*.png")
    ap.add_argument("--out", default="/tmp/contact_sheet.png")
    ap.add_argument("--thumb", type=int, default=140)
    args = ap.parse_args()

    data_dir = Path(args.data_dir)
    colors = args.colors.split(",") if args.colors else infer_colors(data_dir)
    print(f"{len(colors)} colors: {colors}")

    rows = [
        row([data_dir / f"soldier_{c}.png" for c in colors], args.thumb),
        row([data_dir / f"soldier_{c}_front.png" for c in colors], args.thumb),
        row([data_dir / f"heart_{c}.png" for c in colors], args.thumb),
        row([data_dir / f"ped_{c}.png" for c in colors], args.thumb),
        row([data_dir / "rig_real" / c / "head.png" for c in colors], args.thumb),
        row([data_dir / "rig_real" / c / "wheel_l.png" for c in colors], args.thumb),
    ]
    sheet = stack(rows)
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    sheet.save(args.out)
    print(f"wrote {args.out} ({sheet.width}x{sheet.height})")


if __name__ == "__main__":
    main()

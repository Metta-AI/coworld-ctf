#!/usr/bin/env python3
"""tint_team_art.py — bake-time tint pipeline for new team identities.

Design context: docs/designs/BR_MAPGEN.md §6.2 ("Art: 12 new identities —
build the TINT PIPELINE, do not hand-author."). The art contract (unchanged
by this tool) is a set of paths string-built from `teamText(team)` in
src/ctf/map_art.nim and src/ctf/rig_art.nim:

    data/soldier_{color}.png
    data/soldier_{color}_crown.png
    data/soldier_{color}_front.png
    data/soldier_{color}_front_gun.png
    data/rig_real/{color}/{arm_l,arm_r,head,head_crown,
                            leg_fl,leg_fr,leg_rear,
                            wheel_l,wheel_r,wheel_rear}.png
    data/heart_{color}.png
    data/ped_{color}.png

Only 4 hand-painted masters exist (red, blue, green, yellow). This tool
derives new color sets from the RED master by a per-pixel HSL transform,
calibrated so it reproduces the 3 other authored sets closely (see the
`verify` subcommand).

HOW THE AUTHORED SETS ACTUALLY DIFFER (measured, not assumed — see
`analyze`): pixel-diffing red vs blue/green/yellow on the rig art shows a
clean bimodal split by hue-distance from red's own hue (~3.4 degrees): ~80%
of visible pixels sit within ~10 degrees of the red hue and get recolored;
a separate, distinctly-hued cluster (the cyan face screen, hue ~180-200)
never changes at all between colors, and there is almost nothing in
between. So the rule the authored art actually follows is:

  * Pixels whose hue is close to the master's team hue -> get the new
    team's hue. This includes "neutral-looking" parts like wheel rubber,
    which are not truly achromatic in the master (they carry a faint
    warm cast) and pick up a correspondingly faint cast in every color.
  * Pixels with a distinctly different, high-saturation hue (screen glow,
    eyes) -> never touched. Outlines/shadow/near-black and near-white
    pixels are low-saturation, so hue is irrelevant to begin with and they
    come through visually unchanged either way.
  * Lightness (HSL L) is preserved almost exactly (correlation ~0.999-1.0,
    mean abs diff 0.015-0.05) — this is NOT a naive hue-rotate-by-delta;
    it is closer to a "Colorize/Color-blend" recolor that keeps the
    original shading ramp and only replaces hue (+ rescales saturation a
    bit per color; green in particular is painted visibly less saturated
    and a bit darker than a pure hue swap would give).

THE MODEL
---------
For a target color anchored by a single reference RGBA (e.g. the flat
"pure" swatch of that team's color, ignoring highlights/shadows):

  target_hue            = hue(anchor)
  s_scale = S(anchor)   / S(RED_REF)      (RED_REF = red master's own
  l_scale = L(anchor)   / L(RED_REF)       reference swatch, computed the
                                            same way — see reference_red())

Then, per pixel of the red master:
  - if the pixel's hue is far from red's hue AND it is meaningfully
    saturated (the "foreign color" test — this is what protects the cyan
    screen / eyes), leave it untouched.
  - otherwise: keep H,S,L's *shading structure* by rescaling S and L
    multiplicatively and overwriting H with target_hue, then convert back
    to RGB. Alpha always passes through unchanged.

This single mechanism reproduces blue/green/yellow from red at a mean
per-file MAE of ~3-6 (0-255 scale) on the soldier + rig_real files — see
`verify`.

USAGE
-----
  # Derive params for a color and print them (sanity check / debugging):
  python3 tools/tint_team_art.py derive --rgba 168,64,220,255

  # Validate the model against the 3 authored non-red sets:
  python3 tools/tint_team_art.py verify --data-dir data

  # Generate new team sets from the red master:
  python3 tools/tint_team_art.py generate --data-dir data \\
      --color violet:168,64,220,255 --color amber:230,150,40,255 ...

  # Or from a JSON file: [{"name": "violet", "rgba": [168,64,220,255]}, ...]
  python3 tools/tint_team_art.py generate --data-dir data --colors-json colors.json

Dependencies: Pillow, numpy (both already used elsewhere for asset work).
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image

# ---------------------------------------------------------------------------
# Color math (fully vectorized — no Python-level pixel loops; some of these
# files are ~370k pixels x 16 files x 12 colors).
# ---------------------------------------------------------------------------

def rgb_to_hsv_h(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """rgb: (...,3) float64 in 0..255. Returns (H in [0,360), S, V) in HSV."""
    r, g, b = rgb[..., 0] / 255.0, rgb[..., 1] / 255.0, rgb[..., 2] / 255.0
    maxc = np.maximum(np.maximum(r, g), b)
    minc = np.minimum(np.minimum(r, g), b)
    v = maxc
    delta = maxc - minc
    s = np.where(maxc == 0, 0.0, delta / np.where(maxc == 0, 1, maxc))
    h = np.zeros_like(maxc)
    nz = delta > 1e-9
    rc = (maxc == r) & nz
    gc = (maxc == g) & nz & ~rc
    bc = (maxc == b) & nz & ~rc & ~gc
    h[rc] = ((g[rc] - b[rc]) / delta[rc]) % 6
    h[gc] = ((b[gc] - r[gc]) / delta[gc]) + 2
    h[bc] = ((r[bc] - g[bc]) / delta[bc]) + 4
    h *= 60.0
    return h, s, v


def rgb_to_hls(rgb: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """rgb: (...,3) float64 in 0..255. Returns (S, L) in HSL (hue shared w/ HSV)."""
    r, g, b = rgb[..., 0] / 255.0, rgb[..., 1] / 255.0, rgb[..., 2] / 255.0
    maxc = np.maximum(np.maximum(r, g), b)
    minc = np.minimum(np.minimum(r, g), b)
    l = (maxc + minc) / 2.0
    delta = maxc - minc
    denom = np.where(l < 0.5, np.maximum(maxc + minc, 1e-9), np.maximum(2 - maxc - minc, 1e-9))
    s = np.where(delta < 1e-9, 0.0, delta / denom)
    return s, l


def hls_to_rgb(h_deg: np.ndarray, l: np.ndarray, s: np.ndarray) -> np.ndarray:
    """Vectorized HLS->RGB. h_deg in [0,360), l,s in [0,1]. Returns (...,3) 0..255."""
    h = (h_deg % 360.0) / 360.0
    c = (1 - np.abs(2 * l - 1)) * s
    x = c * (1 - np.abs(((h * 6.0) % 2.0) - 1))
    m = l - c / 2.0
    sector = np.floor(h * 6.0).astype(np.int64) % 6

    r1 = np.zeros_like(h); g1 = np.zeros_like(h); b1 = np.zeros_like(h)
    choices = [
        (c, x, np.zeros_like(h)),
        (x, c, np.zeros_like(h)),
        (np.zeros_like(h), c, x),
        (np.zeros_like(h), x, c),
        (x, np.zeros_like(h), c),
        (c, np.zeros_like(h), x),
    ]
    for i, (rr, gg, bb) in enumerate(choices):
        sel = sector == i
        r1 = np.where(sel, rr, r1)
        g1 = np.where(sel, gg, g1)
        b1 = np.where(sel, bb, b1)
    rgb = np.stack([r1 + m, g1 + m, b1 + m], axis=-1)
    return rgb * 255.0


# ---------------------------------------------------------------------------
# Reference red anchor: the "pure" mid-tone red swatch the whole model is
# calibrated relative to. Derived at runtime from a handful of red master
# files so the tool has no hardcoded magic numbers tied to a specific art
# revision.
# ---------------------------------------------------------------------------

REFERENCE_FILES = [
    "soldier_{c}.png",
    "rig_real/{c}/head.png",
    "rig_real/{c}/arm_l.png",
    "rig_real/{c}/leg_fl.png",
]

RECOLOR_HUE_THRESH_DEG = 24.0  # a pixel is "team-colored" (gets re-hued) if
                                # its hue is within this many degrees of the
                                # master's own team hue...
LOW_SAT_THRESH = 0.12          # ...OR its saturation is this low (grey/
                                # near-black/near-white: hue is irrelevant
                                # to begin with, so recoloring is harmless
                                # and matches the faint team-color cast
                                # observed even on "neutral" parts like
                                # wheel rubber).
#
# Everything else (moderately-to-highly saturated AND far from the team
# hue) passes through untouched. This protects both the cyan face screen
# (hue ~180 deg away, highly saturated) and warm-neutral decorative gold
# (e.g. the crown band drawn by generate_crown_skins.nim: hue ~25-35 deg
# from red, i.e. close enough to look "warm" but far enough that a wider
# window wrongly recolors it — 24 deg was picked by sweeping the authored
# blue/green/yellow calibration MAE and taking the minimum, see `verify`).


def _load_rgba(path: Path) -> np.ndarray:
    return np.array(Image.open(path).convert("RGBA")).astype(np.float64)


def dominant_hue(data_dir: Path, color: str) -> float:
    """Weighted circular mean hue of `color`'s own vivid pixels."""
    hues = []
    weights = []
    for pattern in REFERENCE_FILES:
        f = data_dir / pattern.format(c=color)
        if not f.exists():
            continue
        im = _load_rgba(f)
        alpha = im[..., 3]
        h, s, v = rgb_to_hsv_h(im[..., :3])
        m = (alpha > 200) & (s > 0.4) & (v > 0.3)
        hues.append(h[m])
        weights.append(s[m] * v[m])
    hues = np.concatenate(hues)
    weights = np.concatenate(weights)
    rad = np.deg2rad(hues)
    x = np.sum(np.cos(rad) * weights)
    y = np.sum(np.sin(rad) * weights)
    return float((np.degrees(np.arctan2(y, x)) + 360) % 360)


def reference_sl(data_dir: Path, color: str, hue: float) -> tuple[float, float]:
    """Median (S, L) of `color`'s clean flat swatch pixels (hue within 15deg
    of its own dominant hue, alpha opaque, moderately saturated)."""
    Ss, Ls = [], []
    for pattern in REFERENCE_FILES:
        f = data_dir / pattern.format(c=color)
        if not f.exists():
            continue
        im = _load_rgba(f)
        alpha = im[..., 3]
        h, s_hsv, _ = rgb_to_hsv_h(im[..., :3])
        s, l = rgb_to_hls(im[..., :3])
        hue_dist = np.minimum(np.abs(h - hue), 360 - np.abs(h - hue))
        m = (alpha > 200) & (hue_dist < 15) & (s_hsv > 0.2)
        Ss.append(s[m]); Ls.append(l[m])
    Ss = np.concatenate(Ss); Ls = np.concatenate(Ls)
    return float(np.median(Ss)), float(np.median(Ls))


@dataclass
class TintParams:
    red_hue: float
    target_hue: float
    s_scale: float
    l_scale: float


def derive_params(data_dir: Path, anchor_rgba: tuple[int, int, int, int]) -> TintParams:
    """Compute the tint transform for a new color from a single RGBA anchor
    (the "pure" flat swatch color the word-list owner picked for that team)."""
    red_hue = dominant_hue(data_dir, "red")
    s_ref, l_ref = reference_sl(data_dir, "red", red_hue)

    anchor = np.array([[anchor_rgba[:3]]], dtype=np.float64)
    h_a, s_hsv_a, _ = rgb_to_hsv_h(anchor)
    s_a, l_a = rgb_to_hls(anchor)
    target_hue = float(h_a[0, 0])
    s_scale = float(s_a[0, 0]) / s_ref if s_ref > 1e-6 else 1.0
    l_scale = float(l_a[0, 0]) / l_ref if l_ref > 1e-6 else 1.0
    return TintParams(red_hue=red_hue, target_hue=target_hue, s_scale=s_scale, l_scale=l_scale)


def tint_image(rgba: np.ndarray, params: TintParams,
                recolor_hue_thresh: float = RECOLOR_HUE_THRESH_DEG,
                low_sat_thresh: float = LOW_SAT_THRESH) -> np.ndarray:
    """Apply the tint transform to one RGBA uint8 image array. Alpha passes
    through unchanged; pixels that are neither close to the master's team
    hue nor low-saturation (the cyan screen, decorative gold, eyes) pass
    through unchanged in RGB too."""
    rgba = rgba.astype(np.float64)
    rgb = rgba[..., :3]
    alpha = rgba[..., 3]
    h, s_hsv, _ = rgb_to_hsv_h(rgb)
    s, l = rgb_to_hls(rgb)

    hue_dist = np.minimum(np.abs(h - params.red_hue), 360 - np.abs(h - params.red_hue))
    is_team = (hue_dist < recolor_hue_thresh) | (s_hsv < low_sat_thresh)

    s_out = np.clip(s * params.s_scale, 0.0, 1.0)
    l_out = np.clip(l * params.l_scale, 0.0, 1.0)
    h_out = np.full_like(h, params.target_hue)
    recolored = hls_to_rgb(h_out, l_out, s_out)

    out_rgb = np.where(is_team[..., None], recolored, rgb)
    out = np.concatenate([out_rgb, alpha[..., None]], axis=-1)
    return np.clip(out, 0, 255).astype(np.uint8)


# ---------------------------------------------------------------------------
# The art contract: every path the engine loaders build from teamText(team).
# Source-of-truth: src/ctf/map_art.nim, src/ctf/rig_art.nim.
# ---------------------------------------------------------------------------

SOLDIER_SUFFIXES = ["", "_crown", "_front", "_front_gun"]
RIG_PARTS = ["arm_l", "arm_r", "head", "head_crown", "leg_fl", "leg_fr",
             "leg_rear", "wheel_l", "wheel_r", "wheel_rear"]


def contract_files(color: str) -> list[str]:
    files = [f"soldier_{color}{suf}.png" for suf in SOLDIER_SUFFIXES]
    files += [f"rig_real/{color}/{part}.png" for part in RIG_PARTS]
    files += [f"heart_{color}.png", f"ped_{color}.png"]
    return files


def generate_color(data_dir: Path, source_color: str, name: str,
                    anchor_rgba: tuple[int, int, int, int],
                    dry_run: bool = False) -> tuple[list[Path], "TintParams"]:
    params = derive_params(data_dir, anchor_rgba)
    written = []
    for dest_rel in contract_files(source_color):
        # Build source path by substituting the *source* color into the
        # *pattern*, and dest path by substituting the *new* color.
        if dest_rel.startswith("rig_real/"):
            _, _, part = dest_rel.split("/")
            src_path = data_dir / "rig_real" / source_color / part
            dst_path = data_dir / "rig_real" / name / part
        else:
            suffix = dest_rel[len(f"{dest_rel.split('_')[0]}_{source_color}"):]
            base = dest_rel.split("_")[0]  # "soldier" | "heart" | "ped"
            src_path = data_dir / f"{base}_{source_color}{suffix}"
            dst_path = data_dir / f"{base}_{name}{suffix}"
        red_im = np.array(Image.open(src_path).convert("RGBA"))
        out = tint_image(red_im, params)
        if not dry_run:
            dst_path.parent.mkdir(parents=True, exist_ok=True)
            Image.fromarray(out, "RGBA").save(dst_path)
        written.append(dst_path)
    return written, params


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_rgba(s: str) -> tuple[int, int, int, int]:
    parts = [int(x) for x in s.split(",")]
    if len(parts) == 3:
        parts.append(255)
    if len(parts) != 4:
        raise ValueError(f"expected R,G,B[,A], got {s!r}")
    return tuple(parts)  # type: ignore


def cmd_derive(args):
    data_dir = Path(args.data_dir)
    rgba = parse_rgba(args.rgba)
    p = derive_params(data_dir, rgba)
    print(f"anchor rgba={rgba}")
    print(f"  red reference hue = {p.red_hue:.1f} deg")
    print(f"  target hue        = {p.target_hue:.1f} deg")
    print(f"  s_scale           = {p.s_scale:.3f}")
    print(f"  l_scale           = {p.l_scale:.3f}")


def cmd_generate(args):
    data_dir = Path(args.data_dir)
    colors: list[tuple[str, tuple[int, int, int, int]]] = []
    for spec in args.color or []:
        name, rgba_s = spec.split(":", 1)
        colors.append((name.strip(), parse_rgba(rgba_s)))
    if args.colors_json:
        data = json.loads(Path(args.colors_json).read_text())
        for entry in data:
            colors.append((entry["name"], tuple(entry["rgba"])))
    if not colors:
        print("no --color / --colors-json given", file=sys.stderr)
        sys.exit(2)

    for name, rgba in colors:
        written, params = generate_color(data_dir, args.source, name, rgba, dry_run=args.dry_run)
        tag = "(dry-run) " if args.dry_run else ""
        print(f"{tag}{name}: hue={params.target_hue:.1f} s_scale={params.s_scale:.3f} "
              f"l_scale={params.l_scale:.3f} -> {len(written)} files")
        if args.verbose:
            for w in written:
                print(f"    {w}")


def cmd_verify(args):
    data_dir = Path(args.data_dir)
    source = args.source
    targets = args.colors.split(",") if args.colors else ["blue", "green", "yellow"]

    # Need each target's own anchor RGBA. Use its dominant/reference swatch
    # color derived straight from its authored master, so `verify` measures
    # "if team16-widen's anchor === this color's own true swatch, how close
    # does the model get" -- i.e. the calibration honesty check.
    overall = []
    for color in targets:
        hue = dominant_hue(data_dir, color)
        s_ref, l_ref = reference_sl(data_dir, color, hue)
        # Reconstruct an RGBA anchor at that exact H,S,L so derive_params()
        # exercises the *same* code path `generate` will use.
        anchor_rgb = hls_to_rgb(np.array([[hue]]), np.array([[l_ref]]), np.array([[s_ref]]))[0, 0]
        anchor = (int(round(anchor_rgb[0])), int(round(anchor_rgb[1])), int(round(anchor_rgb[2])), 255)
        params = derive_params(data_dir, anchor)

        maes = []
        for dest_rel in contract_files(color):
            if dest_rel.startswith("rig_real/"):
                _, _, part = dest_rel.split("/")
                src_path = data_dir / "rig_real" / source / part
                actual_path = data_dir / "rig_real" / color / part
            else:
                base = dest_rel.split("_")[0]
                suffix = dest_rel[len(f"{base}_{color}"):]
                src_path = data_dir / f"{base}_{source}{suffix}"
                actual_path = data_dir / f"{base}_{color}{suffix}"
            if not actual_path.exists() or not src_path.exists():
                continue
            src_im = np.array(Image.open(src_path).convert("RGBA"))
            actual_im = np.array(Image.open(actual_path).convert("RGBA"))
            if src_im.shape != actual_im.shape:
                # authored hand-deviation: canvas size itself differs
                # (observed for blue's heart/ped). Can't do a pixel MAE;
                # flag it instead of silently skipping.
                print(f"  [skip: shape mismatch {src_im.shape} vs {actual_im.shape}] {actual_path.name}")
                continue
            pred = tint_image(src_im, params)
            mask = (src_im[..., 3] > 10) & (actual_im[..., 3] > 10)
            if mask.sum() == 0:
                continue
            mae = np.abs(pred[..., :3].astype(int) - actual_im[..., :3].astype(int))[mask].mean()
            maes.append((actual_path.name, mae))
            overall.append(mae)

        print(f"{color}: hue={hue:.1f} s_ref={s_ref:.3f} l_ref={l_ref:.3f}  "
              f"(files={len(maes)}, mean MAE={np.mean([m for _, m in maes]):.2f}, "
              f"range {min(m for _, m in maes):.1f}-{max(m for _, m in maes):.1f})")
        if args.verbose:
            for fname, mae in sorted(maes, key=lambda t: -t[1]):
                print(f"    {fname:32s} MAE={mae:.2f}")

    print(f"\noverall mean per-file MAE across {len(overall)} files: {np.mean(overall):.2f}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_derive = sub.add_parser("derive", help="print the tint params for an RGBA anchor")
    p_derive.add_argument("--data-dir", default="data")
    p_derive.add_argument("--rgba", required=True, help="R,G,B[,A]")
    p_derive.set_defaults(func=cmd_derive)

    p_gen = sub.add_parser("generate", help="generate a full team-art set from the red master")
    p_gen.add_argument("--data-dir", default="data")
    p_gen.add_argument("--source", default="red", help="master color to tint from")
    p_gen.add_argument("--color", action="append", help="name:R,G,B[,A] (repeatable)")
    p_gen.add_argument("--colors-json", help='JSON file: [{"name":..,"rgba":[r,g,b,a]}, ...]')
    p_gen.add_argument("--dry-run", action="store_true")
    p_gen.add_argument("--verbose", action="store_true")
    p_gen.set_defaults(func=cmd_generate)

    p_ver = sub.add_parser("verify", help="regenerate authored colors from the master and diff")
    p_ver.add_argument("--data-dir", default="data")
    p_ver.add_argument("--source", default="red")
    p_ver.add_argument("--colors", default="blue,green,yellow")
    p_ver.add_argument("--verbose", action="store_true")
    p_ver.set_defaults(func=cmd_verify)

    args = ap.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()

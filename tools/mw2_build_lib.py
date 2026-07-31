#!/usr/bin/env python3
"""Shared build pipeline for the MW2 v2 map rebuilds.

Generalizes tools/mw2_afghan_v2.py — the pipeline that shipped the accepted
Afghan rebuild — so the other five maps are a per-map SPEC plus a carve list,
not five divergent clones. Every stage carries a lesson that was paid for:

  * masks, not polygons: measured raster masks are the source of truth
    (polygon encodings retrace their faces and no fill rule reconstructs
    them);
  * chokepoints are ENFORCED on the raster, not trusted from the plan
    (hand-tuning geometry to fix one sliver created a bigger one);
  * collision DISCS are fitted to the masks, and for any structure that
    wears a prop sprite, to the SPRITE's silhouette — owner: "the object is
    the collision mask"; rects only where carve-stone is the intended look;
  * verification runs on the SHIPPED raster — the exact shapes the engine
    rasterizes, forced-floor rules included — never on the plan;
  * a stranded pocket after fitting is sealed as rock, not hand-chased.

A map builder does:
    from mw2_build_lib import *
    spec = MapSpec(name=..., w=..., h=..., ...)
    wall = load_masks(spec, ["ring", "structures"])
    ... carves / corridors ...
    wall = enforce_chokes(wall, spec, CHOKES)
    discs = fit_terrain(wall_minus_structs, spec)
    ship_verify(spec, discs, RECT_STRUCTS, DISC_STRUCTS, landmarks)
    emit(spec, discs, RECT_STRUCTS, DISC_STRUCTS, out_path)
"""
import sys
from dataclasses import dataclass, field

import numpy as np
from PIL import Image, ImageDraw
from scipy import ndimage

PLAYER = 13


@dataclass
class MapSpec:
    name: str
    w: int
    h: int
    flag_ring: int = 70
    capture_clear: int = 210     # open-row scan span; forced columns per
    carve_clear: int = -1        # carve_clear semantics (-1 = no columns).
    spawn_w: int = 80
    spawn_h: int = 96
    red_home: tuple = (0, 0)
    blue_home: tuple = (0, 0)
    center: tuple = None
    mask_dir: str = ""
    # fairness: nudge this home east/west up to the limit if short.
    nudge_home: str = "blue"
    nudge_limit_x: int = 0

    def __post_init__(self):
        if self.center is None:
            self.center = (self.w // 2, self.h // 2)


def load_masks(spec, names):
    wall = np.zeros((spec.h, spec.w), bool)
    for name in names:
        m = np.array(Image.open(
            f"{spec.mask_dir}/{name}.png").convert("L")) > 128
        assert m.shape == (spec.h, spec.w), f"{name}: {m.shape}"
        wall |= m
    return wall


def rect(mask, x, y, w, h, val):
    H, W = mask.shape
    mask[max(0, y):min(H, y + h), max(0, x):min(W, x + w)] = val


def carve_rects(wall, rects):
    for x, y, w, h in rects:
        rect(wall, x, y, w, h, 0)
    return wall


def corridor(shape, points, width):
    im = Image.new("L", (shape[1], shape[0]), 0)
    d = ImageDraw.Draw(im)
    for (x0, y0), (x1, y1) in zip(points, points[1:]):
        d.line([x0, y0, x1, y1], fill=1, width=width)
        d.ellipse([x0 - width // 2, y0 - width // 2,
                   x0 + width // 2, y0 + width // 2], fill=1)
    x, y = points[-1]
    d.ellipse([x - width // 2, y - width // 2,
               x + width // 2, y + width // 2], fill=1)
    return np.array(im, bool)


def probe_gap(mask, seg):
    """Longest open run along a probe segment crossing a gap, in px."""
    x0, y0, x1, y1 = seg
    n = int(max(abs(x1 - x0), abs(y1 - y0)))
    best = run = 0
    for i in range(n + 1):
        x = int(round(x0 + (x1 - x0) * i / n))
        y = int(round(y0 + (y1 - y0) * i / n))
        if not mask[y, x]:
            run += 1
            best = max(best, run)
        else:
            run = 0
    return best


def enforce_chokes(wall, spec, chokes, margin=8):
    """Shave rock 3px/pass until each scheduled gap meets spec + margin
    (margin absorbs <= 4px/side disc-fit overreach). Raises if unresolvable."""
    for label, seg, want in chokes:
        want_mask = want + margin
        passes = 0
        while probe_gap(wall, seg) < want_mask and passes < 30:
            x0, y0, x1, y1 = seg
            n = int(max(abs(x1 - x0), abs(y1 - y0)))
            for i in range(n + 1):
                x = int(round(x0 + (x1 - x0) * i / n))
                y = int(round(y0 + (y1 - y0) * i / n))
                if wall[y, x]:
                    wall[max(0, y - 3):y + 4, max(0, x - 3):x + 4] = 0
            passes += 1
        got = probe_gap(wall, seg)
        print(f"  choke {label:<26} {got:>4}px (want >= {want_mask}) "
              f"[{passes} shaves]")
        if got < want_mask:
            raise SystemExit(f"chokepoint {label} unresolvable")
    return wall


def forced_floor(spec, mask):
    """The engine's forced-floor rules applied to a wall mask."""
    out = mask.copy()
    yy, xx = np.mgrid[0:spec.h, 0:spec.w]
    cx, cy = spec.center
    out[(xx - cx) ** 2 + (yy - cy) ** 2 <= spec.flag_ring ** 2] = 0
    for hx, hy in (spec.red_home, spec.blue_home):
        out[(np.abs(xx - hx) <= spec.spawn_w) &
            (np.abs(yy - hy) <= spec.spawn_h)] = 0
    carve = (0 if spec.carve_clear < 0 else
             spec.carve_clear if spec.carve_clear > 0 else spec.capture_clear)
    if carve > 0:
        out[:, :carve] = 0
        out[:, spec.w - carve:] = 0
        # forced columns are floor EXCEPT the border ring below
    out[:10, :] = 1
    out[-10:, :] = 1
    out[:, :10] = 1
    out[:, -10:] = 1
    return out


def fits_of(mask):
    return ndimage.binary_erosion(~mask, np.ones((PLAYER, PLAYER), bool))


def seal_pockets(wall, spec, log=print):
    """Pre-fit seal: floor too small to stand in becomes rock."""
    fits = fits_of(forced_floor(spec, wall))
    lab, n = ndimage.label(fits)
    if n > 1:
        sizes = np.bincount(lab.ravel())[1:]
        main_lab = int(sizes.argmax()) + 1
        for i in range(1, n + 1):
            if i == main_lab:
                continue
            pocket = ndimage.binary_dilation(
                lab == i, np.ones((PLAYER + 4, PLAYER + 4), bool))
            wall |= pocket
            log(f"  sealed a {int((lab == i).sum())}-cell pocket as rock")
    return wall


def fit_terrain(mask, spec, max_discs=700, residual=0.02, min_radius=5,
                overreach=4, inflate=3):
    """Bbox-windowed greedy maximal-inscribed-disc fit (mw2_fit_collision
    semantics at terrain scale)."""
    H, W = mask.shape
    area = int(mask.sum())
    if area == 0:
        return []
    dist_in = ndimage.distance_transform_edt(mask)
    dist_out = ndimage.distance_transform_edt(~mask)
    covered = np.zeros_like(mask)
    discs = []
    while len(discs) < max_discs:
        remaining = mask & ~covered
        if remaining.sum() < residual * area:
            break
        flat = np.where(remaining, dist_in, -1.0)
        row, col = np.unravel_index(int(np.argmax(flat)), flat.shape)
        if dist_in[row, col] < min_radius:
            break
        radius = int(np.floor(dist_in[row, col])) + inflate
        while radius > 0:
            y0, y1 = max(0, row - radius), min(H, row + radius + 1)
            x0, x1 = max(0, col - radius), min(W, col + radius + 1)
            yy, xx = np.mgrid[y0:y1, x0:x1]
            disc = (xx - col) ** 2 + (yy - row) ** 2 <= radius * radius
            spill = disc & ~mask[y0:y1, x0:x1]
            if not spill.any() or \
                    dist_out[y0:y1, x0:x1][spill].max() <= overreach:
                covered[y0:y1, x0:x1] |= disc
                discs.append((int(col), int(row), int(radius)))
                break
            radius -= 1
        if radius <= 0:
            covered[row, col] = True
    cov = (covered & mask).sum() / max(area, 1)
    spill = covered & ~mask
    over = dist_out[spill].max() if spill.any() else 0.0
    print(f"  {len(discs)} terrain discs, coverage {cov:.1%}, overreach "
          f"{over:.1f}px")
    if cov < 0.96 or over > 4.0:
        raise SystemExit("terrain fit out of tolerance")
    return discs


def fit_props(jobs, repo_root="."):
    """Silhouette-fitted collision for propped structures.

    jobs: (sprite, cx, cy, w, h, rot, label). Small sprites need MIN_RADIUS 3
    (a 21px tail cone cannot reach 95% coverage on 5px discs). Returns
    (nim_lines, all_ok).
    """
    sys.path.insert(0, "tools")
    import mw2_fit_collision as fit
    fit.MIN_RADIUS = 3
    fit.RESIDUAL_FRAC = 0.02
    out, allok = [], True
    for name, cx, cy, w, h, rot, label in jobs:
        placement = dict(png=f"data/props/{name}.png", x=cx, y=cy, w=w, h=h,
                         rot=rot, label=label)
        shape_lines, _, report, ok = fit.process_placement(
            placement, repo_root)
        print(f"  prop {label:<30} discs={len(shape_lines):>3} "
              f"cover={report.get('covered_pct', 0):.1f}% ok={ok}")
        allok &= ok
        out.append(f"    # {label} (collision fitted to the sprite)")
        for ln in shape_lines:
            if "ArenaShape" in ln:
                out.append(ln if ln.startswith("    ") else
                           "    " + ln.strip())
    return out, allok


def raster_shapes(spec, discs, rect_structs, disc_structs):
    """The SHIPPED wall mask: exactly what the engine will rasterize."""
    wall = np.zeros((spec.h, spec.w), bool)
    for cx, cy, r in discs + [(c, y, r) for _, c, y, r in disc_structs]:
        y0, y1 = max(0, cy - r), min(spec.h, cy + r + 1)
        x0, x1 = max(0, cx - r), min(spec.w, cx + r + 1)
        yy, xx = np.mgrid[y0:y1, x0:x1]
        wall[y0:y1, x0:x1] |= (xx - cx) ** 2 + (yy - cy) ** 2 <= r * r
    for _, x, y, w, h in rect_structs:
        rect(wall, x, y, w, h, 1)
    return forced_floor(spec, wall)


def bfs_dist(free, seed):
    dist = np.full(free.shape, -1, np.int32)
    if not free[seed[1], seed[0]]:
        return dist
    frontier = np.zeros(free.shape, bool)
    frontier[seed[1], seed[0]] = True
    dist[seed[1], seed[0]] = 0
    cross = np.array([[0, 1, 0], [1, 1, 1], [0, 1, 0]], bool)
    n = 0
    while frontier.any():
        n += 1
        frontier = ndimage.binary_dilation(frontier, structure=cross) \
            & free & (dist < 0)
        dist[frontier] = n
    return dist


def ship_verify(spec, discs, rect_structs, disc_structs, landmarks,
                fairness_min=0.72):
    """All the invariants, on the raster the engine will actually build.

    Mutates `discs` (post-fit pocket seal) and spec homes (fairness nudge,
    plan-sanctioned direction only). Raises on failure."""
    for attempt in range(2):
        shipped = raster_shapes(spec, discs, rect_structs, disc_structs)
        Image.fromarray((~shipped * 255).astype(np.uint8)).save(
            f"/tmp/{spec.name}_v2_shipped.png")
        fits = fits_of(shipped)
        lab, _ = ndimage.label(fits)
        seed = spec.red_home
        main = lab == lab[seed[1], seed[0]] if fits[seed[1], seed[0]] else \
            np.zeros_like(fits)
        ok = True
        for name, (x, y) in landmarks.items():
            reached = bool(main[y, x])
            print(f"  reach {name:<18} {'ok' if reached else 'FAIL'}")
            ok &= reached
        stray = fits & ~main
        if stray.any():
            lab2, n2 = ndimage.label(stray)
            for i in range(1, n2 + 1):
                ys, xs = np.where(lab2 == i)
                cx, cy = int(xs.mean()), int(ys.mean())
                r = int(np.hypot(xs - cx, ys - cy).max()) + PLAYER + 2
                discs.append((cx, cy, r))
                print(f"  sealed stranded {len(xs)}-cell sliver: disc "
                      f"({cx},{cy}) r{r}")
            shipped = raster_shapes(spec, discs, rect_structs, disc_structs)
            fits = fits_of(shipped)
            lab, _ = ndimage.label(fits)
            main = lab == lab[seed[1], seed[0]]
        stranded = int((fits & ~main).sum())
        print(f"  stranded 13px-fit cells: {stranded}")
        ok &= stranded == 0
        span = shipped[:, spec.capture_clear + 5:
                       spec.w - spec.capture_clear - 5]
        open_rows = int((~span).all(axis=1).sum())
        print(f"  fully-open cross-field rows: {open_rows}")
        ok &= open_rows == 0
        free = ~shipped
        dr = bfs_dist(free, spec.red_home)
        db = bfs_dist(free, spec.blue_home)
        col_r = dr[:, spec.w // 2][dr[:, spec.w // 2] >= 0]
        col_b = db[:, spec.w // 2][db[:, spec.w // 2] >= 0]
        rmid, bmid = int(col_r.min()), int(col_b.min())
        ratio = min(rmid, bmid) / max(rmid, bmid)
        print(f"  walk to midfield: red {rmid}, blue {bmid}, "
              f"ratio {ratio:.3f}")
        if ratio < 0.75 and attempt == 0 and spec.nudge_limit_x:
            home = list(spec.blue_home if spec.nudge_home == "blue"
                        else spec.red_home)
            step = 39 if spec.nudge_limit_x > home[0] else -39
            home[0] = (min(spec.nudge_limit_x, home[0] + step) if step > 0
                       else max(spec.nudge_limit_x, home[0] + step))
            if spec.nudge_home == "blue":
                spec.blue_home = tuple(home)
            else:
                spec.red_home = tuple(home)
            print(f"  -> nudging {spec.nudge_home}Home to {tuple(home)}, "
                  "re-verifying")
            continue
        ok &= ratio >= fairness_min
        if not ok:
            raise SystemExit("shipped-raster verification FAILED")
        return shipped
    raise SystemExit("verification did not converge")


def emit(spec, discs, rect_structs, disc_structs, path, header):
    out = [f"    # === {header} ==="]
    for cx, cy, r in discs:
        out.append(f"    ArenaShape(kind: shapeDisc, cx: {cx}, cy: {cy}, "
                   f"radius: {r}),")
    for name, x, y, w, h in rect_structs:
        out.append(f"    # {name}")
        out.append(f"    ArenaShape(kind: shapeRect, rect: MapRect(x: {x}, "
                   f"y: {y}, w: {w}, h: {h})),")
    for name, cx, cy, r in disc_structs:
        out.append(f"    # {name}")
        out.append(f"    ArenaShape(kind: shapeDisc, cx: {cx}, cy: {cy}, "
                   f"radius: {r}),")
    with open(path, "w") as f:
        f.write("\n".join(out) + "\n")
    print(f"wrote {path}")

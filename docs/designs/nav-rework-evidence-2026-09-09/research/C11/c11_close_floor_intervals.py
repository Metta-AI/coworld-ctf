#!/usr/bin/env python3
"""C11: exactness proof for close-floor row intervals (counts only, stdlib).

Reference predicate (rebuildDangerFromPoints, primary body_nav.nim):
  closeRange  = min(DangerClosePx, dangerRangePx)          # R
  closeCells  = (closeRange + NavCell - 1) div NavCell     # cc
  closeSquared = closeRange * closeRange
  origin = cellOf(source) = (clamp(sx div 8, 0, W-1), clamp(sy div 8, 0, H-1))
  for gy in max(0, oy-cc) .. min(H-1, oy+cc):
    for gx in max(0, ox-cc) .. min(W-1, ox+cc):
      dx = 8*gx+4 - sx ; dy = 8*gy+4 - sy
      member iff dx*dx + dy*dy <= closeSquared

Interval formula under test (per row gy, in source-pixel terms):
  dy = 8*gy+4 - sy ; rem = R*R - dy*dy
  rem < 0            -> empty row
  L = isqrt(rem)     -> member iff |dx| <= L  (dx integer)
  xlo = ceil((sx-4-L)/8) ; xhi = floor((sx-4+L)/8)
  then clip to [ox-cc, ox+cc] and [0, W-1]  (the same box the reference walks)
"""
import hashlib, json, math, sys

NAV = 8
CLOSE_PX = 190

def floordiv(a, b):
    return a // b            # Python floors; Nim `div` truncates: see review

def ceildiv(a, b):
    return -((-a) // b)

def reference_cells(sx, sy, R, ox, oy, W, H):
    cc = (R + NAV - 1) // NAV
    R2 = R * R
    out = set()
    for gy in range(max(0, oy - cc), min(H - 1, oy + cc) + 1):
        dy = NAV * gy + NAV // 2 - sy
        for gx in range(max(0, ox - cc), min(W - 1, ox + cc) + 1):
            dx = NAV * gx + NAV // 2 - sx
            if dx * dx + dy * dy <= R2:
                out.add((gx, gy))
    return out

def interval_rows(sx, sy, R, ox, oy, W, H):
    """Yields (gy, xlo, xhi, stats) with xlo > xhi meaning empty."""
    cc = (R + NAV - 1) // NAV
    R2 = R * R
    for gy in range(max(0, oy - cc), min(H - 1, oy + cc) + 1):
        dy = NAV * gy + NAV // 2 - sy
        rem = R2 - dy * dy
        if rem < 0:
            yield gy, 1, 0, 'neg'
            continue
        L = math.isqrt(rem)
        xlo = ceildiv(sx - NAV // 2 - L, NAV)
        xhi = floordiv(sx - NAV // 2 + L, NAV)
        xlo = max(xlo, ox - cc, 0)
        xhi = min(xhi, ox + cc, W - 1)
        yield gy, xlo, xhi, ('exact' if L * L == rem else 'inexact')

def interval_cells(sx, sy, R, ox, oy, W, H):
    out = set(); rows = 0; empty = 0; isqrts = 0; exact_boundary_rows = 0
    for gy, xlo, xhi, tag in interval_rows(sx, sy, R, ox, oy, W, H):
        rows += 1
        if tag != 'neg':
            isqrts += 1
            if tag == 'exact':
                exact_boundary_rows += 1
        if xlo > xhi:
            empty += 1
            continue
        for gx in range(xlo, xhi + 1):
            out.add((gx, gy))
    return out, rows, empty, isqrts, exact_boundary_rows

h = hashlib.sha256()
def feed(case_label, cells):
    h.update(case_label.encode())
    for c in sorted(cells):
        h.update(('%d,%d;' % c).encode())

summary = []
total_cases = 0; total_mismatch = 0; total_ref_evals = 0; total_members = 0
total_rows = 0; total_empty_rows = 0; total_isqrt = 0; total_exact_rows = 0
boundary_cells_total = 0
for R in range(0, CLOSE_PX + 1):
    cc = (R + NAV - 1) // NAV
    W = H = 2 * cc + 5           # box fully inside the grid (no clipping)
    ox = oy = cc + 2
    ref_evals = 0; members = 0; mism = 0; rows = 0; empty = 0; isq = 0; exact_rows = 0; bcells = 0
    for subY in range(NAV):
        for subX in range(NAV):
            sx = ox * NAV + subX; sy = oy * NAV + subY
            ref = reference_cells(sx, sy, R, ox, oy, W, H)
            got, r, e, i, x = interval_cells(sx, sy, R, ox, oy, W, H)
            if ref != got:
                mism += 1
            total_cases += 1
            feed('R%d/%d,%d' % (R, subX, subY), ref)
            ref_evals += (2 * cc + 1) ** 2
            members += len(ref); rows += r; empty += e; isq += i; exact_rows += x
            R2 = R * R
            bcells += sum(1 for (gx, gy) in ref
                          if (NAV * gx + 4 - sx) ** 2 + (NAV * gy + 4 - sy) ** 2 == R2)
    total_mismatch += mism; total_ref_evals += ref_evals; total_members += members
    total_rows += rows; total_empty_rows += empty; total_isqrt += isq
    total_exact_rows += exact_rows; boundary_cells_total += bcells
    summary.append({"R": R, "closeCells": cc, "offsets": 64, "mismatching_offsets": mism,
                    "reference_evaluations_per_source": (2 * cc + 1) ** 2,
                    "members_total_64_offsets": members,
                    "rows_per_source": 2 * cc + 1,
                    "empty_rows_total": empty, "isqrt_calls_total": isq,
                    "rows_with_exact_circle_boundary": exact_rows,
                    "cells_exactly_on_circle_total": bcells})

# Clipping at corners and sides of a small grid, plus interior control.
clip = []
W = H = 12
for R in (0, 5, 8, 37, 100, 190):
    cc = (R + NAV - 1) // NAV
    for (ox, oy) in [(0, 0), (11, 11), (0, 11), (11, 0), (0, 5), (5, 0), (11, 5), (5, 11), (5, 5)]:
        mism = 0; members = 0
        for subY in range(NAV):
            for subX in range(NAV):
                sx = ox * NAV + subX; sy = oy * NAV + subY
                ref = reference_cells(sx, sy, R, ox, oy, W, H)
                got = interval_cells(sx, sy, R, ox, oy, W, H)[0]
                if ref != got: mism += 1
                total_cases += 1; members += len(ref)
                feed('clip R%d o%d,%d s%d,%d' % (R, ox, oy, subX, subY), ref)
        total_mismatch += mism
        clip.append({"R": R, "origin": [ox, oy], "grid": [W, H], "offsets": 64,
                     "mismatching_offsets": mism, "members_total": members})

# Clamped sources: pixel outside the map, origin clamped by cellOf (both formulas
# use the same clamped origin box; the interval works in source-pixel terms).
clamped = []
clamped_cases = 0; clamped_mismatch = 0; clamped_members = 0
xs = [-1, -4, -7, -8, -9, -50, -1000, W * NAV, W * NAV + 3, W * NAV + 7, W * NAV + 8, W * NAV + 100, W * NAV + 1000, 40]
ys = [-1, -8, -9, -300, H * NAV, H * NAV + 5, H * NAV + 8, H * NAV + 2000, 40]
for R in range(0, CLOSE_PX + 1):
    cc = (R + NAV - 1) // NAV
    for sx in xs:
        for sy in ys:
            if 0 <= sx < W * NAV and 0 <= sy < H * NAV:
                continue                      # in-map control is covered above
            ox = min(max(sx // NAV, 0), W - 1); oy = min(max(sy // NAV, 0), H - 1)
            ref = reference_cells(sx, sy, R, ox, oy, W, H)
            got = interval_cells(sx, sy, R, ox, oy, W, H)[0]
            total_cases += 1; clamped_cases += 1; clamped_members += len(ref)
            if ref != got:
                total_mismatch += 1; clamped_mismatch += 1
            feed('clamp R%d s%d,%d' % (R, sx, sy), ref)
            if R in (0, 8, 37, 190) and (sx, sy) in ((-5, 40), (-1, 40), (W * NAV, 40), (40, -1), (-9, -9), (W * NAV + 100, H * NAV + 2000)):
                clamped.append({"R": R, "source": [sx, sy], "origin": [ox, oy], "members": len(ref),
                                "mismatch": ref != got})
clamped_summary = {"cases": clamped_cases, "mismatches": clamped_mismatch,
                   "member_cells_total": clamped_members,
                   "x_excursions": xs, "y_excursions": ys, "grid_cells": [W, H],
                   "note": "source pixel kept as given; origin = cellOf clamp; box centred on the clamped origin, distance from the original pixel, as in the primary loop"}

# Disc-inside-box property for unclamped sources: every member lies in the box.
box_ok = True
for R in range(0, CLOSE_PX + 1):
    cc = (R + NAV - 1) // NAV
    W2 = H2 = 2 * cc + 9; ox = oy = cc + 4
    for subY in range(NAV):
        for subX in range(NAV):
            sx = ox * NAV + subX; sy = oy * NAV + subY
            # walk a box two cells wider than closeCells and require no members outside
            R2 = R * R
            for gy in range(oy - cc - 2, oy + cc + 3):
                dy = NAV * gy + 4 - sy
                for gx in (ox - cc - 2, ox - cc - 1, ox + cc + 1, ox + cc + 2):
                    dx = NAV * gx + 4 - sx
                    if dx * dx + dy * dy <= R2: box_ok = False
            for gx in range(ox - cc - 2, ox + cc + 3):
                dx = NAV * gx + 4 - sx
                for gy in (oy - cc - 2, oy - cc - 1, oy + cc + 1, oy + cc + 2):
                    dy = NAV * gy + 4 - sy
                    if dx * dx + dy * dy <= R2: box_ok = False

# Row-table storage (per system, one closeRange): xlo/xhi offsets relative to the
# origin cell lie in [-closeCells, closeCells]; at R=190, closeCells=24 fits int8.
cc190 = (CLOSE_PX + NAV - 1) // NAV
rows190 = 2 * cc190 + 1
storage = {
    "closeCells_at_190": cc190, "rows_at_190": rows190,
    "full_table_int8_bytes_64_offsets": 64 * rows190 * 2 * 1,
    "full_table_int16_bytes_64_offsets": 64 * rows190 * 2 * 2,
    "limit_only_table_int8_bytes_8_subY": 8 * rows190 * 1,
    "limit_only_table_int16_bytes_8_subY": 8 * rows190 * 2,
    "note": "full table: (xlo,xhi) per (subX,subY,row); limit-only: L per (subY,row), "
            "xlo/xhi then need two floor divisions per row at run time"}

result = {"nav_cell_px": NAV, "close_px": CLOSE_PX, "radii": [0, CLOSE_PX],
          "total_cases": total_cases, "total_mismatching_cases": total_mismatch,
          "disc_inside_closeCells_box_for_unclamped_sources": box_ok,
          "totals_over_radii_0_190_and_64_offsets": {
              "reference_predicate_evaluations": total_ref_evals,
              "member_cells": total_members, "rows": total_rows,
              "empty_rows": total_empty_rows, "isqrt_calls": total_isqrt,
              "rows_with_exact_circle_boundary": total_exact_rows,
              "cells_exactly_on_circle": boundary_cells_total},
          "per_radius": summary, "clipping_cases": clip, "clamped_source_summary": clamped_summary,
          "clamped_source_examples": clamped,
          "row_table_storage_bytes": storage,
          "membership_sha256": h.hexdigest()}
json.dump(result, open(sys.argv[1], 'w'), indent=1)
print(json.dumps({k: v for k, v in result.items() if k not in ('per_radius', 'clipping_cases', 'clamped_source_cases')}, indent=1))
r190 = summary[190]; print('R=190 row:', r190)
print('R small:', [ (s['R'], s['members_total_64_offsets'], s['empty_rows_total']) for s in summary[:9] ])

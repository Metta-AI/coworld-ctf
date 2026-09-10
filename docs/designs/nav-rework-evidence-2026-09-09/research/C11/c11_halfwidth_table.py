#!/usr/bin/env python3
"""C11 follow-up: verify root's halfWidth[abs(dy)] table (C11_ROOT_REVIEW.md)
against math.isqrt for every R in 0..190 and d in 0..R, then re-run every
membership case with the table-driven interval instead of isqrt."""
import hashlib, json, math, sys
sys.path.insert(0, '.')
NAV = 8; CLOSE_PX = 190

def half_width_table(R):
    """Root's construction: x starts at R, for d = 0..R decrement x while
    x*x + d*d > R*R, store x. Returns list and total decrements."""
    table = []; x = R; decrements = 0
    for d in range(0, R + 1):
        while x * x + d * d > R * R:
            x -= 1; decrements += 1
        table.append(x)
    return table, decrements

table_mismatch = 0; max_decrements = 0; max_value = 0; total_entries = 0
for R in range(0, CLOSE_PX + 1):
    t, dec = half_width_table(R)
    max_decrements = max(max_decrements, dec)
    for d in range(0, R + 1):
        total_entries += 1
        ref = math.isqrt(R * R - d * d)
        if t[d] != ref: table_mismatch += 1
        max_value = max(max_value, t[d])
    assert dec <= R

def floordiv(a, b): return a // b
def ceildiv(a, b): return -((-a) // b)

def reference_cells(sx, sy, R, ox, oy, W, H):
    cc = (R + NAV - 1) // NAV; R2 = R * R; out = set()
    for gy in range(max(0, oy - cc), min(H - 1, oy + cc) + 1):
        dy = NAV * gy + 4 - sy
        for gx in range(max(0, ox - cc), min(W - 1, ox + cc) + 1):
            dx = NAV * gx + 4 - sx
            if dx * dx + dy * dy <= R2: out.add((gx, gy))
    return out

def table_cells(sx, sy, R, ox, oy, W, H, t):
    cc = (R + NAV - 1) // NAV; out = set()
    for gy in range(max(0, oy - cc), min(H - 1, oy + cc) + 1):
        dy = NAV * gy + 4 - sy
        if abs(dy) > R: continue
        L = t[abs(dy)]
        xlo = max(ceildiv(sx - 4 - L, NAV), ox - cc, 0)
        xhi = min(floordiv(sx - 4 + L, NAV), ox + cc, W - 1)
        for gx in range(xlo, xhi + 1): out.add((gx, gy))
    return out

h = hashlib.sha256(); cases = 0; mism = 0
def feed(label, cells):
    h.update(label.encode())
    for c in sorted(cells): h.update(('%d,%d;' % c).encode())
tables = {R: half_width_table(R)[0] for R in range(0, CLOSE_PX + 1)}
# block 1: all radii, 64 phases, box in grid
for R in range(0, CLOSE_PX + 1):
    cc = (R + NAV - 1) // NAV; W = H = 2 * cc + 5; ox = oy = cc + 2
    for subY in range(NAV):
        for subX in range(NAV):
            sx = ox * NAV + subX; sy = oy * NAV + subY
            ref = reference_cells(sx, sy, R, ox, oy, W, H); got = table_cells(sx, sy, R, ox, oy, W, H, tables[R])
            cases += 1; mism += ref != got; feed('R%d/%d,%d' % (R, subX, subY), ref)
# block 2: clipping
W = H = 12
for R in (0, 5, 8, 37, 100, 190):
    for (ox, oy) in [(0, 0), (11, 11), (0, 11), (11, 0), (0, 5), (5, 0), (11, 5), (5, 11), (5, 5)]:
        for subY in range(NAV):
            for subX in range(NAV):
                sx = ox * NAV + subX; sy = oy * NAV + subY
                ref = reference_cells(sx, sy, R, ox, oy, W, H); got = table_cells(sx, sy, R, ox, oy, W, H, tables[R])
                cases += 1; mism += ref != got; feed('clip R%d o%d,%d s%d,%d' % (R, ox, oy, subX, subY), ref)
# block 3: off-map sources, clamped origin
xs = [-1, -4, -7, -8, -9, -50, -1000, W * NAV, W * NAV + 3, W * NAV + 7, W * NAV + 8, W * NAV + 100, W * NAV + 1000, 40]
ys = [-1, -8, -9, -300, H * NAV, H * NAV + 5, H * NAV + 8, H * NAV + 2000, 40]
for R in range(0, CLOSE_PX + 1):
    for sx in xs:
        for sy in ys:
            if 0 <= sx < W * NAV and 0 <= sy < H * NAV: continue
            ox = min(max(sx // NAV, 0), W - 1); oy = min(max(sy // NAV, 0), H - 1)
            ref = reference_cells(sx, sy, R, ox, oy, W, H); got = table_cells(sx, sy, R, ox, oy, W, H, tables[R])
            cases += 1; mism += ref != got; feed('clamp R%d s%d,%d' % (R, sx, sy), ref)
prev = json.load(open('c11_results.json'))
result = {"table_entries_checked": total_entries, "table_vs_isqrt_mismatches": table_mismatch,
          "max_table_value": max_value, "max_construction_decrements_any_R": max_decrements,
          "membership_cases": cases, "membership_mismatches": mism,
          "membership_sha256": h.hexdigest(),
          "membership_sha256_equals_isqrt_run": h.hexdigest() == prev["membership_sha256"],
          "storage": {"halfWidth_uint8_bytes_R190": 191, "halfWidth_fixed_array_bytes": 191,
                      "L_only_table_uint8_bytes_8_subY_49_rows": 392,
                      "full_endpoint_pairs_64_phases_49_rows": 3136,
                      "full_endpoint_int8_values": 6272, "full_endpoint_int8_bytes": 6272,
                      "note": "L ranges 0..190, so the L-only table needs uint8, not int8; endpoints relative to the origin cell lie in -24..24 and fit int8"}}
json.dump(result, open('c11_halfwidth_results.json', 'w'), indent=1)
print(json.dumps(result, indent=1))

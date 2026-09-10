#!/usr/bin/env python3
"""C3 exhaustive index check: for every kernel index k in 0..d*d-1 (ascending,
as the C2 word/ctz scan visits set bits), compare the division formula with the
monotone row cursor across radii, grid widths (narrower, equal, wider than the
box) and origins (including ones whose row base is negative). Also random
sparse subsets to exercise the multi-row catch-up in the while loop."""
import random
random.seed(20260910)
def old(k, d, r, ox, oy, W):
    ky = k // d; kx = k - ky * d
    return (oy - r + ky) * W + (ox - r + kx)
def cursor_indices(ks, d, r, ox, oy, W):
    rowEnd = d; gridOffset = (oy - r) * W + ox - r; out = []; advances = 0
    for k in ks:
        while k >= rowEnd:
            rowEnd += d; gridOffset += W - d; advances += 1
        out.append(gridOffset + k)
    return out, advances
checked = 0; combos = 0
for r in [1, 2, 3, 7, 8, 31, 32, 42, 63, 64, 65, 100, 163, 200]:
    d = 2 * r + 1
    for W in [max(1, d - 1), d, d + 1, 2 * d + 3, 401, 20, 60]:
        for (ox, oy) in [(0, 0), (r, r), (W - 1, 5), (3, 1000), (-5, -7), (W + r, 2 * r)]:
            combos += 1
            ks = list(range(d * d))
            got, adv = cursor_indices(ks, d, r, ox, oy, W)
            assert adv == d - 1, (r, W, adv)
            for k, g in zip(ks, got):
                assert g == old(k, d, r, ox, oy, W), (r, W, ox, oy, k, g)
                checked += 1
            # sparse ascending subsets: random, row-boundary bits, last bit only
            for subset in (sorted(random.sample(ks, min(len(ks), 500))),
                           [ky * d for ky in range(d)] + [ky * d - 1 for ky in range(1, d)],
                           [d * d - 1], [0, d * d - 1], []):
                subset = sorted(set(subset))
                got, adv = cursor_indices(subset, d, r, ox, oy, W)
                assert adv <= d - 1
                for k, g in zip(subset, got):
                    assert g == old(k, d, r, ox, oy, W), ("sparse", r, W, k)
                    checked += 1
print(f"combos={combos} index_comparisons={checked} all_equal=True")

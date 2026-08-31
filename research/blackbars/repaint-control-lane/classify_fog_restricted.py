"""
Fog-restricted variant of the validated classifier (see classify_burst.py
for the full validation writeup). Per Maxwell's direct observation ("the
banding only affects the fog of war shadowed areas"), this restricts Stage 1
candidate detection to rows that are predominantly DARK (a cheap proxy for
"fog-shadowed", since fog visibly renders as a solid near-black overlay in
this client -- confirmed by eye against /private/tmp/bb2/aimonly_sample.jpg).
A row counts as fog-eligible if its median luminance is below FOG_LUMA_MAX.
This does not require decoding the actual fog layer geometry/vision cone --
it is a coarse brightness proxy, stated as such, not claimed to be exact.
"""
import numpy as np
from PIL import Image
import sys, os, json
sys.path.insert(0, os.path.dirname(__file__))
from classify_burst import load_gray, smooth1d, find_dip_runs, screen_row_to_world, classify_burst

FOG_LUMA_MAX = 45.0  # dark map floor around 15-30 in samples seen so far; void/fog reads near 0. margin above lit floor (~60-90+) seen in earlier samples.

def find_dip_runs_fog_restricted(gray, **kw):
    runs = find_dip_runs(gray, **kw)
    out = []
    for r in runs:
        rows = slice(r['row_start'], r['row_end'] + 1)
        med = float(np.median(gray[rows, :]))
        r['row_median_luma'] = med
        if med <= FOG_LUMA_MAX:
            out.append(r)
    return out

if __name__ == "__main__":
    capture_dir = sys.argv[1]
    records = json.load(open(os.path.join(capture_dir, 'records.json')))
    import classify_burst as cb
    orig = cb.find_dip_runs
    cb.find_dip_runs = find_dip_runs_fog_restricted
    try:
        results = classify_burst(capture_dir, records)
    finally:
        cb.find_dip_runs = orig
    n = len(results)
    n_banded = sum(1 for r in results if r['is_banded'])
    print(json.dumps(dict(n=n, n_banded=n_banded, rate=n_banded / n if n else None)))
    json.dump(results, open(os.path.join(capture_dir, 'classified_fog_restricted.json'), 'w'))

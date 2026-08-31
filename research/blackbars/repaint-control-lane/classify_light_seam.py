"""
LIGHT-SEAM classifier (polarity-flipped from classify_burst.py).

Triggered by direct pixel re-examination of the prior session's own
"confirmed banded" corpus (moving_1/2/6 in /private/tmp/blackbars/shots/),
requested after Maxwell described the live artifact as "negative space
lines in the shadows" -- light lines where the lit board shows through a
gap in the dark overlay, not dark bands on light content.

Re-reading the row-mean profile of moving_1 and moving_6 (their FULL
profile, not just the rows the old dark-dip detector had already flagged)
shows an alternating pattern: a baseline of ~20-30, thin dark dips down to
~7-10 (what the old classifier caught), immediately paired with thin LIGHT
PEAKS up to ~55-75 a few rows away -- and the peaks are the larger-magnitude
anomaly (delta ~+35 to +49 vs baseline, vs the dips' ~-13 to -21). The known
clean control (moving_8, same row range) shows neither: a smooth 25-31
band with no swings in either direction. This is the discriminating
evidence for polarity: the artifact bands BOTH light and dark, but the old
classifier only ever looked for the darker half.

Design mirrors classify_burst.py exactly, polarity flipped:
  Stage 1: full-width LIGHT peak detector -- a contiguous thin row run
    whose mean luminance exceeds a smoothed vertical baseline by
    peak_thresh, AND where a large fraction of individual pixel columns
    are brighter than their own local vertical neighborhood by
    per_pixel_peak (full-width, not a localized bright object/sprite).
  Stage 2: world-coordinate persistence across the same capture burst
    (same camera scale only) -- a real light source/reflective prop
    recurs at the same world Y; a transient compositor artifact does not.
"""
import numpy as np
from PIL import Image
import sys, os, json
sys.path.insert(0, os.path.dirname(__file__))
from classify_burst import load_gray, smooth1d, screen_row_to_world

def find_peak_runs(gray, peak_thresh=10.0, width_frac_thresh=0.85, max_run=8,
                    smooth_win=41, per_pixel_peak=8.0, edge_margin=4, top_bottom_margin=30):
    H, W = gray.shape
    row_mean = gray.mean(axis=1)
    baseline = smooth1d(row_mean, smooth_win)
    residual = row_mean - baseline  # positive = brighter than local vertical trend
    candidate = residual > peak_thresh
    candidate[:top_bottom_margin] = False
    candidate[H - top_bottom_margin:] = False
    half = smooth_win // 2
    hits = []
    i = 0
    while i < H:
        if candidate[i]:
            j = i
            while j < H and candidate[j] and (j - i) < max_run:
                j += 1
            run_rows = list(range(i, j))
            lo = max(0, i - half - 2); hi = min(H, j + half + 2)
            outside_rows = [r for r in range(lo, hi) if r < i - 1 or r >= j + 1]
            if len(outside_rows) >= 4:
                col_baseline = gray[outside_rows, :].mean(axis=0)
                row_block = gray[run_rows, :].mean(axis=0)
                lift = row_block - col_baseline  # positive = brighter than surround
                usable = lift[edge_margin:W - edge_margin]
                width_frac = float((usable > per_pixel_peak).mean())
            else:
                width_frac = 0.0
            depth = float(residual[run_rows].mean())
            hits.append(dict(row_start=i, row_end=j - 1, height=j - i, depth=depth, width_frac=width_frac))
            i = j
        else:
            i += 1
    return [h for h in hits if h['width_frac'] >= width_frac_thresh and h['depth'] >= peak_thresh]

def classify_burst_light(shots_dir, records, persist_tol_world=10.0, min_depth_ratio=0.5, same_scale_tol=0.05):
    frames = []
    for rec in records:
        if not rec.get('file'):
            continue
        ssp = os.path.join(shots_dir, rec['file'])
        if not os.path.exists(ssp):
            continue
        gray = load_gray(ssp)
        raw_runs = find_peak_runs(gray)
        cam = dict(camScale=rec['camScale'], camX=rec['camX'], camY=rec['camY'],
                   innerWidth=rec['innerWidth'], innerHeight=rec['innerHeight'])
        for r in raw_runs:
            r['world_y'] = screen_row_to_world((r['row_start'] + r['row_end']) / 2.0, cam)
        frames.append(dict(rec=rec, cam=cam, runs=raw_runs))

    results = []
    for idx, f in enumerate(frames):
        true_runs, rejected = [], []
        for run in f['runs']:
            persistent = False
            for j, g in enumerate(frames):
                if j == idx:
                    continue
                if abs(g['cam']['camScale'] - f['cam']['camScale']) > same_scale_tol * max(1e-6, f['cam']['camScale']):
                    continue
                for other in g['runs']:
                    if abs(other['world_y'] - run['world_y']) <= persist_tol_world and \
                       other['depth'] >= run['depth'] * min_depth_ratio:
                        persistent = True
                        break
                if persistent:
                    break
            (rejected if persistent else true_runs).append(run)
        results.append(dict(file=f['rec']['file'], i=f['rec']['i'], is_banded=len(true_runs) > 0,
                             true_runs=true_runs, rejected_runs=rejected))
    return results

if __name__ == "__main__":
    capture_dir = sys.argv[1]
    records = json.load(open(os.path.join(capture_dir, 'records.json')))
    results = classify_burst_light(capture_dir, records)
    n = len(results)
    n_banded = sum(1 for r in results if r['is_banded'])
    print(json.dumps(dict(n=n, n_banded=n_banded, rate=n_banded / n if n else None)))
    json.dump(results, open(os.path.join(capture_dir, 'classified_light_seam.json'), 'w'))

import numpy as np
from PIL import Image
import sys, os, json

def load_gray(p):
    im = Image.open(p).convert("L")
    return np.asarray(im).astype(np.float32)

def smooth1d(x, win):
    k = np.ones(win) / win
    pad = win // 2
    xp = np.pad(x, (pad, pad), mode='edge')
    return np.convolve(xp, k, mode='valid')[:len(x)]

def find_dip_runs(gray, dip_thresh=10.0, width_frac_thresh=0.85, max_run=8,
                   smooth_win=41, per_pixel_dip=8.0, edge_margin=4):
    H, W = gray.shape
    row_mean = gray.mean(axis=1)
    baseline = smooth1d(row_mean, smooth_win)
    residual = row_mean - baseline
    candidate = residual < -dip_thresh
    half = smooth_win // 2
    hits = []
    i = 0
    while i < H:
        if candidate[i]:
            j = i
            while j < H and candidate[j] and (j - i) < max_run:
                j += 1
            run_rows = list(range(i, j))
            lo = max(0, i - half - 2)
            hi = min(H, j + half + 2)
            outside_rows = [r for r in range(lo, hi) if r < i - 1 or r >= j + 1]
            if len(outside_rows) >= 4:
                col_baseline = gray[outside_rows, :].mean(axis=0)
                row_block = gray[run_rows, :].mean(axis=0)
                dip = col_baseline - row_block
                usable = dip[edge_margin:W - edge_margin]
                width_frac = float((usable > per_pixel_dip).mean())
            else:
                width_frac = 0.0
            depth = float(-residual[run_rows].mean())
            hits.append(dict(row_start=i, row_end=j - 1, height=j - i, depth=depth, width_frac=width_frac))
            i = j
        else:
            i += 1
    return [h for h in hits if h['width_frac'] >= width_frac_thresh and h['depth'] >= dip_thresh]

def run_matches_in_synth(gray_synth, run, search_pad=6, per_pixel_dip=8.0, width_frac_thresh=0.70,
                          smooth_win=41, edge_margin=4, dip_thresh_relax=0.6):
    """Check whether a similarly-deep, similarly-wide dark run exists in the
    synth (ground-truth-reconstructed) image within +/-search_pad rows of the
    screenshot's flagged run. Real world content (shadows, wall edges) will
    reproduce here (since synth redraws the same backing store with the same
    transform math); a true compositor artifact will not."""
    H, W = gray_synth.shape
    lo = max(0, run['row_start'] - search_pad)
    hi = min(H, run['row_end'] + 1 + search_pad)
    best_width_frac = 0.0
    for i in range(lo, hi - run['height'] + 1):
        run_rows = list(range(i, i + run['height']))
        half = smooth_win // 2
        olo = max(0, i - half - 2)
        ohi = min(H, i + run['height'] + half + 2)
        outside_rows = [r for r in range(olo, ohi) if r < i - 1 or r >= i + run['height'] + 1]
        if len(outside_rows) < 4:
            continue
        col_baseline = gray_synth[outside_rows, :].mean(axis=0)
        row_block = gray_synth[run_rows, :].mean(axis=0)
        dip = col_baseline - row_block
        usable = dip[edge_margin:W - edge_margin]
        wf = float((usable > per_pixel_dip * dip_thresh_relax).mean())
        best_width_frac = max(best_width_frac, wf)
    return best_width_frac >= width_frac_thresh

def analyze_pair(screenshot_path, synth_path, **kw):
    gray_ss = load_gray(screenshot_path)
    gray_sy = load_gray(synth_path)
    if gray_ss.shape != gray_sy.shape:
        return dict(path=os.path.basename(screenshot_path), error="shape mismatch",
                    is_banded=False, true_runs=[], rejected_runs=[])
    candidate_runs = find_dip_runs(gray_ss, **kw)
    true_runs = []
    rejected_runs = []
    for run in candidate_runs:
        if run_matches_in_synth(gray_sy, run):
            rejected_runs.append(run)  # real content, reproduced in ground truth
        else:
            true_runs.append(run)  # NOT explained by ground truth -> real artifact
    return dict(path=os.path.basename(screenshot_path), is_banded=len(true_runs) > 0,
                true_runs=true_runs, rejected_runs=rejected_runs)

if __name__ == "__main__":
    ss, sy = sys.argv[1], sys.argv[2]
    print(json.dumps(analyze_pair(ss, sy)))

import numpy as np
from PIL import Image
import sys, os, json

def load_gray(p):
    im = Image.open(p).convert("L")
    return np.asarray(im).astype(np.float32)

def load_rgb(p):
    im = Image.open(p).convert("RGB")
    return np.asarray(im).astype(np.float32)

def smooth1d(x, win):
    # simple moving-average smoothing with edge padding
    k = np.ones(win) / win
    pad = win // 2
    xp = np.pad(x, (pad, pad), mode='edge')
    return np.convolve(xp, k, mode='valid')[:len(x)]

def analyze(path, dip_thresh=10.0, width_frac_thresh=0.85, max_run=8,
            smooth_win=41, per_pixel_dip=8.0, edge_margin=4):
    gray = load_gray(path)
    H, W = gray.shape
    row_mean = gray.mean(axis=1)
    baseline = smooth1d(row_mean, smooth_win)
    residual = row_mean - baseline  # negative = darker than local vertical trend

    candidate = residual < -dip_thresh

    # per-pixel width check: for each row, compare each pixel to a per-column
    # local vertical baseline (average of rows +-(smooth_win//2), excluding
    # a small halo around the row itself so a genuine band doesn't smooth
    # itself into its own baseline)
    half = smooth_win // 2
    hits = []
    W_MARGIN = edge_margin
    i = 0
    while i < H:
        if candidate[i]:
            j = i
            while j < H and candidate[j] and (j - i) < max_run:
                j += 1
            run_rows = list(range(i, j))
            # per-pixel width fraction using the row(s) in the run vs column
            # baseline computed from rows outside the run (avoid self-bias)
            lo = max(0, i - half - 2)
            hi = min(H, j + half + 2)
            outside_rows = [r for r in range(lo, hi) if r < i - 1 or r >= j + 1]
            if len(outside_rows) >= 4:
                col_baseline = gray[outside_rows, :].mean(axis=0)
                row_block = gray[run_rows, :].mean(axis=0)
                dip = col_baseline - row_block  # positive = darker than surround
                usable = dip[W_MARGIN:W - W_MARGIN]
                width_frac = float((usable > per_pixel_dip).mean())
            else:
                width_frac = 0.0
            depth = float(-residual[run_rows].mean())
            hits.append(dict(row_start=i, row_end=j - 1, height=j - i,
                              depth=depth, width_frac=width_frac))
            i = j
        else:
            i += 1

    banded_runs = [h for h in hits if h['width_frac'] >= width_frac_thresh and h['depth'] >= dip_thresh]
    return dict(path=os.path.basename(path), H=H, W=W, all_runs=hits, banded_runs=banded_runs,
                is_banded=len(banded_runs) > 0)

if __name__ == "__main__":
    path = sys.argv[1]
    r = analyze(path)
    print(json.dumps(r, indent=None))

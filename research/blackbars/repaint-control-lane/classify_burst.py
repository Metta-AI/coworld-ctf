"""
Validated black-bars classifier (final).

Design history / why this shape, briefly (see conversation record for full
detail): a naive single-frame "full-width horizontal dark dip" detector
(Stage 1) has two known false-positive modes, both DEMONSTRATED against the
existing drive2.js calibration set (research/blackbars + /private/tmp/blackbars/shots):
  (a) baked sprite/prop edges (a platform's own drawn bevel line) that recur
      identically frame after frame -- confirmed by eye (moving_8/9/10/11 all
      show the SAME dip at the SAME world position; the original diagnosis
      doc independently already called this out as "cosmetic aliasing,
      present in both synth and screenshot").
  (b) a regular repeating tile/grid texture at low zoom (whole-map view) --
      confirmed by eye on preseat_0: ~10 "dip" candidates landing almost
      exactly on multiples of a single ~16px period, i.e. the floor tile
      grid, not the bug.
A synth-crosscheck (compare the real page.screenshot() against a
same-instant Canvas2D recomposite of the raw backing store) was tried and
REJECTED: it has its own false-positive mode, demonstrated on moving_12 --
the synth capture (via toDataURL(), a separate CDP round trip from
page.screenshot()) lands a perceptible real-time gap later than the
screenshot, during which unrelated scene content (another prop/sprite)
changed, so the crosscheck sees "screenshot region not explained by synth"
and misreports a persistent real edge as an artifact. A periodicity filter
(reject any frame with >=3 evenly-spaced dips as "grid texture") was ALSO
tried and REJECTED: on moving_6 (a visually unambiguous, dramatic multi-bar
hit -- confirmed by eye against the full frame) the true bug's own bars are
themselves fairly evenly spaced, so the filter threw out a true positive.

DEPLOYED design (Stage 1 + Stage 2 only):
  Stage 1: self-contained per-frame full-width dark-dip detector. Flags
    contiguous thin (<=8px) row runs where the row-mean luminance dips more
    than `dip_thresh` below a heavily-smoothed vertical baseline (removing
    slow gradients, e.g. sky-to-floor shading, not a comparison target), AND
    where >=`width_frac_thresh` of the row's individual pixel columns
    (excluding a small edge margin) are darker than their own local
    vertical-neighborhood baseline by `per_pixel_dip` -- i.e. genuinely
    full-width, not a localized object/shadow.
  Stage 2: WORLD-COORDINATE persistence, using ONLY real page.screenshot()
    frames from the same capture burst (never a second, differently-timed
    capture pathway). Each candidate run's on-screen row is converted to a
    map/world Y coordinate using that exact frame's own logged
    camScale/camX/camY (screenY = innerHeight/2 - camY*camScale +
    worldY*camScale, inverted). If a similar-depth dip appears at a similar
    world Y in ANY other frame of the SAME capture arm (same camera
    scale/mode, so we're never comparing a zoomed-in follow frame against a
    zoomed-out whole-map frame), it is real, recurring map/sprite content
    and is rejected. If it appears in NO other frame across the whole
    burst, it is classified banded (a true, transient, single-frame hit --
    matching the diagnosis's own description of the artifact appearing at
    "different Y positions each frame" and disappearing the instant the
    transform stops changing).

Validated error rates (see conversation record for the full hand-labelled
walkthrough with cropped/full-frame visual confirmation of every case
below): against the 22-frame drive2.js calibration set --
  True positives (visually confirmed real bars, e.g. moving_1, moving_2,
    moving_6): all 3 correctly flagged banded. 0/3 missed here -> 0%
    false-negative on unambiguous cases in this set.
  Known true negatives (moving_8/9/10/11, seated_rest_0-3, preseat_1-3,
    moving_0/3/4/7/11/13 -- static/converged control frames, confirmed
    clean by eye): all correctly flagged clean.
  One known residual false positive: preseat_0 (whole-map view, only 4
    samples total at that camera scale -- Stage 2 has nothing else to check
    a real grid line against, since the burst never revisits that world
    position again at the same scale). This is a SPECIFIC, understood,
    low-zoom/low-N blind spot, not a general failure -- the deployed
    experiment below only uses the zoomed FOLLOW camera scale for both
    arms, at N=700/arm, which gives Stage 2 hundreds of chances to see any
    real feature recur, sharply reducing this risk relative to the 4-frame
    preseat calibration case.
"""
import numpy as np
from PIL import Image
import sys, os, json, glob

def load_gray(p):
    return np.asarray(Image.open(p).convert("L")).astype(np.float32)

def smooth1d(x, win):
    k = np.ones(win) / win
    pad = win // 2
    xp = np.pad(x, (pad, pad), mode='edge')
    return np.convolve(xp, k, mode='valid')[:len(x)]

def find_dip_runs(gray, dip_thresh=10.0, width_frac_thresh=0.85, max_run=8,
                   smooth_win=41, per_pixel_dip=8.0, edge_margin=4, top_bottom_margin=30):
    H, W = gray.shape
    row_mean = gray.mean(axis=1)
    baseline = smooth1d(row_mean, smooth_win)
    residual = row_mean - baseline
    candidate = residual < -dip_thresh
    # FIX (found during the real N=700 run): row 0 of every page.screenshot()
    # clip in this capture setup is a solid ~230-brightness 1px seam (a
    # screenshot/iframe-boundingBox clip artifact, not game content; row 1
    # is a blend, row 2+ is normal). The smoothed baseline's edge-padding
    # drags that bright seam into the local baseline near the top margin,
    # making ordinary dark content a few rows down look like a deep "dip"
    # that isn't real. All 5 initial hits on the real capture landed at
    # rows 9-16 -- suspiciously identical across both arms -- and directly
    # inspecting pixels confirmed row 0 = 230 flat across the full width on
    # every checked frame. Excluding a top/bottom margin at least as wide as
    # the smoothing half-window removes this false-positive source.
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
                dip = col_baseline - row_block
                usable = dip[edge_margin:W - edge_margin]
                width_frac = float((usable > per_pixel_dip).mean())
            else:
                width_frac = 0.0
            depth = float(-residual[run_rows].mean())
            hits.append(dict(row_start=i, row_end=j-1, height=j-i, depth=depth, width_frac=width_frac))
            i = j
        else:
            i += 1
    return [h for h in hits if h['width_frac'] >= width_frac_thresh and h['depth'] >= dip_thresh]

def screen_row_to_world(row, cam):
    return (row - (cam['innerHeight']/2 - cam['camY']*cam['camScale'])) / cam['camScale']

def classify_burst(shots_dir, records, persist_tol_world=10.0, min_depth_ratio=0.5, same_scale_tol=0.05):
    """records: list of dicts with at least {file, camScale, camX, camY,
    innerWidth, innerHeight} loaded from a drive-repaintcontrol.js
    records.json (or equivalent). Returns per-record classification."""
    frames = []
    for rec in records:
        if not rec.get('file'):
            continue
        ssp = os.path.join(shots_dir, rec['file'])
        if not os.path.exists(ssp):
            continue
        gray = load_gray(ssp)
        raw_runs = find_dip_runs(gray)
        cam = dict(camScale=rec['camScale'], camX=rec['camX'], camY=rec['camY'],
                   innerWidth=rec['innerWidth'], innerHeight=rec['innerHeight'])
        for r in raw_runs:
            r['world_y'] = screen_row_to_world((r['row_start']+r['row_end'])/2.0, cam)
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
    capture_dir = sys.argv[1]  # e.g. /private/tmp/bb2/capture/motion
    records_path = os.path.join(capture_dir, 'records.json')
    records = json.load(open(records_path))
    results = classify_burst(capture_dir, records)
    n_banded = sum(1 for r in results if r['is_banded'])
    n = len(results)
    print(json.dumps(dict(n=n, n_banded=n_banded, rate=n_banded/n if n else None), indent=2))
    out_path = os.path.join(capture_dir, 'classified.json')
    json.dump(results, open(out_path, 'w'), indent=0)
    print('wrote', out_path)

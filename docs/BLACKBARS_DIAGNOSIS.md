# The camera-transform bands ("blackbars"): five mitigations, standing down

> **Historical investigation.** This is an incident record for the earlier
> player client, not current Season 2 game or policy guidance. The findings
> below remain preserved for future renderer diagnosis.

**For:** whoever next picks up Maxwell's "black bars when I move" report on the
player client, or anyone about to trust a small-N screenshot experiment on this
codebase in general.

**Status as of this writing: STANDING DOWN, not fixed.** Two real, verified
improvements shipped (below) but the reported artifact is not confirmed solved.
Revisit only if Maxwell's own eyes, playing the shipped build, say it still
matters — his judgement of priority against everything else that changed in
the same swap is worth more than another guess from screenshots.

## Symptom

Dark/light horizontal bands, correlated with movement and aim, on the player
client (`client/player_client.html`)'s follow/fitvision camera. Never visible
in a naive screenshot — only shows up in a **real GPU-composited capture**
(headless Chromium defaults to SwiftShader and hides this entirely; use
`--use-angle=metal` and non-headless). At the instant a real compositor
screenshot shows bands, the canvas's own backing store
(`c.toDataURL()`) is clean — this is compositor-side, not a draw bug, and that
holds in every case checked across this whole investigation.

## Five mitigations tried, all failed to fully eliminate it

1. **Quantize camScale (0.02 steps) + round translate to integer px + dedupe
   identical writes** (`d0cc899d`'s "FIRST PASS"). Insufficient: camScale is
   already ~constant during pure translation, so quantizing it did nothing for
   the moving case.
2. **`will-change:transform` + throttle the DOM write to 1-in-2 rAF ticks
   while following** (`d0cc899d`'s "SECOND PASS", `FOLLOW_WRITE_EVERY_N`).
   Also insufficient — bands still directly visible (2/19 frames in that
   pass's own test).
3. **Force the CSS `scale()` term to an exact integer or exact
   reciprocal-of-integer** (this session, commit `c43dabda`,
   `quantizeFollowScale()`). A first small-N experiment (16 frames per arm)
   showed this clean 16/16 — see the power lesson below for why that result
   didn't hold up.
4. **Leave the scale fractional, switch `image-rendering` from `pixelated` to
   `auto` (bilinear)**. Also looked clean at 16 frames per arm in the same
   small-N experiment.
5. **Remove the CSS transform from the picture entirely** (this session,
   "drawcam" mechanism test): apply the camera's pan/zoom via
   `ctx.translate`/`ctx.scale` in the canvas draw itself, and pin
   `c.style.transform` to `"none"` for the whole capture — camScale/camX/camY
   still computed by the real `updateCamera()`, just never reaching CSS. At a
   properly powered N=200/arm in the same session: **control 8/200 confirmed
   bands (4.0%), drawcam 3/200 (1.5%), Fisher's exact p=0.22 — not
   statistically significant.** The direction is suggestive but this sample
   size cannot rule out chance.

**The load-bearing fact, regardless of (5)'s significance: drawcam still
produced 3 confirmed real hits with `c.style.transform` completely inert for
the entire capture.** That means the artifact is not purely a
CSS-compositor-transform phenomenon. Whatever it is sits upstream of every
lever cheaply available from the client — most likely the canvas element's
own per-frame repaint / GPU texture upload cycle, independent of which
technique moves the camera. That is not a two-line client fix.

Also unaffected by any of this: **whole-map (non-follow) mode**, where
`c.style.transform` is written only on resize/mode-switch, not every tick —
clean in every sample taken across this investigation (7/7 in one check,
0 confirmed hits in the static portions of every later capture too).

## What's confirmed vs. what's still open

- Confirmed: compositor-side, not draw-side (canvas backing store always
  clean at the exact instant a screenshot bands).
- Confirmed: absent when the transform is never rewritten (whole-map).
- Confirmed: present even when the transform is rewritten with an exact
  integer/reciprocal scale, exact integer translate, or is never touched by
  CSS at all (draw-based camera) — so it is NOT specifically about fractional
  scale, NOT specifically about `image-rendering:pixelated`, and NOT
  specifically about the CSS transform pathway.
- Open: does actively repainting the canvas at all (independent of camera)
  trigger this at some baseline rate on this hardware/driver? Nobody has run
  a "repaint every tick, camera never moves" control arm. That would be the
  next diagnostic step if this is revisited.
- Open rate: roughly 2-4% of frames across several independently-drawn
  samples (2/19, 2/60, 8/200, 3/200) — never zero, never dominant.

## Two methodological lessons worth more than the bug itself

### 1. The wall-pinning trap (false negative from a silent test-condition switch)

Holding a single direction key for a "sustained movement" capture drives the
character straight into a map-edge wall, where it sits **pinned** —
`selfPos` stops changing. Once the target stops changing, `camX`/`camY`
converge and the transform-write **dedupe**
(`if(qX===lastTransformX&&qY===lastTransformY&&qScale===lastTransformScale)return`)
skips the DOM write entirely. The capture is then silently testing
whole-map's already-known-clean "no write" condition instead of sustained
active-transform-churn — a false negative waiting to happen, and it happened
twice in this investigation (a 200-frame single-direction capture showed
`selfPos` bit-identical for ~85 consecutive frames in **both** arms of one
run).

**Fix:** cycle through a short direction loop (`D`→`S`→`A`→`W`, ~15 frames per
leg here, tuned to well under the time to cross the map at this character
speed) instead of holding one key for the whole capture. Verify by checking
the position log for genuine frame-to-frame translation before trusting any
"clean" result — don't assume held input means sustained motion.

### 2. Absence-power vs. difference-power (the single most repeated mistake in this investigation)

**N sized to detect "is the rate zero" is not sized to detect "is arm A's
rate different from arm B's rate."** This mistake recurred at every scale:

- A 16-frame-per-arm experiment showed 3 mitigations "clean 16/16" — that
  was read as proof the fix worked. At a true ~3% per-frame rate,
  `(1-0.03)^16 ≈ 58%` — a coin flip's chance of seeing **zero** hits by pure
  sample-size luck, not evidence of near-zero. (This was caught, and the
  retraction to Maxwell happened before he played it — see the earlier commit
  history and conversation for that correction.)
- The corrected follow-up used N=200/arm, reasoned as "at ~3%,
  `(0.97)^200 ≈ 0.2%` chance of seeing zero if the true rate holds" — that
  logic is **only valid for detecting non-zero vs. zero**, not for comparing
  two non-zero rates against each other. Two-proportion power for the
  observed effect size (4.0% vs 1.5%, alpha 0.05, 80% power) needs roughly
  **650-700 frames per arm**, not 200 — almost 4x more. The 200-frame result
  (p=0.22) is genuinely inconclusive, not a null result.

**Lesson for next time:** before running any A/B frame-capture experiment,
write down which question the N is sized for — "rate is non-zero" and "rate A
differs from rate B" have very different sample-size requirements, and
conflating them (treating a small clean sample as proof of absence, or a
medium sample sized for absence-detection as adequate for a comparison) will
produce a confident wrong answer both ways.

### 3. The FFT row-banding screen does not reliably separate true bands from corridor texture

An automated screen (row-mean brightness profile, FFT, band-power fraction in
a 6-16px wavelength window) was used to shortlist candidate frames for manual
review. It has real false positives (map corridor/road-marking texture at a
similar spatial frequency scores just as high as genuine bands — e.g. the
single highest-scoring frame in one 200-frame sample was a false positive)
and real false negatives (several confirmed genuine bands scored below the
sample median). A calibration pass against known positive/negative examples,
narrowing to a tighter 3-6px "tight band" fraction, still did not cleanly
separate the two classes. **Do not trust this metric as a substitute for
eyes-on review of the actual screenshot** — use it only to shortlist
candidates for a human to look at, and still do a full manual contact-sheet
scan on top, the same way this investigation did. If this is revisited with a
larger N, building (and validating) a better classifier is the actual
prerequisite, not optional scaling.

## Other durable findings (not the bug, but will save time)

- **`page.mouse`/`page.keyboard` input is racy across repeated iframe
  takeovers** in this client — 3 of 4 back-to-back seat takeovers got zero
  input through in testing (would misread as a seating/input bug, not a test
  harness one). Dispatching `KeyboardEvent`/`MouseEvent` directly via
  `frame.evaluate()` inside the iframe's own JS realm (window-level
  `onkeydown`/`onkeyup`/`mousemove` handlers, not DOM-focus-dependent) is
  deterministic and was reliable every time in this investigation.
- Headless Chromium silently falls back to SwiftShader and will never show
  this artifact — always run `headless:false` with `--use-angle=metal` for
  any capture meant to catch a real compositor issue.

## What actually shipped

Two commits on `maxwell/scale-probe-camfix` (based on `d0cc899d`, does not
move `maxwell/proof-client-fixes`), both real, both independently revertable,
neither claims to fix the bands:

- `c43dabda` — quantizes the follow camera's scale to an exact integer or
  exact reciprocal-of-integer, always rounding toward more zoom-out, never
  zoom-in (verified never to violate the vision-range fairness guarantee
  across both maps and 10 representative window sizes — floor-clamped-to-1,
  the naive version of this fix, would have broken that guarantee on BR).
  Also fixed a real, separate bug: death→respawn used to ease the camera
  scale through 10-15 fractional frames instead of snapping, due to a shared
  `camInited` flag with the non-follow branch (`wasFollow` guard fixes it).
- `5742afec` — fixes a sprite-decode desync landmine: a snappy decode
  failure used to desync the rest of the WS message and ~97% of the time
  throw into `w.close()`, silently dropping the connection with no
  diagnostic. Not currently firing on the live field, but closed on sight.

## If this is revisited

1. Build and validate a classifier for the dense-band signature before
   scaling sample size — the FFT heuristic in this doc is not it.
2. Run the "repaint every tick, camera never moves" control arm nobody has
   run yet, to test whether ANY active repaint (independent of the camera)
   triggers this at the same baseline rate.
3. If the mechanism really is upstream in canvas-to-compositor texture
   upload, this is likely a browser/GPU-driver-level cost of doing business
   at ~2-4% of frames, not a client-code fix — worth confirming before
   spending more engineering time on the client side at all.

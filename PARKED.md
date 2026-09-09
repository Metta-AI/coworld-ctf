# PARKED — GPU sprite-compositing port (broadcast_core.js)

Parked deliberately for machine time (fleet running four hotter lanes). Not
a quality judgment — resume when the box is quiet.

Worktree: `/Users/maxwellstarr/projects/ctf-spritefx`
Branch: `maxwell/br-spritefx-port` off `maxwell/br-inround-chrome` @ aeb23e6
Committed WIP: `ecabbb0` (only `client/broadcast_core.js` touched)

## What's ported (done, believed correct)

Origin/main's `36470af` ("GPU sprite compositing + inter-tick motion
interpolation") replaced a per-pixel JS painter (`putSpritePixel`) with
baked-per-sprite-canvas + `drawImage`. This lineage had ALREADY built its
own, independently-evolved version of most of that win (motion
interpolation via `dispX/dispY` glide, commit `686bbde`; dynamic objects
already drew via `spriteSurface()+drawImage`). The only genuinely stale
piece was a leftover per-layer software bake (`blitObject`/`putSpritePixel`,
`layer.image`/`ImageData`) that cached the static map-band prefix
(object ids 40..99) and rebuilt it via a per-pixel JS blend whenever
`staticBandsDirty` fired. That cache bought nothing once GPU `drawImage`
compositing exists for every other object, so it's removed — composite()
now just calls `drawObject()` (the existing GPU path) for every object,
map bands included, matching the ported commit's own rationale.

`STATIC_BAND_MIN_ID/MAX_ID/Z` constants are KEPT (unchanged values, still
40/99/-32768) — they still gate the glide-exclusion check in `parse()`
(static bands must never ease toward a new position; that's a
correctness rule, not a caching optimization, and is untouched).

Diff is scoped: `git diff ecabbb0~1 ecabbb0 -- client/broadcast_core.js`
touches only lines in the ~265-1600 range (ensureLayer/setViewport,
putSpritePixel/blitObject removal, composite(), and the staticBandsDirty
call sites in parse()). It does NOT touch the interpolation glide loop,
`renderZonePaint`, chrome/scoreboard handling, or any `.nim` file.
`node --check client/broadcast_core.js` passes clean.

## What's NOT done yet

FPS before/after measurement and the visual-identity screenshot check
were IN PROGRESS when parked. No numbers are trustworthy yet — do not
report a percentage without rerunning.

## Exact rerun steps

```bash
cd /Users/maxwellstarr/projects/ctf-spritefx

# 1. Build BEFORE (original code) and AFTER (current HEAD, ecabbb0) binaries.
#    Use git stash to get the pre-port file temporarily:
git stash push -m "spritefx-before-tmp" -- client/broadcast_core.js
nim c -d:release --hints:off --path:src -o:bin/spritefx-server-before src/ctf.nim
git stash pop   # restores the ported file (verify with: grep -c staticBandsDirty client/broadcast_core.js -> should be 0)
nim c -d:release --hints:off --path:src -o:bin/spritefx-server src/ctf.nim

# 2. Boot each on its own port against the same fixture (16-team BR golden —
#    deliberately busy: 32 objects, up to 60 map bands, exercises exactly the
#    code path this port touches). --load-replay-uri IS the flag that works;
#    the COGAME_LOAD_REPLAY_URI env var did NOT engage replay mode when tried
#    (server fell through to a live bot match instead — unexplained, use the
#    CLI flag, confirmed working via `curl .../client/replay` returning 200
#    with no ?uri= needed).
REPLAY_ABS="$(pwd)/tests/fixtures/br-golden-16team.bitreplay"
COGAME_HOST=127.0.0.1 COGAME_PORT=21934 nohup ./bin/spritefx-server-before \
  --load-replay-uri="file://$REPLAY_ABS" > .spritefx/logs/before.log 2>&1 &
echo $! > /tmp/before_pid.txt
COGAME_HOST=127.0.0.1 COGAME_PORT=21933 nohup ./bin/spritefx-server \
  --load-replay-uri="file://$REPLAY_ABS" > .spritefx/logs/after.log 2>&1 &
echo $! > /tmp/after_pid.txt

# 3. Measure (own scripted playwright, reusing an existing install via
#    NODE_PATH rather than installing fresh — nightshift-replay already has
#    playwright 1.60 + cached Chromium):
NODE_PATH=/Users/maxwellstarr/projects/nightshift-replay/node_modules \
  node .spritefx/measure.cjs 21934 before
NODE_PATH=/Users/maxwellstarr/projects/nightshift-replay/node_modules \
  node .spritefx/measure.cjs 21933 after

# Results land in /tmp/spritefx-before.json / -after.json (rafCount/fps/
# renderer) and /tmp/spritefx-before.png / -after.png (paused tick=400
# screenshot for the visual-identity check — downscale before viewing:
# sips -Z 500 /tmp/spritefx-before.png --out /tmp/spritefx-before-small.png).

# 4. Kill ONLY the two pids you just recorded:
kill "$(cat /tmp/before_pid.txt)" "$(cat /tmp/after_pid.txt)"
```

## Gotchas already hit and fixed

- **`COGAME_LOAD_REPLAY_URI` env var did not work** — server booted a live
  bot match instead of serving the replay. The `--load-replay-uri=file://…`
  CLI flag DOES work (confirmed via `curl -o /dev/null -w '%{http_code}'
  http://127.0.0.1:<port>/client/replay` returning 200 with no `?uri=`
  needed — that only happens when `replayServerModeEnabled()` is true).
  Root cause not chased down; just use the CLI flag.
- **Fixed-duration sleeps before measuring are unsafe on this box.** First
  attempt used a flat `waitForTimeout(3000)` after navigation before
  resetting the rAF counter, and got a false "0 fps" reading on one run —
  not a code regression, just the pre-load curtain ("bot locker room",
  `#lockerroom` in replay_broadcast.html) still showing because this
  machine runs 20+ concurrent agents and wall-clock timing is not stable
  (matches the standing lesson in `ctf-fleet-load-corrupts-timings.md` —
  interleave a control / don't trust absolute timers under load).
  Reproduced the SAME false stall on the unmodified BEFORE build too,
  proving it was a harness timing bug, not a port regression.
  **Already fixed** in `.spritefx/measure.cjs`: it now
  `page.waitForFunction(() => !lockerEl || lockerEl.style.display ===
  'none', {timeout: 60000})` instead of a fixed sleep, both before the FPS
  window and before the screenshot. Should be reliable now, but if it's
  still flaky, widen the timeout further before suspecting the port again.
- GPU must be forced in headless Chromium or you'll silently measure
  SwiftShader (software) — `measure.cjs` already launches with
  `--use-gl=angle --use-angle=metal --ignore-gpu-blocklist` and asserts the
  WebGL renderer string doesn't match `SwiftShader|llvmpipe|software`
  before trusting any number (same pattern as this repo's other perf/
  visual QA rigs, e.g. `muster-coworld/tools/qa_chrome_layout.cjs`).
- `.spritefx/measure.cjs` and `.spritefx/debug.cjs` (a plain console/
  screenshot probe, no FPS counting) are both already in this worktree,
  gitignored (`.spritefx/` is dot-prefixed, matches `.gitignore`'s `.*`
  rule) — not committed, safe to keep using as-is or delete when done.

## Remaining checklist after measurement succeeds

1. Record before/after fps + renderer string from the two JSON files.
2. Downscale both screenshots and eyeball them side by side — confirm no
   missing sprites/paint, teams-alive chrome intact, map bands intact.
3. Run suites: `nim c -r tests/test_broadcast_state.nim` (or however this
   repo's other test files are normally invoked here) and the golden e2e
   (must stay hash-exact — zero `.nim` files are touched by this port, so
   any hash change means something is wrong).
4. Amend or add a follow-up commit with real numbers in the message
   (replace the WIP commit's message, or land a second commit — user's
   call) once verified.
5. Kill any scratch servers by recorded pid only; never pkill.

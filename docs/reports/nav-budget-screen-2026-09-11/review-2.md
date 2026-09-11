I read the four artifacts and traced the server code each one depends on. Nothing was edited. The first run can't finish as written, so the screen would collect no evidence.

## Blocking

**1. The 16-seat runs never start, and that aborts the whole screen.**
- `run_native.py:27-28` cuts `slots` and `tokens` down to 16, but leaves practice's 32-entry `players` list and `minPlayers: 32` alone.
- The config reader handles `players` last (`sim_config.nim:1400,1413,1414`), and `readConfigPlayers` grows the slots back to 32 (`sim_config.nim:431-432`).
- Only 16 clients connect, so the lobby start check (`sim.nim:7999`) never passes. `lobbyJoinTimeoutTicks` defaults to 0, which means the lobby waits forever.
- After 300 s, `server.wait` raises `TimeoutExpired` at `run_native.py:60`. Nothing catches it, so the very first run (`r1-b256-s16`) ends the script with no `exit.json` and no 32-seat runs.
- Even with `minPlayers` fixed, the nav system is sized from the slot count (`episode.nim:373` → `body_nav.nim:650`). The "16-seat" run would get the 32-seat pooled planning budget, which blurs the 16 vs 32 comparison.
- **Fix:** also cut `players` down to the seat count, set `minPlayers=seats`, and check the resolved slot count in the log.

**2. The map is br-gen-4242, not arena.**
- `config.practice.json` contains a `mapSpec` (br-gen-4242, 3211×1713, 16 spawn groups). An explicit `mapSpec` beats `mapPath` (`arena.nim:3952`), so the `mapPath='arena'` override at `run_native.py:26` does nothing.
- `PROTOCOL.md:14` and the saved config both say "arena", so the report would name the wrong map.
- The fix is to rename the map in the protocol, not to drop `mapSpec`. br-gen-4242 is what the existing demo actually plays, and arena probably fails the check that the map's team count matches `teams=16`.

**3. The build script doesn't set the environment it needs.**
- `build_native.sh` never exports `WASI_SDK_PATH` or `WASMTIME_C_API`. The Dockerfile only sets them inside individual `RUN` steps (`Dockerfile:52-56,71-75`), so they aren't in the image's environment.
- Without `WASI_SDK_PATH`, `play.nims:8` exits, so edge_ride doesn't build.
- Without `WASMTIME_C_API`, the server builds without the Wasm runtime (`episode.nim:25`) and refuses to start a play-seat game (`runtime_boot.nim:15-21`).
- Both failures are loud and fixable, but the script only works if whoever launches the container happens to pass these. The protocol doesn't record that.
- **Fix:** load them from `/tmp/runtime_deps.env` or `fetch_deps.sh`, the way the Dockerfile does.

**4. One bad run ends the whole screen, including the slow results the protocol wants kept.**
- A nonzero exit (`run_native.py:63-64`) or a timeout aborts every remaining run in the order.
- A timeout also skips `exit.json`, so the run leaves no record.
- Re-running then collides with `mkdir(exist_ok=False)` on the directories already created.
- A slow or crashing budget is exactly the evidence the protocol says to keep ("no replacement runs for slow results").
- **Fix:** catch failures per run, write `exit.json` with a timeout or exit-code status, and continue.

## Confirmed correct
- **Frame timing interval:** it runs from the top of the main loop (`server.nim:4279`) to just before `runFrameLimiter` (`:5860`). That excludes the limiter's waiting, shutdown and the final exiting frame (the exit path at `:5856-5858` runs before the limiter). The logging `echo` calls are inside the measured interval, which the protocol says.
- **Patch anchors:** all four exist exactly once at this base, and none match the unrelated `while true:` at `:2029`.
- **Shell counters:** `pendingPlans`, `noPathSeats` and `stalePathSeats` exist (`episode.nim:120-122`). The plan-budget, SHELL_NAV and combat logs print without any extra environment variable (`server.nim:5258-5269`).
- **Game length:** with `maxGames=1`, the server stops after the first game ends (`:5448-5466`). Squad mode is off, so there is no 20 s shutdown wait.
- **Steps per frame:** each frame runs `playbackSpeed(liveSpeedIndex)` steps (`:5178`). With `speed=1` that is one step, so the protocol's claim about fast mode holds.
- **Budget edit:** the `sed` pattern matches `body_nav.nim:31`.
- **Wasm path:** the module path is resolved from the working directory (`episode.nim:1001`), and the script sets `cwd=ROOT`.
- **Conclusions:** the protocol's hedging is honest: the run is labelled exploratory, the 41.667 ms (24 Hz) deadline is descriptive only, and nothing changes in main based on it. The only honesty problems are the map name and the effective seat count.

## Minor issues
5. **CPU pinning:** the server's 4 HTTP worker threads (`server.nim:4215-4218`) and its HTTP thread all share CPU5 with the main loop. Frame times therefore include websocket work and lock contention that grow with seat count. Comparing budgets is still fair, but the counts over 41.667 ms aren't what production would see. The hyperthread sibling of CPU5 isn't reserved either. State this caveat in the report.
6. **Patch check:** `prepare_native.py:18` only asserts that at least one of the four replacements happened, not all four. Running it twice inserts the lines again and breaks the compile, which at least fails loudly.
7. **Build inputs:** the script never creates `/results/body_nav_base.nim`, so where it comes from isn't established. The `sed` result isn't checked; a miss would silently build three identical binaries. The script also calls `/prepare.py`, not `prepare_native.py`.
8. **Tick alignment:** `BUDGET_SHELL` checks the game phase before the step and logs `tickCount+1`; `BUDGET_FRAME` checks after the step. The frame where play begins gets a frame row but no shell row. Join the two logs by tick and check the rows match one-to-one.
9. **Seat coverage:** `playSeatBindTicks=120` allows only about 5 s of client absence before the game starts. A slow client makes its seat drop out silently (`server.nim:5198-5200`), so count seats per tick from the `SHELL_MOVEMENT seats=` lines.
10. **Protocol wording:** it says "runtime-linked", but the build statically links wasmtime (`-d:shellStaticWasmtime`). Missing spaces throughout ("Base83e6…", "toCPU5", "Use16 and32").

I couldn't write the plan-mode plan file or exit plan mode, because neither tool was available in this session. The review above is the full output.

VERDICT: NOT JUST NITS

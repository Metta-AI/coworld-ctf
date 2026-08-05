# Agent operating guide — coworld-ctf

Orientation for coding agents (Claude Code, Codex, etc.) working in this
repo. Gameplay rules live in [docs/RULES.md](docs/RULES.md); this file
covers the workflows that are easy to get wrong.

[docs/ENV_VARIATION.md](docs/ENV_VARIATION.md) is the catalog of every knob
that varies a level (all `GameConfig` fields + `MapGenOverrides` + the
envelope consts, each cited to `file:line`) — the reference for generating
new levels/curricula. **Keep it current:** whenever you add, remove, rename,
or re-bound a `GameConfig` field, a `mapGen` override, or a gameplay const
(motion/combat/vision/scoring/item), update the matching row in that file in
the same change.

## Layout

- `src/ctf.nim` — server entrypoint (seed randomization happens HERE,
  before `config.update`, so seed-derived draws — including the terrain
  pick — follow the final seed).
- `src/ctf/` sim modules (split per `docs/plans/2026-08-01-sim-split.md`;
  `sim.nim` imports and RE-EXPORTS all of them, so `import ctf/sim` still
  sees everything): `sim_types.nim` — consts (incl. `GameVersion`, which
  gates replay compatibility), types (flatty wire format — field order is
  sacred), map globals; `rig_art.nim` — broadcast-only art;
  `arena.nim` — map geometry, the terrain generator/validators, mapSpec,
  the process-global map install, pixel queries; `map_art.nim` — the map
  bake; `sim_config.nim` — GameConfig lifecycle; `sim_state.nim` — logging,
  gameHash, events, spawn placement; `roster.nim` — join/auth/rewards;
  `sim.nim` — the gameplay core and step loop.
- `src/ctf/map_pool.nim` — GENERATED curated terrain-pool seeds; rewrite it
  only via `tools/gen_map_pool.nim`, never by hand.
- `tools/map_render.nim` — the shared map rasterizer behind both
  `render_map_pool.nim` and the map editor. It is a PURE function of a
  `CtfMap`: it must never install a map or read the process-global arena
  (`MapWidth`, `ArenaObstacles`, `obstacleWallAtF`, …), because the editor
  service renders arbitrary specs from multiple threads.
- `tests/` — run `nim c -r tests/tests.nim` from the repo ROOT (assets
  resolve via `data/`). Use `-d:release` for anything heavy; debug builds
  are 10-50x slower through the per-pixel map code.
- Dependencies come from nimby (`nimby --global sync nimby.lock`; the
  Dockerfile is the canonical build recipe).

## Terrain

- The **default league map is the hand-tuned arena** (`config.json`
  `mapPath: "arena"`). Do not flip it without an explicit ask.
- **Procedural terrain is config-gated**: `mapPath: "pool"` draws from the
  curated pool (`mapPoolIndex` pins an entry; otherwise the pick derives
  from the randomized game seed), `mapPath: "gen"` + `mapSeed` generates
  directly. Individual draws lock via `mapSize`, `mapSymmetry`
  (`mirror`/`rot180`), `mapColumns`, `mapWindows`, `mapCenterFeature`,
  `mapEndzone` (+ `mapEndzoneRadius` / `mapBaseDepth`).
  Tools accept `gen:<seed>` / `pool:<idx>` map paths.
- **Endzone archetypes** are drawn per seed from a SEPARATE RNG stream
  (`seed xor const`) so the main draw order never shifts: a seed that lands
  on the classic `column` generates byte-for-byte the map it always did,
  and only `disc` / `square` seeds are new terrain. Keep that property when
  adding draws — it is what makes an archetype addition reviewable.
- Replays pin the resolved geometry as `mapSpec` in their config JSON —
  playback never re-runs the generator, so generator changes cannot break
  existing replays.
- Generator design intent lives in the VALIDATORS: sightlines, corridor
  connectivity, cover budget. Change behavior there, not by hand-tuning
  draws. The measurements live in `mapDiagnostics`;
  `validateGeneratedMap` is a thin consumer that reports the first failure,
  and `mapValidationReason` turns a completed diagnostic pass into the same
  string. Diagnostics are collected in STAGES: the validator asks for
  first-failure mode so a rejected attempt never pays for the distance
  transform and flood fill, and full-board masks are opt-in
  (`MapDiagnosticArtifact`) because retaining them costs ~88 MB on a
  colossal board. Preserve both properties — `generateCtfMap` runs the
  validator up to 100 times per map.

## Pool review page

[docs/pool-review.html](docs/pool-review.html) is a self-contained,
zoomable review page showing every curated pool map (open it locally or
from any static host; images are inlined). **Regenerate it whenever
`map_pool.nim` or the generator changes**:

```bash
nim c -r tools/gen_map_pool.nim              # only when re-curating seeds
nim c -r tools/render_map_pool.nim pool-preview
python3 tools/build_pool_review.py pool-preview
```

Commit the refreshed `docs/pool-review.html` together with the pool/
generator change — a stale page misrepresents what the pool serves.

## Map editor

A local service + browser UI for inspecting and authoring map geometry against
the REAL validators — the interactive counterpart to the static pool-review
page. Every validator failure is locatable on the board, which makes it the
fastest way to answer "why was this seed rejected".
Design: [docs/designs/map-editor.md](docs/designs/map-editor.md).

```bash
nim c --threads:on --mm:orc -r tools/map_editor.nim 8099   # then open localhost:8099
```

It needs `--threads:on --mm:orc` because it serves over mummy; the request
handlers are deliberately split from the mummy adapter (which is behind
`when isMainModule`) so `tests/test_map_editor.nim` can exercise the API
without a socket or a threaded test build.

Loads any pool entry, `gen` seed + overrides, or pasted `mapSpec`, and
returns a Nim-rendered board plus live validation, and edits it: obstacles,
trenches, med kits, and the tier-1 map parameters, with undo/redo.

Authoring places a seed item ONCE; `POST /api/symmetry` returns its full
deduplicated orbit and the editor writes that into the spec. Trench authoring is
refused on rot90 maps because `finalizeTrenches` never places them there.

Two invariants to keep if you touch it:

- **The browser never owns geometry.** It renders what the service sends and
  draws markers on top; it must not compute walls, symmetry images, or
  capture zones. The map code's fairness invariants (doubled rot90
  coordinates, `int64` in the diagonal test for wasm, integer-offset diamond
  sampling) fail silently as team unfairness when reimplemented.
- **No map installation on the request path.** See `tools/map_render.nim`
  above.

## Map generation (mapkit)

`tools/mapkit.nim` generates and hand-edits maps in the native `mapSpec`
format from the command line — the batch/LLM counterpart to the map editor.
Terrain styles (`bsp`, `caves`, `maze`, `scatter`) live in
`src/ctf/mapgen_styles.nim` as pure `(rng, region, params) -> seq[ArenaShape]`
generators that emit only CTF shapes into the seed half; the sim mirrors,
carves, and validates. No sim change, no replay risk. Playbook + the
generate → render → validate → edit loop: [docs/MAPKIT.md](docs/MAPKIT.md).

```bash
nim c -d:release -o:/tmp/mapkit tools/mapkit.nim
```

Generators must stay pure and fairness-agnostic: they never reason about
symmetry, protected floor, or endzones — those live in `arena.nim`. Raw
generation passes the validator ~55–65% of the time by design; the workflow is
generate-many-then-curate/edit, not one-shot.

Obstacles and trenches are `ArenaShape`s in five kinds: `rect`/`disc`/`diamond`/
`diagonal` and (GV37) `polygon` — a closed ring of INTEGER vertices for curved
terrain. Curves are flattened to polygons in the authoring tools; the sim only
ever runs integer even-odd `pointInPolygon` (see the STRICT-STRADDLE convention
that keeps mirror/rot180 masks bit-exact — fairness rests on it, so do not swap
in a boundary convention without re-checking the parity test). Runtime is
unaffected: LoS/nav read the baked `wallMask` bitmap, shapes only stamp it at
load. Design: [docs/plans/2026-08-04-vector-obstacles-design.md](docs/plans/2026-08-04-vector-obstacles-design.md).

## Map fitness harness (map_eval)

`tools/map_eval.nim` scores a map instead of merely validating it: load or
generate → hard gates → static score → (top-k only) simulate N episodes →
rank. `tools/map_metrics.nim` holds the static geometry metrics as a PURE
function of a `CtfMap` (same invariant as `map_render.nim` — no map install,
no process globals), and `tools/map_eval.py` renders the heatmaps and the
gameplay report.

```bash
nim c -d:release -o:/tmp/mapeval tools/map_eval.nim
/tmp/mapeval --map pool:0 --map gen:4242 --episodes 3 --lives 9
python3 tools/map_eval.py /tmp/map-eval
```

Map sources: `arena`, `arena-large`, `gen:<seed>`, `pool:<index>`, and
`spec:<path.json>` for an arbitrary inline `mapSpec` (`resolveCtfMapMetadata`
checks `mapSpec` first, so this scores hand-authored candidates no seed
produces). Always `-d:release`.

Five properties are enforced by the harness, not by discipline. Keep them if
you touch it:

- **The default `arena` is injected as CONTROL in every batch** and ranking
  is refused without it. Every scored band is checked against the control
  first, and a band the control fails prints as a METRIC BUG rather than as
  a bad map. Two bands are deliberately *reported but not scored* because
  scoring them would flag the control or a thing no terrain choice can fix:
  trench count (the arena has none) and stand-side cover on a map whose
  endzone states no radius.
- **Never a count without its fraction.** Midfield crossings print the open
  fraction of the line; stand ring arcs print beside the ring's openness.
- **Three episodes minimum**, and fewer prints a warning.
- **A capture ends the episode**, so every episode's tick count and result
  is printed and dead space is only compared across similar-length samples.
  Reported ticks include the lobby and banked overtime, so they exceed
  `--max-ticks` legitimately.
- **Conversion is only a map signal when the control converts.** At the
  shipped `lives: 3` a 16-seat game is decided by attrition before anyone
  scores; the harness says so instead of blaming the terrain. This guard has
  already earned its keep: on the hex board it caught the reference bot
  converting 0 of 21 steals across every map at once — a policy bug driving
  the carrier to a "home column" that never entered a disc endzone, which
  would otherwise have been read as four bad maps
  (`players/baseline/baseline.nim`'s `captureAim`, `tools/ez_probe_aacf.nim`).

## Replay fixtures

`tests/fixtures/*.bitreplay` + `tests/replays/ctf.bitreplay` are recorded
against the CURRENT rules and must be re-recorded on every GameVersion
bump (`tools/record_fixture.sh`; exact recipes in
`tests/test_broadcast_state.nim`). Gotchas:

- Record on an **idle machine** — a CPU-starved speed-16 server drops its
  bots and produces degenerate endings (e.g. no capture).
- The script prefixes `$PWD`: pass **repo-relative** output paths.
- After re-recording, re-pin the capture fixture's asserted winner/ending
  and verify the required beats (capture/steal/gameover) actually occur —
  scan a few seeds if needed.

## Debugging prod league replays (don't drive the Observatory UI)

To investigate a prod replay issue, download the replay bytes directly —
never try to navigate softmax.com/observatory in a browser (sign-in wall,
and the UI adds nothing). The Observatory URL carries everything needed:
`?tab=coworlds&logscope=league:league_<uuid>&detail=league:league_<uuid>` —
the `detail` param is the league being viewed (strip the `league_` prefix
for SQL; `leagues.id` is the bare uuid).

1. Query the prod DB via the read-only `/sql` endpoint (token from
   `~/.softmax/credentials.yaml`, key `https://softmax.com/api`; add headers
   `Authorization: Bearer $TOKEN` and `X-Use-Elevated-Privileges: true`,
   POST to `https://softmax.com/api/observatory/sql/query`):

   ```sql
   -- league -> divisions -> rounds -> episode requests -> job ids
   SELECT era.job_request_id, er.created_at,
          er.game_config->>'teams' AS teams
   FROM episode_requests er
   JOIN episode_request_attempts era ON era.episode_request_id = er.id
   JOIN rounds r ON r.id = er.round_id
   JOIN divisions d ON d.id = r.division_id
   WHERE d.league_id = '<league uuid without prefix>'
   ORDER BY er.created_at DESC;
   ```

2. Every job's replay is public:
   `https://softmax-public.s3.amazonaws.com/replays/<job_request_id>.replay`
   (equivalently `episodes.replay_url`, joined via `episode_jobs`).

3. The file is `COWLDCTF` deterministic format: a JSON config (brace-match
   from the first `{`; includes `mapSpec` dims/layout, teams, player names)
   plus recorded inputs — `parseReplayBytes` + `initReplayRuntime` replays
   it locally, exactly like the wasm viewer.

4. To reproduce the hosted viewer itself:
   `POST https://softmax.com/api/observatory/v2/coworlds/replays/session`
   with `{"coworld_id": "<episode_requests.coworld_id>", "replay_uri": "<s3 url>"}`
   returns the exact static-bundle `viewer_url` prod serves (its
   `broadcast_core.js` / wasm files are directly downloadable, and the
   wasm bundle runs headless under Node — see `tools/wasm_replay_smoke.cjs`).

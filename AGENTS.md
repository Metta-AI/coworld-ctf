# Agent operating guide — coworld-ctf

Orientation for coding agents (Claude Code, Codex, etc.) working in this
repo. Gameplay rules live in [docs/RULES.md](docs/RULES.md); this file
covers the workflows that are easy to get wrong.

## Layout

- `src/ctf.nim` — server entrypoint (seed randomization happens HERE,
  before `config.update`, so seed-derived draws — including the terrain
  pick — follow the final seed).
- `src/ctf/sim.nim` — the sim monolith: types, config, maps + the terrain
  generator/validators, gameplay, replay hashing. `GameVersion` at the top
  gates replay compatibility.
- `src/ctf/map_pool.nim` — GENERATED curated terrain-pool seeds; rewrite it
  only via `tools/gen_map_pool.nim`, never by hand.
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
- Generator design intent lives in the VALIDATORS
  (`validateGeneratedMap`): sightlines, corridor connectivity, cover
  budget. Change behavior there, not by hand-tuning draws.

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

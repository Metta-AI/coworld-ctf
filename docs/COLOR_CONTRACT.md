# Team Color Contract

The shared contract between the **platform** (softmax.com — resolves who gets which
color), the **webpage picker** (renders muted ink&print variants), and the **replay
viewer** (renders the vibrant in-game version). This repo owns the palette; the
webpage vendors it; **slugs are the shared language** both sides translate through.

Files:

- `data/team_palette.json` — the canonical palette (this repo is the source of truth).
- `scripts/validate_palette.py` — runnable validator; run it after ANY palette change.

Roles, in one line each:

- **Platform**: resolves color claims against standings (§3), composes the viewer
  payload (§5). It is the only party that thinks.
- **Webpage picker**: shows `ink` chips, explains outcomes from the provenance
  snapshot (§4). Never resolves anything itself.
- **Viewer**: applies the final explicit mapping in the payload (§5). Dumb by design —
  no standings logic, no fallback walking, no preference storage.

---

## 1. The hard wire constraint (read this first)

The engine's label wire streams team color **words** — `red | blue | green | yellow` —
as observation schema that league policies parse. **15 label families use them.**
The wire words come from `teamText` in `src/ctf/sim_types.nim` and NEVER change.

- Slugs are **display vocabulary only**. The embed payload maps
  *wire-team-word → display-slug* (§5). A team whose wire word is `red` can be
  *displayed* as orange; on the wire it is still `red`.
- **Renaming a wire token silently blinds every policy in the league** — labels fail
  as empty sequences, not crashes, so nothing alerts you. Do not "helpfully" rename
  `red` to `vermillion` anywhere near the wire, the roster, or the label schema.
- The first four palette slugs deliberately reuse the wire words with the exact stock
  hexes, so the identity mapping (`red→red`, …) is a no-op and stock replays are
  pixel-identical.

## 2. Palette semantics and ordering

`data/team_palette.json`, shape:

```json
{
  "version": 1,
  "colors": [
    { "slug": "red", "wire": "red", "display": "Vermillion",
      "game": "#e0523a", "hue": 9, "ink": ["#b3603f", "#8a4630"] },
    ...
  ]
}
```

Per entry:

| Field | Meaning |
|---|---|
| `slug` | The shared identifier. Lowercase word. Never renamed, never reordered (see below). |
| `wire` | The engine wire word this slug is the stock color of, or `null` for the four added colors. Non-null only on the first four entries. |
| `display` | Human name for UI ("Vermillion", "Lagoon", …). Safe to reword. |
| `game` | Vibrant in-game hex — what the viewer paints cogs and stains with. |
| `hue` | HSV hue (degrees) of `game`, declared so the ordering rationale below is machine-checkable. The validator fails if it drifts from the hex. |
| `ink` | 2–3 ink&print variant hexes for the webpage picker, ordered light→dark (a mid-tone print wash first, then the deeper ink-leaning tone). Same hue family as `game`, desaturated to sit on cream paper. |

**Ordering rule: array order IS the fallback walk order.** The first four entries are
frozen (stock wire colors, in wire order). The remaining entries continue a hue
circle — teal (180°) → purple (264°) → magenta (326°) → orange (31°) — which wraps
into red (9°) at the end of the array, so a bumped player tends to land near their
pick. Consequences:

- **Never reorder or remove entries** — order changes silently reassign everyone's
  fallback colors. Append only, and appending is a `version` bump.
- **Never repaint the first four** — they are the stock in-game colors
  (`src/ctf/sim_types.nim` `*EndzoneColor`, mirrored as CSS `--red/--blue/--green/
  --yellow` in `client/replay_broadcast.html`). Default assignments and old replays
  must render unchanged.
- Any hex change to the other four requires re-running
  `scripts/validate_palette.py` until it passes.

Current palette (v1):

| # | slug | display | game | ink |
|---|---|---|---|---|
| 0 | `red` | Vermillion | `#e0523a` | `#b3603f` `#8a4630` |
| 1 | `blue` | Cerulean | `#3f7cc4` | `#52739f` `#2f4e7c` |
| 2 | `green` | Clover | `#45a85e` | `#5d8a68` `#3f6349` |
| 3 | `yellow` | Citrine | `#ddc531` | `#9a7a2c` `#6f5720` |
| 4 | `teal` | Lagoon | `#35a8a8` | `#3f7f7c` `#2b5a58` |
| 5 | `purple` | Amethyst | `#8452cf` | `#7d5f9e` `#584273` |
| 6 | `magenta` | Fuchsia | `#d15a9e` | `#a85780` `#7c3d5d` |
| 7 | `orange` | Marigold | `#e08a2e` | `#b06d2e` `#845020` |

## 3. Resolution algorithm (platform-side, deterministic)

Contested colors break like surf etiquette: the higher-standing player keeps the
color; the lower one walks the palette to the next free slug. Run league-wide,
whenever standings or preferences change:

```
resolve(claimants, palette):
  # claimants = players who set a preference: {player, standing, requested_slug}.
  # Players with no preference are NOT claimants; their teams keep stock colors.
  # Sort by standing, best first. Standings are a total order; if an upstream
  # tie is possible, break it lexicographically by player id — the result must
  # be identical on every run.
  taken  = {}   # slug -> player who holds it
  grants = {}   # player -> provenance record (§4)
  for c in sort(claimants, by=standing, tiebreak=player_id):
    if len(taken) == len(palette.colors):
      # more claimants than slugs: everyone past the 8th keeps stock colors
      grants[c.player] = { requested: c.requested_slug, granted: null,
                           takenBy: walk_of_all_slugs(taken) }
      continue
    i    = palette.indexOf(c.requested_slug)
    walk = []                                # the story of the walk, in order
    while palette.colors[i].slug in taken:
      walk.append({ slug: palette.colors[i].slug,
                    by:   taken[palette.colors[i].slug] })
      i = (i + 1) mod len(palette.colors)    # wrap at the end of the array
    granted        = palette.colors[i].slug
    taken[granted] = c.player
    grants[c.player] = { requested: c.requested_slug, granted: granted,
                         takenBy: walk }
  return grants
```

Properties consumers may rely on: every claimant's `granted` is unique (or `null`);
a claimant whose requested slug is free always gets it; re-running with the same
inputs gives the same outputs; a standings change can only move colors *through*
the players whose relative order changed.

## 4. Provenance (what the picker shows)

One legible snapshot per player — rich enough to answer "why did I get yellow when
I chose orange" without a scene-by-scene story:

```json
{
  "requested": "orange",
  "granted": "yellow",
  "takenBy": [
    { "slug": "orange", "by": "daveey" },
    { "slug": "red",    "by": "alice"  },
    { "slug": "blue",   "by": "bob"    },
    { "slug": "green",  "by": "carol"  }
  ]
}
```

- `takenBy` is the walk in order: each slug that was tried and found taken, with the
  higher-standing holder who has it. `granted` is always the first free slug after
  the listed walk (or equals `requested` when `takenBy` is empty).
- Reading of the example: orange was taken (by daveey), and walking the array from
  orange wraps to red, blue, green — all taken — so the first free slug was yellow.
- `granted: null` (with a full-palette `takenBy`) means "no color left; you keep
  stock team colors" — only possible with more than 8 claimants.
- The picker should render this as one sentence + the chips of the walk, e.g.
  "**orange** was taken by daveey — your color walked to **yellow**."

## 5. Viewer embed payload — `?colors=<base64 JSON>`

Follows the existing `?standings=` precedent (`client/league_replayer.html`): the
Observatory injects a query param whose value is **base64 of UTF-8 JSON**
(`btoa(unescape(encodeURIComponent(json)))`; decode with
`JSON.parse(decodeURIComponent(escape(atob(v))))`). URL-encode the base64 when
composing the URL (it may contain `+ / =`).

Schema (payload version `v: 1`):

```json
{
  "v": 1,
  "palette": 1,
  "teams": {
    "red":    { "slug": "orange", "shimmer": "picasso" },
    "blue":   { "slug": "teal" },
    "green":  { "slug": "green", "shimmer": "focusfire" },
    "yellow": { "slug": "magenta" }
  }
}
```

- `v` (required): payload schema version. Unknown `v` ⇒ viewer ignores the whole
  payload and renders stock.
- `palette` (optional): the palette `version` the platform resolved against, so the
  viewer can log skew. Not required to apply the payload.
- `teams` keys are **wire team words** (`red|blue|green|yellow`) — the words the
  replay roster already uses. Values:
  - `slug` — the display color for the ENTIRE team: cogs AND paint stains (paint is
    the scoreboard; a half-recolored team would corrupt the score read).
  - `shimmer` (optional) — the policy whose agents get the metallic shimmer: the
    dictating (highest-standing) policy owner on that team. Per-agent flag, separate
    from color, so team color stays uniform. Identity is the roster `pol` string
    **after seat-suffix stripping** — the engine strips a hosted `" (N)"` / `"_(N)"`
    suffix so all seats of one policy collapse to one identity. The platform must
    send the stripped form; the viewer compares against stripped roster names.

Concrete example — the exact JSON above, minified and encoded:

```
?colors=eyJ2IjoxLCJwYWxldHRlIjoxLCJ0ZWFtcyI6eyJyZWQiOnsic2x1ZyI6Im9yYW5nZSIsInNoaW1tZXIiOiJwaWNhc3NvIn0sImJsdWUiOnsic2x1ZyI6InRlYWwifSwiZ3JlZW4iOnsic2x1ZyI6ImdyZWVuIiwic2hpbW1lciI6ImZvY3VzZmlyZSJ9LCJ5ZWxsb3ciOnsic2x1ZyI6Im1hZ2VudGEifX19
```

Rules:

- **Boot-time only, immutable per page load.** The viewer applies colors before the
  first frame and never re-reads the param. Changing colors = reloading the embed.
- **Graceful omission at every level**: no `colors` param ⇒ stock identity mapping;
  missing team key ⇒ that team keeps stock; no `shimmer` ⇒ no shimmer; unknown slug
  (version skew) ⇒ that team keeps stock. The viewer never errors over this param.
- **The platform guarantees the four slugs in one payload are distinct.** Grants
  (§3) are already unique; the remaining hazard is a granted slug colliding with the
  *stock* color of a team that has no override in this episode (e.g. blue team has
  no claimant, red team's owner holds slug `blue`). When composing the payload the
  platform resolves this by walking the *unclaimed* team from its stock slug to the
  next slug free within this payload — explicit grants are promises made by the
  picker and are never moved.
- The payload carries slugs, not hexes: the viewer translates slug → `game` hex via
  its own copy of `team_palette.json`. The platform never sends raw colors.
- A `teams` entry may carry `shimmer` with **no** `slug` (that policy shimmers, the
  team keeps its stock color). The viewer accepts it.

## 5.1 How the viewer receives it

The board is **server-rendered** — team color is baked into sprite RGBA in Nim and
shipped over the sprite protocol — so the mapping has to reach the *engine*, not
just the page. `src/ctf/team_colors.nim` is the single funnel; it accepts the raw
param value (base64 JSON, or plain JSON for hand runs) and never raises.

| Delivery path | How the mapping arrives |
|---|---|
| **Static WASM bundle** (`replay-viewer/`, the Observatory production path) | `?colors=` on the board URL. `static_replay.js` hands the raw value to the exported `ctf_set_team_colors(ptr, len)` immediately before `ctf_load_replay`. The league shell (`league.html`) forwards `?colors=` verbatim onto the board iframe's `src`. |
| **Native server** (`bin/ctf-server`) | The `CTF_TEAM_COLORS` environment variable, read in `src/ctf.nim` before the server loop starts. It is an env var, not a CLI flag, because `bitworld/runtime` owns the option parser and rejects unknown options; and it stays out of `GameConfig` so a display choice can never reach the game hash or the recorded replay config. The page still takes `?colors=` for its own chrome. |

Two ordering rules that are easy to get wrong and fail *silently*:

- **Before the first bake.** Every team-colored sprite is baked once and cached,
  and paint stains are append-only behind a send cursor. A mapping installed
  after the first frame changes nothing. `setTeamDisplayColors` therefore
  refuses a second call.
- **After the runtime's `main()`.** On wasm, `Module.onRuntimeInitialized` fires
  *before* emscripten calls `main`, and `main` runs Nim's module-level
  initializers — which reset the mapping to stock. The call must sit next to
  `ctf_load_replay`, which has the same constraint.

The browser chrome resolves the same payload independently (CSS custom
properties + the FPV cog art), reading slug → hex from `window.CTF_PALETTE`,
which is **generated** from `data/team_palette.json` by the same Nim module the
engine paints with (`teamPaletteJs`, emitted alongside `window.CTF_WIRE`). A
palette change needs no JavaScript edit, and the hexes are never re-typed.

## 6. Vendoring guidance (webpage repo)

- Copy `data/team_palette.json` **verbatim** — do not re-serialize, reformat, or
  "optimize" it. Slugs, order, and hexes must be byte-identical in meaning.
- Suggested sync check in the webpage repo's CI: fetch this repo's copy (or pin a
  commit) and diff — `curl -s <raw-url>/data/team_palette.json | diff - vendored/team_palette.json`.
  Fail the build on drift; bump deliberately by re-vendoring.
- The picker renders `ink` variants; the in-game `game` hex is useful as a swatch
  tooltip/preview but is not the click target. Paper is the `#f2e8d8` family; the
  ink variants were validated against exactly that tone (§7).
- If the webpage needs a new color: it gets added HERE first (appended, version
  bump, validator pass), then re-vendored. Never invent slugs webpage-side.

## 7. Validation

`python3 scripts/validate_palette.py` (stdlib only) — run it after any palette
change; it must exit 0. Thresholds (CIEDE2000 unless noted):

| Check | Threshold | Current worst pair (v1) |
|---|---|---|
| A. game colors, all pairs | ≥ 20 | purple/magenta = 21.2 |
| B. paint stains (×0.92 darken, 40% alpha over terrain `#b8a888` and paper `#f2e8d8`), all pairs | ≥ 8 | green/teal on terrain = 8.6 |
| C1. ink chip contrast vs paper `#f2e8d8` (WCAG) | ≥ 3.0 | green `#5d8a68` = 3.27 |
| C2. ink chip vs near-black (viewer ink `#2a1f16`, web ink `#111827`) | ≥ 12 | blue `#2f4e7c` vs web ink = 19.8 |
| C3. ink chips of different slugs, all pairs | ≥ 6 | red `#8a4630` / orange `#845020` = 10.0 |

Any 4-subset of the palette can be live in one episode, so the **worst pair over the
whole palette** is the number that matters, not the average. For calibration: the
stock four's own worst pair (green/yellow) is 30.1 — threshold 20 keeps additions in
the same legibility class the game already ships.

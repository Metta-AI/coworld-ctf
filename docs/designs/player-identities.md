# Player identities (alpha–theta)

## Problem

Players are anonymous on the board beyond team color: within a team, all eight
soldiers render identically. Spectators cannot follow an individual across the
match, and policies cannot re-identify a specific enemy after a fog gap.

## Design

Each team's eight slots get a fixed identity, **alpha** through **theta**,
assigned by slot order within the team (a slot's rank among same-team slots in
the config). Identity is derived from the slot, not stored: deterministic
across matches, reconnects, and replays, with no new sim state and no
`gameHash` impact.

### Badge object (policy-visible)

Each **living** player carries one badge object anchored to their sprite —
the same attach-by-proximity pattern the overhead HP pip bar uses:

- **Sprite:** an 11px round badge — dark ink disc, team-tinted rim, and the
  uppercase Greek glyph (Α Β Γ Δ Ε Ζ Η Θ) in the team color mixed toward
  white. The bundled fonts have no Greek coverage, so the eight glyphs are
  hand-authored 5×7 pixel bitmaps embedded in source (like the code-drawn HP
  bar), upscaled by `boardScale` on emission. 16 sprite definitions total
  (2 teams × 8 identities), ids 4200..4215; object pool 19040..19055.
- **Label:** `identity <color> <name>`, e.g. `identity red alpha`. New,
  additive vocabulary — existing `player <color> <side>` labels are untouched,
  so exact-match label readers (the baseline bot) keep working. Policies
  attach a badge to a player by proximity, exactly as they do `hp <n>/3` bars.
- **Placement:** centered on the soldier body's bottom-right corner, clear of
  the overhead HP-bar/name stack; z just above its own body in the y-sort.
- **Visibility:** fog-gated with its player in POV views (visible player ⇒
  visible identity — it is intel, like HP); always shown in the global
  viewer/replays; living players only, drops with death like the HP bar.

### Non-goals

- No per-identity player-body sprites (would 8× the soldier sprite pool and
  break the documented label vocabulary).
- No sim, protocol, config, or `GameVersion` changes — rendering only.

## Touched surfaces

- `src/ctf/sim.nim`: `IdentityNames` const + `slotIdentityIndex` (rank of a
  slot among same-team slots, via the existing `teamForSlot`).
- `src/ctf/global.nim`: glyph bitmaps, badge sprite builder, an
  `addIdentityBadges` pass in both the global-board and POV builders
  (replay/broadcast reuse those builders and get it for free).
- `docs/RULES.md`: identity assignment under Teams & spawns; the new
  `identity <color> <name>` label beside the player-sprite label docs.

## Validation

Build the server and baseline bot; run 16 bots locally and verify badges in
the global viewer; verify a POV client only receives `identity` labels for
players inside its vision; expand an existing replay to confirm no regression.

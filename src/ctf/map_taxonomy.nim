## map_taxonomy — DESCRIPTIVE labels for a map, not quality terms.
##
## `map_metrics` collapses a map to a single [0,1] `staticScore`: is it any
## good. This module answers a DIFFERENT question a catalog needs — WHAT KIND
## of map is it — and deliberately never gates on the answer. A `siege` map is
## not worse than a `rush` map; they are different products, and the coverage
## view (`tools/map_catalog.nim`) exists to show which kinds the pool actually
## delivers and which cells are empty.
##
## TWO axes, both pure functions of already-computed fields:
##  - `playtypeLabel`  — the route/vision GEOMETRY: rush | control | siege |
##                       skirmish | overwatch. Reads `MapMetrics` (+ `MapRules`
##                       for the one size-dependent term, cover).
##  - `pacingTier`     — the CONTACT CLOCK: fast | standard | methodical, from
##                       `contactTicks` against `TunedContactTicks`.
##
## NO NEW GEOMETRY. Every input is a field `evaluateMap` / `mapRules` already
## produced; this module only partitions them.
##
## CALIBRATION PROVENANCE. Every cut-point below was MEASURED from
## `docs/evidence/staticscore-play-rows-windowed.json` (40 generated maps +
## the hand-authored `arena` control, joined to the 118-map static sweep in
## `staticscore-spread-manifest.json` for the fields the windowed rows omit).
## The numbers in the comments are that file's own quartiles — they are not
## the research report's guesses, and re-deriving one means re-reading that
## file, not editing a report. The partition those cuts produce over the 41
## evidence maps is recorded in each threshold's note so a drift shows up as a
## changed count.

import std/math
import map_metrics, map_rules

# ---------------------------------------------------------------------------
# Playtype — the geometry axis
# ---------------------------------------------------------------------------

const
  # --- calibrated cut-points (evidence quartiles in the note) --------------
  SiegeChokeCount* = 8
    ## `chokeCount >= 8` is `siege`. Measured: the 41 evidence maps' chokeCount
    ## runs q25=0, med=4, q75=8, max=15 — the top quartile is a clean shelf of
    ## maps whose whole design is unavoidable pinches. 11 of 41 land here.

  RushChokeMax* = 1
  RushRouteMax* = 2
    ## `chokeCount <= 1 AND routeCountMin <= 2` is `rush`: open and direct, no
    ## gate to hold and no flank to manage, so contact is immediate and frontal.
    ## The conjunction is deliberately tight (both at/below q25) — rare in this
    ## pool (1 of 41), which is itself the coverage finding, not a mis-tune.

  OverwatchLongRunFrac* = 0.093
    ## Top-quartile axis long-run share (q75=0.093 over the evidence). A map
    ## this laced with long lanes is sightline-dominated...
  OverwatchCoverFrac* = 0.90
    ## ...but ONLY when cover is thin enough to leave those lanes exposed:
    ## `coverPermille <= 0.90 * coverPermilleMax` for the map's OWN size class.
    ## Normalised because the cover budget scales with the class (small 156,
    ## standard 168), so a raw permille cut would just re-measure board size.
    ## 1 of 41 evidence maps clears both — a thin bucket, reported as such.

  SkirmishRouteMin* = 4
  SkirmishVisCv* = 0.394
    ## `routeCountMin >= 4 OR visDegreeCv >= 0.394`: many independent ways
    ## across, or highly uneven exposure — either makes the fight mobile and
    ## many-fronted rather than positional. routeCountMin q75=3 (so >=4 is above
    ## the top quartile) and visDegreeCv q75=0.394. 14 of 41 land here; the
    ## `arena` control (8 routes, CV 0.52) is one of them.

  # `control` is the residual: three-lane-ish, medium everything. 14 of 41.

proc playtypeLabel*(m: MapMetrics, r: MapRules): string =
  ## The map's route/vision archetype as a play label, derived ENTIRELY from
  ## fields `evaluateMap` (`m`) and `mapRules` (`r`) already produced.
  ##
  ## Order matters: the tests are checked most-specific first, so a map that is
  ## both a kill-box maze and open-laned reads as `siege` (the pinch dominates
  ## what a player must do). The tail `control` catches everything the four
  ## specific shapes did not claim.
  ##
  ## Calibrated against `docs/evidence/staticscore-play-rows-windowed.json`;
  ## see the constants above for each cut-point's measured basis.
  # siege — unavoidable-pinch dominated
  if m.chokeCount >= SiegeChokeCount:
    return "siege"
  # overwatch — long lanes on thin cover (cover normalised to the size class)
  let coverCap = float(r.coverPermilleMax) * OverwatchCoverFrac
  if m.longRunFrac >= OverwatchLongRunFrac and float(m.coverPermille) <= coverCap:
    return "overwatch"
  # skirmish — many routes or very uneven exposure. Tested BEFORE rush: a board
  # with only two routes but highly uneven exposure (visDegreeCv >= the top
  # quartile) is a mobile, many-fronted fight, not a clean frontal rush, so the
  # positive skirmish signal wins the overlap. No evidence map sits in that
  # corner (reordering leaves the 41-map partition byte-identical), so this only
  # disambiguates the synthetic case rush's route<=2 shortcut would misread.
  if m.routeCountMin >= SkirmishRouteMin or m.visDegreeCv >= SkirmishVisCv:
    return "skirmish"
  # rush — uniformly open and direct: no gate to hold, few routes to manage
  if m.chokeCount <= RushChokeMax and m.routeCountMin <= RushRouteMax:
    return "rush"
  # control — the residual three-lane middle
  "control"

# ---------------------------------------------------------------------------
# Pacing — the contact-clock axis
# ---------------------------------------------------------------------------

const
  FastContactFrac* = 0.8
    ## `contactTicks < 0.8 * TunedContactTicks` is `fast`: first contact arrives
    ## sooner than the tuned game, so the map plays denser and quicker.
  MethodicalContactFrac* = 1.3
    ## `contactTicks > 1.3 * TunedContactTicks` is `methodical`: contact is
    ## sparser than tuned, so play is slower and more positional. Between the
    ## two bounds is `standard`.
    ##
    ## These are ratios against `map_rules.TunedContactTicks` (the shipped
    ## game's own contact clock), NOT free parameters — a map is fast or slow
    ## RELATIVE TO what the tuned board feels like. They are intentionally
    ## inside the draw band (`DrawStressMin` 0.48 .. `DrawStressMax` 2.89): a
    ## map outside THAT is mis-sized for its roster, a separate verdict
    ## (`fitMapSize`) than how it paces within the playable range.

proc pacingTier*(contactTicks, tunedContact: float): string =
  ## `fast | standard | methodical` from a map's expected ticks-to-first-contact
  ## against the tuned contact clock. Pure ratio; both inputs are already
  ## computed (`map_rules.contactTicks` / `TunedContactTicks`).
  if tunedContact <= 0.0: return "standard"
  let ratio = contactTicks / tunedContact
  if ratio < FastContactFrac: return "fast"
  if ratio > MethodicalContactFrac: return "methodical"
  "standard"

proc pacingTier*(m: MapMetrics, r: MapRules): string =
  ## Convenience twin: derive the contact clock from a map's own size class and
  ## the shipping roster, so a catalog can label a tile from (`m`, `r`) alone.
  ## `r.playfieldPx` is the board's area and `TunedOpponents` is the roster the
  ## whole `map_rules` clock is tuned to.
  pacingTier(contactTicks(r.playfieldPx, TunedOpponents), TunedContactTicks)

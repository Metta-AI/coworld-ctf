# Team perks

## Goal

Let a team (or, in CTF-Doubles, each policy on a team) carry a small set of
**perks** — named, icon-badged buffs that confer abilities for the whole match.
Five perks ship; both the assignment and the magnitudes ("mods") are config,
following the per-team-handicaps pattern
(docs/plans/2026-08-05-per-team-handicaps-design.md) exactly: default config is
**byte-identical to today** — no GameVersion bump, no fixture regen.

| perk     | effect (default mod)                                   |
|----------|--------------------------------------------------------|
| armor    | +1 max hit point per bot                               |
| scope    | aim improves 50% (gun jitter sigma × 0.5)              |
| grenade  | grenade max throw range +25%                           |
| thruster | max speed +10%                                         |
| luck     | 10% of landed gun shots deal double damage (2 hp)      |

## Config surface

`GameConfig` gains:

- `perks*: array[Team, seq[PerkSet]]` — per-team perk **groups**. Empty seq
  (default) = no perks. One group = the whole team shares it. Two or more
  groups = CTF-Doubles: the Nth **distinct policy** to seat on that team (in
  join order, `policyName` collapse) gets group N (clamped to the last group).
- Mod knobs, integer-stored (permille where fractional) so every in-sim
  derivation is integer or perk-gated: `perkArmorHp` (1), `perkScopePermille`
  (500 = fraction of jitter sigma removed), `perkGrenadePermille` (250 = extra
  range), `perkThrusterPermille` (100 = extra speed), `perkLuckPermille`
  (100 = lucky-shot chance), `perkLuckDamage` (2 = a lucky shot's hp).

Authored JSON:

```json
{
  "perks": {
    "red": ["armor", "scope"],
    "blue": [["grenade"], ["thruster", "luck"]]
  },
  "perkMods": { "armorHp": 1, "scopeAim": 0.5, "grenadeRange": 0.25,
                "thrusterSpeed": 0.1, "luckChance": 0.1, "luckDamage": 2 }
}
```

A flat list is shorthand for one group. Unknown perk names raise at parse.
`perkMods` fractions are floats converted to permille once at parse (the
handicaps float→permille rule). `configJson()` echoes `perks` only for teams
with entries and `perkMods` only when some mod differs from its default, so a
default game's replay config is unchanged.

## Resolution (deterministic, replay-safe)

`Player` gains `perks*: PerkSet`, resolved **once at join** (roster.nim): walk
already-seated players of the team in join order collecting distinct
`policyName(address)` identities; this seat's group index is its policy's rank
(existing policy → its rank; new policy → count of seen). Joins are part of the
replay stream, so playback resolves identically; a later leave never reshuffles
perks. `policyName` moves from broadcast.nim to sim_types.nim (pure string
proc) so roster can use it.

## Read sites (accessor-routed, exact base at default)

- **armor** — `playerMaxHp(sim, i)` = `hitPointsFor(team) + perkArmorHp` when
  armored: join, startGame reset, respawn, med-kit full-heal cap, and the
  broadcast hp-bar denominator (global.nim).
- **thruster** — movement tick max speed: `maxSpeedFor(team) *
  (1000 + perkThrusterPermille) div 1000` when perked (integer, composes with
  the handicap interpolation and carrier scaling unchanged).
- **scope** — `aimJitterSigma(sim, shooter)`: sigma `* (1000 -
  perkScopePermille) / 1000` when perked. Float scale is fine: the jitter path
  is already float and the scale only applies when the perk is present, so the
  default RNG draw and value are untouched.
- **grenade** — `grenadeMaxRangeFor(config, perks)` replaces the raw
  `GrenadeMaxRange` in `throwGrenade` and `throwTarget` (which gains a
  `maxRange` parameter; the render charge-ring caller passes the same resolved
  value, so the ring can never disagree with the throw).
- **luck** — in `applyFire`, on a landed hit only: when the shooter carries
  luck, roll `rand(999) < perkLuckPermille` once and deal `perkLuckDamage`
  instead of 1 (damage event, pop, and kill credit all carry the real amount).
  RNG is drawn only when the perk is present — the no-perk stream is untouched.

Handicaps and perks compose: handicap interpolation first, perk bonus on top.

## Observability

- **Broadcast roster**: each seat gains `"pk": ["armor", …]` (omitted when
  empty). The scorebug derives policy groups client-side from the roster's
  existing `pol` + the new `pk` (all seats of one policy share a set).
- **Marker label** (bots): one `perks <color> <group> [<group>…]` label per
  team beside the handicap markers in the init snapshot; a group is
  comma-joined perk names or `-` for none. Emitted for EVERY team (an
  unperked team reads `perks <color> -`), on the handicap rule: absence
  means an old engine, never "no perks" — and the always-on empty form keeps
  the vocabulary lit in the label-contract sweep's default fixture.

## Scorebug (both chromes)

Perk icons are small inline SVGs (shield/crosshair/grenade/flame/clover)
built by a shared chrome_common helper. Each perk keeps ONE fixed color on
every plate (never team-tinted) — the icon identifies the perk, the plate
identifies the team. Hover titles state the perk name plus its resolved
magnitude ("scope - +50% accuracy"), read from the frame's `pmods` block
(permille ints the sim resolves into `buildStateJson`, present only when a
team has perks).

- Broadcast client: the squad-pip strip IS the life meter, so the badges ride
  it. Pips group per policy (`.squad-pol`); a lone policy keeps its badges on
  the strip's outer end, and a two-policy team (CTF-Doubles) **mirrors within
  the strip** — the two pip groups sit adjacent at its center with each
  policy's badges flanking outside its own group. Group order is ALWAYS the
  headline's left-to-right policy order, on both plates: an early version
  clock-mirrored the whole strip on left plates, which visually attached the
  left badges to the wrong policy name. The lives-line numeral stays the
  classic single team count.
- League shell (no pip strip): the team-head lives-line splits into two
  per-policy numerals in CTF-Doubles (same headline order), numerals
  innermost and badges outside.

## No GameVersion bump / no fixture regen

Old replays carry no `perks` key → every accessor returns the exact base
value, no extra RNG is drawn, gameHash is byte-identical. Guarded by the
existing test_replay hash check plus a new default-equivalence test in
test_perks.nim.

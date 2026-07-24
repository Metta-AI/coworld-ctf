# Tier-2 `blocked` field — damage a shield absorbed (for James / engine review)

**What / why.** The Observatory Logs *Healing* tab wants to show "damage blocked"
beside "HP recovered" and "HP lost" — the third defensive lever. That was NOT
derivable from the old event schema (no shield/carrier field; `hit` events keep
`hp:-1`). This change makes it a first-class, first-hand engine fact.

## The change (option (a): one numeric field, the clean one)

`SimEvent` gains `blocked*: int` — on a `Damage` event, how many of that hit's
HP the victim's **shield** absorbed. `0` on every non-Damage kind and on any hit
where the victim held no shield HP.

Derivation is exact, not heuristic: a shield pickup is the ONLY thing that lifts
a cog above the base `config.hitPoints` ceiling (`ShieldHitPoints=6` vs base
`HitPoints=3`; med kits cap at base). So HP the victim holds ABOVE base at impact
is provably shield HP, and the portion of the hit that eats into it is
"prevented" from touching the base cog:

```nim
proc shieldBlocked(sim, targetIndex, amount): int =
  if not players[targetIndex].hasShield: return 0
  let preHp = players[targetIndex].hp + amount   # hp the instant before the hit
  min(amount, max(0, preHp - config.hitPoints))  # shield-bonus hp the hit ate
```

Wired at all three `Damage` emit sites (gun, plasma, grenade), each called right
after `hp` is decremented. Rides the analysis-only event sink — NOT in
`gameHash` (a test asserts this), so replays stay deterministic and live servers
pay nothing (`collectEvents` still gates it).

`tools/extract_events.nim` serializes it as `"blocked"` in each JSONL row.

## Tests

- `tests/test_blocked_damage.nim` (new): full carrier soaks 1; walking a 6-hp
  carrier down proves blocked stops exactly at the base ceiling (3 bonus hp total);
  shieldless cog blocks 0; `blocked` never enters the game hash.
- `tests/test_extract_events.nim`: invariants `0 <= blocked <= amount` on Damage,
  `blocked == 0` on every other kind, and every JSONL row carries the key.

## Downstream (already merged on the web side)

`derivations.ts` `blocksBySeat`/`blocksByPolicy` sum `blocked` by the protected
victim (`target`); `HealingTab` renders a **Blocked** column + episode total,
gated so it only appears when the episode recorded any (no dead zero column,
honest note otherwise). `EpisodeEvent.blocked?` is additive — pre-field streams
read 0.

## Note for the ingestion path

Real episodes light this up automatically once the EVENTS artifact carries
`blocked` (the extractor emits it now). The seed fixture models shieldless 3-HP
cogs, so seeded episodes correctly show the honest "no damage blocked" state.

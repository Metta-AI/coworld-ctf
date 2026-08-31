You are authoring ONE paintbot policy page for **Battle Royale** — the
16-duo, last-squad-standing mode on the paintbot coworld. You do not write
code, and you do not control the cog directly.

## The three layers — know which one you are writing

1. **STRATEGY** — this page. The only layer you write. One JSON scoring
   sheet, no code, no loops.
2. **INTENT** — a short, FIXED, NAMED menu the engine builds each tick
   ("engage the nearest visible enemy," "path to the nearest med kit," "hold
   this covered spot," "rotate toward ring safety," ...). Your page scores
   these named intents using the annotations SCHEMA.md exposes — it never
   sees or names a concrete enemy, seat, or coordinate.
3. **ACTION** — the engine, never you. Once your page's highest-scoring
   intent wins, the engine resolves it into an actual target and the 8-bit
   button mask that moves the cog.

**A strategy that tries to name a specific enemy, a specific pickup, or a
coordinate is malformed.** There is no path for any of that — don't invent
one; score the named intents you're given, using the annotations attached to
them.

## The schema you must produce against

{{SCHEMA}}

## The game, tight

- **16 duos drop onto one map — 32 seats, every cog has exactly one
  partner.** No flag, no heart, no home edge — nothing to carry or capture.
  The only win condition is being the last living duo.
- **One life. No respawn.** The instant a cog is tagged out in this mode it
  is done for the episode — there is no windup to a re-entry, no lives
  counter ticking down to zero. A page authored for a multi-life mode that
  "plays it safe now, makes it up next life" is reasoning about a life this
  mode does not have.
- **Hit points, not health bars.** Default 3 hp per life; one bullet removes
  one. A gun shot has a ~0.2s windup (aim locks the instant you pull the
  trigger) then a ~0.5s cooldown. A spray can (if carried) fires a short
  forward cone instead of the gun, 3 hp per touch, then needs ~0.8s to
  repressurize. A grenade (if carried) is a charge-and-lob AoE, 2 hp in a
  ~52px radius, hurting everyone inside it including the thrower. A shield
  (if carried) is a 3 hp layer on top of base hp, but it fires 3x slower
  while worn and breaks outright once depleted.
- **Vision is fogged.** You see a forward cone plus a small bubble around
  yourself; everything else is masked. Cover is partial — only the sliver of
  a body that is both in a bullet's path and visible can be hit.
- **A shrinking safe ring forces the fight.** The ring closes on a drawn
  center over several phases; standing outside it costs hit points per tick,
  faster as the match goes on. The ring's current rect and its NEXT
  (forecast) rect are both visible live, so ring-timing is a real,
  plannable axis, not a guess — that's what `self.in_ring`,
  `self.dist_to_ring_edge`, and `self.ticks_to_ring_close` are for.
- **Your partner is a first-class strategic axis, not flavor.** You can read
  whether it's still alive (`self.partner_alive`) and how far away it is
  (`self.dist_to_partner`); when it's alive you can also read its hp
  fraction (`partner.hp_frac`). A duo that plays as if it were a solo FFA is
  leaving its own mechanic on the table.
- **Med kits, shields, grenades, and spray cans are floor pickups** placed
  across the map with a rough gradient: kits favor quiet rooms (retreat/
  sustain), shields favor contested hotspots (the item worth fighting over),
  grenades favor alley mouths (an approach tool), sprays favor rooms and
  corners (close-quarters ambush).

## The scoring shape: mid-pack is worth almost nothing

Verify this against source before trusting it stated here, but the verified
read (`sim_types.nim`'s `BrPlacementBonus`) is: this is **not** "a point per
second alive" — that's a different league's function, not this one's. Ours
is an **episode-terminal placement bonus, gated on engagement evidence**: a
duo that records zero attacks and deals zero damage the whole match earns
only the flat loss floor, no matter how long it survived. A duo that fights
AND places earns a bonus keyed to rank, and the table is steep and top-heavy:
2nd place is worth the most (5), it drops fast (4, 4, 3, 3, 2, 2, 2, 1, 1, 1
through 12th), and **13th place through last is worth exactly zero** — the
same flat floor as dying first. There is no consolation prize for a
consistent mid-pack finish. A policy with high variance that sometimes
reaches the top few places beats a policy that reliably, safely finishes
8th. Score so that surviving buys time to find a fight worth taking and to
close out a real placement — never so that avoiding every fight looks like
the best move on the page. **You will never see your own placement or score
mid-episode** — there is no path for it, so don't reason as if you could.

## The vocabulary: score in Glory's own words

Every consequential act mints Glory on the 2-team mode this vocabulary comes
from, and the words are a useful shared vocabulary for BR even though the
Glory system is not yet wired into this mode's own code. Battle Royale has
no flag, so the flag-only deeds (STEAL, CAPTURE, DENIED!, ESCORT, and the
carrier-kill sense of PEEL) do not apply here — do not design around them.
(Note: `intent.is_peel` in SCHEMA.md's path table is a same-spelling but
DIFFERENT, BR-native concept — isolating an enemy from its duo partner, not
the flag-carrier deed. Don't conflate the two.) The deeds that DO fire
independent of any flag, and what each one means, are:

| Word | What earns it |
| --- | --- |
| TAG | a standard gun kill |
| FIRST! | the first kill of the match |
| SPRAYED | a kill with the spray can |
| BOMBED | a kill with a grenade |
| POINT-BLANK | a kill at point-blank range |
| LONGSHOT | a kill at long range |
| MULTI! | more than one kill in a single grenade or spray burst |
| PAYBACK | killing the cog that killed you last life |
| CHASE | killing a target that was fleeing you |
| BOUNTY | killing a veteran (rank 3+) cog |
| WIPEOUT | eliminating the last living member of an enemy duo |
| SHIELD SOAK | quiet ambient credit for damage your shield absorbed |
| OWN PAINT | friendly fire — a PENALTY, never a reward |

Think in these words while you design your rules — a duelist's `score`
weights TAG/POINT-BLANK/CHASE intents high; a survivor's weights SHIELD SOAK
and medkit intents high and TAG low; a third-partier's weights an intent
whose `intent.enemy_hp_frac` is already low. The words themselves never
appear inside the JSON — only the `get` paths in SCHEMA.md do — but a page
that cannot be described in this vocabulary is very likely scoring the wrong
things.

## The tactical situation for THIS page

{{BRIEF}}

## What to return

Return **raw JSON only** — one object matching the schema above, nothing
else. No markdown fences, no prose before or after, no explanation of your
reasoning. If your previous attempt is shown below with validation errors,
fix exactly those errors and return the corrected page, still raw JSON only.

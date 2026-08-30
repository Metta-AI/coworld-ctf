# The one-page policy — schema (Battle Royale)

Status: this document describes the LANDED contract in `src/ctf/policy_page.nim`
(`parsePolicyPage`, `validate`, `DefaultPathRegistry`). The JSON shape, the op
whitelist, and the hard rules below match that module's source exactly. The
`get` path catalog in §3 is still marked `PROVISIONAL` in that source — the
engine lane that enumerates real candidates owns the final list and may
rename or extend it; if a path in this document is ever rejected, trust the
rejection message (it names the path and, for `get`, the nearest known path),
not this file.

This is **Battle Royale**, not the 2-team capture-the-heart mode. There is no
flag, no heart, no capture zone, no home edge. 16 **duos** (32 seats — every
cog has exactly one partner) drop onto one map; a shrinking safe **ring**
forces engagement; the last duo standing wins.

## 0. Three layers: STRATEGY -> INTENT -> ACTION

A one-page policy is the **strategy** layer, and only the strategy layer. It
never drives the cog directly — it never touches the d-pad, the aim, or a
fire button, and it never names a concrete target (there is no enemy ID, no
coordinate, nothing to point at a specific seat). The three layers, and who
owns each:

1. **STRATEGY** (this page, LLM-authored) — scores a short, FIXED, NAMED menu
   of **intents** the engine offers this tick (things like "engage the
   nearest visible enemy," "path to the nearest med kit," "hold this covered
   spot," "rotate toward ring safety"). One JSON object, no code.
2. **INTENT** (the engine's candidate menu) — each intent the page scores
   comes with a small set of engine-computed annotations (§3: is it an
   engagement, how exposed would taking it leave the cog, how weak is the
   targeted enemy if any, etc.) — the `intent.*` values `get` resolves,
   alongside `self.*` (the acting cog's own state) and `partner.*` (its duo
   partner's state). The page ranks these annotated intents; it never
   invents one and never asks for one outside the fixed menu.
3. **ACTION** (the engine, not the page) — once the page's highest-scoring
   intent is picked, the engine's own pathing/aim/fire logic resolves it into
   the actual concrete target (which enemy, which exact pickup) and the 8-bit
   button mask that moves the cog there. The page never sees or influences
   this step.

**A strategy that tries to name a specific enemy or a specific pickup is a
malformed strategy** — there is no path for it, so it cannot be expressed,
and the registry (§3) is exhaustive by design: an attempt to invent one
(`intent.target_seat`, `intent.enemy_id`, coordinates, anything like that) is
an unknown-path validation rejection, not a way to get more specific.

---

## 1. JSON shape

```json
{ "paintbot_policy": 1,
  "name": "doorstep-denier",
  "doc": "one clause describing the maneuver this page encodes",
  "traits": { "nerve": 0.4, "greed": 0.25, "patience": 0.7 },
  "rules": [
    { "when": true,
      "score": ["+", ["*", 30, ["get", "intent.is_enemy"]],
                     ["*", -8, ["get", "intent.exposure"]]] },
    { "when": ["<", ["get", "self.hp_frac"], 0.5],
      "score": ["+", ["*", 40, ["get", "intent.is_medkit"]],
                     ["*", -20, ["get", "intent.threat"]]] }
  ]}
```

Fields:

- `paintbot_policy` (required, integer) — format version. Must be `1`.
- `name` (required, string) — a short slug identifying the page (used as the
  playbook filename stem and in logs/UI).
- `doc` (required by this playbook's convention, string) — one clause, saying
  what maneuver this page encodes ("disengages under half health and
  beelines the nearest medkit"). The parser does not reject unrecognized
  top-level keys, so `doc` round-trips fine; it is not read by the VM, only
  by every human (and every future page) looking at the playbook.
- `traits` (optional, object) — any number of named dials, each a JSON
  number, in `[0.0, 1.0]` by convention (not enforced). A rule reads one back
  with the `trait` access form (§3) — `["trait", "nerve"]`, NOT
  `["get", "trait.nerve"]`. A page need not read back every trait it
  declares; the doc's own canonical example declares three
  (`nerve`/`greed`/`patience`) and never reads any of them inside `rules` —
  traits may simply be authored dials for a human (or a future flashing
  pass) to retune later.
- `rules` (required, non-empty array) — see §2. `"policy has no rules"` is
  the one page-level (not per-rule) validation error.

## 2. Rule evaluation — rules SUM, they do not branch

Each element of `rules` is `{ "when": <bool expr>, "score": <num expr> }`.

**Every rule in the array is evaluated for every intent, every tick.** A
rule whose `when` evaluates true for that intent adds its `score` (for
that same intent) into a running total; a rule whose `when` is false
contributes exactly 0. The **sum across every matching rule** is that
intent's final score. The intent with the highest total wins the tick; the
engine resolves it into a concrete target and the button mask (§0).

This has two consequences that matter for authoring:

- **`when` is not a one-time gate evaluated before intents exist — it is
  evaluated per intent, exactly like `score`.** `when` may legally
  reference `intent.*` paths (e.g. `"when": ["get", "intent.is_enemy"]` is a
  normal, encouraged way to write "this whole rule only applies to
  engagement intents"), not only `self.*` / `partner.*` / trait paths. A
  `self.*`-only `when` (e.g. gating on `self.hp_frac`) still works exactly
  as you'd expect, because `self.*` (and `partner.*`) resolve to the same
  value for every intent the engine hands you in a given tick — it just
  isn't the *only* legal shape.
- **There is no first-match-wins and no implicit `else`.** If you want
  mutually exclusive branches (a healthy-cog rule and a hurt-cog rule), you
  must write `when` clauses that are true/false complements of each other
  (e.g. `["<", ["get","self.hp_frac"], 0.5]` and
  `[">=", ["get","self.hp_frac"], 0.5]`) — the VM does not do this for you,
  and if both happened to be true, both scores would simply add together.
  Conversely, an always-true baseline rule (`"when": true`) plus a
  conditional bonus/penalty rule is a fully supported, additive style — the
  two are not mutually exclusive by construction, and that's fine; their
  contributions just stack.
- A page needs no explicit "do nothing" intent — every intent that matches
  no rule scores exactly 0, so ties fall back to the engine's own fixed
  (lowest-index, deterministic) tie-break, never a crash.

## 3. `get` / `trait` paths

`["get", "<path>"]` looks up one `self.*`, `partner.*`, or `intent.*` path
(§3.1/§3.2/§3.3). `["trait", "<name>"]` looks up one entry from THIS page's
own `traits` object (§3.4) — this is a **separate access form from `get`**,
not a `get` path spelled `trait.nerve`; `["get", "trait.nerve"]` is simply an
unknown `get` path and will be rejected.

**An unknown `get` path is a hard validation rejection, always — never a
silent 0.** The error names the path and, when the registry is non-empty,
the single nearest known path by edit distance, e.g.:

```
rule 0: unknown get path 'intent.is_shield' (nearest known path: 'intent.is_peel')
```

Referencing a trait name your page never declared in its own `traits` object
is likewise a hard validation rejection (no nearest-match suggestion for
traits): `rule 0: unknown trait 'greed' (not declared in this page's traits table)`.

### 3.1 `self.*` — the acting cog's own state (same value for every intent this tick)

| Path | Kind | Meaning |
| --- | --- | --- |
| `self.hp_frac` | number | current hit points / max hit points |
| `self.alive_ticks` | number | ticks survived so far this life |
| `self.in_ring` | bool | inside the current safe ring right now |
| `self.dist_to_ring_edge` | number | distance from the cog's current position to the ring boundary |
| `self.ticks_to_ring_close` | number | ticks remaining before the ring's next shrink phase |
| `self.players_alive` | number | living players remaining in the whole match |
| `self.has_grenade` | bool | carrying a grenade |
| `self.has_shield` | bool | carrying a shield |
| `self.partner_alive` | bool | this cog's duo partner is still alive |
| `self.dist_to_partner` | number | distance from the cog's current position to its partner |

Deliberately absent, always: **`self.placement`, `self.score`, anything
mid-episode-outcome-shaped.** Placement and score are never surfaced to a
running cog (see `prompt.md`) — there is no path for them because there is
nothing to `get`.

### 3.2 `partner.*` — the duo partner's own state

| Path | Kind | Meaning |
| --- | --- | --- |
| `partner.hp_frac` | number | the partner's current hit points / max hit points |

A separate top-level namespace from `self.*` by design (Maxwell's ruling) —
not `self.partner_hp_frac`. Only meaningful together with `self.partner_alive`
(§3.1): a dead partner's `hp_frac` is not a claim about anything real, so gate
on `self.partner_alive` first, the way `tight-trade.json` and
`wide-intel.json` in this playbook both do.

### 3.3 `intent.*` — the specific named intent being scored

| Path | Kind | Meaning |
| --- | --- | --- |
| `intent.is_enemy` | bool | this intent engages a living enemy |
| `intent.enemy_hp_frac` | number | the targeted enemy's `hp_frac`; only meaningful when `intent.is_enemy` is true |
| `intent.dist` | number | distance from the cog's current position to the intent's endpoint |
| `intent.exposure` | number | how visible the intent's endpoint is to living enemies, `0.0`–`1.0` |
| `intent.threat` | number | incoming danger near the intent's endpoint, `0.0`–`1.0` |
| `intent.is_cover` | bool | the intent's endpoint sits behind cover from the nearest known threat |
| `intent.is_medkit` | bool | this intent is "go to a med kit" |
| `intent.is_item` | bool | this intent is "go to" some OTHER floor pickup (grenade/shield/spray) — there is no separate per-type flag beyond `is_medkit`; distinguish further only if a later registry adds one |
| `intent.is_ring_safe` | bool | taking this intent would leave the cog inside the safe ring |
| `intent.is_peel` | bool | **naming note:** this reads like the Glory deed word PEEL, but it is NOT that deed — `dCarrierKill` (PEEL) is gated on a flag carrier, a concept BR does not have (verified in `src/ctf/glory.nim`, which does not exist at all on the BR branch). Best-effort provisional reading, pending confirmation from the engine lane: this intent would isolate an enemy away from ITS duo partner (a 1-on-1 opportunity for you). Not used by this playbook's seed pages for that reason — don't assume the gloss, confirm before leaning on it |

### 3.4 `trait.*` (via `["trait", "name"]`, not `get`)

Reads back a number from this page's own `traits` object — whatever keys the
page itself declared. There is no fixed vocabulary enforced by the VM; the
convention this playbook follows is three dials, each `0.0`–`1.0`:

| Name | Convention |
| --- | --- |
| `nerve` | willingness to hold an exposed fight rather than break it off |
| `greed` | bias toward pickups over positioning |
| `patience` | bias toward rotating late/safe versus early/aggressive |

## 4. Op whitelist (exactly these — no more)

Every non-leaf node in a `when` or `score` expression is a JSON array whose
first element is one of the operator names below. No other operator name is
legal anywhere; `"if"` in particular is explicitly and separately rejected
(see §5). A bare JSON number or boolean is a literal expression. A bare JSON
string is **never** legal directly inside an expression — the only place a
string appears is as `get`'s or `trait`'s single argument.

| Op | Arity | Meaning |
| --- | --- | --- |
| `get` | 1 (string literal) | look up a `self.*`, `partner.*`, or `intent.*` path (§3.1/§3.2/§3.3) |
| `trait` | 1 (string literal) | look up a trait from this page's own `traits` object (§3.3) |
| `+` | 1+ | sum |
| `-` | 1+ | negation (1 arg) or left-to-right subtraction (2+ args: `a - b - c...`) |
| `*` | 1+ | product |
| `/` | 2 | quotient — dividing by zero is defined to yield `0`, not a trap |
| `min` | 1+ | smallest argument |
| `max` | 1+ | largest argument |
| `abs` | 1 | absolute value |
| `clamp` | 3 | `clamp(x, lo, hi)` |
| `<` | 2 | less than |
| `<=` | 2 | less than or equal |
| `>` | 2 | greater than |
| `>=` | 2 | greater than or equal |
| `==` | 2 | equal |
| `and` | 1+ | logical and (short-circuits on the first `false`) |
| `or` | 1+ | logical or (short-circuits on the first `true`) |
| `not` | 1 | logical not |

**There is no `!=`.** Write `["not", ["==", a, b]]` instead.

**Booleans and numbers are one runtime representation (`0.0`/`1.0`).** A
bare boolean literal, or a `get`/`trait` of boolean kind, is a legal operand
anywhere a number is expected — `["*", 30, ["get", "intent.is_enemy"]]`
("weight times indicator") is the canonical pattern for turning a flag into
a scored bonus, not a type-system hole. `and`/`or`/`not` and the five
comparisons all produce/consume this same `0.0`/`1.0` representation.

## 5. Hard rules

- **No loops.** There is no `map`, `reduce`, `for`, or recursion primitive.
  A rule set is a flat list; that is the entire control structure.
- **`"if"` is a hard parse-time rejection wherever it appears** — inside a
  `when`, inside a `score`, anywhere. This is raised by `parsePolicyPage`
  itself (a `PolicyParseError`), before validation against the path registry
  ever runs. A page scores; it does not branch inside an expression. (Rule
  arrays branch the OLD-FASHIONED way, per §2 — with `when` clauses you
  write to be complements of each other, evaluated additively.)
- **An operator name outside §4's whitelist is also a hard parse-time
  rejection**, naming the bad op and listing the legal ones.
- **No user-defined functions, no variables, no mutation.** Every expression
  is pure and total over one candidate's resolved paths this tick.
- **Unknown `get` path or `trait` name is a hard validation-time rejection**
  (returned in the `seq[string]` from `validate`, not raised) — never a
  silent `0`. This is the rule that makes a typo loud instead of a policy
  that quietly scores nothing forever.
- **`when` must be boolean-valued; `score` must be numeric-valued** — mixing
  them up (e.g. a bare `["get", "self.hp_frac"]` as a whole `when`) is a
  validation-time rejection naming which rule and which side.
- **One page, one language.** Score in the same words the scoreboard uses —
  see `prompt.md` for the Battle-Royale-applicable Glory deed vocabulary
  this page's author should be thinking in, even though the deed words
  themselves never appear inside a page's JSON.

## 6. Error message shapes (verbatim prefixes)

- Per-rule validation errors: `"rule <i>: <message>"`, 0-indexed, e.g.
  `rule 0: unknown get path 'intent.is_shield' (nearest known path: 'intent.is_peel')`,
  `rule 1: op 'clamp' expects exactly 3 arguments, got 2`,
  `rule 0: 'when' must be boolean-valued`.
- One page-level error with no rule prefix: `"policy has no rules"`.
- Parse-time failures (raised, not returned in the list) surface as
  `"'if' is forbidden inside a score/when expression..."` or
  `"unknown op '<op>' — not in the op whitelist (...)"` — `flash validate`
  and `flash author` both fold these into the same error-string list a
  validation failure would have produced, so the repair loop treats both
  uniformly.

## 7. Compilation note (not an authoring rule)

A validated page is compiled once, at flash time, into a closure and interned
by content hash (`pageHash`) — sixteen duos sharing a page compile it exactly
once. This does not change how you author a page; it is why authoring one is
cheap.

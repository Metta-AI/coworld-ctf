# starter: collaborative ("ANCHOR")

Duo-first. The persona prompt tells the model its partner is the win
condition: protect always, talk constantly, decide from the partner's state.

What this harness does differently from the other two starters:

- **Partner state leads the summary** — before the seat's own facts, the
  model is told where its duo partner was last seen, their hp, and whether
  they are still alive (from the 0xB1 view's tracks and kill feed).
- **A coordination line every turn** — on top of the model's own chat, the
  harness sends a deliberate partner-directed lobby line each model turn
  ("seat N: pact is live and protect is on...").
- **The pact is guaranteed** (`adjust_entries` in `policy.py`) — every call
  gets a `pact` entry naming the actual duo partner (read from the seat's
  own `play_context`, never hardcoded), with `protect: true` forced and
  disengage on betrayal; a steady `edge_ride` base is appended if the model
  forgot one, any `bodyguard` is forced to ward the partner with
  `interpose: true`, and a `loot` rung (detour 400 px, never contested) is
  added. The harness puts `bodyguard` on the ladder only while the partner
  is alive and has drifted past its leash, and `crossfire` only while the
  partner is alive and an enemy is tracked — an idle guard would otherwise
  pin the seat in place.
- **Canned turns** open with pact + edge_ride and add `bodyguard` (leash
  [60, 180], peel early) and `crossfire` mid-match — even offline, this is
  the only starter whose ladder contains a pact from the opening call and a
  guard on its partner mid-match.
- **Up to 6 model calls a match**, at least 10 s apart.

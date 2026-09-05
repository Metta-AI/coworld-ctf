# starter: collaborative ("ANCHOR")

The social-alliance seat. 16-solo pivot: S2 is now 16 solo entrants, one
policy/bot/team each -- there is no duo partner and nothing in the sim
enforces an alliance between any two seats. The persona prompt makes this
seat play the social game anyway: it opens with a public truce offer,
honors any pact it strikes through conduct alone (never targeting a named
ally, breaking off the moment they shoot first), and plays straight solo
survival the rest of the time.

What this harness does differently from the other two starters:

- **A public truce line, not a directed one** — the harness's per-turn
  chat addition (`extra_chat` in `policy.py`) proposes or reaffirms an
  open no-fight offer instead of addressing a fixed partner; there is no
  seat number to address.
- **`pact` is never hardcoded** — `adjust_entries` applies only generic
  repair (a sane `onBetrayal` default) to whatever seat references the
  MODEL proposes after reading the roster and lobby chat. There is no
  ground-truth ally to inject, so the alliance is entirely the model's own
  judgment call, turn by turn.
- **Solo-survival base** — a moderate `edge_ride` (margin ~260, between
  the cautious and aggressive starters' clamps) plus a gated `loot` rung,
  same shape as the other two starters' base ladders.
- **Up to 6 model calls a match**, at least 10 s apart.

The shared harness (`common/starter_harness.py`) still carries all of its
duo-partner plumbing (`context.self.duo_partner`, `partner_focus`,
`bodyguard`/`crossfire`'s ward-defaults-to-partner) unchanged; this persona
simply never exercises it, because a solo match's context carries no
`duo_partner` to find.

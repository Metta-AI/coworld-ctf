*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

A shout (wire label `<color> shout <player>`, with the message text appended
after a literal `: `) is a short player-authored message any living seated
player can send. It is at most 10 printable characters, heard by every living
player within 247 px of where it landed regardless of team, and limited to one
per player per second. A shout is simulation state rather than chat-window
chrome: it enters the tick's `gameHash` — the per-tick checksum that folds in
every fact able to affect the outcome, so two runs that ever disagree on it
have diverged in actual game state, not merely in rendering — and a replay
reproduces a shout by re-applying the same recorded message at the same tick,
not by storing the rendered bubble.

## Stats

| Property | Value | Ticks | Notes |
| --- | --- | --- | --- |
| Audible radius | 247 px | — | One-fifth of the loaded map's width on the default 1235×659 arena; recomputed per map. Identical formula to [[paint-bomb]]'s max throw range |
| Message length | 10 characters | — | Printable ASCII only; the text is truncated to this length, then leading/trailing whitespace is trimmed |
| Rate limit | 1.0 s | 24 | At most one shout per player; an attempt inside the cooldown is dropped, not queued or delayed |
| Bubble lifetime | 3.0 s | 72 | How long a shout stays in the observable set — and in `gameHash` — after it lands |
| Position jitter | ±20 px | — | Deterministic per shout, not averaged-out noise; the same magnitude as the `shot impact` ring, salted apart from it |

## Rules

### Who can shout, and when

A shout requires a living, seated player during an active episode — a dead
player, and anyone before spawn or after the episode ends, cannot send one. A
spectator connection has no chat path at all: only a seated player's
connection carries a chat message through to the shout system. "Seated"
covers a human client and a policy container identically — both connect
through the same player websocket, so an LLM policy shouts through the exact
mechanism a human player does. Only one shout is live per player at a time; a
new shout immediately replaces that player's previous bubble rather than
queuing behind it.

### No team filter

**Audibility is decided by distance alone.** The check that decides whether a
listener hears a shout tests only that the listener is alive and within the
audible radius — team never enters it. An enemy standing inside the radius
overhears a shout exactly as a teammate would; the `<color>` in the label
names who spoke, not who is allowed to listen. This mirrors
[[perception]]'s "no team radio" rule for vision: there is no private channel
in Paintbot, only a radius.

### Causal, not cosmetic

A shout is folded into the tick's `gameHash` — shouter, team, text, tick and
position are all mixed in — for as long as it stays in the observable set,
the same way [[glory|glory totals]] are. A replay does not store the
rendered bubble; it re-applies the identical recorded chat message at the
identical tick, so two runs that hear different words, or the same words a
tick apart, produce different hashes.

### Mechanic and chrome

The wire label and the rendered bubble carry different amounts of
information:

| Mechanic — what a policy scans for | Chrome — what a viewer sees |
| --- | --- |
| Full string `<color> shout <player>: <text>` | A cream speech-bubble pill holding only `<text>`, outlined in the shouter's team color, floating above their head |

The player's address and the leading `<color> shout ` prefix are wire-only —
they never appear inside the drawn bubble, which shows nothing but the
message itself.

### `shoutCoord`: an opt-in relay, not an engine feature

The engine places no vocabulary on the 10-character payload; it only
sanitizes and rate-limits it. Because it is canonical, shipped and
inspectable, what its build flags do with that payload is a fact about
Paintbot, not advice. [[baseline-policy|The baseline policy]] carries an
opt-in `shoutCoord` compile flag that, when built in, spends its own shout
budget on quantized position fixes instead of ordinary lines: `"C<cx> <cy>"`
for the sender's own map position, and `"T<cx> <cy>"` for a freshly-sighted
enemy carrying the baseline's own objective. `<cx>` and `<cy>` are the
sender's x and y divided by 8 and stringified — an 8 px quantization of the
true position — and a receiving baseline instance reconstructs a point near
the original by multiplying back and adding a 4 px half-step. This rides the
same public shout channel as any other message: nothing in the engine
distinguishes a `shoutCoord` fix from ten characters typed by a person, and
only a policy that chooses to parse the same "C"/"T" convention understands
it.

## Labels

| Label | Stream | Meaning |
| --- | --- | --- |
| `<color> shout <player>: <text>` | Both | A speech bubble; range-gated on a player view, unlimited on the board. |

**Parse this label by prefix, then split on the last `": "`.** `<player>` is
the sender's raw connection address, and `<text>` is arbitrary
player-authored text that can itself contain a colon-space pair — so a
consumer scans the stable `<color> shout ` prefix to find the row, then splits
the remainder on the *last* `": "` to separate the address from the message,
never the first. A player view hears a shout only within 247 px of where it
landed; the broadcast board shows every live shout regardless of distance.

## Version history

| Version | Change |
| --- | --- |
| GV3 | Audible radius, message length limit, rate limit and bubble lifetime set to their current values; none of the four has changed since. |
| 0.7.5 | Chat packets, previously ignored, began rendering as the shout label `<color> shout <player>: <text>`. |

## Gaps

- Whether a standard, engine-parsed callout vocabulary usable by any policy —
  not just one that reimplements a specific baseline convention — is planned
  for this channel. As of GV24 nothing in the engine parses shout text as
  anything but an opaque 10-character string; `shoutCoord`'s "C"/"T" prefixes
  are understood only by a baseline build that chooses to read them.

## See also

- [[perception]] — the fog and sound rules this page's radius and jitter
  numbers belong to
- [[labels]] — the full label table, including this page's row
- [[policies]] — how a policy container connects to send and receive this
  channel
- [[baseline-policy]] — the shipped policy whose `shoutCoord` build is
  described above
- [[paint-bomb]] — shares the exact "one-fifth of map width" formula for its
  own throw range
- [[glory]] — the other system whose numbers are causal via the same
  `gameHash`
- [[main]] — the portal

## Discussion

Advice about what to shout, when to stay quiet, or any vocabulary you worked
out yourself against a live opponent belongs on
[the forum](https://softmax.com/paintbot/forum) rather than here.

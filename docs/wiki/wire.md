*Verified against [[versions|GV24 / Glory 12]].*

**Verified against `GV24 / Glory 12` — the live game is `GV63 / GLORYVERSION 18`; treat details as unconfirmed.**

Every connection to Paintbot's engine is a single WebSocket carrying a
compact binary protocol: a handful of fixed message types, each stating its
own length, concatenated back-to-back with no outer envelope. A
server-to-client frame places and removes named sprites on one of several
layers; a client-to-server frame is almost always the same single byte the
rest of this wiki calls the action mask, sent once every tick. Coordinates on
this wire are plain, unscaled map pixels — the same numbers every other page
here already uses. A second, entirely separate plaintext channel delivers the
match-reward ledger as newline-separated lines, independent of the binary
stream.

## Rules

### Transport

Every connection is exactly one WebSocket, to one of several fixed paths on
the same host — nothing multiplexes two roles onto the same socket:

| Path | Carries |
| --- | --- |
| `/player` | The fogged, per-seat binary stream a policy or a human connects to — see [[policies]] |
| `/global` | The unfogged spectator/broadcast binary stream |
| `/replay` | A saved match, played back on demand, same binary framing — also the one path whose sprite channel smuggles a Glory line, see below |
| `/reward` | A separate plaintext ledger — see below, not the binary protocol at all |

`/player`, `/global` and `/replay` carry WebSocket **binary** messages.
`/reward` carries WebSocket **text** messages instead. **Every multi-byte
integer field on this page is little-endian** — true for every build, since
every runnable on the platform targets `linux/amd64` (see [[policies]]).

### Server-to-client: sprite messages

One binary frame holds one or more of these messages, back-to-back with no
header between them. Each message's own first byte says which kind it is,
and that kind's fixed field layout says how long it runs — a reader walks
the frame by decoding a type byte, consuming that type's fields, and landing
exactly on the next type byte.

| Byte | Message | Fields |
| --- | --- | --- |
| `0x01` | Sprite | `id` u16, `width` u16, `height` u16, `pixel length` u32, that many pixel bytes, `label length` u16, that many label bytes |
| `0x02` | Object | `id` u16, `x` i16, `y` i16, `z` i16, `layer` u8, `sprite id` u16 |
| `0x03` | Delete object | `id` u16 |
| `0x04` | Clear objects | (no fields) |
| `0x05` | Viewport | `layer` u8, `width` u16, `height` u16 |
| `0x06` | Layer | `layer` u8, `kind` u8, `flags` u8 |

**A label belongs to the Sprite message, never to the Object message.** This
is the fact underneath every other page's claim that a policy "matches
objects by label": an Object only carries a numeric `sprite id`. Recovering a
label means keeping a table of every Sprite message received, keyed by its
`id`, and looking up whatever `sprite id` an Object currently points at. Many
Objects routinely point at one Sprite — a whole team's identical soldier art
is one Sprite definition, placed many times over.

**A Sprite definition is only resent when it changes.** An `id` the client
has already seen, at the same width, height and label, is not retransmitted;
most ticks carry only new placements (Object) or removals (Delete object). A
consumer that wants every current object's label, every tick, has to retain
sprite definitions across frames rather than reading only the newest one.

**Worked sample.** A pixel-free Sprite definition for a made-up object
labelled `flag`, 24×24, followed by one placement of it at map pixel
(300, 150) on layer 1:

```
01 09 00 18 00 18 00 00 00 00 00 04 00 66 6c 61 67
02 28 00 2c 01 96 00 00 00 01 09 00
```

| Bytes | Field | Value |
| --- | --- | --- |
| `01` | message type | Sprite |
| `09 00` | sprite id | 9 |
| `18 00` | width | 24 |
| `18 00` | height | 24 |
| `00 00 00 00` | pixel length | 0 — pixel-free, see below |
| `04 00` | label length | 4 |
| `66 6c 61 67` | label | `flag` |
| `02` | message type | Object |
| `28 00` | object id | 40 |
| `2c 01` | x | 300 |
| `96 00` | y | 150 |
| `00 00` | z | 0 |
| `01` | layer | 1 |
| `09 00` | sprite id | 9 |

Those 29 bytes are everything one frame needs to say "object 40 is a 24×24
thing labelled `flag`, at map pixel (300, 150)." A consumer that already knew
sprite id 9 from an earlier frame would see only the second line next tick —
the Sprite message would not be resent.

**The pixel payload is a compressed byte blob, and most consumers never
decode it.** It unpacks to raw RGBA, 4 bytes per pixel, `width × height`
pixels — but anything that reads only labels and positions, never pixel art,
can skip decoding it and needs only the label and the width/height pair a
Sprite message arrives with. A Sprite message may carry a **zero-length**
pixel payload on purpose, exactly as in the worked sample above: a
deliberately pixel-free definition that still carries a real label, width
and height.

**Clear objects removes everything in one instruction; Delete object removes
one.** Ordinary per-tick housekeeping is individual Delete-object messages
for whatever left the frame since last tick; a full Clear is reserved for a
larger reset.

### Client-to-server: control messages

| Byte | Message | Fields |
| --- | --- | --- |
| `0x81` | Chat | `length` u16, that many ASCII bytes |
| `0x82` | Mouse move | `x` i16, `y` i16, optional trailing `layer` u8 |
| `0x83` | Mouse button | `button` u8, `down` u8 (0 or 1) |
| `0x84` | Input | `mask` u8 |
| `0x85` | Ready | (no fields) |
| `0x86` | Debug sprite | `length` u32, that many bytes |

**`0x84` is the only message a policy needs to send every tick, and its
one-byte payload is exactly the eight-bit mask [[action-mask]] documents.**
Sending `0x84` then the byte `0x24` (36 decimal — Left + A, the same
combination [[action-mask]] itself works through) moves left while firing. A
human seat's browser client writes the identical byte for the identical
mask; nothing about this message distinguishes a human from a policy.

**On `/player`, `0x81` is how a [[shouts|shout]] actually leaves a socket.**
The engine applies its own rate limit and length truncation on arrival, so
sending more or longer text than the rules allow is safe — it is clipped or
dropped, never rejected. The two-byte length `2` followed by the ASCII bytes
for `gg` — `0x81 0x02 0x00 0x67 0x67` — is a complete, valid shout packet from
a seated player.

**The identical byte means something else on `/global` and `/replay`.** Those
two paths read `0x81` as a viewer control instead — things like POV
selection, replay seeking and HUD toggling — never as a shout. A spectator
connection has no path to the shout system at all; see [[shouts]] for the
full rule.

### Coordinates

Object `x`/`y`/`z` on the `/player` stream — the one a policy actually reads
— are plain **map pixels, unscaled**: the same pixel space every distance
elsewhere on this wiki is already written in, so no conversion is needed
before comparing a wire object's position against a radius or range
documented on another page. A separate ×2 factor exists only inside the
spectator/replay board builder that feeds `/global` and `/replay`; it never
reaches `/player`. [[perception]]'s own coordinate section agrees with this
account.

### Frame size and chunking

One tick's full update can be larger than a single WebSocket frame allows,
so the engine may split it across more than one binary message — **but
never in the middle of one Sprite/Object/etc. message**. A receiver that
concatenates every binary message it gets, in arrival order, and parses the
result exactly as documented above ends up with identical state whether the
engine sent it as one frame or ten. The split exists only to stay under a
frame-size ceiling; it never changes what arrives.

### The reward channel

A second, independent WebSocket (`/reward`) carries the **match-reward
ledger** — the `+1` / `−1` / `−1` numbers [[scoring]] and [[episode]]
document — as plain text, once per tick, with no relation to the binary
sprite stream at all. Each line reads `<name> <identity> <value>`,
newline-terminated. `<identity>` identifies the connection, not a persistent
player account. `<name>` is one of `reward`, `wins_red`, `wins_blue`,
`games_red`, `games_blue`, `kills`, `deaths`, `captures`; one tick's message
holds one such block of lines per seated player.

**Nothing on this channel carries Glory, and neither does `/player`, ever.**
Every line name above is either the raw reward ledger or a plain combat
counter — there is no line for Glory, a deed, or an achievement on `/reward`,
and `/player` carries none by any mechanism.

**A replay is the one exception, and it does not use this channel.** While a
connection is watching a replay rather than a live match — the case `/replay`
serves, and one a `/global` connection also falls into if it happens to be
pointed at a server that is itself replaying rather than running live — a
Glory line does reach the viewer, but on the *binary* sprite channel, not
here: it is packed once per viewer, not every tick, into the label field of
a reserved sprite that is never drawn, riding alongside the rest of that
viewer's one-time HUD payload. A live `/global` connection to a running match
gets none of this. See [[glory]] for how that ledger is actually computed.

## Version history

| Version | Change |
| --- | --- |
| Wiki | This page previously claimed no stream ever carries Glory, full stop. That was wrong for a replay connection: `/replay` (and a `/global` connection watching a replay) carries a Glory line inside the *binary* sprite channel, packed into a reserved sprite's label. `/player`, `/reward`, and a live `/global` connection still carry none. See [[glory]]. |
| Wiki | This page also described `0x81` as how a shout leaves a socket without saying which path that held for. It holds only on `/player`; the identical byte on `/global` and `/replay` is read as a viewer control instead, never a shout. See [[shouts]]. |

## Gaps

- The exact trigger for a full Clear-objects message versus ordinary
  per-id Delete-object housekeeping.
- What a client's Ready (`0x85`) packet changes about the server's own
  behaviour once received.
- What the Layer message's `kind` byte's values mean — confirmed to exist
  and to tag each layer with some render-style distinction, not confirmed
  what a consumer gains from reading it.
- Whether a dropped and reconnecting `/player` socket can resume into the
  same seat without losing ticks, or whether a fresh connection is always a
  fresh seat — see [[policies]].
- The compressed pixel payload's exact format. Not needed by a policy that
  only reads labels and positions, but undocumented here for the rarer
  consumer that wants the art.

## See also

- [[perception]] — what the labels and positions this page's bytes carry
  actually mean, and the fog rules gating them
- [[labels]] — the label vocabulary a policy resolves through the
  Sprite/Object mechanism this page documents
- [[action-mask]] — the eight bits inside this page's one-byte Input message
- [[policies]] — how a container gets the URL that connects to `/player`
- [[submitting-a-policy]] — implementing this page's protocol end to end
- [[shouts]] — what a policy's Chat message actually does once it lands
- [[scoring]] — the ledger the reward channel's `reward` line carries
- [[glory]] — the causal ledger; absent from every plaintext line on this
  page, and reaching a viewer at all only via a replay connection's
  sprite-label payload
- [[main]] — the portal, and the promise this page exists to keep

## Discussion

Client library choices, connection-pooling tricks, and any latency numbers
you measured yourself belong on
[the forum](https://softmax.com/paintbot/forum) rather than here.

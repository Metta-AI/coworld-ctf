# The play's view, as a fixed-layout binary frame

> **Historical design record (2026-08-31).** Preserved as the lane-C decision
> record that led to the shipped binary view. For current contracts, use the
> schemas and SDK referenced by the living play-calling design.

Lane C spec, 2026-08-31. James ratified the call: **the play's copy of the
view becomes a fixed-layout binary frame; JSON stays for the socket and
replay copies.** This is the implementation input for lane A's view
producer and for the design amendment.

## Why, in one paragraph

A guest that must parse JSON pays for every byte. Measured on the real
runtime: a tight loop that only *touches* each view byte costs 23
instructions per byte with Nim's checks on and 7.5 with them off, and the
real JSON reader costs ~28-57 fuel per byte on top of an 11,187-fuel
fixed cost. `StepFuel` is 50,000, so the affordable JSON view is about
600 bytes against a 32,768-byte cap — and no reader optimization changes
that order of magnitude, because ~50 instructions per byte is simply what
JSON parsing costs (5-20x a memcpy is the normal range). A fixed-layout
frame removes the parse entirely: a field read becomes an offset
computation and one aligned load.

The decisive measurement is the third one, and it is worth stating
plainly because it closes the question: **a correct JSON reader cannot
even *skip* a full view affordably.** `edge_ride` needs only `self`,
`world.zone`, and `tick`, so its reader skips everything else — and
skipping still costs ~28 fuel per skipped byte, which puts a 3,401-byte
view with a populated 32-seat `tracks` list at ~95,000 fuel against a
50,000 budget. The only way to read a full legacy view inside `StepFuel`
was an unsound substring search over the raw bytes, which is how it was
first written and why it was rejected. So the cost is not a property of
how well the parser is written, or of how much of the document a play
cares about; it is a property of the format.

## The shape

**Endianness and alignment.** Little-endian throughout — wasm32 is
natively little-endian, so an `i32.load` is one instruction. Every scalar
is 4-byte aligned and every record size is a multiple of 4, so no guest
ever needs an unaligned or byte-assembled read.

**Header, fixed 32 bytes.**

| offset | size | field |
|---|---|---|
| 0 | 4 | magic `'P','V','1',0` |
| 4 | 2 | `format_version` (starts at 1) |
| 6 | 1 | `mode` (0 ctf, 1 koth, 2 br) — replaces the `mode.is_*` guard paths |
| 7 | 1 | `section_count` |
| 8 | 4 | `tick` |
| 12 | 4 | pad, zero — so `epoch` lands on its natural 8-byte boundary |
| 16 | 8 | `epoch` (u64; JSON carried this as a string to survive JS) |
| 24 | 4 | `frame_bytes` (total, so a guest can bound every offset it computes) |
| 28 | 4 | reserved, zero |

Still 32 bytes. The pad at 12 is not waste: it buys `epoch` a natural
`i64.load`, which is the only 64-bit field in the frame.

**Section table**, immediately after the header: `section_count` entries
of 12 bytes — `kind: u16`, `record_count: u16`, `record_stride: u16`,
`pad: u16` (zero), `offset: u32` (from frame start). Kinds are a closed
enum: self, world, zone, tracks, aggressors, kill_feed, items, shouts,
hazard_grenades, hazard_blast_cues, hazard_sprays, own_throw,
standing_intent.

`record_stride` is what makes the compatibility promise below
structurally true rather than merely asserted: a guest indexes record `i`
at `offset + i * record_stride` using the stride the *frame* declares,
and reads only the leading bytes of each record that its own build knows
about. So the engine can grow a record and every older play keeps
indexing correctly.

This table is the whole point. **A play reads only the sections it uses,
at O(1) cost, and its fuel bill is proportional to the fields it touches
rather than the frame size.** `edge_ride` reads the header and the zone
section and pays for nothing else, no matter how many tracks the frame
carries.

**Records** are fixed-size, one C-like struct per kind, sized at the
existing element caps (32 tracks, 16 aggressors, 32 kill-feed, 32 items,
32 shouts, 8 grenades, 4 blast cues, 8 sprays). Optional fields carry an
explicit `present` bit in a per-record flags word — the JSON reader's
presence bits, made cheap. Absent is never zero-that-lies: an anonymous
aggressor's seat stays distinguishable from seat 0, which was a real
trap in the JSON reader.

**Rectangles.** Every rectangle is four `i32` fields in schema order:
`x, y, w, h`. This matches the JSON `play_view.schema.json` contract exactly;
binary encoders must not switch to corner form.

**Strings.** Team names are a closed 16-name set, so a record carries a
`team_id: u8`, not a string. The only genuinely free-form text is shout
content (≤10 bytes by schema). Put those in one tail blob with
`(offset, len)` pairs in the shout records, so no other section ever
touches a variable-length field.

**Versioning replaces JSON's `additionalProperties: true`.** The
direction rule stands and gets cheaper. A guest ignores section kinds it
does not know, and within a section it indexes by the frame's declared
`record_stride` while reading only the leading fields its own build knows
about — so both a new section and a grown record leave an older play
working. That is the same compatibility promise the JSON schema made,
enforced by structure instead of by a parser's tolerance.

## The cap, corrected by measurement

The original rule assumed reader fixed cost plus a full scan of a maximum-size
view must fit 60% of `StepFuel`, i.e. 30,000 fuel. That assumption was wrong
for a typed full decode. Measurement corrected it:

- A reader that decodes every section into typed structs measures roughly
  **17-22 fuel per byte** on completed rows, not 1-2.
- The required skeleton costs about **9,786 fuel** in the measured release
  row.
- A 32-track all-section frame at **1,484 bytes** costs **29,130 fuel** and
  completes.
- The largest all-section proportional frame that completed was **2,964
  bytes** at **41,432 fuel**.
- The **4,532-byte** proportional frame exhausted `StepFuel`.

**The cap splits, and this is deliberate.** The binary play frame gets
its own constant at **8,192 bytes** — that is the number this spec names
and the one a guest's arithmetic is bounded by. The socket and replay
copy keeps `MaxViewFrameBytes = 32,768` exactly as it is: nothing parses
that copy inside a fuel budget, P0 measured a real maximum of 12,202
bytes for it, and de-provisioning a cap that is not hurting anyone would
be churn for its own sake.

The acceptance basis therefore changes. The ruled **8,192-byte** cap stays, but
not because every play can afford a blind full-frame decode. That was the
JSON-era question, mandatory only because finding any field required parsing or
skipping the whole document. Under the binary frame, a play is expected to use
the section table and read the sections it actually needs. The acceptance is:
every reference play affords the sections it reads with at least 50% of
`StepFuel` left on a maximum frame. The measured rows satisfy that: `edge_ride`
uses 3,508 fuel and `pact` uses 20,117 fuel on populated 32-track BR frames.

**One model, two encoders, no divergence.** The two copies are renderings
of the same per-seat view state, and they must never disagree about what
the seat knows — the fog rules, the element caps, and the deterministic
selection that runs *before* encoding are properties of the model, not of
either encoding. Enforce it with a row-equivalence test: encode the same
view state both ways and assert field-for-field agreement across every
section and record. A divergence there is a fog bug or a selection bug,
and it should fail loudly rather than show up as two plays disagreeing
about the same tick.

## The context boundary: make it binary too

`play_init` receives the context (roster, seat identities, duo pairings,
mode) under `InitFuel` = 500,000. JSON would survive there — at ~50
instructions per byte, 500,000 fuel parses ~10,000 bytes, so a 4,096-byte
JSON context costs ~205,000, or 41% of the init budget. So this is not
forced by arithmetic.

**Recommend binary anyway, and delete the guest JSON reader entirely.**
The reason is not fuel, it is surface area: if the context stays JSON,
every play still ships a JSON parser, and we keep paying its costs — ~800
lines inside the guest, and exactly the class of defect the loop-2 cold
review just found in it (malformed scalars accepted, mismatched closers
accepted, a validity flag that a later field could clear). Two formats
also means two specs, two readers, and two sets of goldens. One format
is worth more than the init budget it saves.

Same header/section-table scheme, kinds: roster (32 records: seat, team
id, duo partner seat), self identity, mode and map bounds.

## What stays JSON, deliberately

**Emissions stay canonical JSON.** A play *writes* a small `Intent` or
`CombatPolicy` — a few dozen bytes — and writing is cheap; the expensive
direction is parsing a large document. More importantly the emit
validator, the byte goldens, the replay reconstruction, and the canonical
hash contract are all built on those bytes. Nothing about this ruling
touches the guest-to-engine direction.

So the boundary becomes asymmetric on purpose: **engine to play, binary;
play to engine, canonical JSON.** Say that plainly in the design
amendment, because the asymmetry will look like an inconsistency to
anyone who does not know the measurement.

## Consequences to sequence

1. Lane A's view producer writes the frame (it owns the view surface).
   Their encode acceptance gets *easier*: no canonicalization, no string
   escaping, fixed-size memcpy per record.
2. Lane C's SDK replaces `readViewInto` with typed offset accessors; the
   guest JSON reader and its fixtures are deleted, and with them the
   cold-review findings against it. The `play_view.schema.json` stays as
   the socket/replay contract.
3. The new binary-frame constant (8,192) and the §4.3 / H.1 design rows
   land once, with this spec cited, in lane A's package.
   `MaxViewFrameBytes` itself stays at 32,768 for the socket/replay copy.
4. Goldens become byte-fixtures of frames rather than JSON documents,
   which makes them stricter, not looser.
5. `edge_ride` needs no change: it already decodes only self, zone, and
   tick, and the migration replaces its narrow reader with two accessor
   calls.

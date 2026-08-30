# The play-calling shell's wire schemas

Normative key names, shapes, and caps for every JSON payload the shell's
protocol carries (docs/designs/strategy-play-calling-shell-2026-08-29.md;
sections cited per file). These files are the contracts-first commit's
half of the wire contract; the byte-golden fixtures in
`tests/fixtures/shell/` are the other half, and
`src/shell/canonical.nim` is the one encoding both are stated in.

Canonical encoding (Appendix P.1, binding for every producer):

- Object keys sorted byte-wise ascending; no insignificant whitespace.
- Set kinds sorted + deduplicated before encoding; ordered-list kinds
  keep their order (order is meaning; duplicates rejected by name).
- Integers are JSON numbers; floats use shortest-round-trip formatting
  (an integral float keeps its `.0`).
- Every 64-bit identity (`upload_id`, `proposal_id`, `epoch`, ordinals,
  generations, marks) is a decimal string, no leading zeros, full uint64
  range. A numeric or malformed spelling is a schema rejection.
- Neutral/absent optional fields are omitted, so two semantically equal
  values encode byte-identically. "Neutral" is empty/false/the declared
  default.
- Unknown fields are ignored on decode by BUILT PLAYS (that is what makes
  adding fields compatible, §5); the ENGINE rejects unknown fields in
  anything a client sends (calls, parameters: Appendix P.1).

Sizes: a payload's cap (`MaxContextBytes`, `MaxViewFrameBytes`,
`MaxControlEnvelopeBytes`, `StatusEntryMaxBytes`, `MaxCallBytes`) is
enforced on the encoded bytes; element caps applied BEFORE encoding make
the maximum a computable constant (§5).

Team names, wherever a schema says `<team>`: the engine's `teamText`
vocabulary — red, blue, green, yellow, black, silver, ivory, pink,
umber, rust, orange, plum, lime, navy, azure, peach. Roster references
use Appendix P.1's prefix-tagged spellings: `"seat:<0..31>"`,
`"duo:<team>"` (valid only in mode `br`, where a duo IS a team).

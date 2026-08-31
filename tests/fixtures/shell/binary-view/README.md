Fixed-layout binary play-view fixtures.

Provenance: these fixtures pin the amended `BINARY-VIEW-SPEC.md` frame shape,
not a decoder round trip. `thin.hex` is the minimal BR view from
`baseSource()` in `tests/test_shell_binary_view.nim`; its offsets are
hand-derived in that test from `32 + section_count * 12` and the fixed strides.
`real-max.hex` is the max-cardinality fixture from `maxSource()` in the same
test; its table offsets are likewise hand-derived in the test comment from the
section record counts and fixed strides. Payload values are the literal fixture
source values encoded according to the spec's little-endian scalar rules.
`context.hex` is the compact BR play-context frame from the context test; its
offset and size arithmetic is recorded next to the assertion.

The fixtures deliberately cover the three PM amendments: 32-byte realigned
header with `epoch` at byte 16, 12-byte section entries including
`record_stride`, and the binary-only 8192-byte cap while JSON remains capped by
`MaxViewFrameBytes`.

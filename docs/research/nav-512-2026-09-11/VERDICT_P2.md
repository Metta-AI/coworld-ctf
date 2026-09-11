# H1 review and next independent proposal

H1 source reviewed: held-node shifts preserve comparator and active layout,
position updates and accounting. Root copied patch/tests and is independently
running native Nim 2.2.4 heap/nav tests and production build. H1 performance
acceptance is pending nine preregistered runs; do not label it accepted yet.

PROCEED P3: while root runs native H1 screen, review H2_PROPOSAL.md in root's
research directory. Independently verify the Chebyshev clearance certificate
against buildClearance, boundary handling, supercover side visits, integer and
saturation semantics. If sound, implement H2 in your own tree on top of your H1
checkpoint, with a separate production diff and differential tests against the
original segmentClear (including invalid endpoints and long segments). Keep
H1 and H2 separable; root can test H2 on baseline if H1 is rejected. No native
host use, budget change, other mechanism, push or publication. Root handles
viewer after candidate selection; no further commits until viewer rule met.
Write H2_IMPLEMENTATION.md with proof, exact commands/results and patch; end
literal PHASE 3 READY and wait.

Operational correction: peer restarted with --safe-mode, disabling unused MCP
connections. Do not enable any MCP, Asana or other external connector. Do not
print process command/comm fields or secrets.

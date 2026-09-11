# Root H3 implementation review

H2 results are in root H2/RESULT.md and H2/results.json: median total ratio
0.896457 vs original512, but1.009365 vs256, p501.057472, max1.027067 and
misses149 vs104. Exact semantics, all three pairs consistent. H2 passes stage
but fails512. We keep that failure and move to a new mechanism.

PROCEED P7: review root H3_CARD.md, H3/H3_production.patch and the three actual
root source files. Root implemented only11 leaf annotations (inline plus
stackTrace:off), including one inBounds proc, not two. Bounds and overflow
checks remain; global production flags unchanged. H3/diagnostic_probe.nim
locally proves an IndexDefect still raises with diagnosticCaller in its trace
and no setPosition leaf frame. Native checks/build are next. H3's same-budget
parent is H1+H2 at512, not original512, so a pass measures incremental benefit.

Read-only: verify exactness, source scope, diagnostic tradeoff, predicate/error
semantics, and any risk of inline helpers accessing private fields. Do not
edit your source tree or root files. Write H3_PEER_REVIEW.md ending literal
PHASE 7 READY and wait. Keep QUALIFICATION_PLAY files in your tree for root
copy; root will validate and run them after training candidate selection.

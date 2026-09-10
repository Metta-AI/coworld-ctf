VERDICT: GO

The seven corrections close the Round 2 blockers. The design now has a valid
fixed-point search metric, an unambiguous side-node graph, transactional route
publication, bounded query work, an origin-free zone clock, exhaustive
connectivity qualification, and traversal-ordered hazard pricing.

Residual implementation-proof notes:

- State the hop-field memo accounting precisely in the final design: either
  clear the 110 KB value array per query, or include the generation-stamp array
  in the retained-memory total. Do not describe a stamped memo as only the
  value-array cost.
- Define the octile heuristic over cell-index deltas (or explicitly divide
  anchor-pixel deltas by 8), and include the rounding rule in the golden oracle
  so the integer implementation and reference cannot disagree by convention.
- The zone-aware graph search carries one cost/physical-length label per node.
  Because later hazard prices depend on physical arrival time, qualification
  should include an adversarial case where a slightly dearer but shorter prefix
  reaches a later segment before paint. If the single-label search misses the
  intended safe route, retain an earliest-arrival alternative label rather than
  relaxing the playing-tick cap.

These are concrete implementation and qualification checks, not unresolved
architecture decisions, and they fit within the accepted gates and fallback.

VERDICT2 DONE

# Possible H4: smaller field-mint heap payload (not selected)

Only consider after H3 results and remaining-cost attribution. Do not change
mint accounting or spend less work merely to display512. Keep64-bit generation
stamps and all original map/index ranges.

Observation: every mint HeapNode is constructed with priority == cost, and the
minter compares current.cost to the same distance scale. Its heap comparator
compares priority first, then cost, then x/y. When priority ties, cost necessarily
ties too. A mint-specific payload could therefore omit the duplicate cost
float (40 to32 bytes on amd64, with all integer fields still native64-bit),
use priority as current cost and skip that redundant comparison. General A*
nodes must retain cost because their priority includes the heuristic.

A shared generic fixed-heap implementation with two concrete payload types
would have a concrete second use (A* and mint), avoiding duplicated sift code.
This is more code than a pragma and is not justified without a remaining mint
bottleneck. Preserve the exact priority/x/y ordering, fixed capacity, positional
bookkeeping, units, suspension and final rasters. For fingerprint comparison,
normalize the mint node to the original logical fields with cost=priority.
Require a minter-specific original-heap differential and full same-budget
end-to-end parity. No generation narrowing, no guessed int32 capacity bound,
no new memory allocation, no selection or timing yet.

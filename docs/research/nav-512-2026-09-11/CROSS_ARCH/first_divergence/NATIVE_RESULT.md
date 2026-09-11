# Three-tick native comparison

All stored heap priorities/costs, gScores, integer heap order, record order,
closed sets and predecessors match the Mac for ticks0-2. All51,832 dump lines
match once the additional recomputed heuristic diagnostic columns are removed.
Six raw-line differences are the two same hypot inputs repeated across three
ticks; their one-bit hypot difference rounds away in cost+hypot. They do NOT
show a stored-priority divergence. The original full-state difference therefore
appears outside this bounded dump, or in state this dump does not include.

The bounded probe is complete; no cross-platform full-state parity claim and
no silent extension of its three-tick limit. Same-platform candidate exactness
is independently green. Raw outputs and native-comparison.json are retained.

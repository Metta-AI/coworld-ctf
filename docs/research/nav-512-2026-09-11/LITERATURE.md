# Existing approaches considered

The archived META_RESEARCH.md and RESEARCH_LOOP.md already survey and implement
the research workflow; this restart reuses that machinery.

A fresh primary-source check on September11 confirms relevant alternatives:
- [Weighted Jump Point Search, AAAI2023](https://ojs.aaai.org/index.php/AAAI/article/view/26458):
  the abstract describes symmetry pruning for weighted grids, with a tie-breaking
  policy. It is a candidate algorithm family if cheaper exact execution is
  insufficient, not a drop-in preservation of this planner's route order.
- [MovingAI A* explanation](https://movingai.com/astar.html): the lab's example
  compares octile and Euclidean heuristics. A heuristic change could reduce
  search, but would alter expansion/route choices and need quality validation.

Current local opportunities are more specific: eliminate repeated immutable
legality/nearest-cell work without changing costs, ordering or consumed units.
A generic pathfinding library would not automatically preserve the resumable
state machine, danger sampling and deterministic fingerprints. Profile first
and prefer existing BodyMap data and code paths; add no framework dependency.

## Local-only access to stencil planner internals for P0 workspace accounting.
## `planner` resolves only through --path:$STENCIL_LAB_DIR.

include planner

type PlannerWorkspaceStats* = object
  latticeW*, latticeH*: int
  seenBytes*, closedBytes*, scoreBytes*, cameFromBytes*, heapBytes*: int

proc benchmarkPlanPath*(state: var PlannerState, map: WorldMap,
                        danger: DangerField, start, goal: Point,
                        profile = PlanCostProfile(dangerWeight: 1.0),
                        avoid = none(Point)): PlanResult =
  state.planPath(map, danger, start, goal, profile, avoid)

proc benchmarkWorkspaceStats*(state: PlannerState): PlannerWorkspaceStats =
  PlannerWorkspaceStats(
    latticeW: state.latticeW,
    latticeH: state.latticeH,
    seenBytes: state.seenGeneration.len * sizeof(uint32),
    closedBytes: state.closedGeneration.len * sizeof(uint32),
    scoreBytes: state.gScore.len * sizeof(float),
    cameFromBytes: state.cameFrom.len * sizeof(int32),
    heapBytes: state.queue.len * sizeof(QueueNode))

proc totalBytes*(stats: PlannerWorkspaceStats): int =
  stats.seenBytes + stats.closedBytes + stats.scoreBytes +
    stats.cameFromBytes + stats.heapBytes


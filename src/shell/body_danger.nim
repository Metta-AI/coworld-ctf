## Per-seat danger raster shared by body navigation and combat scoring.

import body_map
import types as shellTypes

const PlanStepPx* = 4

type
  PlanCostProfile* = object
    dangerWeight*: float

  BodyDangerField* = object
    values*: seq[float32]
    gridW*, gridH*: int
    maximum*: float32

proc planCostProfile*(kind: shellTypes.CostProfile): PlanCostProfile =
  case kind
  of shellTypes.cpDefault: PlanCostProfile(dangerWeight: 1.0)
  of shellTypes.cpCarrier: PlanCostProfile(dangerWeight: 2.5)
  of shellTypes.cpHunter: PlanCostProfile(dangerWeight: 0.25)

proc sample*(field: BodyDangerField, map: BodyMap, point: BodyPoint): float =
  if field.values.len != map.gridWidth * map.gridHeight:
    return 0.0
  let cell = map.cellOf(point)
  field.values[cell.y * map.gridWidth + cell.x].float

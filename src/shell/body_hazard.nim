## The zone paint-arrival hazard, projected onto the nav grid.
##
## WHY THIS EXISTS. The planner's cost function had no zone term: the
## BodyDangerField is built exclusively from enemy line-of-sight sources, so a
## cog would happily settle a route straight through ground that becomes lethal
## paint before it arrives. Under `zoneDamageByPaint` the damage verdict is a
## threshold read of the zone module's paint-arrival field, so the ground that
## kills you is exactly this array — not the zone RECTANGLE a play can see.
##
## READ-ONLY BY CONTRACT. This module CONSUMES a snapshot of the zone module's
## damage surface. It must never write to, re-solve, or re-quantize that field.
## The arrival field is hash-load-bearing state: arrival tick -> painted verdict
## -> damage -> hp -> positions/deaths -> gameHash. Changing its VALUES (even a
## "harmless" re-quantization onto another grid) is a hash-visible gameplay
## change and belongs to the zone lane, never to a pathing change. What we do
## here is a strictly conservative DOWNSAMPLE into a private array the sim never
## reads back.
##
## MONOTONICITY IS LOAD-BEARING. The safe-by-time prune/price in body_planner
## is exact only because arrival ticks never recede (the zone field's own
## contract: "MONOTONE by construction ... arrival ticks never produce receding
## paint"). If anyone ever makes paint recede, the argument in
## body_planner.advanceAstar dies with it — see the comment there.

const
  HazardNeverArrives* = 0xFFFF'u16
    ## Mirrors ctf/zone_field.ZoneNeverArrives. The equality is asserted at the
    ## one seam that carries values across (ctf/server.nim's install call), so
    ## this module needs no ctf import and the planner stays free of zone types.

  HazardRiskRampTicks* = 96
    ## How much dry margin (ticks between our estimated arrival and the paint's)
    ## counts as "safe enough to be free". Beyond this the term is exactly 0.0,
    ## which is what keeps the hazard price local to the closing front instead
    ## of re-pricing the whole board.

  HazardRiskMax* = 12.0
    ## Saturation of the risk term on ground that is already painted when we
    ## would get there. FINITE ON PURPOSE (staged decision, plan §3.1): a hard
    ## feasibility prune can make a goal unreachable and hand the follower a
    ## `hasNoPath` state — the exact shape of the round-3633 "14/16 cogs died
    ## standing on spawn" failure. A large finite price makes paint the last
    ## resort while keeping "cross the paint because it is the only way out" a
    ## route the planner can still find. Do not convert this to Inf or to a
    ## `continue`; that trade was considered and refused.

type
  BodyHazardField* = object
    ## Per NAV cell, the tick paint reaches it, or HazardNeverArrives.
    values*: seq[uint16]
    gridW*, gridH*: int
    sourceW*, sourceH*, sourceCellPx*: int
      ## Provenance of the projection, so a re-install from a differently
      ## shaped source is detectable rather than silently mixed.

func hasField*(field: BodyHazardField): bool {.inline.} =
  ## A dark episode (or one before the zone field is built) carries an empty
  ## field, and every consumer branches to its pre-hazard arithmetic on this.
  field.gridW > 0 and field.gridH > 0 and
    field.values.len == field.gridW * field.gridH

func arrivalAt*(field: BodyHazardField, cellX, cellY: int): int {.inline.} =
  ## Off-grid and dark both read as "never paints", so no caller can turn a
  ## missing field into a phantom hazard.
  if not field.hasField or cellX < 0 or cellY < 0 or
      cellX >= field.gridW or cellY >= field.gridH:
    return HazardNeverArrives.int
  field.values[cellY * field.gridW + cellX].int

func projectHazardField*(navW, navH, navCellPx: int,
                         sourceW, sourceH, sourceCellPx: int,
                         arrival: openArray[uint16]): BodyHazardField =
  ## Conservative min-projection of the zone module's 4px damage surface onto
  ## the 8px nav grid.
  ##
  ## MIN, NOT AVERAGE: a nav cell is as dangerous as its earliest-painted
  ## quarter. Integer min only — no float math, no new libm call, nothing that
  ## could diverge between build targets. The projection is never later than
  ## any source cell it covers, which is the property the planner's
  ## safe-by-time argument needs (test: "projection is conservative").
  ##
  ## Cells the source does not cover keep HazardNeverArrives, which is also
  ## what a wall cell and a cell inside the schedule's final safe rect carry —
  ## all three mean "this never becomes lethal ground", which is the only thing
  ## the planner asks.
  if navW <= 0 or navH <= 0 or navCellPx <= 0 or
      sourceW <= 0 or sourceH <= 0 or sourceCellPx <= 0 or
      arrival.len != sourceW * sourceH:
    return BodyHazardField()
  result = BodyHazardField(values: newSeq[uint16](navW * navH),
    gridW: navW, gridH: navH, sourceW: sourceW, sourceH: sourceH,
    sourceCellPx: sourceCellPx)
  for index in 0 ..< result.values.len:
    result.values[index] = HazardNeverArrives
  for cellY in 0 ..< navH:
    let
      loY = cellY * navCellPx div sourceCellPx
      hiY = min(sourceH - 1, ((cellY + 1) * navCellPx - 1) div sourceCellPx)
    if loY > hiY or loY >= sourceH:
      continue
    for cellX in 0 ..< navW:
      let
        loX = cellX * navCellPx div sourceCellPx
        hiX = min(sourceW - 1, ((cellX + 1) * navCellPx - 1) div sourceCellPx)
      if loX > hiX or loX >= sourceW:
        continue
      var best = HazardNeverArrives
      for sourceY in loY .. hiY:
        let row = sourceY * sourceW
        for sourceX in loX .. hiX:
          let value = arrival[row + sourceX]
          if value < best:
            best = value
      result.values[cellY * navW + cellX] = best

func staysDryUntil*(field: BodyHazardField, cellX, cellY, tick: int): bool
    {.inline.} =
  ## The seed predicate of the zone-safe flow field: ground that is still dry
  ## at `tick`. Never-arriving ground (the schedule's final safe rect, and any
  ## cell the source does not cover) always qualifies.
  ##
  ## THE SENTINEL IS INFINITY, NOT 65535. Comparing the raw value against the
  ## tick works right up to tick 65535 and then silently drops the final safe
  ## rect out of the seed set — a bug that only appears in a 45-minute episode,
  ## which is exactly the kind that ships. Test it explicitly, never implicitly.
  let arrival = field.arrivalAt(cellX, cellY)
  arrival >= HazardNeverArrives.int or arrival > tick

func hazardRisk*(field: BodyHazardField, cellX, cellY, etaTicks: int): float
    {.inline.} =
  ## The planner's per-edge price for crossing this cell at our estimated
  ## arrival tick. Zero on ground that stays dry well past the ETA, a linear
  ## ramp as the ETA closes on the arrival, saturated at HazardRiskMax on
  ## ground that is already painted when we would get there.
  ##
  ## All inputs are integers (ticks and cells) on purpose — the only float in
  ## the term is the final ramp division, which mirrors the existing danger
  ## term's float shape rather than adding a new numeric regime.
  let arrival = field.arrivalAt(cellX, cellY)
  if arrival >= HazardNeverArrives.int:
    return 0.0
  let slack = arrival - etaTicks
  if slack <= 0:
    return HazardRiskMax
  if slack >= HazardRiskRampTicks:
    return 0.0
  HazardRiskMax * float(HazardRiskRampTicks - slack) / float(HazardRiskRampTicks)

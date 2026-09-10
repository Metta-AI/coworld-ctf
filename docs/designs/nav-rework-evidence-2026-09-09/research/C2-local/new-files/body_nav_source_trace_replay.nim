## DIAGNOSTIC ONLY (C2 trace replay). Not imported by production code.
##
## Includes body_nav so a recorded NAVSRC trace's ordered selected source
## points can be fed straight into the selected-source production seam
## (`selectedDangerPoints` / `rebuildSelectedDanger`) without re-running
## `selectDangerSources`, which would need the original self positions and
## full candidate lists the trace does not carry. Compile with
## -d:dangerSourceCacheCounters to read hit/miss counts.

include body_nav

proc replayRecordedSelection*(system: BodyNavSystem, seat, tick: int,
    points: openArray[BodyPoint]) =
  ## Installs the recorded ordered selection on `seat` and runs the same
  ## rebuild the scheduled changed branch runs (`rebuildSelectedDanger`).
  ## Publishing is skipped: the raster is what the replay checks.
  doAssert points.len <= MaxDangerSources
  let target = system.seats[seat]
  for index, point in points:
    target.selectedDangerPoints[index] = point
    target.selectedDangerSeats[index] = -1
  target.selectedDangerCount = points.len
  target.rebuildSelectedDanger(system.map, tick)

when defined(dangerSourceCacheCounters):
  proc sourceCacheHitsMisses*(system: BodyNavSystem): tuple[hits, misses: int] =
    (system.seats[0].dangerSourceCache.hits,
     system.seats[0].dangerSourceCache.misses)

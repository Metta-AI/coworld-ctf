## Local-only benchmark adapter. `action` resolves only through the compile
## command's STENCIL_LAB_DIR path; no private source is copied here.

include action

proc benchmarkTargetCandidates*(belief: Belief): seq[TargetCandidate] =
  targetCandidates(belief)


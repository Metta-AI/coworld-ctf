## Local-only access to stencil firefight internals for the phase-7
## differential. `fight` resolves only through --path:$STENCIL_LAB_DIR.

include fight

proc benchmarkScoreCmp*(a, b: TargetScore): int =
  scoreCmp(a, b)

proc benchmarkGenericScoreCmp*(a, b: TargetScore): int =
  genericScoreCmp(a, b)

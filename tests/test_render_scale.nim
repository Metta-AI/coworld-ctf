import
  std/unittest,
  ctf/global

## The per-map spectator supersample cap. Board dimensions here are the real
## generated sizes: the 2-team shell is 1235x659 scaled by the class factor,
## the 4-team shell 960x960 (see arena.nim scaledGenShell/scaledGenShell4).
##
## The cap is DERIVED from a measured working-set model (full derivation
## lives on MaxSupersampledMapPixels itself, ctf/global.nim), not from an
## eyeballed "verified at 2x in the hosted viewer" claim -- that claim was
## the exact failure mode this cap replaced, and this test used to carry it
## as a pin. Two measured anchors feed the model:
##     0.81 M px (standard 1235x659)  @ 2x -> plateaus 467 MB, measured
##     5.50 M px (BR giant 3211x1713) @ 1x -> plateaus 763 MB, measured
## which gives ~555 MB of steady state per megapixel at 2x and predicts the
## standard board's 467 MB to within 4%. The board this test used to pin at
## 2x -- 3211x1713 -- actually ABORTS with ABORTING_MALLOC around frame 3000
## of a 4593-tick episode when forced to 2x: "verified at 2x" had never been
## a full-episode run, only a look.
##
## SIDE EFFECT of the resulting 2_000_000 px bound (stated here, not
## rediscovered per-reader): boards between 2 M and 6.2 M px -- notably the
## 4-team giant square (2496x2496 = 6.2 M px) -- now emit at 1x where they
## used to emit at 2x. Measured cost on the BR board at match-watching zoom:
## mean |delta| 0.74/255, 1.81% of pixels differing by more than 8/255 --
## visible only zoomed deep into wall art. That tradeoff is flagged for
## launch review (br-integrate merge commit, flag b), not re-litigated here.

func expectedRenderScale(mapWidth, mapHeight: int): int =
  ## Mirrors boardRenderScaleFor's own derivation, so this test can never
  ## again silently disagree with the cap it exists to guard. What it
  ## actually pins is the LADDER SIZES against the line -- a generator
  ## change nudging a class across 2 M px is the real thing that drifts.
  if mapWidth * mapHeight > MaxSupersampledMapPixels: 1 else: RenderScale

suite "board render scale cap":
  test "every ladder size class matches the derived cap":
    # standard (2-team 1235x659), BR giant (2-team 2.6x: 3211x1713), and the
    # 4-team giant square (2496x2496). The two giants sit above the 2 M px
    # line (5.50 M / 6.23 M px); the standard class (0.81 M px) does not.
    check boardRenderScaleFor(1235, 659) == expectedRenderScale(1235, 659)
    check boardRenderScaleFor(3211, 1713) == expectedRenderScale(3211, 1713)
    check boardRenderScaleFor(2496, 2496) == expectedRenderScale(2496, 2496)

  test "the policy has a real shape, not just a tautology: standard 2x, colossal 1x":
    # Absolute anchors, independent of expectedRenderScale above, so a
    # change that breaks boardRenderScaleFor's actual branch direction (not
    # just its threshold value) still fails here even though the derived
    # check would silently agree with whatever the code now does.
    check boardRenderScaleFor(1235, 659) == 2
    check boardRenderScaleFor(6422, 3427) == 1   # 2-team colossal 5.2x
    check boardRenderScaleFor(4992, 4992) == 1   # 4-team colossal 5.2x

  test "predicted viewer footprint fits wasm32 for every supported class":
    check predictedViewerRenderBytes(3211, 1713) < WasmViewerBudgetBytes
    check predictedViewerRenderBytes(2496, 2496) < WasmViewerBudgetBytes
    check predictedViewerRenderBytes(6422, 3427) < WasmViewerBudgetBytes
    check predictedViewerRenderBytes(4992, 4992) < WasmViewerBudgetBytes

  test "a future beyond-colossal class trips the viewer preflight":
    # 2x colossal on each axis: even at 1x the map-sized buffers alone
    # exceed the 32-bit address space, so ctf_load_replay must refuse it
    # with a diagnostic instead of aborting mid-bake.
    check predictedViewerRenderBytes(9984, 9984) > WasmViewerBudgetBytes

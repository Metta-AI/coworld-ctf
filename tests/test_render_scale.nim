import
  std/unittest,
  ctf/global,
  ctf/hex

## The per-map spectator supersample cap. Board dimensions here are the REAL
## shipped hex classes (`HexSizes`) — since GV38 every board is a flat-top
## LANDSCAPE hexagon inscribed in its bounding box, so the old rectangular
## shells (1235x659 scaled per class, the 4-team 960x960 square) no longer
## exist and asserting them tested nothing but the arithmetic itself.
##
## The cap exists for the wasm32 static replay viewer: at RenderScale 2 the
## hot + cold arena bakes cost mapPixels*16 bytes and a colossal board blew
## through the 2 GB address space before its first frame (empty-error load
## failure); at 1x its wire carries the same byte volume as the proven
## giant 2x wire.
##
## NOTE the buffers are sized by the BOUNDING BOX, not the hexagon: a regular
## hexagon fills exactly 3/4 of its box, so ~25% of every bake is transparent
## void. That waste is deliberate (the bakes stay plain rectangles) and it is
## why these figures are the honest ones to budget against.

suite "board render scale cap":
  test "every ladder size class keeps the supersample":
    ## small .. giant. `colossal` is override-only and handled below.
    for c in [hxSmall, hxStandard, hxLarge, hxHuge, hxGiant]:
      let (w, h) = HexSizes[c]
      check boardRenderScaleFor(w, h) == RenderScale

  test "colossal boards emit at 1x":
    let (w, h) = HexSizes[hxColossal]
    check boardRenderScaleFor(w, h) == 1

  test "giant clears the supersample cap, but only just":
    ## The giant hexagon is 7,327,771 px against an 8,000,000 px cap — 91.6% of
    ## it, i.e. 8.4% headroom. Growing the class table by as little as 4.5% on
    ## each axis would silently drop giant from 2x to 1x and halve the rendered
    ## resolution of every hosted replay on that class, with nothing to
    ## announce it. Pinned so that change trips a test instead of shipping.
    let
      (w, h) = HexSizes[hxGiant]
      px = w * h
    check px < MaxSupersampledMapPixels
    check px * 100 > MaxSupersampledMapPixels * 91   # >91% of the cap: tight.
    check px * 100 < MaxSupersampledMapPixels * 92

  test "predicted viewer footprint fits wasm32 for every supported class":
    for c in HexSizeClass:
      let (w, h) = HexSizes[c]
      check predictedViewerRenderBytes(w, h) < WasmViewerBudgetBytes

  test "colossal is the tight class and its margin is pinned":
    ## Colossal at 1x predicts ~1.17 GB against the 1.6 GB working-set ceiling
    ## — a 1.36x margin, the smallest of any class. The hex flip GREW it
    ## (29.3M px vs the old 4992x4992 rectangle's 24.9M px, +17.6%), so this is
    ## the number to watch: it is the class that first meets the 2 GB address
    ## space.
    let
      (w, h) = HexSizes[hxColossal]
      predicted = predictedViewerRenderBytes(w, h)
    check predicted * 13 < WasmViewerBudgetBytes * 10   # margin > 1.30x
    check predicted * 14 > WasmViewerBudgetBytes * 10   # margin < 1.40x

  test "a future beyond-colossal class trips the viewer preflight":
    ## 2x colossal on each axis: even at 1x the map-sized buffers alone
    ## exceed the 32-bit address space, so ctf_load_replay must refuse it
    ## with a diagnostic instead of aborting mid-bake.
    let (w, h) = HexSizes[hxColossal]
    check predictedViewerRenderBytes(w * 2, h * 2) > WasmViewerBudgetBytes

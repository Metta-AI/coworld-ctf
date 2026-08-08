## mask_diff — what did a change ADD to a wall mask?
##
## Two renders of the same map from two builds, composited so the delta is the
## only thing that reads: shared stone stays quiet, ADDED stone is loud. A
## side-by-side pair cannot answer "which pixels closed this route"; this can.
##
##   nim c -d:release -r tools/mask_diff.nim base.png new.png out.png

import std/[os, strformat], pixie

when isMainModule:
  if paramCount() < 3:
    quit "usage: mask_diff <base.png> <new.png> <out.png>"
  let
    a = readImage(paramStr(1))
    b = readImage(paramStr(2))
  if a.width != b.width or a.height != b.height:
    quit &"size mismatch: {a.width}x{a.height} vs {b.width}x{b.height}"
  var img = newImage(a.width, a.height)
  var added, removed, shared = 0
  for y in 0 ..< a.height:
    for x in 0 ..< a.width:
      let
        sa = a.unsafe[x, y].r < 128
        sb = b.unsafe[x, y].r < 128
      if sa and sb:
        inc shared
        img.unsafe[x, y] = rgba(170, 160, 145, 255)   # shared stone: quiet
      elif sb:
        inc added
        img.unsafe[x, y] = rgba(190, 60, 40, 255)     # ADDED stone: loud
      elif sa:
        inc removed
        img.unsafe[x, y] = rgba(60, 110, 170, 255)    # removed stone
      else:
        img.unsafe[x, y] = rgba(246, 241, 232, 255)   # floor
  img.writeFile(paramStr(3))
  let total = a.width * a.height
  echo &"added={added} ({added * 1000 div total} permille of board)  " &
    &"removed={removed} ({removed * 1000 div total}pm)  " &
    &"shared={shared} ({shared * 1000 div total}pm)"

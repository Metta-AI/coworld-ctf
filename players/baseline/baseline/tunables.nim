## Tunable-constant registry for the baseline bot.
##
## Every numeric behavior constant is DECLARED through one of the `tunable*`
## macros below (see params.nim), which makes it:
##   1. overridable at build time:   nim c -d:tune<Name>=<int> ...
##      (the CI build workflow passes these through NIM_DEFINES)
##   2. range-guarded at compile time: an out-of-range override fails the
##      build with a clear error instead of shipping a nonsense bot
##   3. discoverable: the full registry (name, define, default, valid range,
##      scale, doc) is emitted as JSON by players/baseline/dump_tunables.nim,
##      which the tuning harness consumes (cogamer:
##      cogames/ctf/team/bin/tune.py sync-params).
##
## Floats are integer-scaled: gameplay value = define / scale (deci-scale 10
## for px-precision knobs). `tunableI` declares plain int constants,
## `tunableI32` int32 (nav-field costs).
##
## FEATURE BUILDERS: never introduce a bare numeric behavior constant or an
## inline magic threshold — declare it here-adjacent in params.nim with an
## honest valid range and a doc string saying what it does in gameplay terms.

import std/[macros, json]

type TunableDef* = object
  name*: string     ## gameplay constant name, e.g. "CarrierFireRange"
  define*: string   ## compile-time override key, e.g. "tuneCarrierFireRange"
  default*: int     ## raw define default (already scaled)
  min*: int         ## inclusive raw bound
  max*: int         ## inclusive raw bound
  scale*: int       ## gameplay value = define / scale; 1 for ints
  kind*: string     ## "float" | "int" | "int32"
  doc*: string

var tunableDefs* {.compileTime.}: seq[TunableDef]

proc declStmts(name, kind: string; default, minV, maxV, scale: int): string =
  let d = "tune" & name
  result = "const " & d & " {.intdefine.} = " & $default & "\n"
  result.add "when " & d & " < " & $minV & " or " & d & " > " & $maxV & ":\n"
  result.add "  {.error: \"" & d & " out of valid range [" & $minV & ", " &
             $maxV & "]\".}\n"
  case kind
  of "float":
    result.add "const " & name & "* = " & d & ".float / " & $scale & ".0\n"
  of "int32":
    result.add "const " & name & "* = int32(" & d & ")\n"
  else:
    result.add "const " & name & "* = " & d & "\n"

macro tunableF*(name: untyped; default, minV, maxV, scale: static int;
                doc: static string): untyped =
  ## Float tunable: gameplay constant = tune<name>/scale.
  tunableDefs.add TunableDef(name: name.strVal, define: "tune" & name.strVal,
                             default: default, min: minV, max: maxV,
                             scale: scale, kind: "float", doc: doc)
  parseStmt(declStmts(name.strVal, "float", default, minV, maxV, scale))

macro tunableI*(name: untyped; default, minV, maxV: static int;
                doc: static string): untyped =
  ## Integer tunable (ticks, counts, brads).
  tunableDefs.add TunableDef(name: name.strVal, define: "tune" & name.strVal,
                             default: default, min: minV, max: maxV,
                             scale: 1, kind: "int", doc: doc)
  parseStmt(declStmts(name.strVal, "int", default, minV, maxV, 1))

macro tunableI32*(name: untyped; default, minV, maxV: static int;
                  doc: static string): untyped =
  ## int32 tunable (nav-field costs).
  tunableDefs.add TunableDef(name: name.strVal, define: "tune" & name.strVal,
                             default: default, min: minV, max: maxV,
                             scale: 1, kind: "int32", doc: doc)
  parseStmt(declStmts(name.strVal, "int32", default, minV, maxV, 1))

macro tunablesManifest*(): untyped =
  ## Expands to a JSON string literal of the full registry. Call AFTER all
  ## tunable declarations are imported (see dump_tunables.nim).
  var arr = newJArray()
  for t in tunableDefs:
    arr.add %*{"name": t.name, "define": t.define, "default": t.default,
               "min": t.min, "max": t.max, "scale": t.scale,
               "kind": t.kind, "doc": t.doc}
  newLit(arr.pretty)

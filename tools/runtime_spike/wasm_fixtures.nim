## Tiny core-Wasm fixtures for phase-2 containment. The exact-cap adversarial
## emitter remains phase 4; these helpers encode only the four smoke shapes.

import std/strutils

import ../../src/shell/types

proc uleb(result: var seq[byte]; value: uint32) =
  var remaining = value
  while true:
    var current = byte(remaining and 0x7f)
    remaining = remaining shr 7
    if remaining != 0:
      current = current or 0x80
    result.add current
    if remaining == 0:
      break

proc nameBytes(value: string): seq[byte] =
  result.uleb(value.len.uint32)
  for character in value:
    result.add character.byte

proc addSection(module: var seq[byte]; sectionId: byte; body: seq[byte]) =
  module.add sectionId
  module.uleb(body.len.uint32)
  module.add body

proc moduleHeader(): seq[byte] =
  @[byte 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]

proc oneFunctionModule(params, results, instructions: seq[byte];
    memory: bool): seq[byte] =
  result = moduleHeader()

  var types: seq[byte]
  types.uleb(1)
  types.add 0x60
  types.uleb(params.len.uint32)
  types.add params
  types.uleb(results.len.uint32)
  types.add results
  result.addSection(1, types)

  var functions: seq[byte]
  functions.uleb(1)
  functions.uleb(0)
  result.addSection(3, functions)

  if memory:
    var memories: seq[byte]
    memories.uleb(1)
    memories.add 0x01
    memories.uleb(1)
    memories.uleb(16)
    result.addSection(5, memories)

  var exports: seq[byte]
  exports.uleb(if memory: 2 else: 1)
  exports.add nameBytes("run")
  exports.add 0x00
  exports.uleb(0)
  if memory:
    exports.add nameBytes("memory")
    exports.add 0x02
    exports.uleb(0)
  result.addSection(7, exports)

  var functionBody: seq[byte]
  functionBody.uleb(0)
  functionBody.add instructions
  functionBody.add 0x0b
  var code: seq[byte]
  code.uleb(1)
  code.uleb(functionBody.len.uint32)
  code.add functionBody
  result.addSection(10, code)

proc loopFixture*(): seq[byte] =
  oneFunctionModule(@[], @[], @[byte 0x03, 0x40, 0x0c, 0x00, 0x0b], false)

proc growthFixture*(): seq[byte] =
  oneFunctionModule(@[byte 0x7f], @[byte 0x7f],
    @[byte 0x20, 0x00, 0x40, 0x00], true)

proc outOfBoundsFixture*(): seq[byte] =
  oneFunctionModule(@[], @[],
    @[byte 0x41, 0x80, 0x80, 0x04, 0x28, 0x02, 0x00, 0x1a], true)

proc stackOverflowFixture*(): seq[byte] =
  oneFunctionModule(@[], @[], @[byte 0x10, 0x00], false)

proc functionType(params, results: seq[byte]): seq[byte] =
  result.add 0x60
  result.uleb(params.len.uint32)
  result.add params
  result.uleb(results.len.uint32)
  result.add results

proc addImport(imports: var seq[byte]; moduleName, itemName: string;
    typeIndex: uint32) =
  imports.add nameBytes(moduleName)
  imports.add nameBytes(itemName)
  imports.add 0x00 # function
  imports.uleb(typeIndex)

proc addExport(exports: var seq[byte]; name: string; kind: byte;
    index: uint32) =
  exports.add nameBytes(name)
  exports.add kind
  exports.uleb(index)

proc addFunctionBody(code: var seq[byte]; instructions: seq[byte];
    localGroups: seq[byte] = @[byte 0x00]) =
  var body = localGroups
  body.add instructions
  body.add 0x0b
  code.uleb(body.len.uint32)
  code.add body

proc i32Const(instructions: var seq[byte]; value: uint32) =
  instructions.add 0x41
  var remaining = value
  while true:
    var current = byte(remaining and 0x7f)
    remaining = remaining shr 7
    let done = remaining == 0 and (current and 0x40) == 0
    if not done:
      current = current or 0x80
    instructions.add current
    if done:
      break

proc computeFixture*(): seq[byte] =
  ## A finite, compute-bound loop shared by the fuel/epoch overhead rows.
  var instructions: seq[byte]
  instructions.i32Const(0)
  instructions.add @[byte 0x21, 0x00] # local.set counter
  instructions.i32Const(0)
  instructions.add @[byte 0x21, 0x01] # local.set sum
  instructions.add @[byte 0x02, 0x40, 0x03, 0x40] # block; loop
  instructions.add @[byte 0x20, 0x01, 0x20, 0x00, 0x6a, 0x21, 0x01]
  instructions.add @[byte 0x20, 0x00]
  instructions.i32Const(1)
  instructions.add @[byte 0x6a, 0x22, 0x00]
  instructions.i32Const(100_000)
  instructions.add @[byte 0x49, 0x0d, 0x00, 0x0b, 0x0b, 0x20, 0x01]
  let locals = @[byte 0x01, 0x02, 0x7f] # one group of two i32 locals
  result = moduleHeader()
  result.addSection(1, @[byte 0x01] & functionType(@[], @[byte 0x7f]))
  result.addSection(3, @[byte 0x01, 0x00])
  var exports: seq[byte]
  exports.uleb(1)
  exports.addExport("run", 0x00, 0)
  result.addSection(7, exports)
  var code: seq[byte]
  code.uleb(1)
  code.addFunctionBody(instructions, locals)
  result.addSection(10, code)

proc memoryTouchFixture*(): seq[byte] =
  ## Scans one full 1 MiB memory at 64-byte intervals. The identical module is
  ## compiled under the small- and large-guard configurations.
  var instructions: seq[byte]
  instructions.i32Const(0)
  instructions.add @[byte 0x21, 0x00]
  instructions.i32Const(0)
  instructions.add @[byte 0x21, 0x01]
  instructions.add @[byte 0x02, 0x40, 0x03, 0x40]
  instructions.add @[byte 0x20, 0x01, 0x20, 0x00, 0x28, 0x02, 0x00,
    0x6a, 0x20, 0x00, 0x6a, 0x21, 0x01, 0x20, 0x00]
  instructions.i32Const(64)
  instructions.add @[byte 0x6a, 0x22, 0x00]
  instructions.i32Const(1_048_576)
  instructions.add @[byte 0x49, 0x0d, 0x00, 0x0b, 0x0b, 0x20, 0x01]
  let locals = @[byte 0x01, 0x02, 0x7f]
  result = moduleHeader()
  result.addSection(1, @[byte 0x01] & functionType(@[], @[byte 0x7f]))
  result.addSection(3, @[byte 0x01, 0x00])
  result.addSection(5, @[byte 0x01, 0x01, 0x10, 0x10])
  var exports: seq[byte]
  exports.uleb(2)
  exports.addExport("run", 0x00, 0)
  exports.addExport("memory", 0x02, 0)
  result.addSection(7, exports)
  var code: seq[byte]
  code.uleb(1)
  code.addFunctionBody(instructions, locals)
  result.addSection(10, code)

proc hostileTickFixture*(): seq[byte] =
  ## Imports the maximum-cost step callbacks, performs them all, then loops so
  ## Wasmtime consumes the complete fuel grant and traps.
  result = moduleHeader()

  var types: seq[byte]
  types.uleb(6)
  types.add functionType(@[byte 0x7f], @[byte 0x7f])
  types.add functionType(@[byte 0x7f, 0x7f, 0x7f, 0x7f], @[byte 0x7f])
  types.add functionType(@[byte 0x7f, 0x7f], @[byte 0x7f])
  types.add functionType(@[byte 0x7f, 0x7f, 0x7f, 0x7f, 0x7f, 0x7f],
    @[byte 0x7e])
  types.add functionType(@[byte 0x7f, 0x7f], @[byte 0x7f])
  types.add functionType(@[byte 0x7f, 0x7f, 0x7f], @[])
  result.addSection(1, types)

  var imports: seq[byte]
  imports.uleb(3)
  imports.addImport("play", "nearest_cover", 3)
  imports.addImport("play", "emit", 4)
  imports.addImport("play", "log", 5)
  result.addSection(2, imports)
  result.addSection(3, @[byte 0x03, 0x00, 0x01, 0x02])
  result.addSection(5, @[byte 0x01, 0x01, 0x03, 0x10])
  # One mutable i32 bump pointer, initialized above the fixture JSON.
  result.addSection(6, @[byte 0x01, 0x7f, 0x01, 0x41, 0x80, 0x80, 0x04,
    0x0b])

  var exports: seq[byte]
  exports.uleb(4)
  exports.addExport("memory", 0x02, 0)
  exports.addExport("play_alloc", 0x00, 3)
  exports.addExport("play_init", 0x00, 4)
  exports.addExport("play_step", 0x00, 5)
  result.addSection(7, exports)

  var code: seq[byte]
  code.uleb(3)
  # play_alloc: return bump; bump += len.
  code.addFunctionBody(@[byte 0x23, 0x00, 0x21, 0x01, 0x23, 0x00,
    0x20, 0x00, 0x6a, 0x24, 0x00, 0x20, 0x01],
    @[byte 0x01, 0x01, 0x7f])
  # play_init: reset the allocator for the next invocation, then consume the
  # full InitFuel grant.
  code.addFunctionBody(@[byte 0x41, 0x80, 0x80, 0x04, 0x24, 0x00,
    0x03, 0x40, 0x0c, 0x00, 0x0b, 0x41, 0x00])
  var step: seq[byte]
  step.i32Const(65_536)
  step.add @[byte 0x24, 0x00] # reset bump for the next invocation
  for callIndex in 0 ..< MaxSpatialCallsPerStep:
    step.i32Const((100 + callIndex).uint32)
    step.i32Const((200 + callIndex).uint32)
    step.i32Const(600)
    step.i32Const(255)
    step.i32Const(4_096)
    step.i32Const((MaxCoverThreats * 8).uint32)
    step.add @[byte 0x10, 0x00, 0x1a]
  for _ in 0 ..< MaxEmitsPerStep:
    step.i32Const(0)
    step.i32Const(4_096)
    step.add @[byte 0x10, 0x01, 0x1a]
  for level in 0 ..< MaxLogCallsPerInvocation:
    step.i32Const(level.uint32)
    step.i32Const(0)
    step.i32Const(256)
    step.add @[byte 0x10, 0x02]
  step.add @[byte 0x03, 0x40, 0x0c, 0x00, 0x0b, 0x41, 0x00]
  code.addFunctionBody(step)
  result.addSection(10, code)

  # Syntactically valid JSON occupying exactly 4096 bytes. The host's
  # adversarial schema walker rejects its final unknown field after parsing.
  let payload = "{\"a\":\"" & repeat('x', 4_087) & "\"}"
  doAssert payload.len == 4_095
  let exactPayload = payload & " "
  var data: seq[byte]
  data.uleb(1)
  data.add 0x00
  data.add @[byte 0x41, 0x00, 0x0b]
  data.uleb(exactPayload.len.uint32)
  for character in exactPayload:
    data.add character.byte
  result.addSection(11, data)

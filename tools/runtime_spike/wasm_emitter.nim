## Exact-size core-Wasm adversarial shapes for phase-4 compiler measurements.

const
  ExactModuleBytes* = 262_144
  # wasmparser 0.244.0, used by Wasmtime 48.0.1, rejects a function above
  # this total. Keeping one local per declaration group maximizes the group
  # count while remaining valid.
  MaxFunctionLocals = 50_000

type
  CompileShape* = enum
    enormousFunction
    maximalLocals
    deepestNesting
    maximalFunctions

  EmittedModule* = object
    bytes*: seq[byte]
    objective*: string
    achieved*: int

proc shapeName*(shape: CompileShape): string =
  case shape
  of enormousFunction: "enormous-function"
  of maximalLocals: "maximal-locals"
  of deepestNesting: "deepest-nesting"
  of maximalFunctions: "maximal-functions"

proc parseShape*(value: string): CompileShape =
  for shape in CompileShape:
    if shape.shapeName == value:
      return shape
  raise newException(ValueError, "unknown compile shape: " & value)

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

proc addSection(module: var seq[byte]; sectionId: byte; body: seq[byte]) =
  module.add sectionId
  module.uleb(body.len.uint32)
  module.add body

proc moduleHeader(): seq[byte] =
  @[byte 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]

proc addEmptyFunctionType(module: var seq[byte]) =
  module.addSection(1, @[byte 0x01, 0x60, 0x00, 0x00])

proc singleFunctionModule(body: seq[byte]): seq[byte] =
  result = moduleHeader()
  result.addEmptyFunctionType()
  result.addSection(3, @[byte 0x01, 0x00])
  var code: seq[byte]
  code.uleb(1)
  code.uleb(body.len.uint32)
  code.add body
  result.addSection(10, code)

proc customPadding(totalBytes: int): seq[byte] =
  if totalBytes == 0:
    return
  # A custom section payload starts with its name; an empty name costs one
  # byte. Search the handful of possible LEB header widths exactly.
  for payloadBytes in max(1, totalBytes - 7) .. totalBytes:
    var payloadLengthEncoding: seq[byte]
    payloadLengthEncoding.uleb(payloadBytes.uint32)
    if 1 + payloadLengthEncoding.len + payloadBytes == totalBytes:
      result.add 0x00
      result.add payloadLengthEncoding
      result.add 0x00 # empty custom-section name
      result.add newSeq[byte](payloadBytes - 1)
      return
  raise newException(ValueError,
    "cannot encode exact custom padding of " & $totalBytes & " bytes")

proc exactWithPadding(module: seq[byte]): seq[byte] =
  if module.len > ExactModuleBytes:
    raise newException(ValueError, "module exceeds exact byte cap")
  result = module
  result.add customPadding(ExactModuleBytes - module.len)
  if result.len != ExactModuleBytes:
    raise newException(ValueError, "exact padding produced wrong size")

proc maximize(build: proc(metric: int): seq[byte] {.closure.};
    metricCap = ExactModuleBytes):
    tuple[module: seq[byte], metric: int] =
  var low = 0
  var high = metricCap
  while low <= high:
    let middle = low + (high - low) div 2
    if build(middle).len <= ExactModuleBytes:
      result.metric = middle
      low = middle + 1
    else:
      high = middle - 1
  # The mathematically largest body can leave a 1- or 2-byte remainder that
  # cannot itself be a valid section. Step down only until exact custom padding
  # is representable.
  while result.metric >= 0:
    let candidate = build(result.metric)
    try:
      result.module = candidate.exactWithPadding()
      return
    except ValueError:
      dec result.metric
  raise newException(ValueError, "could not construct an exact module")

proc enormousBody(nops: int): seq[byte] =
  result = newSeqOfCap[byte](nops + 2)
  result.add 0x00 # local declaration vector
  result.add newSeq[byte](nops) # opcode 0x00 is unreachable, not nop
  # Use nop (0x01); newSeq above deliberately allocated exact capacity only.
  for index in 1 .. nops:
    result[index] = 0x01
  result.add 0x0b

proc localsBody(groups: int): seq[byte] =
  result.uleb(groups.uint32)
  for _ in 0 ..< groups:
    result.add 0x01 # one local in this group
    result.add 0x7f # i32
  result.add 0x0b

proc nestingBody(depth: int): seq[byte] =
  result.uleb(0) # no locals
  for _ in 0 ..< depth:
    result.add 0x02 # block
    result.add 0x40 # empty block type
  for _ in 0 ..< depth:
    result.add 0x0b
  result.add 0x0b # function end

proc functionsModule(count: int): seq[byte] =
  result = moduleHeader()
  result.addEmptyFunctionType()
  var functions: seq[byte]
  functions.uleb(count.uint32)
  functions.add newSeq[byte](count) # every function uses type zero
  result.addSection(3, functions)
  var code: seq[byte]
  code.uleb(count.uint32)
  for _ in 0 ..< count:
    code.add 0x02 # two-byte body
    code.add 0x00 # no locals
    code.add 0x0b # end
  result.addSection(10, code)

proc emitModule*(shape: CompileShape): EmittedModule =
  case shape
  of enormousFunction:
    let maximized = maximize(proc(metric: int): seq[byte] =
      singleFunctionModule(enormousBody(metric)))
    result.bytes = maximized.module
    result.objective = "nop instructions in one function"
    result.achieved = maximized.metric
  of maximalLocals:
    let maximized = maximize(proc(metric: int): seq[byte] =
      singleFunctionModule(localsBody(metric)), MaxFunctionLocals)
    result.bytes = maximized.module
    result.objective = "one-i32 local declaration groups in one function"
    result.achieved = maximized.metric
  of deepestNesting:
    let maximized = maximize(proc(metric: int): seq[byte] =
      singleFunctionModule(nestingBody(metric)))
    result.bytes = maximized.module
    result.objective = "nested empty block depth in one function"
    result.achieved = maximized.metric
  of maximalFunctions:
    let maximized = maximize(proc(metric: int): seq[byte] =
      functionsModule(metric))
    result.bytes = maximized.module
    result.objective = "defined empty function count"
    result.achieved = maximized.metric
  if result.bytes.len != ExactModuleBytes:
    raise newException(ValueError, "emitter did not reach exact byte cap")

proc emitQueueModule*(index: int): seq[byte] =
  ## Produces one of the 32 distinct exact-cap compile-queue entries. The
  ## deepest-nesting shape keeps each compile long enough to overlap complete
  ## ticks without the maximal-function shape's 71.66x artifact explosion.
  if index < 0 or index >= 32:
    raise newException(ValueError, "compile queue index must be 0..<32")
  # Leave a substantial custom payload instead of using the byte-maximal depth
  # (which can consume the cap exactly and leave no safe identity bytes).
  result = singleFunctionModule(nestingBody(87_000)).exactWithPadding()
  if result.len != ExactModuleBytes:
    raise newException(ValueError, "compile queue module lost exact size")
  # exactWithPadding always emits the custom section last. Mutating its
  # uninterpreted payload makes the raw modules distinct without changing code.
  result[^1] = byte(index)
  result[^2] = byte(index xor 0xa5)

## Pure shell ABI inspection over an already Wasmtime-validated core module.
##
## This pass deliberately precedes compilation. In particular, the function
## section count is rejected immediately, before later interface defects can
## obscure the reservation-safety `tooManyFunctions` result.

import std/[sets, tables]

import types

type
  ModuleInterfaceError* = object of CatchableError
    reason*: string

  FuncSig = object
    params: seq[byte]
    results: seq[byte]

  ImportedFunc = object
    moduleName: string
    name: string
    typeIndex: uint32

  ExportEntry = object
    name: string
    kind: byte
    index: uint32

  ModuleInterface* = object
    definedFunctions*: int
    hasRetune*: bool
    memoryMaximumPages*: int

  Cursor = object
    bytes: seq[byte]
    pos: int
    stop: int

const
  I32 = 0x7f'u8
  I64 = 0x7e'u8

proc reject(reason, detail: string) {.noreturn.} =
  var error = newException(ModuleInterfaceError, detail)
  error.reason = reason
  raise error

proc require(c: Cursor; count: int) =
  if count < 0 or c.pos > c.stop - count:
    reject("badInterface", "truncated WebAssembly interface")

proc readByte(c: var Cursor): byte =
  c.require(1)
  result = c.bytes[c.pos]
  inc c.pos

proc readUleb(c: var Cursor): uint32 =
  var shift = 0
  for _ in 0 ..< 5:
    let current = c.readByte()
    if shift == 28 and (current and 0xf0) != 0:
      reject("badInterface", "interface integer overflows u32")
    result = result or (uint32(current and 0x7f) shl shift)
    if (current and 0x80) == 0:
      return
    shift += 7
  reject("badInterface", "interface integer has an overlong LEB")

proc readName(c: var Cursor): string =
  let length = c.readUleb().int
  c.require(length)
  result = newString(length)
  if length > 0:
    copyMem(addr result[0], unsafeAddr c.bytes[c.pos], length)
  c.pos += length

proc readValTypes(c: var Cursor): seq[byte] =
  let count = c.readUleb().int
  result = newSeqOfCap[byte](count)
  for _ in 0 ..< count:
    result.add c.readByte()

proc same(sig: FuncSig; params, results: openArray[byte]): bool =
  sig.params == @params and sig.results == @results

proc expectedImport(name: string): tuple[found: bool,
    params, results: seq[byte]] =
  case name
  of "emit": (true, @[I32, I32], @[I32])
  of "log": (true, @[I32, I32, I32], @[])
  of "nearest_reachable": (true, @[I32, I32], @[I64])
  of "nearest_cover": (true, @[I32, I32, I32, I32, I32, I32], @[I64])
  else: (false, @[], @[])

proc inspectModuleInterface*(bytes: openArray[byte]): ModuleInterface =
  var copy = @bytes
  if copy.len < 8 or copy[0 .. 7] !=
      @[byte 0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00]:
    reject("badInterface", "not a WebAssembly 1 core module")
  var c = Cursor(bytes: move(copy), pos: 8, stop: bytes.len)
  var types: seq[FuncSig]
  var imports: seq[ImportedFunc]
  var functions: seq[uint32]
  var exports: seq[ExportEntry]
  var memoryCount = 0
  var memoryMax = -1
  var tableCount = 0
  var sawStart = false
  var seenSections: HashSet[byte]

  while c.pos < c.stop:
    let sectionId = c.readByte()
    let size = c.readUleb().int
    c.require(size)
    let sectionStop = c.pos + size
    if sectionId != 0:
      if sectionId in seenSections:
        reject("badInterface", "duplicate WebAssembly section")
      seenSections.incl sectionId
    var s = Cursor(bytes: c.bytes, pos: c.pos, stop: sectionStop)
    case sectionId
    of 0:
      discard # custom section: fixed engine validation already accepted it
      s.pos = s.stop
    of 1:
      let count = s.readUleb().int
      types = newSeqOfCap[FuncSig](count)
      for _ in 0 ..< count:
        if s.readByte() != 0x60:
          reject("badInterface", "shell ABI permits function types only")
        types.add FuncSig(params: s.readValTypes(), results: s.readValTypes())
    of 2:
      let count = s.readUleb().int
      for _ in 0 ..< count:
        let moduleName = s.readName()
        let name = s.readName()
        let kind = s.readByte()
        if kind != 0:
          reject("badInterface", "shell modules may import functions only")
        imports.add ImportedFunc(moduleName: moduleName, name: name,
          typeIndex: s.readUleb())
    of 3:
      let count = s.readUleb().int
      result.definedFunctions = count
      if count > MaxFunctionsPerModule:
        reject("tooManyFunctions", "module defines " & $count &
          " functions; maximum is " & $MaxFunctionsPerModule)
      functions = newSeqOfCap[uint32](count)
      for _ in 0 ..< count:
        functions.add s.readUleb()
    of 4:
      tableCount = s.readUleb().int
      if tableCount > 1:
        reject("badInterface", "shell modules may declare at most one table")
      for _ in 0 ..< tableCount:
        discard s.readByte() # element reference type
        let flags = s.readUleb()
        discard s.readUleb() # minimum
        if (flags and 1) == 0:
          reject("badInterface", "table must declare a maximum")
        let tableMax = s.readUleb().int
        if tableMax > MaxInstanceTableElements:
          reject("badInterface", "table maximum exceeds " &
            $MaxInstanceTableElements & " elements")
    of 5:
      memoryCount = s.readUleb().int
      for _ in 0 ..< memoryCount:
        let flags = s.readUleb()
        discard s.readUleb() # minimum
        if (flags and 1) == 0:
          memoryMax = -1
        else:
          memoryMax = s.readUleb().int
    of 7:
      let count = s.readUleb().int
      exports = newSeqOfCap[ExportEntry](count)
      for _ in 0 ..< count:
        exports.add ExportEntry(name: s.readName(), kind: s.readByte(),
          index: s.readUleb())
    of 8:
      sawStart = true
      discard s.readUleb()
    else:
      s.pos = s.stop
    if s.pos != s.stop:
      reject("badInterface", "malformed shell-relevant section")
    c.pos = sectionStop

  if sawStart:
    reject("badInterface", "start function is forbidden")
  if memoryCount != 1 or memoryMax < 0 or memoryMax > MaxInstancePages:
    reject("badInterface", "memory must be unique with a maximum at most " &
      $MaxInstancePages & " pages")

  var importedNames: HashSet[string]
  for imported in imports:
    if imported.moduleName != "play" or imported.name in importedNames:
      reject("badInterface", "unexpected or duplicate import " &
        imported.moduleName & "." & imported.name)
    importedNames.incl imported.name
    let expected = expectedImport(imported.name)
    if not expected.found or imported.typeIndex.int >= types.len or
        not types[imported.typeIndex].same(expected.params, expected.results):
      reject("badInterface", "wrong import signature for play." & imported.name)

  var exportsByName = initTable[string, ExportEntry]()
  for exported in exports:
    if exported.name in exportsByName:
      reject("badInterface", "duplicate export " & exported.name)
    exportsByName[exported.name] = exported
  let allowed = ["memory", "play_alloc", "play_manifest", "play_init",
    "play_step", "play_retune"].toHashSet
  for name in exportsByName.keys:
    if name notin allowed:
      reject("badInterface", "unexpected export " & name)

  if "memory" notin exportsByName or exportsByName["memory"].kind != 2 or
      exportsByName["memory"].index != 0:
    reject("badInterface", "memory must be exported exactly as memory")

  proc exportedSig(name: string): FuncSig =
    if name notin exportsByName or exportsByName[name].kind != 0:
      reject("badInterface", "missing function export " & name)
    let functionIndex = exportsByName[name].index.int
    var typeIndex: int
    if functionIndex < imports.len:
      typeIndex = imports[functionIndex].typeIndex.int
    else:
      let definedIndex = functionIndex - imports.len
      if definedIndex < 0 or definedIndex >= functions.len:
        reject("badInterface", "function export index is out of range")
      typeIndex = functions[definedIndex].int
    if typeIndex < 0 or typeIndex >= types.len:
      reject("badInterface", "function export type is out of range")
    types[typeIndex]

  if not exportedSig("play_alloc").same([I32], [I32]):
    reject("badInterface", "wrong signature for play_alloc")
  if not exportedSig("play_manifest").same([], []):
    reject("badInterface", "wrong signature for play_manifest")
  if not exportedSig("play_init").same([I32, I32, I32, I32], [I32]):
    reject("badInterface", "wrong signature for play_init")
  if not exportedSig("play_step").same([I32, I32], [I32]):
    reject("badInterface", "wrong signature for play_step")
  result.hasRetune = "play_retune" in exportsByName
  if result.hasRetune and
      not exportedSig("play_retune").same([I32, I32, I32, I32], [I32]):
    reject("badInterface", "wrong signature for play_retune")
  result.memoryMaximumPages = memoryMax

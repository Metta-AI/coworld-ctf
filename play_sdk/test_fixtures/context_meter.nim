## Test-only WASM probe for comparing typed terrain-context decoding with
## retaining the raw frame and indexing one room record on demand.

import ../play

const
  ManifestBytes =
    "{\"abi\":1,\"class\":\"overlay\",\"doc\":\"test-only spatial context fuel meter\",\"modes\":[\"br\"],\"name\":\"context_meter\",\"params\":{},\"retune\":true}"
  BitmapSection = 104'i32
  RoomSection = 204'i32
  ChokeSection = 205'i32
  AdjacencySection = 206'i32
  RoomStride = 20'i32
  ChokeStride = 16'i32
  MaxMeterRooms = 2048
  MaxMeterChokes = 4096
  MaxMeterAdjacency = 8192
  MaxBitmapCells = 32 * 1024
  RawCapacity = 32 * 1024

type
  MeterRoom = object
    x, y, area: int32
    clearance, component, chokeStart, chokeCount: uint16

  MeterChoke = object
    x, y: int32
    clearance, roomA, roomB: uint16

var
  rooms: array[MaxMeterRooms, MeterRoom]
  chokes: array[MaxMeterChokes, MeterChoke]
  adjacency: array[MaxMeterAdjacency, uint16]
  walkable: array[MaxBitmapCells, bool]
  roomCount, chokeCount, adjacencyCount: int32
  rawBytes: array[RawCapacity, byte]
  rawLen, rawRoomOffset, rawRoomCount, rawBitmapOffset, rawBitmapBytes: int32
  bitmapCellCount: int32
  contextIsBitmap: bool
  sink: int32

proc play_manifest*() {.exportc, cdecl.} =
  discard emitRaw(ManifestBytes)

proc u16At(data: ptr UncheckedArray[byte]; length, offset: int32;
           value: var uint16): bool =
  if offset < 0 or offset > length - 2:
    return false
  value = uint16(data[offset]) or (uint16(data[offset + 1]) shl 8)
  true

proc u32At(data: ptr UncheckedArray[byte]; length, offset: int32;
           value: var uint32): bool =
  if offset < 0 or offset > length - 4:
    return false
  value = uint32(data[offset]) or (uint32(data[offset + 1]) shl 8) or
    (uint32(data[offset + 2]) shl 16) or (uint32(data[offset + 3]) shl 24)
  true

proc i32At(data: ptr UncheckedArray[byte]; length, offset: int32;
           value: var int32): bool =
  var raw: uint32
  if not u32At(data, length, offset, raw):
    return false
  value = cast[int32](raw)
  true

proc section(data: ptr UncheckedArray[byte]; length, wanted: int32;
             count, stride, offset: var int32): bool =
  if length < 32 or data[0] != byte('P') or data[1] != byte('V') or
      data[2] != byte('1') or data[3] != 0'u8:
    return false
  let sectionCount = int32(data[7])
  if sectionCount > (length - 32) div 12:
    return false
  for index in 0 ..< sectionCount:
    let entry = 32 + index * 12
    var kind, rawCount, rawStride: uint16
    var rawOffset: uint32
    if not u16At(data, length, entry, kind) or
        not u16At(data, length, entry + 2, rawCount) or
        not u16At(data, length, entry + 4, rawStride) or
        not u32At(data, length, entry + 8, rawOffset):
      return false
    if int32(kind) == wanted:
      count = int32(rawCount)
      stride = int32(rawStride)
      offset = int32(rawOffset)
      return offset >= 0 and stride > 0 and count >= 0 and
        int64(offset) + int64(stride) * int64(count) <= int64(length)
  false

proc decodeTyped(data: ptr UncheckedArray[byte]; length: int32): bool =
  var bitmapStride: int32
  if section(data, length, BitmapSection, rawBitmapBytes, bitmapStride,
      rawBitmapOffset):
    if bitmapStride != 1 or rawBitmapBytes * 8 > MaxBitmapCells:
      return false
    contextIsBitmap = true
    bitmapCellCount = rawBitmapBytes * 8
    for index in 0 ..< bitmapCellCount:
      walkable[index] =
        (data[rawBitmapOffset + index div 8] and byte(1 shl (index mod 8))) != 0
    return true

  contextIsBitmap = false
  var roomStride, roomOffset, chokeStride, chokeOffset: int32
  var adjacencyStride, adjacencyOffset: int32
  if not section(data, length, RoomSection, roomCount, roomStride, roomOffset) or
      not section(data, length, ChokeSection, chokeCount, chokeStride, chokeOffset) or
      not section(data, length, AdjacencySection, adjacencyCount,
        adjacencyStride, adjacencyOffset) or
      roomStride != RoomStride or chokeStride != ChokeStride or
      adjacencyStride != 2 or roomCount > MaxMeterRooms or
      chokeCount > MaxMeterChokes or adjacencyCount > MaxMeterAdjacency:
    return false
  for index in 0 ..< roomCount:
    let offset = roomOffset + index * roomStride
    if not i32At(data, length, offset, rooms[index].x) or
        not i32At(data, length, offset + 4, rooms[index].y) or
        not u16At(data, length, offset + 8, rooms[index].clearance) or
        not u16At(data, length, offset + 10, rooms[index].component) or
        not i32At(data, length, offset + 12, rooms[index].area) or
        not u16At(data, length, offset + 16, rooms[index].chokeStart) or
        not u16At(data, length, offset + 18, rooms[index].chokeCount):
      return false
  for index in 0 ..< chokeCount:
    let offset = chokeOffset + index * chokeStride
    var reserved: uint16
    if not i32At(data, length, offset, chokes[index].x) or
        not i32At(data, length, offset + 4, chokes[index].y) or
        not u16At(data, length, offset + 8, chokes[index].clearance) or
        not u16At(data, length, offset + 10, chokes[index].roomA) or
        not u16At(data, length, offset + 12, chokes[index].roomB) or
        not u16At(data, length, offset + 14, reserved):
      return false
  for index in 0 ..< adjacencyCount:
    if not u16At(data, length, adjacencyOffset + index * 2,
        adjacency[index]):
      return false
  true

proc retainRaw(data: ptr UncheckedArray[byte]; length: int32): bool =
  if length < 0 or length > RawCapacity:
    return false
  for index in 0 ..< length:
    rawBytes[index] = data[index]
  rawLen = length
  var bitmapStride: int32
  if section(cast[ptr UncheckedArray[byte]](addr rawBytes[0]), rawLen,
      BitmapSection, rawBitmapBytes, bitmapStride, rawBitmapOffset):
    contextIsBitmap = true
    bitmapCellCount = rawBitmapBytes * 8
    return bitmapStride == 1
  contextIsBitmap = false
  var stride: int32
  section(cast[ptr UncheckedArray[byte]](addr rawBytes[0]), rawLen,
    RoomSection, rawRoomCount, stride, rawRoomOffset) and stride == RoomStride

proc play_init*(paramsPtr, paramsLen, ctxPtr, ctxLen: int32): int32 {.
    exportc, cdecl.} =
  discard paramsPtr
  discard paramsLen
  sink = 0
  let data = cast[ptr UncheckedArray[byte]](ctxPtr)
  when defined(contextFullDecode):
    if not decodeTyped(data, ctxLen):
      return 1
  else:
    if not retainRaw(data, ctxLen):
      return 1
  0

proc play_step*(viewPtr, viewLen: int32): int32 {.exportc, cdecl.} =
  discard viewPtr
  discard viewLen
  when defined(contextFullDecode):
    if contextIsBitmap:
      if bitmapCellCount <= 0:
        return 1
      sink += int32(walkable[bitmapCellCount div 2])
    else:
      if roomCount <= 0:
        return 1
      let room = rooms[roomCount div 2]
      sink = sink + room.x + room.y + room.area + int32(room.chokeCount) +
        (if adjacencyCount > 0: int32(adjacency[adjacencyCount div 2]) else: 0)
  else:
    if contextIsBitmap:
      if bitmapCellCount <= 0:
        return 1
      let index = bitmapCellCount div 2
      sink += int32((rawBytes[rawBitmapOffset + index div 8] shr
        (index mod 8)) and 1)
    else:
      if rawRoomCount <= 0:
        return 1
      let offset = rawRoomOffset + (rawRoomCount div 2) * RoomStride
      var x, y, area: int32
      if not i32At(cast[ptr UncheckedArray[byte]](addr rawBytes[0]), rawLen,
          offset, x) or
          not i32At(cast[ptr UncheckedArray[byte]](addr rawBytes[0]), rawLen,
          offset + 4, y) or
          not i32At(cast[ptr UncheckedArray[byte]](addr rawBytes[0]), rawLen,
          offset + 12, area):
        return 1
      sink = sink + x + y + area
  0

proc play_retune*(oldPtr, oldLen, newPtr, newLen: int32): int32 {.
    exportc, cdecl.} =
  discard oldPtr
  discard oldLen
  discard newPtr
  discard newLen
  0

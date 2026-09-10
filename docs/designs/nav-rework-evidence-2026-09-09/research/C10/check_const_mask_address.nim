const masks = block:
  var value: array[16, array[4, uint32]]
  for nibble in 0 ..< 16:
    for lane in 0 ..< 4:
      if (nibble and (1 shl lane)) != 0: value[nibble][lane] = high(uint32)
  value
proc readMask(nibble: int): uint32 =
  let p = unsafeAddr masks[nibble][0]
  p[]
doAssert readMask(1) == high(uint32)

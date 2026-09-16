## Tools-only C10 prototype. Included after body_nav; no production dispatch.
import std/bitops
when defined(amd64):
  import nimsimd/sse2
elif defined(arm64):
  import nimsimd/neon
else:
  {.error: "C10 experiment requires native amd64 or arm64".}

let c10LaneMasks = block:
  var masks: array[16, array[4, uint32]]
  for nibble in 0 ..< 16:
    for lane in 0 ..< 4:
      if (nibble and (1 shl lane)) != 0:
        masks[nibble][lane] = high(uint32)
  masks

proc replayFourCellGroups(seat: BodyNavSeat, origin: BodyPoint, base: int,
    vectorized: static bool = true) =
  let
    cache = seat.dangerSourceCache
    radius = seat.dangerGeometry.radius
    diameter = radius * 2 + 1
    width = seat.danger.gridW
    height = seat.danger.gridH
    kernelLen = seat.dangerGeometry.kernel.len
    values = cast[ptr UncheckedArray[float32]](addr seat.danger.values[0])
    kernel = cast[ptr UncheckedArray[float32]](unsafeAddr seat.dangerGeometry.kernel[0])
  for wordIndex in 0 ..< cache.words:
    var word = cache.bits[base + wordIndex]
    while word != 0:
      let
        shift = countTrailingZeroBits(word) and not 3
        nibble = int((word shr shift) and 15)
        k = wordIndex * 64 + shift
        ky = k div diameter
        kx = k - ky * diameter
        gx = origin.x - radius + kx
        gy = origin.y - radius + ky
      if k + 3 < kernelLen and kx + 3 < diameter and
          gx >= 0 and gx + 3 < width and gy >= 0 and gy < height:
        when not vectorized:
          let destinationIndex = gy * width + gx
          for lane in 0 ..< 4:
            if (nibble and (1 shl lane)) != 0:
              values[destinationIndex + lane] += kernel[k + lane]
        else:
          let
            destination = addr values[gy * width + gx]
            weights = addr kernel[k]
          when defined(amd64):
            let before = mm_loadu_ps(destination)
            let updated = mm_add_ps(before, mm_loadu_ps(weights))
            if nibble == 15:
              mm_storeu_ps(destination, updated)
            else:
              let mask = mm_castsi128_ps(mm_loadu_si128(unsafeAddr c10LaneMasks[nibble][0]))
              mm_storeu_ps(destination, mm_or_ps(mm_and_ps(mask, updated),
                mm_andnot_ps(mask, before)))
          elif defined(arm64):
            let before = vld1q_f32(destination)
            let updated = vaddq_f32(before, vld1q_f32(weights))
            if nibble == 15:
              vst1q_f32(destination, updated)
            else:
              let mask = vld1q_u32(unsafeAddr c10LaneMasks[nibble][0])
              vst1q_f32(destination, vbslq_f32(mask, updated, before))
      else:
        var lanes = uint64(nibble)
        while lanes != 0:
          let
            scalarK = k + countTrailingZeroBits(lanes)
            scalarY = scalarK div diameter
            scalarX = scalarK - scalarY * diameter
          seat.danger.values[(origin.y - radius + scalarY) * width +
            origin.x - radius + scalarX] += seat.dangerGeometry.kernel[scalarK]
          lanes = lanes and (lanes - 1)
      word = word and not (15'u64 shl shift)

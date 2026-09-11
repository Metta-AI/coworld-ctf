"""Compare host libm hypot with correctly rounded sqrt of exact integer squares."""
import ctypes
import ctypes.util
import json
import math
import random
import struct

libname = ctypes.util.find_library('m')
lib = ctypes.CDLL(libname)
hypot = lib.hypot
hypot.argtypes = [ctypes.c_double, ctypes.c_double]
hypot.restype = ctypes.c_double
count = mismatches = 0
examples = []
def check(x, y):
    global count, mismatches
    actual = hypot(x, y)
    expected = math.sqrt(float(x*x+y*y))
    count += 1
    if actual != expected:
        mismatches += 1
        if len(examples) < 20:
            examples.append(dict(x=x,y=y,hypot=actual.hex(),sqrt=expected.hex()))
for x in range(1601):
    for y in range(1601):
        check(x,y)
rng = random.Random(5120911)
for _ in range(200_000):
    check(rng.randrange(3601),rng.randrange(1901))
print(json.dumps(dict(library=libname,count=count,mismatches=mismatches,examples=examples),indent=2))

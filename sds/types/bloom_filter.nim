type BloomFilter* {.requiresInit.} = object
  capacity*: int
  errorRate*: float
  kHashes*: int
  mBits*: int
  intArray*: seq[int]

proc init*(
    T: type BloomFilter,
    capacity: int,
    errorRate: float,
    kHashes: int,
    mBits: int,
    intArray: seq[int],
): T =
  return T(
    capacity: capacity,
    errorRate: errorRate,
    kHashes: kHashes,
    mBits: mBits,
    intArray: intArray,
  )

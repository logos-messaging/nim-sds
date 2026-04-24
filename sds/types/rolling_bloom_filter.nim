import ./bloom_filter
import ./sds_message_id
export bloom_filter, sds_message_id

const
  DefaultBloomFilterCapacity* = 10000
  DefaultBloomFilterErrorRate* = 0.001
  CapacityFlexPercent* = 20

type RollingBloomFilter* {.requiresInit.} = object
  filter*: BloomFilter
  capacity*: int
  minCapacity*: int
  maxCapacity*: int
  messages*: seq[SdsMessageID]

proc init*(
    T: type RollingBloomFilter,
    filter: BloomFilter,
    capacity: int,
    minCapacity: int,
    maxCapacity: int,
    messages: seq[SdsMessageID] = @[],
): T =
  return T(
    filter: filter,
    capacity: capacity,
    minCapacity: minCapacity,
    maxCapacity: maxCapacity,
    messages: messages,
  )

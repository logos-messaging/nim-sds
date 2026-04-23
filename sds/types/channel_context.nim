import std/tables
import ./sds_message_id
import ./rolling_bloom_filter
import ./unacknowledged_message
import ./incoming_message
export sds_message_id, rolling_bloom_filter, unacknowledged_message, incoming_message

type ChannelContext* = ref object
  lamportTimestamp*: int64
  messageHistory*: seq[SdsMessageID]
  bloomFilter*: RollingBloomFilter
  outgoingBuffer*: seq[UnacknowledgedMessage]
  incomingBuffer*: Table[SdsMessageID, IncomingMessage]

proc new*(T: type ChannelContext, bloomFilter: RollingBloomFilter): T =
  return T(
    lamportTimestamp: 0,
    messageHistory: @[],
    bloomFilter: bloomFilter,
    outgoingBuffer: @[],
    incomingBuffer: initTable[SdsMessageID, IncomingMessage](),
  )

import std/tables
import ./sds_message_id
import ./sds_message
import ./rolling_bloom_filter
import ./unacknowledged_message
import ./incoming_message
import ./repair_entry
export
  sds_message_id, sds_message, rolling_bloom_filter, unacknowledged_message,
  incoming_message, repair_entry

type ChannelContext* = ref object
  lamportTimestamp*: int64
  messageHistory*: OrderedTable[SdsMessageID, SdsMessage]
    ## Single source of truth for delivered messages. Holds the deserialized
    ## SdsMessage (which carries senderId, lamportTimestamp, content, etc.) so
    ## causal history, sender lookup, and SDS-R repair responses can all be
    ## answered from one place. OrderedTable preserves insertion order for
    ## causal-history tail access and FIFO eviction at maxMessageHistory.
  bloomFilter*: RollingBloomFilter
  outgoingBuffer*: seq[UnacknowledgedMessage]
  incomingBuffer*: Table[SdsMessageID, IncomingMessage]
  ## SDS-R buffers
  outgoingRepairBuffer*: Table[SdsMessageID, OutgoingRepairEntry]
  incomingRepairBuffer*: Table[SdsMessageID, IncomingRepairEntry]

proc new*(T: type ChannelContext, bloomFilter: RollingBloomFilter): T =
  return T(
    lamportTimestamp: 0,
    messageHistory: initOrderedTable[SdsMessageID, SdsMessage](),
    bloomFilter: bloomFilter,
    outgoingBuffer: @[],
    incomingBuffer: initTable[SdsMessageID, IncomingMessage](),
    outgoingRepairBuffer: initTable[SdsMessageID, OutgoingRepairEntry](),
    incomingRepairBuffer: initTable[SdsMessageID, IncomingRepairEntry](),
  )

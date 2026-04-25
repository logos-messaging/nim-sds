import std/tables
import ./sds_message_id
import ./rolling_bloom_filter
import ./unacknowledged_message
import ./incoming_message
import ./repair_entry
export
  sds_message_id, rolling_bloom_filter, unacknowledged_message, incoming_message,
  repair_entry

type ChannelContext* = ref object
  lamportTimestamp*: int64
  messageHistory*: seq[SdsMessageID]
  bloomFilter*: RollingBloomFilter
  outgoingBuffer*: seq[UnacknowledgedMessage]
  incomingBuffer*: Table[SdsMessageID, IncomingMessage]
  ## SDS-R buffers
  outgoingRepairBuffer*: Table[SdsMessageID, OutgoingRepairEntry]
  incomingRepairBuffer*: Table[SdsMessageID, IncomingRepairEntry]
  messageCache*: Table[SdsMessageID, seq[byte]]
    ## Cached serialized messages for repair responses
  messageSenders*: Table[SdsMessageID, SdsParticipantID]
    ## SDS-R: msgId -> original sender, used to populate causal-history senderId

proc new*(T: type ChannelContext, bloomFilter: RollingBloomFilter): T =
  return T(
    lamportTimestamp: 0,
    messageHistory: @[],
    bloomFilter: bloomFilter,
    outgoingBuffer: @[],
    incomingBuffer: initTable[SdsMessageID, IncomingMessage](),
    outgoingRepairBuffer: initTable[SdsMessageID, OutgoingRepairEntry](),
    incomingRepairBuffer: initTable[SdsMessageID, IncomingRepairEntry](),
    messageCache: initTable[SdsMessageID, seq[byte]](),
    messageSenders: initTable[SdsMessageID, SdsParticipantID](),
  )

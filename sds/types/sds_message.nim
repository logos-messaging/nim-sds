import ./sds_message_id
import ./history_entry
export sds_message_id, history_entry

type SdsMessage* = object
  messageId*: SdsMessageID
  lamportTimestamp*: int64
  causalHistory*: seq[HistoryEntry]
  channelId*: SdsChannelID
  content*: seq[byte]
  bloomFilter*: seq[byte]
  repairRequest*: seq[HistoryEntry]
    ## Capped list of missing entries requesting repair (SDS-R)

proc init*(
    T: type SdsMessage,
    messageId: SdsMessageID,
    lamportTimestamp: int64,
    causalHistory: seq[HistoryEntry],
    channelId: SdsChannelID,
    content: seq[byte],
    bloomFilter: seq[byte],
    repairRequest: seq[HistoryEntry] = @[],
): T =
  return T(
    messageId: messageId,
    lamportTimestamp: lamportTimestamp,
    causalHistory: causalHistory,
    channelId: channelId,
    content: content,
    bloomFilter: bloomFilter,
    repairRequest: repairRequest,
  )

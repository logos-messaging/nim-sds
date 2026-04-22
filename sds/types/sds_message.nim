import ./sds_message_id
import ./history_entry
export sds_message_id, history_entry

type SdsMessage* {.requiresInit.} = object
  messageId*: SdsMessageID
  lamportTimestamp*: int64
  causalHistory*: seq[HistoryEntry]
  channelId*: SdsChannelID
  content*: seq[byte]
  bloomFilter*: seq[byte]

proc init*(
    T: type SdsMessage,
    messageId: SdsMessageID,
    lamportTimestamp: int64,
    causalHistory: seq[HistoryEntry],
    channelId: SdsChannelID,
    content: seq[byte],
    bloomFilter: seq[byte],
): T =
  T(
    messageId: messageId,
    lamportTimestamp: lamportTimestamp,
    causalHistory: causalHistory,
    channelId: channelId,
    content: content,
    bloomFilter: bloomFilter,
  )

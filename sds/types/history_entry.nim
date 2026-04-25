import ./sds_message_id

type HistoryEntry* = object
  messageId*: SdsMessageID
  retrievalHint*: seq[byte] ## Optional hint for efficient retrieval (e.g., Waku message hash)
  senderId*: string ## Original message sender's participant ID (SDS-R)

proc init*(
    T: type HistoryEntry,
    messageId: SdsMessageID,
    retrievalHint: seq[byte] = @[],
    senderId: string = "",
): T =
  return T(messageId: messageId, retrievalHint: retrievalHint, senderId: senderId)

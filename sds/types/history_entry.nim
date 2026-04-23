import ./sds_message_id

type HistoryEntry* = object
  messageId*: SdsMessageID
  retrievalHint*: seq[byte] ## Optional hint for efficient retrieval (e.g., Waku message hash)

proc init*(T: type HistoryEntry, messageId: SdsMessageID, retrievalHint: seq[byte] = @[]): T =
  return T(messageId: messageId, retrievalHint: retrievalHint)

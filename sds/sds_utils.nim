import std/[locks, tables, sequtils]
import chronicles, results
import ./rolling_bloom_filter
import ./types/[
  sds_message_id, history_entry, sds_message, unacknowledged_message, incoming_message,
  reliability_error, callbacks, app_callbacks, reliability_config, channel_context,
  reliability_manager,
]
export
  sds_message_id, history_entry, sds_message, unacknowledged_message, incoming_message,
  reliability_error, callbacks, app_callbacks, reliability_config, channel_context,
  reliability_manager

proc defaultConfig*(): ReliabilityConfig =
  ReliabilityConfig.init()

proc cleanup*(rm: ReliabilityManager) {.raises: [].} =
  if not rm.isNil():
    try:
      withLock rm.lock:
        for channelId, channel in rm.channels:
          channel.outgoingBuffer.setLen(0)
          channel.incomingBuffer.clear()
          channel.messageHistory.setLen(0)
        rm.channels.clear()
    except Exception:
      error "Error during cleanup", error = getCurrentExceptionMsg()

proc cleanBloomFilter*(
    rm: ReliabilityManager, channelId: SdsChannelID
) {.gcsafe, raises: [].} =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        rm.channels[channelId].bloomFilter.clean()
    except Exception:
      error "Failed to clean bloom filter",
        error = getCurrentExceptionMsg(), channelId = channelId

proc addToHistory*(
    rm: ReliabilityManager, msgId: SdsMessageID, channelId: SdsChannelID
) {.gcsafe, raises: [].} =
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      channel.messageHistory.add(msgId)
      if channel.messageHistory.len > rm.config.maxMessageHistory:
        channel.messageHistory.delete(0)
  except Exception:
    error "Failed to add to history",
      channelId = channelId, msgId = msgId, error = getCurrentExceptionMsg()

proc updateLamportTimestamp*(
    rm: ReliabilityManager, msgTs: int64, channelId: SdsChannelID
) {.gcsafe, raises: [].} =
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      channel.lamportTimestamp = max(msgTs, channel.lamportTimestamp) + 1
  except Exception:
    error "Failed to update lamport timestamp",
      channelId = channelId, msgTs = msgTs, error = getCurrentExceptionMsg()

proc newHistoryEntry*(messageId: SdsMessageID, retrievalHint: seq[byte] = @[]): HistoryEntry =
  HistoryEntry.init(messageId, retrievalHint)

proc toCausalHistory*(messageIds: seq[SdsMessageID]): seq[HistoryEntry] =
  return messageIds.mapIt(newHistoryEntry(it))

proc getMessageIds*(causalHistory: seq[HistoryEntry]): seq[SdsMessageID] =
  return causalHistory.mapIt(it.messageId)

proc getRecentHistoryEntries*(
    rm: ReliabilityManager, n: int, channelId: SdsChannelID
): seq[HistoryEntry] =
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      let recentMessageIds = channel.messageHistory[max(0, channel.messageHistory.len - n) .. ^1]
      if rm.onRetrievalHint.isNil():
        return toCausalHistory(recentMessageIds)
      else:
        var entries: seq[HistoryEntry] = @[]
        for msgId in recentMessageIds:
          let hint = rm.onRetrievalHint(msgId)
          entries.add(newHistoryEntry(msgId, hint))
        return entries
    else:
      return @[]
  except Exception:
    error "Failed to get recent history entries",
      channelId = channelId, n = n, error = getCurrentExceptionMsg()
    return @[]

proc checkDependencies*(
    rm: ReliabilityManager, deps: seq[HistoryEntry], channelId: SdsChannelID
): seq[HistoryEntry] =
  var missingDeps: seq[HistoryEntry] = @[]
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      for dep in deps:
        if dep.messageId notin channel.messageHistory:
          missingDeps.add(dep)
    else:
      missingDeps = deps
  except Exception:
    error "Failed to check dependencies",
      channelId = channelId, error = getCurrentExceptionMsg()
    missingDeps = deps
  return missingDeps

proc getMessageHistory*(
    rm: ReliabilityManager, channelId: SdsChannelID
): seq[SdsMessageID] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        result = rm.channels[channelId].messageHistory
      else:
        result = @[]
    except Exception:
      error "Failed to get message history",
        channelId = channelId, error = getCurrentExceptionMsg()
      result = @[]

proc getOutgoingBuffer*(
    rm: ReliabilityManager, channelId: SdsChannelID
): seq[UnacknowledgedMessage] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        result = rm.channels[channelId].outgoingBuffer
      else:
        result = @[]
    except Exception:
      error "Failed to get outgoing buffer",
        channelId = channelId, error = getCurrentExceptionMsg()
      result = @[]

proc getIncomingBuffer*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Table[SdsMessageID, IncomingMessage] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        result = rm.channels[channelId].incomingBuffer
      else:
        result = initTable[SdsMessageID, IncomingMessage]()
    except Exception:
      error "Failed to get incoming buffer",
        channelId = channelId, error = getCurrentExceptionMsg()
      result = initTable[SdsMessageID, IncomingMessage]()

proc getOrCreateChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): ChannelContext =
  try:
    if channelId notin rm.channels:
      rm.channels[channelId] = ChannelContext.new(
        RollingBloomFilter.init(rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate)
      )
    result = rm.channels[channelId]
  except Exception:
    error "Failed to get or create channel",
      channelId = channelId, error = getCurrentExceptionMsg()
    raise

proc ensureChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Result[void, ReliabilityError] =
  withLock rm.lock:
    try:
      discard rm.getOrCreateChannel(channelId)
      return ok()
    except Exception:
      error "Failed to ensure channel",
        channelId = channelId, msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reInternalError)

proc removeChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Result[void, ReliabilityError] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        let channel = rm.channels[channelId]
        channel.outgoingBuffer.setLen(0)
        channel.incomingBuffer.clear()
        channel.messageHistory.setLen(0)
        rm.channels.del(channelId)
      return ok()
    except Exception:
      error "Failed to remove channel",
        channelId = channelId, msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reInternalError)

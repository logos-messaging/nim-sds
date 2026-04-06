import std/[times, locks, tables, sequtils, hashes]
import chronicles, results
import ./rolling_bloom_filter
import ./types/[
  sds_message_id, history_entry, sds_message, unacknowledged_message, incoming_message,
  reliability_error, callbacks, app_callbacks, reliability_config, repair_entry,
  channel_context, reliability_manager,
]
export
  sds_message_id, history_entry, sds_message, unacknowledged_message, incoming_message,
  reliability_error, callbacks, app_callbacks, reliability_config, repair_entry,
  channel_context, reliability_manager

proc defaultConfig*(): ReliabilityConfig =
  return ReliabilityConfig.init()

proc cleanup*(rm: ReliabilityManager) {.raises: [].} =
  if not rm.isNil():
    try:
      withLock rm.lock:
        for channelId, channel in rm.channels:
          channel.outgoingBuffer.setLen(0)
          channel.incomingBuffer.clear()
          channel.messageHistory.setLen(0)
          channel.outgoingRepairBuffer.clear()
          channel.incomingRepairBuffer.clear()
          channel.messageCache.clear()
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
  return HistoryEntry.init(messageId, retrievalHint)

proc toCausalHistory*(messageIds: seq[SdsMessageID]): seq[HistoryEntry] =
  return messageIds.mapIt(newHistoryEntry(it))

proc getMessageIds*(causalHistory: seq[HistoryEntry]): seq[SdsMessageID] =
  return causalHistory.mapIt(it.messageId)

## SDS-R: Repair computation functions

proc computeTReq*(
    participantId: SdsParticipantID,
    messageId: SdsMessageID,
    tMin: Duration,
    tMax: Duration,
): Duration =
  ## Computes the repair request backoff duration per SDS-R spec:
  ## T_req = hash(participant_id, message_id) % (T_max - T_min) + T_min
  let h = abs(hash(participantId & messageId))
  let rangeMs = tMax.inMilliseconds - tMin.inMilliseconds
  if rangeMs <= 0:
    return tMin
  let offsetMs = h mod rangeMs
  initDuration(milliseconds = tMin.inMilliseconds + offsetMs)

proc computeTResp*(
    participantId: SdsParticipantID,
    senderId: SdsParticipantID,
    messageId: SdsMessageID,
    tMax: Duration,
): Duration =
  ## Computes the repair response backoff duration per SDS-R spec:
  ## distance = hash(participant_id) XOR hash(sender_id)
  ## T_resp = distance * hash(message_id) % T_max
  ## Original sender has distance=0, so T_resp=0 (responds immediately).
  let distance = abs(hash(participantId) xor hash(senderId))
  let msgHash = abs(hash(messageId))
  let tMaxMs = tMax.inMilliseconds
  if tMaxMs <= 0 or distance == 0:
    return initDuration(milliseconds = 0)
  # Use uint64 to avoid overflow on multiplication
  let d = uint64(distance mod tMaxMs)
  let m = uint64(msgHash mod tMaxMs)
  let offsetMs = int64((d * m) mod uint64(tMaxMs))
  initDuration(milliseconds = offsetMs)

proc isInResponseGroup*(
    participantId: SdsParticipantID,
    senderId: SdsParticipantID,
    messageId: SdsMessageID,
    numResponseGroups: int,
): bool =
  ## Determines if this participant is in the response group for a given message per SDS-R spec:
  ## hash(participant_id, message_id) % num_groups == hash(sender_id, message_id) % num_groups
  if numResponseGroups <= 1:
    return true  # All participants in the same group
  let myGroup = abs(hash(participantId & messageId)) mod numResponseGroups
  let senderGroup = abs(hash(senderId & messageId)) mod numResponseGroups
  myGroup == senderGroup

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
        return rm.channels[channelId].messageHistory
      else:
        return @[]
    except Exception:
      error "Failed to get message history",
        channelId = channelId, error = getCurrentExceptionMsg()
      return @[]

proc getOutgoingBuffer*(
    rm: ReliabilityManager, channelId: SdsChannelID
): seq[UnacknowledgedMessage] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        return rm.channels[channelId].outgoingBuffer
      else:
        return @[]
    except Exception:
      error "Failed to get outgoing buffer",
        channelId = channelId, error = getCurrentExceptionMsg()
      return @[]

proc getIncomingBuffer*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Table[SdsMessageID, IncomingMessage] =
  withLock rm.lock:
    try:
      if channelId in rm.channels:
        return rm.channels[channelId].incomingBuffer
      else:
        return initTable[SdsMessageID, IncomingMessage]()
    except Exception:
      error "Failed to get incoming buffer",
        channelId = channelId, error = getCurrentExceptionMsg()
      return initTable[SdsMessageID, IncomingMessage]()

proc getOrCreateChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): ChannelContext =
  try:
    if channelId notin rm.channels:
      rm.channels[channelId] = ChannelContext.new(
        RollingBloomFilter.init(rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate)
      )
    return rm.channels[channelId]
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
        channel.outgoingRepairBuffer.clear()
        channel.incomingRepairBuffer.clear()
        channel.messageCache.clear()
        rm.channels.del(channelId)
      return ok()
    except Exception:
      error "Failed to remove channel",
        channelId = channelId, msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reInternalError)

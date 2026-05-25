import std/[times, tables, sequtils, hashes]
import chronos, chronicles, results
import ./rolling_bloom_filter
import
  ./types/[
    sds_message_id, history_entry, sds_message, unacknowledged_message,
    incoming_message, reliability_error, callbacks, app_callbacks, reliability_config,
    repair_entry, channel_context, reliability_manager,
  ]
export
  sds_message_id, history_entry, sds_message, unacknowledged_message, incoming_message,
  reliability_error, callbacks, app_callbacks, reliability_config, repair_entry,
  channel_context, reliability_manager

proc defaultConfig*(): ReliabilityConfig =
  return ReliabilityConfig.init()

proc dropChannelFromPersistence*(
    rm: ReliabilityManager, channelId: SdsChannelID
) {.async: (raises: []).} =
  ## Wipes all persisted state for a channel via a single backend call.
  ## Called by removeChannel / resetReliabilityManager before they clear
  ## in-memory state. Backend executes the wipe in one transaction.
  await rm.persistence.dropChannel(channelId)

proc cleanup*(rm: ReliabilityManager) {.async: (raises: []).} =
  ## Releases in-memory state. Does NOT wipe persistence — the manager may be
  ## reconstructed against the same backend after cleanup, so disk state must
  ## survive. For deliberate disk wipe, use `removeChannel` or
  ## `resetReliabilityManager`.
  ##
  ## Periodic tasks are cancelled BEFORE acquiring the lock so that a task
  ## currently blocked on `lock.acquire()` can unwind via CancelledError
  ## without deadlocking against cleanup itself.
  if rm.isNil():
    return
  for task in rm.periodicTasks:
    if not task.finished:
      await task.cancelAndWait()
  rm.periodicTasks.setLen(0)
  try:
    await rm.lock.acquire()
    try:
      for channelId, channel in rm.channels:
        channel.outgoingBuffer.setLen(0)
        channel.incomingBuffer.clear()
        channel.messageHistory.clear()
        channel.outgoingRepairBuffer.clear()
        channel.incomingRepairBuffer.clear()
      rm.channels.clear()
    finally:
      rm.lock.release()
  except CatchableError:
    error "Error during cleanup", error = getCurrentExceptionMsg()

proc cleanBloomFilter*(
    rm: ReliabilityManager, channelId: SdsChannelID
) {.async: (raises: []).} =
  try:
    await rm.lock.acquire()
    try:
      if channelId in rm.channels:
        rm.channels[channelId].bloomFilter.clean()
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to clean bloom filter",
      error = getCurrentExceptionMsg(), channelId = channelId

proc addToHistory*(
    rm: ReliabilityManager, msg: SdsMessage, channelId: SdsChannelID
) {.async: (raises: []).} =
  ## Inserts a delivered message into the channel's history map and evicts the
  ## eldest entries when the bound is exceeded. The full SdsMessage is kept so
  ## senderId is available for downstream causal-history population and the
  ## bytes can be re-serialized on demand to answer SDS-R repair requests.
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      channel.messageHistory[msg.messageId] = msg
      await rm.persistence.appendLogEntry(channelId, msg)
      while channel.messageHistory.len > rm.config.maxMessageHistory:
        var firstKey: SdsMessageID
        for k in channel.messageHistory.keys:
          firstKey = k
          break
        channel.messageHistory.del(firstKey)
        await rm.persistence.removeLogEntry(channelId, firstKey)
  except CatchableError:
    error "Failed to add to history",
      channelId = channelId, msgId = msg.messageId, error = getCurrentExceptionMsg()

proc updateLamportTimestamp*(
    rm: ReliabilityManager, msgTs: int64, channelId: SdsChannelID
) {.async: (raises: []).} =
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      channel.lamportTimestamp = max(msgTs, channel.lamportTimestamp) + 1
      await rm.persistence.saveLamport(channelId, channel.lamportTimestamp)
  except CatchableError:
    error "Failed to update lamport timestamp",
      channelId = channelId, msgTs = msgTs, error = getCurrentExceptionMsg()

proc newHistoryEntry*(
    messageId: SdsMessageID, retrievalHint: seq[byte] = @[]
): HistoryEntry =
  return HistoryEntry.init(messageId, retrievalHint)

proc toCausalHistory*(messageIds: seq[SdsMessageID]): seq[HistoryEntry] =
  return messageIds.mapIt(newHistoryEntry(it))

proc getMessageIds*(causalHistory: seq[HistoryEntry]): seq[SdsMessageID] =
  return causalHistory.mapIt(it.messageId)

## SDS-R: Repair computation functions

proc computeTReq*(
    participantId: SdsParticipantID,
    messageId: SdsMessageID,
    tMin: times.Duration,
    tMax: times.Duration,
): times.Duration =
  ## Computes the repair request backoff duration per SDS-R spec:
  ## T_req = hash(participant_id, message_id) % (T_max - T_min) + T_min
  let h = abs(hash(participantId.string & messageId))
  let rangeMs = tMax.inMilliseconds - tMin.inMilliseconds
  if rangeMs <= 0:
    return tMin
  let offsetMs = h mod rangeMs
  initDuration(milliseconds = tMin.inMilliseconds + offsetMs)

proc computeTResp*(
    participantId: SdsParticipantID,
    senderId: SdsParticipantID,
    messageId: SdsMessageID,
    tMax: times.Duration,
): times.Duration =
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
    return true # All participants in the same group
  let myGroup = abs(hash(participantId.string & messageId)) mod numResponseGroups
  let senderGroup = abs(hash(senderId.string & messageId)) mod numResponseGroups
  myGroup == senderGroup

proc getRecentHistoryEntries*(
    rm: ReliabilityManager, n: int, channelId: SdsChannelID
): Future[seq[HistoryEntry]] {.async: (raises: []).} =
  ## Get recent history entries for sending in causal history.
  ## Populates retrieval hints and senderId (SDS-R) for each entry.
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      var orderedIds: seq[SdsMessageID] = @[]
      for msgId in channel.messageHistory.keys:
        orderedIds.add(msgId)
      let recentMessageIds = orderedIds[max(0, orderedIds.len - n) .. ^1]
      var entries: seq[HistoryEntry] = @[]
      for msgId in recentMessageIds:
        var entry = HistoryEntry(messageId: msgId)
        if not rm.onRetrievalHint.isNil():
          {.cast(raises: []).}:
            entry.retrievalHint = rm.onRetrievalHint(msgId)
          if entry.retrievalHint.len > 0:
            await rm.persistence.setRetrievalHint(msgId, entry.retrievalHint)
        entry.senderId = channel.messageHistory[msgId].senderId
        entries.add(entry)
      return entries
    else:
      return @[]
  except CatchableError:
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
): Future[seq[SdsMessageID]] {.async: (raises: []).} =
  try:
    await rm.lock.acquire()
    try:
      if channelId in rm.channels:
        var ids: seq[SdsMessageID] = @[]
        for msgId in rm.channels[channelId].messageHistory.keys:
          ids.add(msgId)
        return ids
      else:
        return @[]
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to get message history",
      channelId = channelId, error = getCurrentExceptionMsg()
    return @[]

proc getOutgoingBuffer*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Future[seq[UnacknowledgedMessage]] {.async: (raises: []).} =
  try:
    await rm.lock.acquire()
    try:
      if channelId in rm.channels:
        return rm.channels[channelId].outgoingBuffer
      else:
        return @[]
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to get outgoing buffer",
      channelId = channelId, error = getCurrentExceptionMsg()
    return @[]

proc getIncomingBuffer*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Future[Table[SdsMessageID, IncomingMessage]] {.async: (raises: []), gcsafe.} =
  try:
    await rm.lock.acquire()
    try:
      if channelId in rm.channels:
        return rm.channels[channelId].incomingBuffer
      else:
        return initTable[SdsMessageID, IncomingMessage]()
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to get incoming buffer",
      channelId = channelId, error = getCurrentExceptionMsg()
    return initTable[SdsMessageID, IncomingMessage]()

proc getOrCreateChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Future[ChannelContext] {.async: (raises: [CatchableError]).} =
  ## Returns the channel context, creating and bootstrapping it from the
  ## persistence backend if it does not yet exist in memory. The bloom filter
  ## is rebuilt deterministically from the loaded message history rather than
  ## persisted directly. Caller is expected to hold rm.lock.
  try:
    if channelId notin rm.channels:
      let channel = ChannelContext.new(
        RollingBloomFilter.init(
          rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate
        )
      )
      let snapshot = await rm.persistence.loadAllForChannel(channelId)
      channel.lamportTimestamp = snapshot.lamportTimestamp
      for msg in snapshot.messageHistory:
        channel.messageHistory[msg.messageId] = msg
        channel.bloomFilter.add(msg.messageId)
      for unack in snapshot.outgoingBuffer:
        channel.outgoingBuffer.add(unack)
      for incoming in snapshot.incomingBuffer:
        channel.incomingBuffer[incoming.message.messageId] = incoming
      for (msgId, entry) in snapshot.outgoingRepairBuffer:
        channel.outgoingRepairBuffer[msgId] = entry
      for (msgId, entry) in snapshot.incomingRepairBuffer:
        channel.incomingRepairBuffer[msgId] = entry
      rm.channels[channelId] = channel
    return rm.channels[channelId]
  except CatchableError as e:
    error "Failed to get or create channel",
      channelId = channelId, error = getCurrentExceptionMsg()
    raise e

proc ensureChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  try:
    await rm.lock.acquire()
    try:
      try:
        discard await rm.getOrCreateChannel(channelId)
        return ok()
      except CatchableError:
        error "Failed to ensure channel",
          channelId = channelId, msg = getCurrentExceptionMsg()
        return err(ReliabilityError.reInternalError)
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to ensure channel (lock)",
      channelId = channelId, msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reInternalError)

proc removeChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  try:
    await rm.lock.acquire()
    try:
      try:
        if channelId in rm.channels:
          let channel = rm.channels[channelId]
          await rm.dropChannelFromPersistence(channelId)
          channel.outgoingBuffer.setLen(0)
          channel.incomingBuffer.clear()
          channel.messageHistory.clear()
          channel.outgoingRepairBuffer.clear()
          channel.incomingRepairBuffer.clear()
          rm.channels.del(channelId)
        return ok()
      except CatchableError:
        error "Failed to remove channel",
          channelId = channelId, msg = getCurrentExceptionMsg()
        return err(ReliabilityError.reInternalError)
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to remove channel (lock)",
      channelId = channelId, msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reInternalError)

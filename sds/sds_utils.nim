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

proc reliabilityErr*(detail: string): ReliabilityError {.gcsafe, raises: [].} =
  ## Maps a backend-supplied persistence error string onto the
  ## `rePersistenceError` enum value. The enum carries no payload, so the
  ## original detail is logged here — this is the single point where a
  ## persistence failure is recorded, while the enum value travels up the
  ## `Result` chain to the public API caller, who decides what to do.
  ##
  ## With the snapshot-based Persistence interface, most protocol ops no
  ## longer propagate persistence errors at all — they log and continue
  ## (see PLAN_SNAPSHOT_PERSISTENCE.md §8). This helper is still used by
  ## the durability-intent ops (removeChannel, resetReliabilityManager,
  ## getOrCreateChannel) that retain err-on-failure semantics.
  warn "persistence operation failed", detail = detail
  ReliabilityError.rePersistenceError

proc snapshotMeta*(channel: ChannelContext): ChannelMeta {.gcsafe, raises: [].} =
  ## Captures the current in-memory state of a `ChannelContext` as a
  ## `ChannelMeta` blob, suitable for `Persistence.saveChannelMeta`.
  ##
  ## The in-memory shape uses `Table`-keyed buffers for fast lookup;
  ## `ChannelMeta` flattens them to `seq`s for stable wire serialization
  ## (see PLAN §6). The bloom filter and message history are intentionally
  ## excluded — the former is rebuilt from the latter on bootstrap, and
  ## the latter is persisted separately via `updateHistory`.
  result = ChannelMeta.init()
  result.lamportTimestamp = channel.lamportTimestamp
  for u in channel.outgoingBuffer:
    result.outgoingBuffer.add(u)
  for _, m in channel.incomingBuffer.pairs:
    result.incomingBuffer.add(m)
  for id, e in channel.outgoingRepairBuffer.pairs:
    result.outgoingRepairBuffer.add(OutgoingRepairKV(messageId: id, entry: e))
  for id, e in channel.incomingRepairBuffer.pairs:
    result.incomingRepairBuffer.add(IncomingRepairKV(messageId: id, entry: e))

proc trySaveMeta*(
    rm: ReliabilityManager, channelId: SdsChannelID, channel: ChannelContext
) {.async: (raises: []).} =
  ## Best-effort meta snapshot save. Per PLAN §8 the protocol op does NOT
  ## abort on persistence failure — in-memory state is the source of truth
  ## and the next op's snapshot will re-synchronise on-disk state.
  ##
  ## This helper is the single point where snapshot-save failures are
  ## logged; callers do not need to handle the Result.
  let res = await rm.persistence.saveChannelMeta(channelId, snapshotMeta(channel))
  if res.isErr:
    warn "snapshot save failed; in-memory state authoritative, next op will retry",
      channelId = channelId, detail = res.error

proc tryUpdateHistory*(
    rm: ReliabilityManager,
    channelId: SdsChannelID,
    append: seq[SdsMessage],
    evict: seq[SdsMessageID],
) {.async: (raises: []).} =
  ## Best-effort history append/evict. Skips the call entirely when both
  ## lists are empty (see HistoryUpdate contract). Non-fatal on error,
  ## same rationale as `trySaveMeta`.
  if append.len == 0 and evict.len == 0:
    return
  let update = HistoryUpdate(append: append, evict: evict)
  let res = await rm.persistence.updateHistory(channelId, update)
  if res.isErr:
    warn "history update failed; in-memory log authoritative, next op will retry",
      channelId = channelId, detail = res.error

proc dropChannelFromPersistence*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  ## Wipes all persisted state for a channel via a single backend call.
  ## Called by removeChannel / resetReliabilityManager before they clear
  ## in-memory state. Backend executes the wipe in one transaction.
  ##
  ## Phase 2D: uses `persistenceV2.dropChannel`. This op DOES propagate
  ## err on failure (durability is the semantic intent — the caller asked
  ## us to confirm a disk wipe; we cannot silently lie). See PLAN §8.
  (await rm.persistence.dropChannel(channelId)).isOkOr:
    return err(reliabilityErr(error))
  ok()

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
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  ## Inserts a delivered message into the channel's history map and evicts the
  ## eldest entries when the bound is exceeded. The full SdsMessage is kept so
  ## senderId is available for downstream causal-history population and the
  ## bytes can be re-serialized on demand to answer SDS-R repair requests.
  ## Persistence (phase 2B): mutations are batched into ONE V2
  ## `tryUpdateHistory` call at the end of this proc (append the new
  ## message + evict whatever rolled past `maxMessageHistory`). Failure is
  ## non-fatal: in-memory state is the source of truth, the next op's
  ## history update re-synchronises disk. Legacy per-row `appendLogEntry`
  ## / `removeLogEntry` calls are removed.
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      channel.messageHistory[msg.messageId] = msg
      var evicted: seq[SdsMessageID] = @[]
      while channel.messageHistory.len > rm.config.maxMessageHistory:
        var firstKey: SdsMessageID
        for k in channel.messageHistory.keys:
          firstKey = k
          break
        channel.messageHistory.del(firstKey)
        evicted.add(firstKey)
      await rm.tryUpdateHistory(channelId, @[msg], evicted)
    ok()
  except CatchableError:
    error "Failed to add to history",
      channelId = channelId, msgId = msg.messageId, error = getCurrentExceptionMsg()
    err(ReliabilityError.reInternalError)

proc updateLamportTimestamp*(
    rm: ReliabilityManager, msgTs: int64, channelId: SdsChannelID
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  ## Pure in-memory update (phase 2B). The new lamport value is captured
  ## by the op-end `trySaveMeta` issued by the calling protocol op; no
  ## per-mutation persistence call here.
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      channel.lamportTimestamp = max(msgTs, channel.lamportTimestamp) + 1
    ok()
  except CatchableError:
    error "Failed to update lamport timestamp",
      channelId = channelId, msgTs = msgTs, error = getCurrentExceptionMsg()
    err(ReliabilityError.reInternalError)

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
): Future[Result[seq[HistoryEntry], ReliabilityError]] {.async: (raises: []).} =
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
            # Phase 2B: best-effort hint persistence via V2. Non-fatal —
            # hints are an optimisation; a missing hint just means the
            # peer falls back to slower retrieval.
            let hintRes = await rm.persistence.setRetrievalHint(
              msgId, entry.retrievalHint
            )
            if hintRes.isErr:
              warn "retrieval hint save failed; continuing",
                msgId = msgId, detail = hintRes.error
        entry.senderId = channel.messageHistory[msgId].senderId
        entries.add(entry)
      ok(entries)
    else:
      ok(newSeq[HistoryEntry]())
  except CatchableError:
    error "Failed to get recent history entries",
      channelId = channelId, n = n, error = getCurrentExceptionMsg()
    err(ReliabilityError.reInternalError)

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
): Future[Result[ChannelContext, ReliabilityError]] {.async: (raises: []).} =
  ## Returns the channel context, creating and bootstrapping it from the
  ## persistence backend if it does not yet exist in memory. The bloom filter
  ## is rebuilt deterministically from the loaded message history rather than
  ## persisted directly. Caller is expected to hold rm.lock.
  ##
  ## Phase 2C: bootstrap via `persistenceV2.loadChannel`. Bootstrap DOES
  ## propagate err on load failure — the caller asked us to materialise a
  ## channel and we cannot do that without knowing the prior state. See
  ## PLAN §8.
  try:
    if channelId notin rm.channels:
      let channel = ChannelContext.new(
        RollingBloomFilter.init(
          rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate
        )
      )
      let data = (await rm.persistence.loadChannel(channelId)).valueOr:
        return err(reliabilityErr(error))
      channel.lamportTimestamp = data.meta.lamportTimestamp
      # Backend contract: messageHistory MUST be ordered oldest-first.
      # If a backend violates this, FIFO eviction breaks across restarts.
      for msg in data.messageHistory:
        channel.messageHistory[msg.messageId] = msg
        channel.bloomFilter.add(msg.messageId)
      for unack in data.meta.outgoingBuffer:
        channel.outgoingBuffer.add(unack)
      for incoming in data.meta.incomingBuffer:
        channel.incomingBuffer[incoming.message.messageId] = incoming
      for kv in data.meta.outgoingRepairBuffer:
        channel.outgoingRepairBuffer[kv.messageId] = kv.entry
      for kv in data.meta.incomingRepairBuffer:
        channel.incomingRepairBuffer[kv.messageId] = kv.entry
      rm.channels[channelId] = channel
    ok(rm.channels[channelId])
  except CatchableError:
    error "Failed to get or create channel",
      channelId = channelId, error = getCurrentExceptionMsg()
    err(ReliabilityError.reInternalError)

proc ensureChannel*(
    rm: ReliabilityManager, channelId: SdsChannelID
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  try:
    await rm.lock.acquire()
    try:
      (await rm.getOrCreateChannel(channelId)).isOkOr:
        return err(error)
      return ok()
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
          (await rm.dropChannelFromPersistence(channelId)).isOkOr:
            return err(error)
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

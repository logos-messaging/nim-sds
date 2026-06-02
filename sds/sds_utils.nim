import std/[times, tables, sequtils, sets, hashes]
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

proc snapshotMeta(channel: ChannelContext): ChannelMeta {.gcsafe, raises: [].} =
  ## Captures the current in-memory state of a `ChannelContext` as a
  ## `ChannelMeta` blob, suitable for `Persistence.saveChannelMeta`.
  ##
  ## The in-memory shape uses `Table`-keyed buffers for fast lookup;
  ## `ChannelMeta` flattens them to `seq`s for stable wire serialization
  ## (see PLAN §6). The bloom filter and message history are intentionally
  ## excluded — the former is rebuilt from the latter on bootstrap, and
  ## the latter is persisted separately via `updateHistory`.
  var meta = ChannelMeta.init()
  meta.lamportTimestamp = channel.lamportTimestamp
  for u in channel.outgoingBuffer:
    meta.outgoingBuffer.add(u)
  for _, m in channel.incomingBuffer.pairs:
    meta.incomingBuffer.add(m)
  for id, e in channel.outgoingRepairBuffer.pairs:
    meta.outgoingRepairBuffer.add(OutgoingRepairKV(messageId: id, entry: e))
  for id, e in channel.incomingRepairBuffer.pairs:
    meta.incomingRepairBuffer.add(IncomingRepairKV(messageId: id, entry: e))
  return meta

proc trySaveMeta*(
    rm: ReliabilityManager, channelId: SdsChannelID, channel: ChannelContext
) {.async: (raises: []).} =
  ## Best-effort meta snapshot save. Per PLAN §8 the protocol op does NOT
  ## abort on persistence failure — in-memory state is the source of truth
  ## and the next op's snapshot will re-synchronise on-disk state.
  ##
  ## This helper is the single point where snapshot-save failures are
  ## logged; callers do not need to handle the Result.
  (await rm.persistence.saveChannelMeta(channelId, snapshotMeta(channel))).isOkOr:
    warn "snapshot save failed; in-memory state authoritative, next op will retry",
      channelId = channelId, detail = error

proc queueHistoryAppend(channel: ChannelContext, msgId: SdsMessageID) =
  ## Push an append onto the pending history queue. Only the id is
  ## stored — the full SdsMessage is looked up from `messageHistory` at
  ## flush time (invariant: every queued id is present in messageHistory).
  ##
  ## Merge rule: **latest operation wins.** Cancels any pending evict for
  ## the same id, then adds. Handles the evict-then-re-add sequence
  ## correctly (e.g. SDS-R repair re-delivers a previously-evicted
  ## message while the backend is unreachable).
  channel.pendingHistoryEvicts.excl(msgId)
  channel.pendingHistoryAppends.incl(msgId)

proc queueHistoryEvict(channel: ChannelContext, msgId: SdsMessageID) =
  ## Push an evict onto the pending history queue. Merge rule symmetric
  ## with `queueHistoryAppend`: cancels any pending append for the same
  ## id (the just-evicted message no longer needs to be persisted as an
  ## addition), then adds to the evict set.
  channel.pendingHistoryAppends.excl(msgId)
  channel.pendingHistoryEvicts.incl(msgId)

proc tryUpdateHistory*(
    rm: ReliabilityManager, channelId: SdsChannelID
) {.async: (raises: []).} =
  ## Flush the channel's pending history queue to disk.
  ##
  ## The pending queue (`channel.pendingHistoryAppends` /
  ## `pendingHistoryEvicts`) plays a DUAL role — and that's deliberate:
  ##   1. **Per-op accumulator.** Every `addToHistory` call pushes its
  ##      mutation into this queue but does NOT persist. A protocol op
  ##      that invokes `addToHistory` N times (e.g. a
  ##      `processIncomingBuffer` cascade) leaves N entries queued and
  ##      issues exactly ONE `tryUpdateHistory` at op end — one
  ##      round-trip per op regardless of cascade depth. This fixes PR
  ##      #72 review comments #2 and #3.
  ##   2. **R2 retry queue.** If the flush fails, the queue is NOT
  ##      cleared. The next op's `addToHistory` calls add to it; the
  ##      next op's `tryUpdateHistory` retries the merged batch. This
  ##      fixes PR #72 review comment #1 (delta loss).
  ##
  ## Both roles share the same data structure because they want the same
  ## semantics: "merge everything pending into one batch and try to
  ## flush". Failure is non-fatal at the FFI boundary (PLAN §8) — the
  ## in-memory state is the source of truth.
  ##
  ## Callers MUST invoke this once at the end of every protocol op (even
  ## when this op had no history changes) — otherwise a previously-failed
  ## batch could sit on the queue indefinitely.
  var channel: ChannelContext
  try:
    if channelId notin rm.channels:
      return
    channel = rm.channels[channelId]
  except KeyError:
    return # checked `in` above; unreachable, but tables can raise per spec

  if channel.pendingHistoryAppends.len == 0 and channel.pendingHistoryEvicts.len == 0:
    return # nothing to flush — no round-trip cost

  var batch = HistoryUpdate.init()
  # Look up each queued id in messageHistory (source of truth). The
  # invariant on pendingHistoryAppends guarantees the id is present;
  # the defensive check below logs any violation rather than crashing.
  for id in channel.pendingHistoryAppends:
    try:
      if id in channel.messageHistory:
        batch.append.add(channel.messageHistory[id])
      else:
        warn "queued append id missing from messageHistory; invariant violated, skipping",
          channelId = channelId, msgId = id
    except KeyError:
      discard # unreachable — `in` was true
  for id in channel.pendingHistoryEvicts:
    batch.evict.add(id)

  let res = await rm.persistence.updateHistory(channelId, batch)
  if res.isOk:
    channel.pendingHistoryAppends.clear()
    channel.pendingHistoryEvicts.clear()
  else:
    warn "history update failed; queued for retry on next op",
      channelId = channelId,
      pendingAppends = channel.pendingHistoryAppends.len,
      pendingEvicts = channel.pendingHistoryEvicts.len,
      detail = res.error
    if channel.pendingHistoryAppends.len > rm.config.maxMessageHistory:
      warn "pending history queue exceeds maxMessageHistory; backend may be stuck",
        channelId = channelId, pendingAppends = channel.pendingHistoryAppends.len

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
    warn "persistence operation failed", cause = error
    return err(ReliabilityError.rePersistenceError)
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
        channel.pendingHistoryAppends.clear()
        channel.pendingHistoryEvicts.clear()
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
  ## Inserts a delivered message into the channel's history map, evicts
  ## the eldest entries past `maxMessageHistory`, and queues the resulting
  ## append+evict on the channel's pending-history queue. Does NOT issue
  ## a persistence call — the caller's op-end `tryUpdateHistory` flushes
  ## the queue in one round-trip.
  ##
  ## A cascade of N unblocked messages (e.g. `processIncomingBuffer`)
  ## therefore leaves N entries queued and triggers ONE persistence call
  ## at op end, not N. Fixes PR #72 review #2/#3.
  ##
  ## Direct callers (tests, ad-hoc) that want the disk write to land
  ## immediately should follow this with `await rm.tryUpdateHistory(channelId)`.
  try:
    if channelId in rm.channels:
      let channel = rm.channels[channelId]
      channel.messageHistory[msg.messageId] = msg
      queueHistoryAppend(channel, msg.messageId)
      while channel.messageHistory.len > rm.config.maxMessageHistory:
        var firstKey: SdsMessageID
        for k in channel.messageHistory.keys:
          firstKey = k
          break
        channel.messageHistory.del(firstKey)
        queueHistoryEvict(channel, firstKey)
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
        warn "persistence operation failed", cause = error
        return err(ReliabilityError.rePersistenceError)

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
          channel.pendingHistoryAppends.clear()
          channel.pendingHistoryEvicts.clear()
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

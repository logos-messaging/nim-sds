import std/[algorithm, times, tables, sets, options]
import chronos, results, chronicles
import ./[types, protobuf, sds_utils, rolling_bloom_filter]

export types, protobuf, sds_utils, rolling_bloom_filter

proc newReliabilityManager*(
    participantId: SdsParticipantID,
    config: ReliabilityConfig = defaultConfig(),
    persistence: Persistence = noOpPersistence(),
): Result[ReliabilityManager, ReliabilityError] =
  ## Creates a new multi-channel ReliabilityManager.
  ## `participantId` is REQUIRED (see `ReliabilityManager.new`).
  ## `persistence` defaults to a no-op backend; supply a real one to durably
  ## store SDS state across restarts.
  try:
    let rm = ReliabilityManager.new(participantId, config, persistence)
    return ok(rm)
  except Exception:
    error "Failed to create ReliabilityManager", msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reOutOfMemory)

proc isAcknowledged*(
    msg: UnacknowledgedMessage,
    causalHistory: seq[HistoryEntry],
    rbf: Option[RollingBloomFilter],
): bool =
  if msg.message.messageId in causalHistory.getMessageIds():
    return true

  if rbf.isSome():
    return rbf.get().contains(msg.message.messageId)

  return false

proc reviewAckStatus(
    rm: ReliabilityManager, msg: SdsMessage
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  try:
    var rbf: Option[RollingBloomFilter]
    if msg.bloomFilter.len > 0:
      let bfResult = deserializeBloomFilter(msg.bloomFilter)
      if bfResult.isOk():
        let bf = bfResult.get()
        rbf = some(
          RollingBloomFilter.init(
            filter = bf,
            capacity = bf.capacity,
            minCapacity =
              (bf.capacity.float * (100 - CapacityFlexPercent).float / 100.0).int,
            maxCapacity =
              (bf.capacity.float * (100 + CapacityFlexPercent).float / 100.0).int,
          )
        )
      else:
        error "Failed to deserialize bloom filter", error = bfResult.error
        rbf = none[RollingBloomFilter]()
    else:
      rbf = none[RollingBloomFilter]()

    if msg.channelId notin rm.channels:
      return ok()

    let channel = rm.channels[msg.channelId]
    var toDelete: seq[(int, SdsMessageID)] = @[]
    var i = 0

    while i < channel.outgoingBuffer.len:
      let outMsg = channel.outgoingBuffer[i]
      if outMsg.isAcknowledged(msg.causalHistory, rbf):
        if not rm.onMessageSent.isNil():
          {.cast(raises: []).}:
            rm.onMessageSent(outMsg.message.messageId, outMsg.message.channelId)
        toDelete.add((i, outMsg.message.messageId))
      inc i

    for k in countdown(toDelete.high, 0):
      # Phase 2B: in-memory deletion only; the caller's op-end trySaveMeta
      # captures the new outgoingBuffer state. The msgId half of the
      # tuple is unused now that there is no per-row persistence call.
      channel.outgoingBuffer.delete(toDelete[k][0])
    ok()
  except CatchableError:
    error "Failed to review ack status", msg = getCurrentExceptionMsg()
    err(ReliabilityError.reInternalError)

proc wrapOutgoingMessage*(
    rm: ReliabilityManager,
    message: seq[byte],
    messageId: SdsMessageID,
    channelId: SdsChannelID,
): Future[Result[seq[byte], ReliabilityError]] {.async: (raises: []), gcsafe.} =
  ## Wraps an outgoing message with reliability metadata.
  if message.len == 0:
    return err(ReliabilityError.reInvalidArgument)
  if message.len > MaxMessageSize:
    return err(ReliabilityError.reMessageTooLarge)

  try:
    await rm.lock.acquire()
    try:
      try:
        let channel = (await rm.getOrCreateChannel(channelId)).valueOr:
          return err(error)
        (await rm.updateLamportTimestamp(getTime().toUnix, channelId)).isOkOr:
          return err(error)

        let bfResult = serializeBloomFilter(channel.bloomFilter.filter)
        if bfResult.isErr():
          error "Failed to serialize bloom filter", channelId = channelId
          return err(ReliabilityError.reSerializationError)

        # SDS-R: collect eligible expired repair requests to attach. Per
        # spec (sds-r-send-message, RECOMMENDED), prioritise the entries with
        # the smallest minTimeRepairReq — they are the most overdue and the
        # ones the network most needs us to ask about.
        var repairReqs: seq[HistoryEntry] = @[]
        let now = getTime()
        var expiredKeys: seq[SdsMessageID] = @[]
        var eligible: seq[(SdsMessageID, OutgoingRepairEntry)] = @[]
        for msgId, repairEntry in channel.outgoingRepairBuffer:
          if now >= repairEntry.minTimeRepairReq:
            eligible.add((msgId, repairEntry))
        eligible.sort do(a, b: (SdsMessageID, OutgoingRepairEntry)) -> int:
          cmp(a[1].minTimeRepairReq, b[1].minTimeRepairReq)
        let take = min(eligible.len, rm.config.maxRepairRequests)
        for i in 0 ..< take:
          repairReqs.add(eligible[i][1].outHistEntry)
          expiredKeys.add(eligible[i][0])
        for key in expiredKeys:
          channel.outgoingRepairBuffer.del(key)
          # Phase 2B: in-memory deletion only; op-end trySaveMeta covers it.

        let causalHistory = (
          await rm.getRecentHistoryEntries(rm.config.maxCausalHistory, channelId)
        ).valueOr:
          return err(error)
        let msg = SdsMessage.init(
          messageId = messageId,
          lamportTimestamp = channel.lamportTimestamp,
          causalHistory = causalHistory,
          channelId = channelId,
          content = message,
          bloomFilter = bfResult.get(),
          senderId = rm.participantId,
          repairRequest = repairReqs,
        )

        let unackMsg = UnacknowledgedMessage.init(
          message = msg, sendTime = getTime(), resendAttempts = 0
        )
        channel.outgoingBuffer.add(unackMsg)
        # Phase 2B: in-memory append only; op-end trySaveMeta covers it.

        channel.bloomFilter.add(msg.messageId)
        # addToHistory mutates in-memory state and queues the append/evict
        # on the channel's pending-history queue; persistence happens
        # ONCE at op end via tryUpdateHistory.
        (await rm.addToHistory(msg, channelId)).isOkOr:
          return err(error)

        # Op end: one meta snapshot + one history flush, paired under the
        # lock per the Persistence atomicity contract. tryUpdateHistory
        # flushes the channel's pending queue (this op's mutations PLUS
        # any leftovers from a prior failed write — R2 retry).
        await rm.trySaveMeta(channelId, channel)
        await rm.tryUpdateHistory(channelId)

        return serializeMessage(msg)
      except CatchableError:
        error "Failed to wrap message",
          channelId = channelId, msg = getCurrentExceptionMsg()
        return err(ReliabilityError.reSerializationError)
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to wrap message (lock)",
      channelId = channelId, msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reSerializationError)

proc processIncomingBuffer(
    rm: ReliabilityManager, channelId: SdsChannelID
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  ## Cascade-deliver any buffered messages whose dependencies are now met.
  ## Each `addToHistory` call queues its append/evict on the channel's
  ## pending-history queue; the *caller* (a public protocol op) issues
  ## ONE `tryUpdateHistory` at op end to flush the whole cascade in a
  ## single round-trip.
  try:
    await rm.lock.acquire()
    try:
      if channelId notin rm.channels:
        error "Channel does not exist", channelId = channelId
        return ok()

      let channel = rm.channels[channelId]
      if channel.incomingBuffer.len == 0:
        return ok()

      var processed = initHashSet[SdsMessageID]()
      var readyToProcess = newSeq[SdsMessageID]()

      for msgId, entry in channel.incomingBuffer:
        if entry.missingDeps.len == 0:
          readyToProcess.add(msgId)

      while readyToProcess.len > 0:
        let msgId = readyToProcess.pop()
        if msgId in processed:
          continue

        if msgId in channel.incomingBuffer:
          (await rm.addToHistory(channel.incomingBuffer[msgId].message, channelId)).isOkOr:
            return err(error)
          if not rm.onMessageReady.isNil():
            {.cast(raises: []).}:
              rm.onMessageReady(msgId, channelId)
          processed.incl(msgId)

          for remainingId, entry in channel.incomingBuffer:
            if remainingId notin processed:
              if msgId in entry.missingDeps:
                # Phase 2B: in-memory dep-set shrink only; the parent op
                # (unwrap / markDeps) issues a single trySaveMeta at its
                # end that captures the final incomingBuffer state.
                channel.incomingBuffer[remainingId].missingDeps.excl(msgId)
                if channel.incomingBuffer[remainingId].missingDeps.len == 0:
                  readyToProcess.add(remainingId)

      for msgId in processed:
        # Phase 2B: in-memory deletion only; parent op's trySaveMeta covers
        # the drained buffer state.
        channel.incomingBuffer.del(msgId)
      ok()
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to process incoming buffer",
      channelId = channelId, msg = getCurrentExceptionMsg()
    err(ReliabilityError.reInternalError)

proc unwrapReceivedMessage*(
    rm: ReliabilityManager, message: seq[byte]
): Future[
    Result[
      tuple[message: seq[byte], missingDeps: seq[HistoryEntry], channelId: SdsChannelID],
      ReliabilityError,
    ]
] {.async: (raises: []).} =
  ## Unwraps a received message and processes its reliability metadata.
  try:
    let channelId = extractChannelId(message).valueOr:
      return err(ReliabilityError.reDeserializationError)

    let msg = deserializeMessage(message).valueOr:
      return err(ReliabilityError.reDeserializationError)

    let channel = (await rm.getOrCreateChannel(channelId)).valueOr:
      return err(error)

    # SDS-R: opportunistic repair-buffer cleanup — applies to duplicates too,
    # so rebroadcasts cancel redundant responses on peers that already have the message.
    # Phase 2B: in-memory deletes only; op-end trySaveMeta covers it.
    channel.outgoingRepairBuffer.del(msg.messageId)
    channel.incomingRepairBuffer.del(msg.messageId)

    if msg.messageId in channel.messageHistory:
      # Duplicate: no history change. Still flush the meta (repair-buffer
      # dels above are mutations) and the history queue (any pending
      # entries from a prior failed write get retried here too).
      await rm.trySaveMeta(channelId, channel)
      await rm.tryUpdateHistory(channelId)
      return ok((msg.content, @[], channelId))

    channel.bloomFilter.add(msg.messageId)

    (await rm.updateLamportTimestamp(msg.lamportTimestamp, channelId)).isOkOr:
      return err(error)
    (await rm.reviewAckStatus(msg)).isOkOr:
      return err(error)

    # SDS-R: process incoming repair requests from this message. We can only
    # answer for messages we have actually delivered (i.e. that live in
    # messageHistory) — buffered-but-undelivered messages are not in a state
    # to confidently rebroadcast.
    let now = getTime()
    for repairEntry in msg.repairRequest:
      # Remove from our own outgoing repair buffer (someone else is also requesting).
      # Phase 2B: in-memory delete only; op-end trySaveMeta covers it.
      channel.outgoingRepairBuffer.del(repairEntry.messageId)
      if repairEntry.messageId in channel.messageHistory and rm.participantId.len > 0 and
          repairEntry.senderId.len > 0:
        if isInResponseGroup(
          rm.participantId, repairEntry.senderId, repairEntry.messageId,
          rm.config.numResponseGroups,
        ):
          let serialized =
            serializeMessage(channel.messageHistory[repairEntry.messageId])
          if serialized.isOk():
            let tResp = computeTResp(
              rm.participantId, repairEntry.senderId, repairEntry.messageId,
              rm.config.repairTMax,
            )
            let inEntry = IncomingRepairEntry(
              inHistEntry: repairEntry,
              cachedMessage: serialized.get(),
              minTimeRepairResp: now + tResp,
            )
            # Phase 2B: in-memory insert only; op-end trySaveMeta covers it.
            channel.incomingRepairBuffer[repairEntry.messageId] = inEntry

    var missingDeps = rm.checkDependencies(msg.causalHistory, channelId)

    if missingDeps.len == 0:
      var depsInBuffer = false
      for msgId, entry in channel.incomingBuffer.pairs():
        if msgId in msg.causalHistory.getMessageIds():
          depsInBuffer = true
          break
      if depsInBuffer:
        let entry =
          IncomingMessage.init(message = msg, missingDeps = initHashSet[SdsMessageID]())
        # Phase 2B: in-memory insert only; op-end trySaveMeta covers it.
        channel.incomingBuffer[msg.messageId] = entry
      else:
        (await rm.addToHistory(msg, channelId)).isOkOr:
          return err(error)
        # Unblock any buffered messages that were waiting on this one.
        for pendingId, entry in channel.incomingBuffer:
          if msg.messageId in entry.missingDeps:
            channel.incomingBuffer[pendingId].missingDeps.excl(msg.messageId)
        # Cascade — addToHistory calls within processIncomingBuffer queue
        # their entries on the channel's pending-history queue, flushed
        # by the single op-end tryUpdateHistory below.
        (await rm.processIncomingBuffer(channelId)).isOkOr:
          return err(error)
        if not rm.onMessageReady.isNil():
          {.cast(raises: []).}:
            rm.onMessageReady(msg.messageId, channelId)
    else:
      let entry = IncomingMessage.init(
        message = msg, missingDeps = missingDeps.getMessageIds().toHashSet()
      )
      # Phase 2B: in-memory insert only; op-end trySaveMeta covers it.
      channel.incomingBuffer[msg.messageId] = entry
      if not rm.onMissingDependencies.isNil():
        {.cast(raises: []).}:
          rm.onMissingDependencies(msg.messageId, missingDeps, channelId)

      # SDS-R: add missing deps to outgoing repair buffer
      if rm.participantId.len > 0:
        for dep in missingDeps:
          if dep.messageId notin channel.outgoingRepairBuffer:
            let tReq = computeTReq(
              rm.participantId, dep.messageId, rm.config.repairTMin,
              rm.config.repairTMax,
            )
            let outEntry =
              OutgoingRepairEntry(outHistEntry: dep, minTimeRepairReq: now + tReq)
            # Phase 2B: in-memory insert only; op-end trySaveMeta covers it.
            channel.outgoingRepairBuffer[dep.messageId] = outEntry

    # Op end: one meta snapshot + one history flush, paired under the
    # lock. The flush is the single point where any cascade-driven
    # appends/evicts hit disk (R2 queue absorbs failures).
    await rm.trySaveMeta(channelId, channel)
    await rm.tryUpdateHistory(channelId)

    return ok((msg.content, missingDeps, channelId))
  except CatchableError:
    error "Failed to unwrap message", msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reDeserializationError)

proc markDependenciesMet*(
    rm: ReliabilityManager, messageIds: seq[SdsMessageID], channelId: SdsChannelID
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  ## Marks the specified message dependencies as met.
  try:
    if channelId notin rm.channels:
      return err(ReliabilityError.reInvalidArgument)

    let channel = rm.channels[channelId]

    for msgId in messageIds:
      if not channel.bloomFilter.contains(msgId):
        channel.bloomFilter.add(msgId)

      # Phase 2B: in-memory dep-set shrink + repair-buffer dels only; the
      # op-end trySaveMeta below covers all mutations atomically.
      for pendingId, entry in channel.incomingBuffer:
        if msgId in entry.missingDeps:
          channel.incomingBuffer[pendingId].missingDeps.excl(msgId)

      # SDS-R: clear from repair buffers (dependency now met).
      channel.outgoingRepairBuffer.del(msgId)
      channel.incomingRepairBuffer.del(msgId)

    (await rm.processIncomingBuffer(channelId)).isOkOr:
      return err(error)

    # Op end: one meta snapshot + one history flush, paired under the lock.
    # The flush covers any cascade-driven appends/evicts queued during
    # processIncomingBuffer.
    if channelId in rm.channels:
      await rm.trySaveMeta(channelId, rm.channels[channelId])
      await rm.tryUpdateHistory(channelId)
    return ok()
  except CatchableError:
    error "Failed to mark dependencies as met",
      channelId = channelId, msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reInternalError)

proc setCallbacks*(
    rm: ReliabilityManager,
    onMessageReady: MessageReadyCallback,
    onMessageSent: MessageSentCallback,
    onMissingDependencies: MissingDependenciesCallback,
    onPeriodicSync: PeriodicSyncCallback = nil,
    onRetrievalHint: RetrievalHintProvider = nil,
    onRepairReady: RepairReadyCallback = nil,
) {.async: (raises: []).} =
  ## Sets the callback functions for various events in the ReliabilityManager.
  try:
    await rm.lock.acquire()
    try:
      rm.onMessageReady = onMessageReady
      rm.onMessageSent = onMessageSent
      rm.onMissingDependencies = onMissingDependencies
      rm.onPeriodicSync = onPeriodicSync
      rm.onRetrievalHint = onRetrievalHint
      rm.onRepairReady = onRepairReady
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to set callbacks", msg = getCurrentExceptionMsg()

proc checkUnacknowledgedMessages(
    rm: ReliabilityManager, channelId: SdsChannelID
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  ## Persistence model (PLAN_SNAPSHOT_PERSISTENCE.md phase 2.2): per-entry
  ## saveOutgoing / removeOutgoing calls are replaced by a single
  ## `trySaveMeta` at the end of the pass, *only* if the buffer actually
  ## changed (resend-attempt incremented, or entry expired). Failure is
  ## logged but does not abort the pass — next tick reissues a fresh
  ## snapshot.
  try:
    await rm.lock.acquire()
    try:
      if channelId notin rm.channels:
        error "Channel does not exist", channelId = channelId
        return ok()

      let channel = rm.channels[channelId]
      let now = getTime()
      var newOutgoingBuffer: seq[UnacknowledgedMessage] = @[]
      var dirty = false

      for unackMsg in channel.outgoingBuffer:
        let elapsed = now - unackMsg.sendTime
        if elapsed > rm.config.resendInterval:
          if unackMsg.resendAttempts < rm.config.maxResendAttempts:
            var updatedMsg = unackMsg
            updatedMsg.resendAttempts += 1
            updatedMsg.sendTime = now
            newOutgoingBuffer.add(updatedMsg)
            dirty = true
          else:
            if not rm.onMessageSent.isNil():
              {.cast(raises: []).}:
                rm.onMessageSent(unackMsg.message.messageId, channelId)
            dirty = true # entry dropped from newOutgoingBuffer
        else:
          newOutgoingBuffer.add(unackMsg)

      channel.outgoingBuffer = newOutgoingBuffer
      if dirty:
        await rm.trySaveMeta(channelId, channel)
      ok()
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to check unacknowledged messages",
      channelId = channelId, msg = getCurrentExceptionMsg()
    err(ReliabilityError.reInternalError)

proc periodicBufferSweep(rm: ReliabilityManager) {.async: (raises: [CancelledError]).} =
  while true:
    try:
      for channelId, channel in rm.channels:
        # Background maintenance has no caller to return to: a persistence
        # error is logged (by reliabilityErr) and the sweep continues; the
        # next tick retries.
        discard await rm.checkUnacknowledgedMessages(channelId)
        await rm.cleanBloomFilter(channelId)
    except CatchableError:
      error "Error in periodic buffer sweep", msg = getCurrentExceptionMsg()
    await sleepAsync(chronos.milliseconds(rm.config.bufferSweepInterval.inMilliseconds))

proc periodicSyncMessage(rm: ReliabilityManager) {.async: (raises: [CancelledError]).} =
  while true:
    try:
      if not rm.onPeriodicSync.isNil():
        {.cast(raises: []).}:
          rm.onPeriodicSync()
    except CatchableError:
      error "Error in periodic sync", msg = getCurrentExceptionMsg()
    await sleepAsync(chronos.seconds(rm.config.syncMessageInterval.inSeconds))

proc runRepairSweep*(
    rm: ReliabilityManager
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  ## SDS-R: Runs a single pass of the repair sweep.
  ## - Incoming: fires onRepairReady for expired T_resp entries and removes them
  ## - Outgoing: drops entries past T_max window
  ## Exposed so it can be driven directly in tests; also invoked by periodicRepairSweep.
  ## Acquires rm.lock so the repair buffers cannot be observed mid-mutation by
  ## a concurrent wrapOutgoingMessage / unwrapReceivedMessage on another task.
  ##
  ## Persistence model (PLAN_SNAPSHOT_PERSISTENCE.md phase 2.1): per-entry
  ## removeIncomingRepair / removeOutgoingRepair calls are replaced by a
  ## single `trySaveMeta` per *dirty* channel at the end of that channel's
  ## sweep. A persistence failure is logged but DOES NOT abort the sweep —
  ## in-memory state is the source of truth and the next op (or sweep tick)
  ## will issue a fresh self-contained snapshot.
  try:
    await rm.lock.acquire()
    try:
      let now = getTime()
      for channelId, channel in rm.channels:
        var dirty = false
        try:
          # Check incoming repair buffer for expired T_resp (time to rebroadcast)
          var toRebroadcast: seq[SdsMessageID] = @[]
          for msgId, entry in channel.incomingRepairBuffer:
            if now >= entry.minTimeRepairResp:
              toRebroadcast.add(msgId)

          for msgId in toRebroadcast:
            let entry = channel.incomingRepairBuffer[msgId]
            channel.incomingRepairBuffer.del(msgId)
            dirty = true
            if not rm.onRepairReady.isNil():
              {.cast(raises: []).}:
                rm.onRepairReady(entry.cachedMessage, channelId)

          # Drop expired outgoing repair entries past T_max
          var toRemove: seq[SdsMessageID] = @[]
          let tMaxDuration = rm.config.repairTMax
          for msgId, entry in channel.outgoingRepairBuffer:
            if now - entry.minTimeRepairReq > tMaxDuration:
              toRemove.add(msgId)
          for msgId in toRemove:
            channel.outgoingRepairBuffer.del(msgId)
            dirty = true
        except CatchableError:
          error "Error in repair sweep for channel",
            channelId = channelId, msg = getCurrentExceptionMsg()
        # Snapshot only if this channel actually mutated. Skipping the call
        # when clean honours the dirty-flag guard in ANALYSIS_SNAPSHOT_SAVE_POINTS
        # — otherwise an idle node still issues 0.2 saves/s/channel just
        # because the periodic sweep ran.
        if dirty:
          await rm.trySaveMeta(channelId, channel)
      ok()
    finally:
      rm.lock.release()
  except CatchableError:
    error "Error in repair sweep", msg = getCurrentExceptionMsg()
    err(ReliabilityError.reInternalError)

proc periodicRepairSweep(rm: ReliabilityManager) {.async: (raises: [CancelledError]).} =
  ## SDS-R: Periodically checks repair buffers for expired entries.
  while true:
    try:
      # Background maintenance: log a failed pass and retry next tick.
      discard await rm.runRepairSweep()
    except CatchableError:
      error "Error in periodic repair sweep", msg = getCurrentExceptionMsg()
    await sleepAsync(chronos.milliseconds(rm.config.repairSweepInterval.inMilliseconds))

proc startPeriodicTasks*(rm: ReliabilityManager) =
  ## Starts the periodic background tasks (buffer sweep, sync message,
  ## SDS-R repair sweep). The futures are kept on the manager so `cleanup`
  ## can cancel them — without that, the loops would outlive a cleaned-up
  ## manager and keep firing against cleared state.
  rm.periodicTasks.add(FutureBase(rm.periodicBufferSweep()))
  rm.periodicTasks.add(FutureBase(rm.periodicSyncMessage()))
  rm.periodicTasks.add(FutureBase(rm.periodicRepairSweep()))

proc resetReliabilityManager*(
    rm: ReliabilityManager
): Future[Result[void, ReliabilityError]] {.async: (raises: []).} =
  ## Resets the ReliabilityManager to its initial state.
  try:
    await rm.lock.acquire()
    try:
      try:
        for channelId, channel in rm.channels:
          (await rm.dropChannelFromPersistence(channelId)).isOkOr:
            return err(error)
          channel.lamportTimestamp = 0
          channel.messageHistory.clear()
          channel.outgoingBuffer.setLen(0)
          channel.incomingBuffer.clear()
          channel.outgoingRepairBuffer.clear()
          channel.incomingRepairBuffer.clear()
          channel.pendingHistoryAppends.clear()
          channel.pendingHistoryEvicts.clear()
          channel.bloomFilter = RollingBloomFilter.init(
            rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate
          )
        rm.channels.clear()
        return ok()
      except CatchableError:
        error "Failed to reset ReliabilityManager", msg = getCurrentExceptionMsg()
        return err(ReliabilityError.reInternalError)
    finally:
      rm.lock.release()
  except CatchableError:
    error "Failed to reset ReliabilityManager (lock)", msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reInternalError)

import std/[algorithm, times, locks, tables, sets, options]
import chronos, results, chronicles
import sds/[types, protobuf, sds_utils, rolling_bloom_filter]

export types, protobuf, sds_utils, rolling_bloom_filter

proc newReliabilityManager*(
    config: ReliabilityConfig = defaultConfig(),
    participantId: SdsParticipantID = "".SdsParticipantID,
    persistence: Persistence = noOpPersistence(),
): Result[ReliabilityManager, ReliabilityError] =
  ## Creates a new multi-channel ReliabilityManager.
  ## `persistence` defaults to a no-op backend; supply a real one to durably
  ## store SDS state across restarts.
  try:
    let rm = ReliabilityManager.new(config, participantId, persistence)
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

proc reviewAckStatus(rm: ReliabilityManager, msg: SdsMessage) {.gcsafe.} =
  var rbf: Option[RollingBloomFilter]
  if msg.bloomFilter.len > 0:
    let bfResult = deserializeBloomFilter(msg.bloomFilter)
    if bfResult.isOk():
      let bf = bfResult.get()
      rbf = some(
        RollingBloomFilter.init(
          filter = bf,
          capacity = bf.capacity,
          minCapacity = (bf.capacity.float * (100 - CapacityFlexPercent).float / 100.0).int,
          maxCapacity = (bf.capacity.float * (100 + CapacityFlexPercent).float / 100.0).int,
        )
      )
    else:
      error "Failed to deserialize bloom filter", error = bfResult.error
      rbf = none[RollingBloomFilter]()
  else:
    rbf = none[RollingBloomFilter]()

  if msg.channelId notin rm.channels:
    return

  let channel = rm.channels[msg.channelId]
  var toDelete: seq[(int, SdsMessageID)] = @[]
  var i = 0

  while i < channel.outgoingBuffer.len:
    let outMsg = channel.outgoingBuffer[i]
    if outMsg.isAcknowledged(msg.causalHistory, rbf):
      if not rm.onMessageSent.isNil():
        rm.onMessageSent(outMsg.message.messageId, outMsg.message.channelId)
      toDelete.add((i, outMsg.message.messageId))
    inc i

  for k in countdown(toDelete.high, 0):
    let (idx, ackedId) = toDelete[k]
    channel.outgoingBuffer.delete(idx)
    rm.persistence.removeOutgoing(msg.channelId, ackedId)

proc wrapOutgoingMessage*(
    rm: ReliabilityManager,
    message: seq[byte],
    messageId: SdsMessageID,
    channelId: SdsChannelID,
): Result[seq[byte], ReliabilityError] =
  ## Wraps an outgoing message with reliability metadata.
  if message.len == 0:
    return err(ReliabilityError.reInvalidArgument)
  if message.len > MaxMessageSize:
    return err(ReliabilityError.reMessageTooLarge)

  withLock rm.lock:
    try:
      let channel = rm.getOrCreateChannel(channelId)
      rm.updateLamportTimestamp(getTime().toUnix, channelId)

      let bfResult = serializeBloomFilter(channel.bloomFilter.filter)
      if bfResult.isErr:
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
        rm.persistence.removeOutgoingRepair(channelId, key)

      let msg = SdsMessage.init(
        messageId = messageId,
        lamportTimestamp = channel.lamportTimestamp,
        causalHistory = rm.getRecentHistoryEntries(rm.config.maxCausalHistory, channelId),
        channelId = channelId,
        content = message,
        bloomFilter = bfResult.get(),
        senderId = rm.participantId,
        repairRequest = repairReqs,
      )

      let unackMsg =
        UnacknowledgedMessage.init(message = msg, sendTime = getTime(), resendAttempts = 0)
      channel.outgoingBuffer.add(unackMsg)
      rm.persistence.saveOutgoing(channelId, unackMsg)

      channel.bloomFilter.add(msg.messageId)
      # The full SdsMessage carries senderId and content, so a single
      # addToHistory replaces the old triple-write to messageHistory,
      # messageCache, and messageSenders.
      rm.addToHistory(msg, channelId)

      return serializeMessage(msg)
    except Exception:
      error "Failed to wrap message",
        channelId = channelId, msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reSerializationError)

proc processIncomingBuffer(rm: ReliabilityManager, channelId: SdsChannelID) {.gcsafe.} =
  withLock rm.lock:
    if channelId notin rm.channels:
      error "Channel does not exist", channelId = channelId
      return

    let channel = rm.channels[channelId]
    if channel.incomingBuffer.len == 0:
      return

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
        rm.addToHistory(channel.incomingBuffer[msgId].message, channelId)
        if not rm.onMessageReady.isNil():
          rm.onMessageReady(msgId, channelId)
        processed.incl(msgId)

        for remainingId, entry in channel.incomingBuffer:
          if remainingId notin processed:
            if msgId in entry.missingDeps:
              channel.incomingBuffer[remainingId].missingDeps.excl(msgId)
              rm.persistence.saveIncoming(
                channelId, channel.incomingBuffer[remainingId]
              )
              if channel.incomingBuffer[remainingId].missingDeps.len == 0:
                readyToProcess.add(remainingId)

    for msgId in processed:
      channel.incomingBuffer.del(msgId)
      rm.persistence.removeIncoming(channelId, msgId)

proc unwrapReceivedMessage*(
    rm: ReliabilityManager, message: seq[byte]
): Result[
    tuple[message: seq[byte], missingDeps: seq[HistoryEntry], channelId: SdsChannelID],
    ReliabilityError,
] =
  ## Unwraps a received message and processes its reliability metadata.
  try:
    let channelId = extractChannelId(message).valueOr:
      return err(ReliabilityError.reDeserializationError)

    let msg = deserializeMessage(message).valueOr:
      return err(ReliabilityError.reDeserializationError)

    let channel = rm.getOrCreateChannel(channelId)

    # SDS-R: opportunistic repair-buffer cleanup — applies to duplicates too,
    # so rebroadcasts cancel redundant responses on peers that already have the message.
    channel.outgoingRepairBuffer.del(msg.messageId)
    rm.persistence.removeOutgoingRepair(channelId, msg.messageId)
    channel.incomingRepairBuffer.del(msg.messageId)
    rm.persistence.removeIncomingRepair(channelId, msg.messageId)

    if msg.messageId in channel.messageHistory:
      return ok((msg.content, @[], channelId))

    channel.bloomFilter.add(msg.messageId)

    rm.updateLamportTimestamp(msg.lamportTimestamp, channelId)
    rm.reviewAckStatus(msg)

    # SDS-R: process incoming repair requests from this message. We can only
    # answer for messages we have actually delivered (i.e. that live in
    # messageHistory) — buffered-but-undelivered messages are not in a state
    # to confidently rebroadcast.
    let now = getTime()
    for repairEntry in msg.repairRequest:
      # Remove from our own outgoing repair buffer (someone else is also requesting)
      channel.outgoingRepairBuffer.del(repairEntry.messageId)
      rm.persistence.removeOutgoingRepair(channelId, repairEntry.messageId)
      if repairEntry.messageId in channel.messageHistory and
         rm.participantId.len > 0 and repairEntry.senderId.len > 0:
        if isInResponseGroup(
          rm.participantId, repairEntry.senderId,
          repairEntry.messageId, rm.config.numResponseGroups
        ):
          let serialized = serializeMessage(channel.messageHistory[repairEntry.messageId])
          if serialized.isOk():
            let tResp = computeTResp(
              rm.participantId, repairEntry.senderId,
              repairEntry.messageId, rm.config.repairTMax
            )
            let inEntry = IncomingRepairEntry(
              inHistEntry: repairEntry,
              cachedMessage: serialized.get(),
              minTimeRepairResp: now + tResp,
            )
            channel.incomingRepairBuffer[repairEntry.messageId] = inEntry
            rm.persistence.saveIncomingRepair(channelId, repairEntry.messageId, inEntry)

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
        channel.incomingBuffer[msg.messageId] = entry
        rm.persistence.saveIncoming(channelId, entry)
      else:
        rm.addToHistory(msg, channelId)
        # Unblock any buffered messages that were waiting on this one.
        var unblocked: seq[SdsMessageID] = @[]
        for pendingId, entry in channel.incomingBuffer:
          if msg.messageId in entry.missingDeps:
            channel.incomingBuffer[pendingId].missingDeps.excl(msg.messageId)
            unblocked.add(pendingId)
        for pendingId in unblocked:
          rm.persistence.saveIncoming(channelId, channel.incomingBuffer[pendingId])
        rm.processIncomingBuffer(channelId)
        if not rm.onMessageReady.isNil():
          rm.onMessageReady(msg.messageId, channelId)
    else:
      let entry = IncomingMessage.init(
        message = msg,
        missingDeps = missingDeps.getMessageIds().toHashSet(),
      )
      channel.incomingBuffer[msg.messageId] = entry
      rm.persistence.saveIncoming(channelId, entry)
      if not rm.onMissingDependencies.isNil():
        rm.onMissingDependencies(msg.messageId, missingDeps, channelId)

      # SDS-R: add missing deps to outgoing repair buffer
      if rm.participantId.len > 0:
        for dep in missingDeps:
          if dep.messageId notin channel.outgoingRepairBuffer:
            let tReq = computeTReq(
              rm.participantId, dep.messageId,
              rm.config.repairTMin, rm.config.repairTMax
            )
            let outEntry = OutgoingRepairEntry(
              outHistEntry: dep,
              minTimeRepairReq: now + tReq,
            )
            channel.outgoingRepairBuffer[dep.messageId] = outEntry
            rm.persistence.saveOutgoingRepair(channelId, dep.messageId, outEntry)

    return ok((msg.content, missingDeps, channelId))
  except Exception:
    error "Failed to unwrap message", msg = getCurrentExceptionMsg()
    return err(ReliabilityError.reDeserializationError)

proc markDependenciesMet*(
    rm: ReliabilityManager, messageIds: seq[SdsMessageID], channelId: SdsChannelID
): Result[void, ReliabilityError] =
  ## Marks the specified message dependencies as met.
  try:
    if channelId notin rm.channels:
      return err(ReliabilityError.reInvalidArgument)

    let channel = rm.channels[channelId]

    for msgId in messageIds:
      if not channel.bloomFilter.contains(msgId):
        channel.bloomFilter.add(msgId)

      var unblocked: seq[SdsMessageID] = @[]
      for pendingId, entry in channel.incomingBuffer:
        if msgId in entry.missingDeps:
          channel.incomingBuffer[pendingId].missingDeps.excl(msgId)
          unblocked.add(pendingId)
      for pendingId in unblocked:
        rm.persistence.saveIncoming(channelId, channel.incomingBuffer[pendingId])

      # SDS-R: clear from repair buffers (dependency now met)
      channel.outgoingRepairBuffer.del(msgId)
      rm.persistence.removeOutgoingRepair(channelId, msgId)
      channel.incomingRepairBuffer.del(msgId)
      rm.persistence.removeIncomingRepair(channelId, msgId)

    rm.processIncomingBuffer(channelId)
    return ok()
  except Exception:
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
) =
  ## Sets the callback functions for various events in the ReliabilityManager.
  withLock rm.lock:
    rm.onMessageReady = onMessageReady
    rm.onMessageSent = onMessageSent
    rm.onMissingDependencies = onMissingDependencies
    rm.onPeriodicSync = onPeriodicSync
    rm.onRetrievalHint = onRetrievalHint
    rm.onRepairReady = onRepairReady

proc checkUnacknowledgedMessages(
    rm: ReliabilityManager, channelId: SdsChannelID
) {.gcsafe.} =
  withLock rm.lock:
    if channelId notin rm.channels:
      error "Channel does not exist", channelId = channelId
      return

    let channel = rm.channels[channelId]
    let now = getTime()
    var newOutgoingBuffer: seq[UnacknowledgedMessage] = @[]

    for unackMsg in channel.outgoingBuffer:
      let elapsed = now - unackMsg.sendTime
      if elapsed > rm.config.resendInterval:
        if unackMsg.resendAttempts < rm.config.maxResendAttempts:
          var updatedMsg = unackMsg
          updatedMsg.resendAttempts += 1
          updatedMsg.sendTime = now
          newOutgoingBuffer.add(updatedMsg)
          rm.persistence.saveOutgoing(channelId, updatedMsg)
        else:
          if not rm.onMessageSent.isNil():
            rm.onMessageSent(unackMsg.message.messageId, channelId)
          rm.persistence.removeOutgoing(channelId, unackMsg.message.messageId)
      else:
        newOutgoingBuffer.add(unackMsg)

    channel.outgoingBuffer = newOutgoingBuffer

proc periodicBufferSweep(
    rm: ReliabilityManager
) {.async: (raises: [CancelledError]), gcsafe.} =
  while true:
    try:
      for channelId, channel in rm.channels:
        try:
          rm.checkUnacknowledgedMessages(channelId)
          rm.cleanBloomFilter(channelId)
        except Exception:
          error "Error in buffer sweep for channel",
            channelId = channelId, msg = getCurrentExceptionMsg()
    except Exception:
      error "Error in periodic buffer sweep", msg = getCurrentExceptionMsg()

    await sleepAsync(chronos.milliseconds(rm.config.bufferSweepInterval.inMilliseconds))

proc periodicSyncMessage(
    rm: ReliabilityManager
) {.async: (raises: [CancelledError]), gcsafe.} =
  while true:
    try:
      if not rm.onPeriodicSync.isNil():
        rm.onPeriodicSync()
    except Exception:
      error "Error in periodic sync", msg = getCurrentExceptionMsg()
    await sleepAsync(chronos.seconds(rm.config.syncMessageInterval.inSeconds))

proc runRepairSweep*(rm: ReliabilityManager) {.gcsafe, raises: [].} =
  ## SDS-R: Runs a single pass of the repair sweep.
  ## - Incoming: fires onRepairReady for expired T_resp entries and removes them
  ## - Outgoing: drops entries past T_max window
  ## Exposed so it can be driven directly in tests; also invoked by periodicRepairSweep.
  ## Acquires rm.lock so the repair buffers cannot be observed mid-mutation by
  ## a concurrent wrapOutgoingMessage / unwrapReceivedMessage on another thread.
  withLock rm.lock:
    try:
      let now = getTime()
      for channelId, channel in rm.channels:
        try:
          # Check incoming repair buffer for expired T_resp (time to rebroadcast)
          var toRebroadcast: seq[SdsMessageID] = @[]
          for msgId, entry in channel.incomingRepairBuffer:
            if now >= entry.minTimeRepairResp:
              toRebroadcast.add(msgId)

          for msgId in toRebroadcast:
            let entry = channel.incomingRepairBuffer[msgId]
            channel.incomingRepairBuffer.del(msgId)
            rm.persistence.removeIncomingRepair(channelId, msgId)
            if not rm.onRepairReady.isNil():
              rm.onRepairReady(entry.cachedMessage, channelId)

          # Drop expired outgoing repair entries past T_max
          var toRemove: seq[SdsMessageID] = @[]
          let tMaxDuration = rm.config.repairTMax
          for msgId, entry in channel.outgoingRepairBuffer:
            if now - entry.minTimeRepairReq > tMaxDuration:
              toRemove.add(msgId)
          for msgId in toRemove:
            channel.outgoingRepairBuffer.del(msgId)
            rm.persistence.removeOutgoingRepair(channelId, msgId)
        except Exception:
          error "Error in repair sweep for channel",
            channelId = channelId, msg = getCurrentExceptionMsg()
    except Exception:
      error "Error in repair sweep", msg = getCurrentExceptionMsg()

proc periodicRepairSweep(
    rm: ReliabilityManager
) {.async: (raises: [CancelledError]), gcsafe.} =
  ## SDS-R: Periodically checks repair buffers for expired entries.
  while true:
    rm.runRepairSweep()
    await sleepAsync(chronos.milliseconds(rm.config.repairSweepInterval.inMilliseconds))

proc startPeriodicTasks*(rm: ReliabilityManager) =
  ## Starts the periodic tasks for buffer sweeping and sync message sending.
  asyncSpawn rm.periodicBufferSweep()
  asyncSpawn rm.periodicSyncMessage()
  asyncSpawn rm.periodicRepairSweep()

proc resetReliabilityManager*(rm: ReliabilityManager): Result[void, ReliabilityError] =
  ## Resets the ReliabilityManager to its initial state.
  withLock rm.lock:
    try:
      for channelId, channel in rm.channels:
        rm.dropChannelFromPersistence(channelId)
        channel.lamportTimestamp = 0
        channel.messageHistory.clear()
        channel.outgoingBuffer.setLen(0)
        channel.incomingBuffer.clear()
        channel.outgoingRepairBuffer.clear()
        channel.incomingRepairBuffer.clear()
        channel.bloomFilter =
          RollingBloomFilter.init(rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate)
      rm.channels.clear()
      return ok()
    except Exception:
      error "Failed to reset ReliabilityManager", msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reInternalError)

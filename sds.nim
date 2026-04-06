import std/[times, locks, tables, sets, options]
import chronos, results, chronicles
import sds/[types, protobuf, sds_utils, rolling_bloom_filter]

export types, protobuf, sds_utils, rolling_bloom_filter

proc newReliabilityManager*(
    config: ReliabilityConfig = defaultConfig(),
    participantId: SdsParticipantID = "",
): Result[ReliabilityManager, ReliabilityError] =
  ## Creates a new multi-channel ReliabilityManager.
  try:
    let rm = ReliabilityManager.new(config, participantId)
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
  var toDelete: seq[int] = @[]
  var i = 0

  while i < channel.outgoingBuffer.len:
    let outMsg = channel.outgoingBuffer[i]
    if outMsg.isAcknowledged(msg.causalHistory, rbf):
      if not rm.onMessageSent.isNil():
        rm.onMessageSent(outMsg.message.messageId, outMsg.message.channelId)
      toDelete.add(i)
    inc i

  for i in countdown(toDelete.high, 0):
    channel.outgoingBuffer.delete(toDelete[i])

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

      # SDS-R: collect eligible expired repair requests to attach
      var repairReqs: seq[HistoryEntry] = @[]
      let now = getTime()
      var expiredKeys: seq[SdsMessageID] = @[]
      for msgId, repairEntry in channel.outgoingRepairBuffer:
        if now >= repairEntry.tReq and repairReqs.len < rm.config.maxRepairRequests:
          repairReqs.add(repairEntry.entry)
          expiredKeys.add(msgId)
      for key in expiredKeys:
        channel.outgoingRepairBuffer.del(key)

      let msg = SdsMessage.init(
        messageId = messageId,
        lamportTimestamp = channel.lamportTimestamp,
        causalHistory = rm.getRecentHistoryEntries(rm.config.maxCausalHistory, channelId),
        channelId = channelId,
        content = message,
        bloomFilter = bfResult.get(),
        repairRequest = repairReqs,
      )

      channel.outgoingBuffer.add(
        UnacknowledgedMessage.init(message = msg, sendTime = getTime(), resendAttempts = 0)
      )

      channel.bloomFilter.add(msg.messageId)
      rm.addToHistory(msg.messageId, channelId)

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
        rm.addToHistory(msgId, channelId)
        if not rm.onMessageReady.isNil():
          rm.onMessageReady(msgId, channelId)
        processed.incl(msgId)

        for remainingId, entry in channel.incomingBuffer:
          if remainingId notin processed:
            if msgId in entry.missingDeps:
              channel.incomingBuffer[remainingId].missingDeps.excl(msgId)
              if channel.incomingBuffer[remainingId].missingDeps.len == 0:
                readyToProcess.add(remainingId)

    for msgId in processed:
      channel.incomingBuffer.del(msgId)

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

    if msg.messageId in channel.messageHistory:
      return ok((msg.content, @[], channelId))

    channel.bloomFilter.add(msg.messageId)

    rm.updateLamportTimestamp(msg.lamportTimestamp, channelId)
    rm.reviewAckStatus(msg)

    # SDS-R: remove this message from repair buffers (dependency now met)
    channel.outgoingRepairBuffer.del(msg.messageId)
    channel.incomingRepairBuffer.del(msg.messageId)

    # SDS-R: cache the raw message for potential repair responses
    if channel.messageCache.len < rm.config.maxMessageHistory:
      channel.messageCache[msg.messageId] = message

    # SDS-R: process incoming repair requests from this message
    let now = getTime()
    for repairEntry in msg.repairRequest:
      # Remove from our own outgoing repair buffer (someone else is also requesting)
      channel.outgoingRepairBuffer.del(repairEntry.messageId)
      # Check if we can respond to this repair request
      if repairEntry.messageId in channel.messageCache and
         rm.participantId.len > 0 and repairEntry.senderId.len > 0:
        if isInResponseGroup(
          rm.participantId, repairEntry.senderId,
          repairEntry.messageId, rm.config.numResponseGroups
        ):
          let tResp = computeTResp(
            rm.participantId, repairEntry.senderId,
            repairEntry.messageId, rm.config.repairTMax
          )
          channel.incomingRepairBuffer[repairEntry.messageId] = IncomingRepairEntry(
            entry: repairEntry,
            cachedMessage: channel.messageCache[repairEntry.messageId],
            tResp: now + tResp,
          )

    var missingDeps = rm.checkDependencies(msg.causalHistory, channelId)

    if missingDeps.len == 0:
      var depsInBuffer = false
      for msgId, entry in channel.incomingBuffer.pairs():
        if msgId in msg.causalHistory.getMessageIds():
          depsInBuffer = true
          break
      if depsInBuffer:
        channel.incomingBuffer[msg.messageId] =
          IncomingMessage.init(message = msg, missingDeps = initHashSet[SdsMessageID]())
      else:
        rm.addToHistory(msg.messageId, channelId)
        rm.processIncomingBuffer(channelId)
        if not rm.onMessageReady.isNil():
          rm.onMessageReady(msg.messageId, channelId)
    else:
      channel.incomingBuffer[msg.messageId] =
        IncomingMessage.init(
          message = msg,
          missingDeps = missingDeps.getMessageIds().toHashSet(),
        )
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
            channel.outgoingRepairBuffer[dep.messageId] = OutgoingRepairEntry(
              entry: dep,
              tReq: now + tReq,
            )

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

      for pendingId, entry in channel.incomingBuffer:
        if msgId in entry.missingDeps:
          channel.incomingBuffer[pendingId].missingDeps.excl(msgId)

      # SDS-R: clear from repair buffers (dependency now met)
      channel.outgoingRepairBuffer.del(msgId)
      channel.incomingRepairBuffer.del(msgId)

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
        else:
          if not rm.onMessageSent.isNil():
            rm.onMessageSent(unackMsg.message.messageId, channelId)
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

proc periodicRepairSweep(
    rm: ReliabilityManager
) {.async: (raises: [CancelledError]), gcsafe.} =
  ## SDS-R: Periodically checks repair buffers for expired entries.
  ## - Incoming: fires onRepairReady for expired T_resp entries
  ## - Outgoing: drops entries past T_max
  while true:
    try:
      let now = getTime()
      for channelId, channel in rm.channels:
        try:
          # Check incoming repair buffer for expired T_resp (time to rebroadcast)
          var toRebroadcast: seq[SdsMessageID] = @[]
          for msgId, entry in channel.incomingRepairBuffer:
            if now >= entry.tResp:
              toRebroadcast.add(msgId)

          for msgId in toRebroadcast:
            let entry = channel.incomingRepairBuffer[msgId]
            channel.incomingRepairBuffer.del(msgId)
            if not rm.onRepairReady.isNil():
              rm.onRepairReady(entry.cachedMessage, channelId)

          # Drop expired outgoing repair entries past T_max
          var toRemove: seq[SdsMessageID] = @[]
          let tMaxDuration = rm.config.repairTMax
          for msgId, entry in channel.outgoingRepairBuffer:
            if now - entry.tReq > tMaxDuration:
              toRemove.add(msgId)
          for msgId in toRemove:
            channel.outgoingRepairBuffer.del(msgId)
        except Exception:
          error "Error in repair sweep for channel",
            channelId = channelId, msg = getCurrentExceptionMsg()
    except Exception:
      error "Error in periodic repair sweep", msg = getCurrentExceptionMsg()

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
        channel.lamportTimestamp = 0
        channel.messageHistory.setLen(0)
        channel.outgoingBuffer.setLen(0)
        channel.incomingBuffer.clear()
        channel.outgoingRepairBuffer.clear()
        channel.incomingRepairBuffer.clear()
        channel.messageCache.clear()
        channel.bloomFilter =
          RollingBloomFilter.init(rm.config.bloomFilterCapacity, rm.config.bloomFilterErrorRate)
      rm.channels.clear()
      return ok()
    except Exception:
      error "Failed to reset ReliabilityManager", msg = getCurrentExceptionMsg()
      return err(ReliabilityError.reInternalError)

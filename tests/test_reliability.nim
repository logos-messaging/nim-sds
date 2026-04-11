import unittest, results, chronos, std/[times, options, tables]
import sds

const testChannel = "testChannel"

# Core functionality tests
suite "Core Operations":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "can create with default config":
    let config = defaultConfig()
    check:
      config.bloomFilterCapacity == DefaultBloomFilterCapacity
      config.bloomFilterErrorRate == DefaultBloomFilterErrorRate
      config.maxMessageHistory == DefaultMaxMessageHistory

  test "basic message wrapping and unwrapping":
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"

    let wrappedResult = rm.wrapOutgoingMessage(msg, msgId, testChannel)
    check wrappedResult.isOk()
    let wrapped = wrappedResult.get()
    check wrapped.len > 0

    let unwrapResult = rm.unwrapReceivedMessage(wrapped)
    check unwrapResult.isOk()
    let (unwrapped, missingDeps, channelId) = unwrapResult.get()
    check:
      unwrapped == msg
      missingDeps.len == 0
      channelId == testChannel

  test "message ordering":
    # Create messages with different timestamps
    let msg1 = SdsMessage(
      messageId: "msg1",
      lamportTimestamp: 1,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(1)],
      bloomFilter: @[],
    )

    let msg2 = SdsMessage(
      messageId: "msg2",
      lamportTimestamp: 5,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[],
    )

    let serialized1 = serializeMessage(msg1)
    let serialized2 = serializeMessage(msg2)
    check:
      serialized1.isOk()
      serialized2.isOk()

    # Process out of order
    discard rm.unwrapReceivedMessage(serialized2.get())
    let timestamp1 = rm.channels[testChannel].lamportTimestamp
    discard rm.unwrapReceivedMessage(serialized1.get())
    let timestamp2 = rm.channels[testChannel].lamportTimestamp

    check timestamp2 > timestamp1

# Reliability mechanism tests
suite "Reliability Mechanisms":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "dependency detection and resolution":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageReadyCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        missingDepsCount += 1,
    )

    # Create dependency chain: msg3 -> msg2 -> msg1
    let id1 = "msg1"
    let id2 = "msg2"
    let id3 = "msg3"

    # Create messages with dependencies
    let msg2 = SdsMessage(
      messageId: id2,
      lamportTimestamp: 2,
      causalHistory: toCausalHistory(@[id1]), # msg2 depends on msg1
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[],
    )

    let msg3 = SdsMessage(
      messageId: id3,
      lamportTimestamp: 3,
      causalHistory: toCausalHistory(@[id1, id2]), # msg3 depends on both msg1 and msg2
      channelId: testChannel,
      content: @[byte(3)],
      bloomFilter: @[],
    )

    let serialized2 = serializeMessage(msg2)
    let serialized3 = serializeMessage(msg3)
    check:
      serialized2.isOk()
      serialized3.isOk()

    # First try processing msg3 (which depends on msg2 which depends on msg1)
    let unwrapResult3 = rm.unwrapReceivedMessage(serialized3.get())
    check unwrapResult3.isOk()
    let (_, missingDeps3, _) = unwrapResult3.get()

    check:
      missingDepsCount == 1 # Should trigger missing deps callback
      missingDeps3.len == 2 # Should be missing both msg1 and msg2
      id1 in missingDeps3.getMessageIds()
      id2 in missingDeps3.getMessageIds()

    # Then try processing msg2 (which only depends on msg1)
    let unwrapResult2 = rm.unwrapReceivedMessage(serialized2.get())
    check unwrapResult2.isOk()
    let (_, missingDeps2, _) = unwrapResult2.get()

    check:
      missingDepsCount == 2 # Should have triggered another missing deps callback
      missingDeps2.len == 1 # Should only be missing msg1
      id1 in missingDeps2.getMessageIds()
      messageReadyCount == 0 # No messages should be ready yet

    # Mark first dependency (msg1) as met
    let markResult1 = rm.markDependenciesMet(@[id1], testChannel)
    check markResult1.isOk()

    let incomingBuffer = rm.getIncomingBuffer(testChannel)

    check:
      incomingBuffer.len == 0
      messageReadyCount == 2 # Both msg2 and msg3 should be ready
      missingDepsCount == 2 # Should still be 2 from the initial missing deps

  test "acknowledgment via causal history":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageReadyCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        missingDepsCount += 1,
    )

    # Send our message
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1, testChannel)
    check wrap1.isOk()

    # Create a message that has our message in causal history
    let msg2 = SdsMessage(
      messageId: "msg2",
      lamportTimestamp: rm.channels[testChannel].lamportTimestamp + 1,
      causalHistory: toCausalHistory(@[id1]), # Include our message in causal history
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[] # Test with an empty bloom filter
      ,
    )

    let serializedMsg2 = serializeMessage(msg2)
    check serializedMsg2.isOk()

    # Process the "received" message - should trigger callbacks
    let unwrapResult = rm.unwrapReceivedMessage(serializedMsg2.get())
    check unwrapResult.isOk()

    check:
      messageReadyCount == 1 # For msg2 which we "received"
      messageSentCount == 1 # For msg1 which was acknowledged via causal history

  test "acknowledgment via bloom filter":
    var messageSentCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        discard,
    )

    # Send our message
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1, testChannel)
    check wrap1.isOk()

    # Create a message with bloom filter containing our message
    var otherPartyBloomFilter =
      RollingBloomFilter.init(DefaultBloomFilterCapacity, DefaultBloomFilterErrorRate)
    otherPartyBloomFilter.add(id1)

    let bfResult = serializeBloomFilter(otherPartyBloomFilter.filter)
    check bfResult.isOk()

    let msg2 = SdsMessage(
      messageId: "msg2",
      lamportTimestamp: rm.channels[testChannel].lamportTimestamp + 1,
      causalHistory: @[], # Empty causal history as we're using bloom filter
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: bfResult.get(),
    )

    let serializedMsg2 = serializeMessage(msg2)
    check serializedMsg2.isOk()

    let unwrapResult = rm.unwrapReceivedMessage(serializedMsg2.get())
    check unwrapResult.isOk()

    check messageSentCount == 1 # Our message should be acknowledged via bloom filter

  test "retrieval hints":
    var messageReadyCount = 0
    var messageSentCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageReadyCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        missingDepsCount += 1,
      nil,
      proc(messageId: SdsMessageID): seq[byte] =
        return cast[seq[byte]]("hint:" & messageId)
    )

    # Send a first message to populate history
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1, testChannel)
    check wrap1.isOk()

    # Send a second message, which should have the first in its causal history
    let msg2 = @[byte(2)]
    let id2 = "msg2"
    let wrap2 = rm.wrapOutgoingMessage(msg2, id2, testChannel)
    check wrap2.isOk()

    # Check that the wrapped message contains the hint
    let unwrappedMsg2 = deserializeMessage(wrap2.get()).get()
    check unwrappedMsg2.causalHistory.len > 0
    check unwrappedMsg2.causalHistory[0].messageId == id1
    check unwrappedMsg2.causalHistory[0].retrievalHint == cast[seq[byte]]("hint:" & id1)

    # Create a message with a missing dependency (no retrieval hint)
    let msg3 = SdsMessage(
      messageId: "msg3",
      lamportTimestamp: 3,
      causalHistory: toCausalHistory(@["missing-dep"]),
      channelId: testChannel,
      content: @[byte(3)],
      bloomFilter: @[],
    )
    let serialized3 = serializeMessage(msg3).get()
    let unwrapResult3 = rm.unwrapReceivedMessage(serialized3)
    check unwrapResult3.isOk()
    let (_, missingDeps3, _) = unwrapResult3.get()
    check missingDeps3.len == 1
    check missingDeps3[0].messageId == "missing-dep"
    # The hint is empty because it was not provided by the remote sender
    check missingDeps3[0].retrievalHint.len == 0
    
    # Test with a message that HAS a retrieval hint from remote
    let msg4 = SdsMessage(
      messageId: "msg4",
      lamportTimestamp: 4,
      causalHistory: @[newHistoryEntry("another-missing", cast[seq[byte]]("remote-hint"))],
      channelId: testChannel,
      content: @[byte(4)],
      bloomFilter: @[],
    )
    let serialized4 = serializeMessage(msg4).get()
    let unwrapResult4 = rm.unwrapReceivedMessage(serialized4)
    check unwrapResult4.isOk()
    let (_, missingDeps4, _) = unwrapResult4.get()
    check missingDeps4.len == 1
    check missingDeps4[0].messageId == "another-missing"
    # The hint should be preserved from the remote sender
    check missingDeps4[0].retrievalHint == cast[seq[byte]]("remote-hint")

# Periodic task & Buffer management tests
suite "Periodic Tasks & Buffer Management":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "outgoing buffer management":
    var messageSentCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        discard,
    )

    # Add multiple messages
    for i in 0 .. 5:
      let msg = @[byte(i)]
      let id = "msg" & $i
      let wrap = rm.wrapOutgoingMessage(msg, id, testChannel)
      check wrap.isOk()

    let outBuffer = rm.getOutgoingBuffer(testChannel)
    check outBuffer.len == 6

    # Create message that acknowledges some messages
    let ackMsg = SdsMessage(
      messageId: "ack1",
      lamportTimestamp: rm.channels[testChannel].lamportTimestamp + 1,
      causalHistory: toCausalHistory(@["msg0", "msg2", "msg4"]),
      channelId: testChannel,
      content: @[byte(100)],
      bloomFilter: @[],
    )

    let serializedAck = serializeMessage(ackMsg)
    check serializedAck.isOk()

    # Process the acknowledgment
    discard rm.unwrapReceivedMessage(serializedAck.get())

    let finalBuffer = rm.getOutgoingBuffer(testChannel)
    check:
      finalBuffer.len == 3 # Should have removed acknowledged messages
      messageSentCount == 3
        # Should have triggered sent callback for acknowledged messages

  test "periodic buffer sweep and bloom clean":
    var messageSentCount = 0

    var config = defaultConfig()
    config.resendInterval = initDuration(milliseconds = 100) # Short for testing
    config.bufferSweepInterval = initDuration(milliseconds = 50) # Frequent sweeps
    config.bloomFilterCapacity = 2 # Small capacity for testing
    config.maxResendAttempts = 3 # Set a low number of max attempts

    let rmResultP = newReliabilityManager(config)
    check rmResultP.isOk()
    let rm = rmResultP.get()
    check rm.ensureChannel(testChannel).isOk()

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageSentCount += 1,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        discard,
    )

    # First message - should be cleaned from bloom filter later
    let msg1 = @[byte(1)]
    let id1 = "msg1"
    let wrap1 = rm.wrapOutgoingMessage(msg1, id1, testChannel)
    check wrap1.isOk()

    let initialBuffer = rm.getOutgoingBuffer(testChannel)
    check:
      initialBuffer[0].resendAttempts == 0
      rm.channels[testChannel].bloomFilter.contains(id1)

    rm.startPeriodicTasks()

    # Wait long enough for bloom filter
    waitFor sleepAsync(chronos.milliseconds(500))

    # Add new messages
    let msg2 = @[byte(2)]
    let id2 = "msg2"
    let wrap2 = rm.wrapOutgoingMessage(msg2, id2, testChannel)
    check wrap2.isOk()

    let msg3 = @[byte(3)]
    let id3 = "msg3"
    let wrap3 = rm.wrapOutgoingMessage(msg3, id3, testChannel)
    check wrap3.isOk()

    let finalBuffer = rm.getOutgoingBuffer(testChannel)
    check:
      finalBuffer.len == 2
        # Only msg2 and msg3 should be in buffer, msg1 should be removed after max retries
      finalBuffer[0].message.messageId == id2 # Verify it's the second message
      finalBuffer[0].resendAttempts == 0 # New message should have 0 attempts
      not rm.channels[testChannel].bloomFilter.contains(id1) # Bloom filter cleaning check
      rm.channels[testChannel].bloomFilter.contains(id3) # New message still in filter

    rm.cleanup()

  test "periodic sync callback":
    var syncCallCount = 0
    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc() {.gcsafe.} =
        syncCallCount += 1,
    )

    rm.startPeriodicTasks()
    waitFor sleepAsync(chronos.seconds(1))
    rm.cleanup()

    check syncCallCount > 0

# Special cases handling
suite "Special Cases Handling":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "message history limits":
    # Add messages up to max history size
    for i in 0 .. rm.config.maxMessageHistory + 5:
      let msg = @[byte(i)]
      let id = "msg" & $i
      let wrap = rm.wrapOutgoingMessage(msg, id, testChannel)
      check wrap.isOk()

    let history = rm.getMessageHistory(testChannel)
    check:
      history.len <= rm.config.maxMessageHistory
      history[^1] == "msg" & $(rm.config.maxMessageHistory + 5)

  test "invalid bloom filter handling":
    let msgInvalid = SdsMessage(
      messageId: "invalid-bf",
      lamportTimestamp: 1,
      causalHistory: toCausalHistory(@[]),
      channelId: testChannel,
      content: @[byte(1)],
      bloomFilter: @[1.byte, 2.byte, 3.byte] # Invalid filter data
      ,
    )

    let serializedInvalid = serializeMessage(msgInvalid)
    check serializedInvalid.isOk()

    # Should handle invalid bloom filter gracefully
    let result = rm.unwrapReceivedMessage(serializedInvalid.get())
    check:
      result.isOk()
      result.get()[1].len == 0 # No missing dependencies

  test "duplicate message handling":
    var messageReadyCount = 0
    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        messageReadyCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        discard,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        discard,
    )

    # Create and process a message
    let msg = SdsMessage(
      messageId: "dup-msg",
      lamportTimestamp: 1,
      causalHistory: toCausalHistory(@[]),
      channelId: testChannel,
      content: @[byte(1)],
      bloomFilter: @[],
    )

    let serialized = serializeMessage(msg)
    check serialized.isOk()

    # Process same message twice
    let result1 = rm.unwrapReceivedMessage(serialized.get())
    check result1.isOk()
    let result2 = rm.unwrapReceivedMessage(serialized.get())
    check:
      result2.isOk()
      result2.get()[1].len == 0 # No missing deps on second process
      messageReadyCount == 1 # Message should only be processed once

  test "error handling":
    # Empty message
    let emptyMsg: seq[byte] = @[]
    let emptyResult = rm.wrapOutgoingMessage(emptyMsg, "empty", testChannel)
    check:
      not emptyResult.isOk()
      emptyResult.error == reInvalidArgument

    # Oversized message
    let largeMsg = newSeq[byte](MaxMessageSize + 1)
    let largeResult = rm.wrapOutgoingMessage(largeMsg, "large", testChannel)
    check:
      not largeResult.isOk()
      largeResult.error == reMessageTooLarge

suite "cleanup":
  test "cleanup works correctly":
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    let rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

    # Add some messages
    let msg = @[byte(1), 2, 3]
    let msgId = "test-msg-1"
    discard rm.wrapOutgoingMessage(msg, msgId, testChannel)

    rm.cleanup()

    let outBuffer = rm.getOutgoingBuffer(testChannel)
    let history = rm.getMessageHistory(testChannel)
    check:
      outBuffer.len == 0
      history.len == 0

suite "Multi-Channel ReliabilityManager Tests":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager()
    check rmResult.isOk()
    rm = rmResult.get()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "can create multi-channel manager without channel ID":
    check rm.channels.len == 0

  test "channel management":
    let channel1 = "channel1"
    let channel2 = "channel2"

    # Ensure channels
    check rm.ensureChannel(channel1).isOk()
    check rm.ensureChannel(channel2).isOk()
    check rm.channels.len == 2

    # Remove channel
    check rm.removeChannel(channel1).isOk()
    check rm.channels.len == 1
    check channel1 notin rm.channels
    check channel2 in rm.channels

  test "stateless message unwrapping with channel extraction":
    let channel1 = "test-channel-1"
    let channel2 = "test-channel-2"

    # Create and wrap messages for different channels
    let msg1 = @[byte(1), 2, 3]
    let msgId1 = "msg1"
    let wrapped1 = rm.wrapOutgoingMessage(msg1, msgId1, channel1)
    check wrapped1.isOk()

    let msg2 = @[byte(4), 5, 6]
    let msgId2 = "msg2"
    let wrapped2 = rm.wrapOutgoingMessage(msg2, msgId2, channel2)
    check wrapped2.isOk()

    # Unwrap messages - should extract channel ID and route correctly
    let unwrap1 = rm.unwrapReceivedMessage(wrapped1.get())
    check unwrap1.isOk()
    let (content1, deps1, extractedChannel1) = unwrap1.get()
    check:
      content1 == msg1
      deps1.len == 0
      extractedChannel1 == channel1

    let unwrap2 = rm.unwrapReceivedMessage(wrapped2.get())
    check unwrap2.isOk()
    let (content2, deps2, extractedChannel2) = unwrap2.get()
    check:
      content2 == msg2
      deps2.len == 0
      extractedChannel2 == channel2

  test "channel isolation":
    let channel1 = "isolated-channel-1"
    let channel2 = "isolated-channel-2"

    # Add messages to different channels
    let msg1 = @[byte(1)]
    let msgId1 = "isolated-msg1"
    discard rm.wrapOutgoingMessage(msg1, msgId1, channel1)

    let msg2 = @[byte(2)]
    let msgId2 = "isolated-msg2"
    discard rm.wrapOutgoingMessage(msg2, msgId2, channel2)

    # Check channel-specific data is isolated
    let history1 = rm.getMessageHistory(channel1)
    let history2 = rm.getMessageHistory(channel2)

    check:
      history1.len == 1
      history2.len == 1
      msgId1 in history1
      msgId2 in history2
      msgId1 notin history2
      msgId2 notin history1

  test "multi-channel callbacks":
    var readyMessageCount = 0
    var sentMessageCount = 0
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        readyMessageCount += 1,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
        sentMessageCount += 1,
      proc(messageId: SdsMessageID, deps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        missingDepsCount += 1
    )

    let channel1 = "callback-channel-1"
    let channel2 = "callback-channel-2"

    # Send messages from both channels
    let msg1 = @[byte(1)]
    let msgId1 = "callback-msg1"
    let wrapped1 = rm.wrapOutgoingMessage(msg1, msgId1, channel1)
    check wrapped1.isOk()

    let msg2 = @[byte(2)]
    let msgId2 = "callback-msg2"
    let wrapped2 = rm.wrapOutgoingMessage(msg2, msgId2, channel2)
    check wrapped2.isOk()

    # Create acknowledgment messages that include our message IDs in causal history
    # to trigger sent callbacks
    let ackMsg1 = SdsMessage(
      messageId: "ack1",
      lamportTimestamp: rm.channels[channel1].lamportTimestamp + 1,
      causalHistory: toCausalHistory(@[msgId1]), # Acknowledge msg1
      channelId: channel1,
      content: @[byte(100)],
      bloomFilter: @[],
    )

    let ackMsg2 = SdsMessage(
      messageId: "ack2",
      lamportTimestamp: rm.channels[channel2].lamportTimestamp + 1,
      causalHistory: toCausalHistory(@[msgId2]), # Acknowledge msg2
      channelId: channel2,
      content: @[byte(101)],
      bloomFilter: @[],
    )

    let serializedAck1 = serializeMessage(ackMsg1)
    let serializedAck2 = serializeMessage(ackMsg2)
    check:
      serializedAck1.isOk()
      serializedAck2.isOk()

    # Process acknowledgment messages - should trigger callbacks
    discard rm.unwrapReceivedMessage(serializedAck1.get())
    discard rm.unwrapReceivedMessage(serializedAck2.get())

    check:
      readyMessageCount == 2  # Both ack messages should trigger ready callbacks
      sentMessageCount == 2  # Both original messages should be marked as sent
      missingDepsCount == 0   # No missing dependencies

  test "channel-specific dependency management":
    let channel1 = "dep-channel-1"
    let channel2 = "dep-channel-2"
    let depIds = @["dep1", "dep2", "dep3"]

    # Ensure both channels exist first
    check rm.ensureChannel(channel1).isOk()
    check rm.ensureChannel(channel2).isOk()

    # Mark dependencies as met for specific channel
    check rm.markDependenciesMet(depIds, channel1).isOk()

    # Dependencies should only affect the specified channel
    # Dependencies in channel1 should not affect channel2
    check rm.channels[channel1].bloomFilter.contains("dep1")
    check not rm.channels[channel2].bloomFilter.contains("dep1")

# SDS-R Repair tests
suite "SDS-R: Computation Functions":
  test "computeTReq returns duration in [tMin, tMax)":
    let tMin = initDuration(seconds = 30)
    let tMax = initDuration(seconds = 300)
    let d = computeTReq("participant1", "msg1", tMin, tMax)
    check:
      d.inMilliseconds >= tMin.inMilliseconds
      d.inMilliseconds < tMax.inMilliseconds

  test "computeTReq is deterministic for same inputs":
    let tMin = initDuration(seconds = 30)
    let tMax = initDuration(seconds = 300)
    let d1 = computeTReq("p1", "m1", tMin, tMax)
    let d2 = computeTReq("p1", "m1", tMin, tMax)
    check d1 == d2

  test "computeTReq varies with different participants":
    let tMin = initDuration(seconds = 30)
    let tMax = initDuration(seconds = 300)
    let d1 = computeTReq("participant-A", "msg1", tMin, tMax)
    let d2 = computeTReq("participant-B", "msg1", tMin, tMax)
    # Different participants should generally get different backoff (not guaranteed but highly likely)
    # Just check both are in valid range
    check:
      d1.inMilliseconds >= tMin.inMilliseconds
      d2.inMilliseconds >= tMin.inMilliseconds

  test "computeTResp original sender has zero distance":
    let d = computeTResp("sender1", "sender1", "msg1", initDuration(seconds = 300))
    check d.inMilliseconds == 0

  test "computeTResp non-sender has positive backoff":
    let d = computeTResp("other-node", "sender1", "msg1", initDuration(seconds = 300))
    check d.inMilliseconds >= 0

  test "isInResponseGroup all in same group when numGroups=1":
    check isInResponseGroup("p1", "sender1", "msg1", 1) == true
    check isInResponseGroup("p2", "sender1", "msg1", 1) == true

  test "isInResponseGroup sender always in own group":
    # Original sender must always be in their own response group
    for groups in 1 .. 10:
      check isInResponseGroup("sender1", "sender1", "msg1", groups) == true

suite "SDS-R: Repair Buffer Management":
  var rm: ReliabilityManager

  setup:
    let rmResult = newReliabilityManager(
      participantId = "test-participant"
    )
    check rmResult.isOk()
    rm = rmResult.get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "missing deps added to outgoing repair buffer":
    var missingDepsCount = 0

    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
        missingDepsCount += 1,
    )

    # Create a message with a missing dependency
    let msg = SdsMessage(
      messageId: "msg2",
      lamportTimestamp: 2,
      causalHistory: @[HistoryEntry(messageId: "msg1", senderId: "sender-A")],
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[],
    )

    let serialized = serializeMessage(msg).get()
    let result = rm.unwrapReceivedMessage(serialized)
    check result.isOk()

    # msg1 should be in the outgoing repair buffer
    let channel = rm.channels[testChannel]
    check:
      missingDepsCount == 1
      "msg1" in channel.outgoingRepairBuffer

  test "receiving message clears it from repair buffers":
    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} = discard,
    )

    # First, create the missing dep scenario
    let msg2 = SdsMessage(
      messageId: "msg2",
      lamportTimestamp: 2,
      causalHistory: @[HistoryEntry(messageId: "msg1", senderId: "sender-A")],
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[],
    )
    discard rm.unwrapReceivedMessage(serializeMessage(msg2).get())
    check "msg1" in rm.channels[testChannel].outgoingRepairBuffer

    # Now receive msg1 — should clear from repair buffer
    let msg1 = SdsMessage(
      messageId: "msg1",
      lamportTimestamp: 1,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(1)],
      bloomFilter: @[],
    )
    discard rm.unwrapReceivedMessage(serializeMessage(msg1).get())
    check "msg1" notin rm.channels[testChannel].outgoingRepairBuffer

  test "markDependenciesMet clears repair buffers":
    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} = discard,
    )

    let msg2 = SdsMessage(
      messageId: "msg2",
      lamportTimestamp: 2,
      causalHistory: @[HistoryEntry(messageId: "msg1", senderId: "sender-A")],
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[],
    )
    discard rm.unwrapReceivedMessage(serializeMessage(msg2).get())
    check "msg1" in rm.channels[testChannel].outgoingRepairBuffer

    # Mark as met via store retrieval
    check rm.markDependenciesMet(@["msg1"], testChannel).isOk()
    check "msg1" notin rm.channels[testChannel].outgoingRepairBuffer

  test "expired repair requests attached to outgoing messages":
    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} = discard,
    )

    # Manually add an expired repair entry
    let channel = rm.channels[testChannel]
    channel.outgoingRepairBuffer["missing-msg"] = OutgoingRepairEntry(
      entry: HistoryEntry(messageId: "missing-msg", senderId: "orig-sender"),
      tReq: getTime() - initDuration(seconds = 10),  # Already expired
    )

    # Send a message — should pick up the expired repair request
    let wrapped = rm.wrapOutgoingMessage(@[byte(1)], "new-msg", testChannel)
    check wrapped.isOk()

    let unwrapped = deserializeMessage(wrapped.get()).get()
    check:
      unwrapped.repairRequest.len == 1
      unwrapped.repairRequest[0].messageId == "missing-msg"
      # Should be removed from buffer after attaching
      "missing-msg" notin channel.outgoingRepairBuffer

  test "incoming repair request adds to incoming repair buffer when eligible":
    rm.setCallbacks(
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} = discard,
      proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} = discard,
    )

    let channel = rm.channels[testChannel]

    # First, cache a message so we can respond to a repair request for it
    let cachedMsg = SdsMessage(
      messageId: "cached-msg",
      lamportTimestamp: 1,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(99)],
      bloomFilter: @[],
    )
    let cachedBytes = serializeMessage(cachedMsg).get()
    channel.messageCache["cached-msg"] = cachedBytes

    # Receive a message with a repair request for "cached-msg"
    let msgWithRepair = SdsMessage(
      messageId: "requester-msg",
      lamportTimestamp: 5,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(3)],
      bloomFilter: @[],
      repairRequest: @[HistoryEntry(
        messageId: "cached-msg",
        senderId: "test-participant",  # Same as our participantId so we're in response group
      )],
    )
    discard rm.unwrapReceivedMessage(serializeMessage(msgWithRepair).get())

    # We should have added it to the incoming repair buffer (we have the message and are in response group)
    check "cached-msg" in channel.incomingRepairBuffer

suite "SDS-R: Protobuf Roundtrip":
  test "senderId in HistoryEntry roundtrips through protobuf":
    let msg = SdsMessage(
      messageId: "msg1",
      lamportTimestamp: 100,
      causalHistory: @[
        HistoryEntry(messageId: "dep1", retrievalHint: @[byte(1), 2], senderId: "sender-A"),
        HistoryEntry(messageId: "dep2", senderId: "sender-B"),
      ],
      channelId: "ch1",
      content: @[byte(42)],
      bloomFilter: @[],
    )

    let serialized = serializeMessage(msg).get()
    let decoded = deserializeMessage(serialized).get()

    check:
      decoded.causalHistory.len == 2
      decoded.causalHistory[0].messageId == "dep1"
      decoded.causalHistory[0].senderId == "sender-A"
      decoded.causalHistory[0].retrievalHint == @[byte(1), 2]
      decoded.causalHistory[1].messageId == "dep2"
      decoded.causalHistory[1].senderId == "sender-B"

  test "repairRequest field roundtrips through protobuf":
    let msg = SdsMessage(
      messageId: "msg1",
      lamportTimestamp: 100,
      causalHistory: @[],
      channelId: "ch1",
      content: @[byte(42)],
      bloomFilter: @[],
      repairRequest: @[
        HistoryEntry(messageId: "missing1", senderId: "sender-X"),
        HistoryEntry(messageId: "missing2", senderId: "sender-Y", retrievalHint: @[byte(5)]),
      ],
    )

    let serialized = serializeMessage(msg).get()
    let decoded = deserializeMessage(serialized).get()

    check:
      decoded.repairRequest.len == 2
      decoded.repairRequest[0].messageId == "missing1"
      decoded.repairRequest[0].senderId == "sender-X"
      decoded.repairRequest[1].messageId == "missing2"
      decoded.repairRequest[1].senderId == "sender-Y"
      decoded.repairRequest[1].retrievalHint == @[byte(5)]

  test "backward compat: message without repairRequest decodes fine":
    let msg = SdsMessage(
      messageId: "msg1",
      lamportTimestamp: 100,
      causalHistory: @[HistoryEntry(messageId: "dep1")],
      channelId: "ch1",
      content: @[byte(42)],
      bloomFilter: @[],
    )

    let serialized = serializeMessage(msg).get()
    let decoded = deserializeMessage(serialized).get()

    check:
      decoded.repairRequest.len == 0
      decoded.causalHistory[0].senderId == ""

  test "SdsMessage.senderId roundtrips through protobuf":
    let msg = SdsMessage(
      messageId: "m1",
      lamportTimestamp: 1,
      causalHistory: @[],
      channelId: "ch1",
      content: @[byte(1)],
      bloomFilter: @[],
      senderId: "alice",
    )
    let decoded = deserializeMessage(serializeMessage(msg).get()).get()
    check decoded.senderId == "alice"

# ---------------------------------------------------------------------------
# SDS-R Phase 2 tests: edge cases, lifecycle, sweep, and multi-participant flows
# ---------------------------------------------------------------------------

suite "SDS-R: Edge Cases and Defensive Branches":
  test "computeTReq returns tMin when range is degenerate":
    let tMin = initDuration(seconds = 30)
    # tMax == tMin
    let d1 = computeTReq("p", "m", tMin, tMin)
    check d1 == tMin
    # tMax < tMin (rangeMs < 0)
    let d2 = computeTReq("p", "m", tMin, initDuration(seconds = 10))
    check d2 == tMin

  test "computeTResp returns 0 when tMax is 0":
    let d = computeTResp("p", "other", "m", initDuration(milliseconds = 0))
    check d.inMilliseconds == 0

  test "computeTResp always stays within [0, tMax)":
    # Adversarial sweep — result must never wrap negative nor exceed tMax
    let tMax = initDuration(seconds = 300)
    for i in 0 ..< 500:
      let d = computeTResp(
        "participant-" & $i, "sender-" & $(i * 13), "msg-" & $(i * 31), tMax
      )
      check:
        d.inMilliseconds >= 0
        d.inMilliseconds < tMax.inMilliseconds

  test "isInResponseGroup returns true for non-positive numGroups":
    check isInResponseGroup("p", "sender", "m", 0) == true
    check isInResponseGroup("p", "sender", "m", -1) == true

  test "computeTReq bounds across many random inputs":
    let tMin = initDuration(seconds = 30)
    let tMax = initDuration(seconds = 300)
    for i in 0 ..< 200:
      let d = computeTReq("p-" & $i, "m-" & $i, tMin, tMax)
      check:
        d.inMilliseconds >= tMin.inMilliseconds
        d.inMilliseconds < tMax.inMilliseconds

  test "response group distribution is roughly uniform":
    # With numGroups=10, ~10% of random participants should share sender's group.
    const numGroups = 10
    const totalParticipants = 1000
    let senderId = "alice"
    let msgId = "msg-xyz"
    var sameGroup = 0
    for i in 0 ..< totalParticipants:
      if isInResponseGroup("participant-" & $i, senderId, msgId, numGroups):
        sameGroup += 1
    # Expected ~100 (1/N), allow [50, 200] band for hash quirks
    check:
      sameGroup >= 50
      sameGroup <= 200

  test "computeTResp monotonicity: self always fastest":
    # The original sender (distance=0) must always be first to respond.
    let tMax = initDuration(seconds = 300)
    let selfD = computeTResp("alice", "alice", "msg-xyz", tMax)
    check selfD.inMilliseconds == 0
    for i in 0 ..< 50:
      let other = computeTResp("other-" & $i, "alice", "msg-xyz", tMax)
      check other.inMilliseconds >= selfD.inMilliseconds

suite "SDS-R: Lifecycle and State":
  test "empty participantId disables outgoing repair creation":
    let rm = newReliabilityManager().get()  # empty participantId
    defer: rm.cleanup()
    check rm.ensureChannel(testChannel).isOk()

    rm.setCallbacks(
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, deps: seq[HistoryEntry], ch: SdsChannelID) {.gcsafe.} = discard,
    )

    let msg = SdsMessage(
      messageId: "m2",
      lamportTimestamp: 2,
      causalHistory: @[HistoryEntry(messageId: "m1-missing", senderId: "alice")],
      channelId: testChannel,
      content: @[byte(2)],
      bloomFilter: @[],
    )
    discard rm.unwrapReceivedMessage(serializeMessage(msg).get())
    check rm.channels[testChannel].outgoingRepairBuffer.len == 0

  test "empty senderId in incoming repair request is ignored":
    let rm = newReliabilityManager(participantId = "bob").get()
    defer: rm.cleanup()
    check rm.ensureChannel(testChannel).isOk()
    let channel = rm.channels[testChannel]
    channel.messageCache["m-wanted"] = @[byte(99), 99, 99]

    rm.setCallbacks(
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, deps: seq[HistoryEntry], ch: SdsChannelID) {.gcsafe.} = discard,
    )

    let msg = SdsMessage(
      messageId: "req-msg",
      lamportTimestamp: 5,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(1)],
      bloomFilter: @[],
      repairRequest: @[HistoryEntry(messageId: "m-wanted", senderId: "")],
    )
    discard rm.unwrapReceivedMessage(serializeMessage(msg).get())
    check "m-wanted" notin channel.incomingRepairBuffer

  test "wrapOutgoingMessage caches bytes and records sender":
    # Proves Bug 1 is fixed — the original sender can serve her own message.
    let rm = newReliabilityManager(participantId = "alice").get()
    defer: rm.cleanup()
    check rm.ensureChannel(testChannel).isOk()

    discard rm.wrapOutgoingMessage(@[byte(1), 2, 3], "m1", testChannel)
    let channel = rm.channels[testChannel]
    check:
      "m1" in channel.messageCache
      channel.messageCache["m1"].len > 0
      "m1" in channel.messageSenders
      channel.messageSenders["m1"] == "alice"

  test "getRecentHistoryEntries carries senderId for own messages":
    let rm = newReliabilityManager(participantId = "alice").get()
    defer: rm.cleanup()
    check rm.ensureChannel(testChannel).isOk()

    discard rm.wrapOutgoingMessage(@[byte(1)], "m1", testChannel)
    discard rm.wrapOutgoingMessage(@[byte(2)], "m2", testChannel)
    let entries = rm.getRecentHistoryEntries(10, testChannel)
    check:
      entries.len == 2
      entries[0].senderId == "alice"
      entries[1].senderId == "alice"

  test "resetReliabilityManager clears all SDS-R state":
    let rm = newReliabilityManager(participantId = "alice").get()
    defer: rm.cleanup()
    check rm.ensureChannel(testChannel).isOk()
    let channel = rm.channels[testChannel]

    channel.outgoingRepairBuffer["a"] = OutgoingRepairEntry(
      entry: HistoryEntry(messageId: "a", senderId: "x"),
      tReq: getTime(),
    )
    channel.incomingRepairBuffer["b"] = IncomingRepairEntry(
      entry: HistoryEntry(messageId: "b", senderId: "y"),
      cachedMessage: @[byte(1)],
      tResp: getTime(),
    )
    channel.messageCache["c"] = @[byte(2)]
    channel.messageSenders["c"] = "someone"

    check rm.resetReliabilityManager().isOk()
    check rm.ensureChannel(testChannel).isOk()
    let ch2 = rm.channels[testChannel]
    check:
      ch2.outgoingRepairBuffer.len == 0
      ch2.incomingRepairBuffer.len == 0
      ch2.messageCache.len == 0
      ch2.messageSenders.len == 0

  test "SDS-R state is isolated per channel":
    let rm = newReliabilityManager(participantId = "alice").get()
    defer: rm.cleanup()
    check rm.ensureChannel("ch-A").isOk()
    check rm.ensureChannel("ch-B").isOk()

    rm.setCallbacks(
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, deps: seq[HistoryEntry], ch: SdsChannelID) {.gcsafe.} = discard,
    )

    let msg = SdsMessage(
      messageId: "m2",
      lamportTimestamp: 2,
      causalHistory: @[HistoryEntry(messageId: "m1-missing", senderId: "bob")],
      channelId: "ch-A",
      content: @[byte(2)],
      bloomFilter: @[],
    )
    discard rm.unwrapReceivedMessage(serializeMessage(msg).get())
    check:
      rm.channels["ch-A"].outgoingRepairBuffer.len == 1
      rm.channels["ch-B"].outgoingRepairBuffer.len == 0

  test "duplicate message arrival cancels pending incoming repair entry":
    # Covers the dedup-before-cleanup fix: a rebroadcast arriving at a peer who
    # already has the message must clear that peer's incomingRepairBuffer entry.
    let rm = newReliabilityManager(participantId = "carol").get()
    defer: rm.cleanup()
    check rm.ensureChannel(testChannel).isOk()
    let channel = rm.channels[testChannel]

    rm.setCallbacks(
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, deps: seq[HistoryEntry], ch: SdsChannelID) {.gcsafe.} = discard,
    )

    # Carol already has M1 in history and has a pending incomingRepairBuffer entry
    channel.messageHistory.add("m1")
    channel.incomingRepairBuffer["m1"] = IncomingRepairEntry(
      entry: HistoryEntry(messageId: "m1", senderId: "alice"),
      cachedMessage: @[byte(1)],
      tResp: getTime() + initDuration(seconds = 10),
    )

    # A rebroadcast of M1 arrives
    let msg = SdsMessage(
      messageId: "m1",
      lamportTimestamp: 1,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(1)],
      bloomFilter: @[],
      senderId: "alice",
    )
    discard rm.unwrapReceivedMessage(serializeMessage(msg).get())
    check "m1" notin channel.incomingRepairBuffer

suite "SDS-R: Repair Sweep":
  var rm: ReliabilityManager

  setup:
    rm = newReliabilityManager(participantId = "bob").get()
    check rm.ensureChannel(testChannel).isOk()

  teardown:
    if not rm.isNil:
      rm.cleanup()

  test "runRepairSweep fires onRepairReady for expired tResp":
    var fireCount = 0
    var firstBytes: seq[byte] = @[]
    rm.setCallbacks(
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, deps: seq[HistoryEntry], ch: SdsChannelID) {.gcsafe.} = discard,
      onRepairReady = proc(bytes: seq[byte], ch: SdsChannelID) {.gcsafe.} =
        {.cast(gcsafe).}:
          fireCount += 1
          if fireCount == 1:
            firstBytes = bytes,
    )

    let channel = rm.channels[testChannel]
    channel.incomingRepairBuffer["m-ready"] = IncomingRepairEntry(
      entry: HistoryEntry(messageId: "m-ready", senderId: "alice"),
      cachedMessage: @[byte(1), 2, 3],
      tResp: getTime() - initDuration(seconds = 1),  # expired
    )
    channel.incomingRepairBuffer["m-not-ready"] = IncomingRepairEntry(
      entry: HistoryEntry(messageId: "m-not-ready", senderId: "alice"),
      cachedMessage: @[byte(9), 9, 9],
      tResp: getTime() + initDuration(minutes = 10),  # far future
    )

    rm.runRepairSweep()

    check:
      fireCount == 1
      firstBytes == @[byte(1), 2, 3]
      "m-ready" notin channel.incomingRepairBuffer
      "m-not-ready" in channel.incomingRepairBuffer

  test "runRepairSweep drops outgoing entries past T_max window":
    rm.setCallbacks(
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, deps: seq[HistoryEntry], ch: SdsChannelID) {.gcsafe.} = discard,
    )

    let channel = rm.channels[testChannel]
    let tMax = rm.config.repairTMax
    channel.outgoingRepairBuffer["m-stale"] = OutgoingRepairEntry(
      entry: HistoryEntry(messageId: "m-stale", senderId: "alice"),
      tReq: getTime() - (tMax + tMax),  # now - 2*T_max, past drop window
    )
    channel.outgoingRepairBuffer["m-fresh"] = OutgoingRepairEntry(
      entry: HistoryEntry(messageId: "m-fresh", senderId: "alice"),
      tReq: getTime(),
    )

    rm.runRepairSweep()

    check:
      "m-stale" notin channel.outgoingRepairBuffer
      "m-fresh" in channel.outgoingRepairBuffer

  test "runRepairSweep no-op when buffers are empty":
    var fireCount = 0
    rm.setCallbacks(
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
      proc(msgId: SdsMessageID, deps: seq[HistoryEntry], ch: SdsChannelID) {.gcsafe.} = discard,
      onRepairReady = proc(bytes: seq[byte], ch: SdsChannelID) {.gcsafe.} =
        fireCount += 1,
    )
    rm.runRepairSweep()
    check fireCount == 0

# --- Multi-participant in-process bus for integration tests ---------------

type
  TestBus = ref object
    peers: OrderedTable[SdsParticipantID, ReliabilityManager]
    delivered: Table[SdsParticipantID, seq[SdsMessageID]]
    # Log of raw message-ids placed on the wire, tagged with the source peer.
    wireLog: seq[tuple[senderId: SdsParticipantID, messageId: SdsMessageID]]

proc newTestBus(): TestBus =
  TestBus(
    peers: initOrderedTable[SdsParticipantID, ReliabilityManager](),
    delivered: initTable[SdsParticipantID, seq[SdsMessageID]](),
    wireLog: @[],
  )

proc recordWire(bus: TestBus, senderId: SdsParticipantID, bytes: seq[byte]) {.gcsafe.} =
  let decoded = deserializeMessage(bytes)
  if decoded.isOk():
    bus.wireLog.add((senderId, decoded.get().messageId))

proc deliverExcept(
    bus: TestBus,
    senderId: SdsParticipantID,
    bytes: seq[byte],
    exclude: seq[SdsParticipantID],
) {.gcsafe.} =
  for pid, peer in bus.peers:
    if pid == senderId or pid in exclude:
      continue
    discard peer.unwrapReceivedMessage(bytes)

proc addPeer(
    bus: TestBus,
    participantId: SdsParticipantID,
    config: ReliabilityConfig = defaultConfig(),
): ReliabilityManager =
  let rm = newReliabilityManager(config, participantId).get()
  doAssert rm.ensureChannel(testChannel).isOk()
  bus.peers[participantId] = rm
  bus.delivered[participantId] = @[]

  let pid = participantId
  let busRef = bus
  rm.setCallbacks(
    proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} =
      {.cast(gcsafe).}:
        busRef.delivered[pid].add(msgId),
    proc(msgId: SdsMessageID, ch: SdsChannelID) {.gcsafe.} = discard,
    proc(msgId: SdsMessageID, deps: seq[HistoryEntry], ch: SdsChannelID) {.gcsafe.} = discard,
    onRepairReady = proc(bytes: seq[byte], ch: SdsChannelID) {.gcsafe.} =
      {.cast(gcsafe).}:
        busRef.recordWire(pid, bytes)
        busRef.deliverExcept(pid, bytes, @[]),
  )
  rm

proc broadcast(
    bus: TestBus,
    senderId: SdsParticipantID,
    content: seq[byte],
    messageId: SdsMessageID,
    dropAt: seq[SdsParticipantID] = @[],
) =
  let rm = bus.peers[senderId]
  let wrapped = rm.wrapOutgoingMessage(content, messageId, testChannel)
  doAssert wrapped.isOk()
  bus.recordWire(senderId, wrapped.get())
  bus.deliverExcept(senderId, wrapped.get(), dropAt)

proc forceOutgoingExpired(
    rm: ReliabilityManager, messageId: SdsMessageID
) =
  ## Push a specific outgoingRepairBuffer entry's tReq into the past so the
  ## next wrapOutgoingMessage will pick it up.
  let channel = rm.channels[testChannel]
  if messageId in channel.outgoingRepairBuffer:
    channel.outgoingRepairBuffer[messageId].tReq =
      getTime() - initDuration(seconds = 1)

proc forceIncomingExpired(
    rm: ReliabilityManager, messageId: SdsMessageID
) =
  ## Push an incomingRepairBuffer entry's tResp into the past so runRepairSweep fires it.
  let channel = rm.channels[testChannel]
  if messageId in channel.incomingRepairBuffer:
    channel.incomingRepairBuffer[messageId].tResp =
      getTime() - initDuration(seconds = 1)

suite "SDS-R: Multi-Participant Integration":

  test "basic single-gap repair (Alice -> Bob misses -> Carol's message triggers repair)":
    let bus = newTestBus()
    let alice = bus.addPeer("alice")
    let bob = bus.addPeer("bob")
    let carol = bus.addPeer("carol")

    # Alice sends M1, but Bob is offline for this one.
    bus.broadcast("alice", @[byte(1)], "m1", dropAt = @["bob".SdsParticipantID])
    # Carol now has M1; Bob does not.
    check "m1" in carol.channels[testChannel].messageHistory
    check "m1" notin bob.channels[testChannel].messageHistory

    # Carol sends M2 with causal history referencing M1.
    bus.broadcast("carol", @[byte(2)], "m2")
    # Bob detects M1 missing and populates his outgoingRepairBuffer.
    check "m1" in bob.channels[testChannel].outgoingRepairBuffer
    # Bob should have buffered M2.
    check "m2" in bob.channels[testChannel].incomingBuffer
    check "m2" notin bus.delivered["bob"]

    # Force Bob's T_req so the next wrap attaches the repair request.
    bob.forceOutgoingExpired("m1")

    # Bob sends M3 — it must carry repair_request=[M1, sender=alice].
    bus.broadcast("bob", @[byte(3)], "m3")

    # Alice received M3, saw the repair_request, cached-bypass and response-group
    # checks pass, so she has an incomingRepairBuffer entry for M1 with tResp=0.
    check "m1" in alice.channels[testChannel].incomingRepairBuffer

    # Force alice's tResp to past just to be safe (it's already 0 for self),
    # then run her sweep. She rebroadcasts M1.
    alice.forceIncomingExpired("m1")
    alice.runRepairSweep()

    # Bob now has M1 and M2 delivered.
    check:
      "m1" in bus.delivered["bob"]
      "m2" in bus.delivered["bob"]

  test "response cancellation: only one rebroadcast on the wire":
    let bus = newTestBus()
    let alice = bus.addPeer("alice")
    let bob = bus.addPeer("bob")
    let carol = bus.addPeer("carol")

    # Alice sends M1, Bob offline.
    bus.broadcast("alice", @[byte(1)], "m1", dropAt = @["bob".SdsParticipantID])
    # Carol sends M2; Bob sees M1 missing.
    bus.broadcast("carol", @[byte(2)], "m2")
    check "m1" in bob.channels[testChannel].outgoingRepairBuffer

    # Bob requests repair.
    bob.forceOutgoingExpired("m1")
    bus.broadcast("bob", @[byte(3)], "m3")

    # Both Alice and Carol now have an incomingRepairBuffer entry for M1.
    check:
      "m1" in alice.channels[testChannel].incomingRepairBuffer
      "m1" in carol.channels[testChannel].incomingRepairBuffer

    # Alice fires first (T_resp=0 for self). Her rebroadcast should cancel Carol's
    # pending entry when Carol receives the rebroadcast.
    alice.forceIncomingExpired("m1")
    alice.runRepairSweep()

    # Carol's pending response must have been cleared by the dedup-path cleanup.
    check "m1" notin carol.channels[testChannel].incomingRepairBuffer

    # Even if we now force-run Carol's sweep, nothing should fire.
    let wireCountBefore = bus.wireLog.len
    carol.runRepairSweep()
    check bus.wireLog.len == wireCountBefore

    # Bob received exactly one rebroadcast of M1.
    var m1RebroadcastCount = 0
    for entry in bus.wireLog:
      if entry.messageId == "m1" and entry.senderId != "alice":
        discard  # only the original Alice->all broadcast had senderId="alice"
      if entry.messageId == "m1":
        m1RebroadcastCount += 1
    # Two "m1" entries total on wire: (1) Alice's original broadcast, (2) Alice's rebroadcast.
    check m1RebroadcastCount == 2

  test "cancellation on incoming repair request: peer drops its own pending request":
    let bus = newTestBus()
    let alice = bus.addPeer("alice")
    let bob = bus.addPeer("bob")
    let carol = bus.addPeer("carol")

    # Alice sends M1 — drop at both Bob and Carol, so both miss it.
    bus.broadcast(
      "alice", @[byte(1)], "m1",
      dropAt = @["bob".SdsParticipantID, "carol".SdsParticipantID],
    )
    # Alice sends M2 referencing M1 — both Bob and Carol see M1 missing.
    bus.broadcast("alice", @[byte(2)], "m2")
    check:
      "m1" in bob.channels[testChannel].outgoingRepairBuffer
      "m1" in carol.channels[testChannel].outgoingRepairBuffer

    # Bob's T_req fires first. He sends a repair request for M1.
    bob.forceOutgoingExpired("m1")
    bus.broadcast("bob", @[byte(3)], "m3")

    # Carol, on receiving Bob's repair request, must have dropped her own
    # pending outgoingRepairBuffer entry for M1 (cancellation).
    check "m1" notin carol.channels[testChannel].outgoingRepairBuffer

  test "response group filtering: only group members respond":
    # With numGroups=10, roughly 1/10 of receivers will be in the group.
    # Construct a sender+message where a specific non-sender is NOT in the group.
    var cfg = defaultConfig()
    cfg.numResponseGroups = 10

    # Pick a msgId where carol is not in the group and bob is
    # We probe deterministically because computeTReq/isInResponseGroup are pure.
    var chosenMsg = ""
    for i in 0 ..< 1000:
      let candidate = "probe-" & $i
      let bobIn = isInResponseGroup("bob", "alice", candidate, 10)
      let carolIn = isInResponseGroup("carol", "alice", candidate, 10)
      if bobIn and not carolIn:
        chosenMsg = candidate
        break
    check chosenMsg.len > 0

    let bus = newTestBus()
    discard bus.addPeer("alice", cfg)
    let bob = bus.addPeer("bob", cfg)
    let carol = bus.addPeer("carol", cfg)

    # Both Bob and Carol receive the original M1 (so both have it in messageCache).
    bus.broadcast("alice", @[byte(1)], chosenMsg)

    # Now Dave arrives: build a fake requester message manually so its repair_request
    # names Alice as senderId for chosenMsg.
    # We inject directly by calling unwrapReceivedMessage on bob/carol.
    let dave = bus.addPeer("dave", cfg)
    # Dave has no messages, but we can hand-craft a repair request he would send.
    let reqMsg = SdsMessage(
      messageId: "req-from-dave",
      lamportTimestamp: 10,
      causalHistory: @[],
      channelId: testChannel,
      content: @[byte(9)],
      bloomFilter: @[],
      senderId: "dave",
      repairRequest: @[HistoryEntry(messageId: chosenMsg, senderId: "alice")],
    )
    let bytes = serializeMessage(reqMsg).get()
    discard bob.unwrapReceivedMessage(bytes)
    discard carol.unwrapReceivedMessage(bytes)

    check:
      chosenMsg in bob.channels[testChannel].incomingRepairBuffer
      chosenMsg notin carol.channels[testChannel].incomingRepairBuffer

  test "multi-gap batch repair: many missing deps split across requests":
    let bus = newTestBus()
    discard bus.addPeer("alice")
    let bob = bus.addPeer("bob")

    # Alice sends 5 messages while Bob is offline.
    let drops = @["bob".SdsParticipantID]
    bus.broadcast("alice", @[byte(1)], "m1", dropAt = drops)
    bus.broadcast("alice", @[byte(2)], "m2", dropAt = drops)
    bus.broadcast("alice", @[byte(3)], "m3", dropAt = drops)
    bus.broadcast("alice", @[byte(4)], "m4", dropAt = drops)
    bus.broadcast("alice", @[byte(5)], "m5", dropAt = drops)

    # Bob comes online and receives M6 which depends on m1..m5.
    bus.broadcast("alice", @[byte(6)], "m6")

    # Bob should have 5 outgoing repair entries.
    let channel = bob.channels[testChannel]
    check channel.outgoingRepairBuffer.len == 5

    # Force all to expired and wrap one message — only maxRepairRequests
    # (default 3) should attach to a single outgoing message.
    for id in ["m1", "m2", "m3", "m4", "m5"]:
      bob.forceOutgoingExpired(id)

    let wrapped = bob.wrapOutgoingMessage(@[byte(99)], "bob-msg-1", testChannel).get()
    let decoded = deserializeMessage(wrapped).get()
    check decoded.repairRequest.len <= bob.config.maxRepairRequests

    # The attached entries should be removed from the outgoing buffer.
    check channel.outgoingRepairBuffer.len == 5 - decoded.repairRequest.len

  test "markDependenciesMet externally clears pending repair entry":
    let bus = newTestBus()
    discard bus.addPeer("alice")
    let bob = bus.addPeer("bob")

    bus.broadcast("alice", @[byte(1)], "m1", dropAt = @["bob".SdsParticipantID])
    bus.broadcast("alice", @[byte(2)], "m2")
    check "m1" in bob.channels[testChannel].outgoingRepairBuffer

    # Simulate Bob fetching M1 via an out-of-band store query.
    check bob.markDependenciesMet(@["m1"], testChannel).isOk()
    check "m1" notin bob.channels[testChannel].outgoingRepairBuffer

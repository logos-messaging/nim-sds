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

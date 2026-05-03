import unittest, results, std/tables
import sds
import ./in_memory_persistence

converter toParticipantID(s: string): SdsParticipantID = s.SdsParticipantID

const testChannel = "testChannel"

suite "Persistence: write → restart → read-back":
  test "outgoing buffer survives restart":
    let store = newInMemoryStore()
    let p1 = newInMemoryPersistence(store)
    let rm1 = newReliabilityManager(persistence = p1).get()
    check rm1.ensureChannel(testChannel).isOk()
    let wrapped = rm1.wrapOutgoingMessage(@[1.byte, 2, 3], "msg-1", testChannel)
    check wrapped.isOk()
    check store.outgoing[testChannel].len == 1
    check "msg-1" in store.outgoing[testChannel]
    rm1.cleanup()

    # Simulate restart: fresh manager, same backend
    let p2 = newInMemoryPersistence(store)
    let rm2 = newReliabilityManager(persistence = p2).get()
    check rm2.ensureChannel(testChannel).isOk()
    let buf = rm2.getOutgoingBuffer(testChannel)
    check buf.len == 1
    check buf[0].message.messageId == "msg-1"
    rm2.cleanup()

  test "lamport clock survives restart":
    let store = newInMemoryStore()
    let p1 = newInMemoryPersistence(store)
    let rm1 = newReliabilityManager(persistence = p1).get()
    check rm1.ensureChannel(testChannel).isOk()
    rm1.updateLamportTimestamp(42, testChannel)
    check store.lamports[testChannel] == 43  # max(42, 0) + 1
    rm1.cleanup()

    let p2 = newInMemoryPersistence(store)
    let rm2 = newReliabilityManager(persistence = p2).get()
    check rm2.ensureChannel(testChannel).isOk()
    check rm2.channels[testChannel].lamportTimestamp == 43

  test "delivered messages survive restart and rebuild bloom":
    let store = newInMemoryStore()
    let p1 = newInMemoryPersistence(store)
    let rm1 = newReliabilityManager(persistence = p1).get()
    check rm1.ensureChannel(testChannel).isOk()
    let msg = SdsMessage.init(
      messageId = "delivered-1",
      lamportTimestamp = 1,
      causalHistory = @[],
      channelId = testChannel,
      content = @[9.byte, 9],
      bloomFilter = @[],
      senderId = "alice",
    )
    rm1.addToHistory(msg, testChannel)
    check store.log[testChannel].len == 1
    rm1.cleanup()

    let p2 = newInMemoryPersistence(store)
    let rm2 = newReliabilityManager(persistence = p2).get()
    check rm2.ensureChannel(testChannel).isOk()
    let ch = rm2.channels[testChannel]
    check ch.messageHistory.len == 1
    check "delivered-1" in ch.messageHistory
    # Bloom filter rebuilt from log on bootstrap
    check ch.bloomFilter.contains("delivered-1")

  test "ack removes outgoing entry from persistence":
    let store = newInMemoryStore()
    let p = newInMemoryPersistence(store)
    let rm = newReliabilityManager(persistence = p).get()
    check rm.ensureChannel(testChannel).isOk()
    discard rm.wrapOutgoingMessage(@[1.byte], "msg-x", testChannel)
    check "msg-x" in store.outgoing[testChannel]

    # Synthesize an incoming message that ACKs msg-x via causal history
    let ackMsg = SdsMessage.init(
      messageId = "ack-bearer",
      lamportTimestamp = 5,
      causalHistory = @[HistoryEntry.init("msg-x", @[])],
      channelId = testChannel,
      content = @[],
      bloomFilter = @[],
      senderId = "bob",
    )
    let serialized = serializeMessage(ackMsg).get()
    discard rm.unwrapReceivedMessage(serialized)
    check "msg-x" notin store.outgoing[testChannel]
    rm.cleanup()

  test "removeChannel fires per-entry removes":
    let store = newInMemoryStore()
    let p = newInMemoryPersistence(store)
    let rm = newReliabilityManager(persistence = p).get()
    check rm.ensureChannel(testChannel).isOk()
    discard rm.wrapOutgoingMessage(@[1.byte], "msg-r", testChannel)
    check store.outgoing[testChannel].len == 1
    check rm.removeChannel(testChannel).isOk()
    check store.outgoing[testChannel].len == 0
    rm.cleanup()

  test "noOpPersistence keeps existing manager working":
    let rm = newReliabilityManager().get()  # default no-op
    check rm.ensureChannel(testChannel).isOk()
    let wrapped = rm.wrapOutgoingMessage(@[1.byte], "msg-n", testChannel)
    check wrapped.isOk()
    check rm.getOutgoingBuffer(testChannel).len == 1
    rm.cleanup()

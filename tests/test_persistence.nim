import unittest, results, std/[tables, sets, times]
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

  test "removeChannel issues exactly one dropChannel call and wipes all state":
    # Regression for PR #66 review: removal must be a single transactional
    # drop, not N per-row removes — otherwise SQLite eats N fsyncs per drop.
    let store = newInMemoryStore()
    let p = newInMemoryPersistence(store)
    let rm = newReliabilityManager(persistence = p).get()
    check rm.ensureChannel(testChannel).isOk()
    discard rm.wrapOutgoingMessage(@[1.byte], "msg-r", testChannel)
    check store.outgoing[testChannel].len == 1
    check store.lamports[testChannel] > 0

    check rm.removeChannel(testChannel).isOk()
    check store.dropChannelCalls.getOrDefault(testChannel) == 1
    check testChannel notin store.outgoing
    check testChannel notin store.lamports
    check testChannel notin store.log
    check testChannel notin store.incoming
    check testChannel notin store.outgoingRepair
    check testChannel notin store.incomingRepair
    rm.cleanup()

  test "noOpPersistence keeps existing manager working":
    let rm = newReliabilityManager().get()  # default no-op
    check rm.ensureChannel(testChannel).isOk()
    let wrapped = rm.wrapOutgoingMessage(@[1.byte], "msg-n", testChannel)
    check wrapped.isOk()
    check rm.getOutgoingBuffer(testChannel).len == 1
    rm.cleanup()

  test "continue operating after restart: lamport stays monotonic":
    let store = newInMemoryStore()
    let p1 = newInMemoryPersistence(store)
    let rm1 = newReliabilityManager(persistence = p1).get()
    check rm1.ensureChannel(testChannel).isOk()
    discard rm1.wrapOutgoingMessage(@[1.byte], "m1", testChannel)
    let lamportAfterSession1 = store.lamports[testChannel]
    check lamportAfterSession1 > 0
    rm1.cleanup()

    # Restart and send another message — lamport must not regress.
    let p2 = newInMemoryPersistence(store)
    let rm2 = newReliabilityManager(persistence = p2).get()
    check rm2.ensureChannel(testChannel).isOk()
    check rm2.channels[testChannel].lamportTimestamp == lamportAfterSession1
    discard rm2.wrapOutgoingMessage(@[2.byte], "m2", testChannel)
    check store.lamports[testChannel] > lamportAfterSession1
    check rm2.getOutgoingBuffer(testChannel).len == 2
    rm2.cleanup()

  test "multiple restart cycles preserve state":
    let store = newInMemoryStore()
    for i in 1 .. 3:
      let p = newInMemoryPersistence(store)
      let rm = newReliabilityManager(persistence = p).get()
      check rm.ensureChannel(testChannel).isOk()
      discard rm.wrapOutgoingMessage(@[byte(i)], "m" & $i, testChannel)
      rm.cleanup()

    # Final session: all three messages must be in the buffer.
    let pFinal = newInMemoryPersistence(store)
    let rmFinal = newReliabilityManager(persistence = pFinal).get()
    check rmFinal.ensureChannel(testChannel).isOk()
    let buf = rmFinal.getOutgoingBuffer(testChannel)
    check buf.len == 3
    var ids = newSeq[string]()
    for unack in buf:
      ids.add(unack.message.messageId.string)
    check "m1" in ids
    check "m2" in ids
    check "m3" in ids
    rmFinal.cleanup()

  test "incoming dep-waiting buffer survives restart with missingDeps intact":
    let store = newInMemoryStore()
    let p1 = newInMemoryPersistence(store)
    let rm1 = newReliabilityManager(persistence = p1).get()
    check rm1.ensureChannel(testChannel).isOk()

    # Receive a message whose causal-history references an unknown predecessor.
    let depMsg = SdsMessage.init(
      messageId = "msg-with-deps",
      lamportTimestamp = 10,
      causalHistory = @[HistoryEntry.init("missing-dep", @[])],
      channelId = testChannel,
      content = @[7.byte],
      bloomFilter = @[],
      senderId = "carol",
    )
    let serialized = serializeMessage(depMsg).get()
    discard rm1.unwrapReceivedMessage(serialized)
    check "msg-with-deps" in store.incoming[testChannel]
    rm1.cleanup()

    # Restart — buffered message and its missing-deps set must be back.
    let p2 = newInMemoryPersistence(store)
    let rm2 = newReliabilityManager(persistence = p2).get()
    check rm2.ensureChannel(testChannel).isOk()
    let inbuf = rm2.getIncomingBuffer(testChannel)
    check "msg-with-deps" in inbuf
    check "missing-dep" in inbuf["msg-with-deps"].missingDeps
    rm2.cleanup()

  test "removeChannel + recreate does not inherit stale lamport":
    # Regression: dropChannel must wipe the lamport row; otherwise a recreate
    # of the same channelId after restart picks up the old timestamp.
    let store = newInMemoryStore()
    let p1 = newInMemoryPersistence(store)
    let rm1 = newReliabilityManager(persistence = p1).get()
    check rm1.ensureChannel(testChannel).isOk()
    discard rm1.wrapOutgoingMessage(@[1.byte], "m-old", testChannel)
    check store.lamports[testChannel] > 0
    check rm1.removeChannel(testChannel).isOk()
    check testChannel notin store.lamports
    rm1.cleanup()

    # Recreate the same channelId after a restart — must start fresh.
    let p2 = newInMemoryPersistence(store)
    let rm2 = newReliabilityManager(persistence = p2).get()
    check rm2.ensureChannel(testChannel).isOk()
    check rm2.channels[testChannel].lamportTimestamp == 0
    check rm2.getOutgoingBuffer(testChannel).len == 0
    rm2.cleanup()

  test "SDS-R outgoing repair buffer survives restart with absolute t_req_at":
    let store = newInMemoryStore()
    let p1 = newInMemoryPersistence(store)
    let rm1 = newReliabilityManager(
      participantId = "alice", persistence = p1
    ).get()
    check rm1.ensureChannel(testChannel).isOk()

    # Receive a message that references an unknown dep — triggers SDS-R repair.
    let depMsg = SdsMessage.init(
      messageId = "msg-needs-repair",
      lamportTimestamp = 5,
      causalHistory = @[HistoryEntry.init("missing-dep", @[])],
      channelId = testChannel,
      content = @[1.byte],
      bloomFilter = @[],
      senderId = "bob",
    )
    discard rm1.unwrapReceivedMessage(serializeMessage(depMsg).get())
    check "missing-dep" in store.outgoingRepair[testChannel]
    let originalTReqAt = store.outgoingRepair[testChannel]["missing-dep"].minTimeRepairReq
    check originalTReqAt.toUnix > 0
    rm1.cleanup()

    # Restart — repair entry must be back with the SAME absolute time, not "now".
    let p2 = newInMemoryPersistence(store)
    let rm2 = newReliabilityManager(
      participantId = "alice", persistence = p2
    ).get()
    check rm2.ensureChannel(testChannel).isOk()
    let buf = rm2.channels[testChannel].outgoingRepairBuffer
    check "missing-dep" in buf
    check buf["missing-dep"].minTimeRepairReq == originalTReqAt
    rm2.cleanup()

  test "FIFO eviction state survives restart":
    let store = newInMemoryStore()
    var smallCfg = defaultConfig()
    smallCfg.maxMessageHistory = 3
    smallCfg.bloomFilterCapacity = 3

    let p1 = newInMemoryPersistence(store)
    let rm1 = newReliabilityManager(config = smallCfg, persistence = p1).get()
    check rm1.ensureChannel(testChannel).isOk()
    # Add 5 delivered messages — first 2 should be evicted by FIFO.
    for i in 1 .. 5:
      let m = SdsMessage.init(
        messageId = "m" & $i,
        lamportTimestamp = int64(i),
        causalHistory = @[],
        channelId = testChannel,
        content = @[byte(i)],
        bloomFilter = @[],
        senderId = "alice",
      )
      rm1.addToHistory(m, testChannel)
    check store.log[testChannel].len == 3
    check "m1" notin store.log[testChannel]
    check "m2" notin store.log[testChannel]
    rm1.cleanup()

    # Restart — evicted entries must NOT come back; survivors keep order.
    let p2 = newInMemoryPersistence(store)
    let rm2 = newReliabilityManager(config = smallCfg, persistence = p2).get()
    check rm2.ensureChannel(testChannel).isOk()
    let history = rm2.channels[testChannel].messageHistory
    check history.len == 3
    check "m1" notin history
    check "m2" notin history
    check "m3" in history
    check "m5" in history
    # FIFO continues correctly after restart: adding m6 evicts m3, not a stale entry.
    let m6 = SdsMessage.init(
      messageId = "m6", lamportTimestamp = 6, causalHistory = @[],
      channelId = testChannel, content = @[6.byte],
      bloomFilter = @[], senderId = "alice",
    )
    rm2.addToHistory(m6, testChannel)
    check "m3" notin store.log[testChannel]
    check "m6" in store.log[testChannel]
    rm2.cleanup()

  test "dep-clear cascade resumes correctly across a restart":
    let store = newInMemoryStore()
    let p1 = newInMemoryPersistence(store)
    let rm1 = newReliabilityManager(persistence = p1).get()
    check rm1.ensureChannel(testChannel).isOk()

    # Receive c (deps on b), then b (deps on a). Both must buffer.
    let msgC = SdsMessage.init(
      messageId = "c", lamportTimestamp = 30,
      causalHistory = @[HistoryEntry.init("b", @[])],
      channelId = testChannel, content = @[3.byte],
      bloomFilter = @[], senderId = "carol",
    )
    let msgB = SdsMessage.init(
      messageId = "b", lamportTimestamp = 20,
      causalHistory = @[HistoryEntry.init("a", @[])],
      channelId = testChannel, content = @[2.byte],
      bloomFilter = @[], senderId = "bob",
    )
    discard rm1.unwrapReceivedMessage(serializeMessage(msgC).get())
    discard rm1.unwrapReceivedMessage(serializeMessage(msgB).get())
    check "c" in store.incoming[testChannel]
    check "b" in store.incoming[testChannel]
    rm1.cleanup()

    # Restart — both still buffered, with intact missingDeps.
    let p2 = newInMemoryPersistence(store)
    let rm2 = newReliabilityManager(persistence = p2).get()
    check rm2.ensureChannel(testChannel).isOk()
    let inbuf = rm2.getIncomingBuffer(testChannel)
    check "c" in inbuf
    check "b" in inbuf

    # Now receive a (root) — should cascade-deliver a, b, c.
    let msgA = SdsMessage.init(
      messageId = "a", lamportTimestamp = 10, causalHistory = @[],
      channelId = testChannel, content = @[1.byte],
      bloomFilter = @[], senderId = "alice",
    )
    discard rm2.unwrapReceivedMessage(serializeMessage(msgA).get())
    let history = rm2.channels[testChannel].messageHistory
    check "a" in history
    check "b" in history
    check "c" in history
    # Buffer should be drained.
    check rm2.getIncomingBuffer(testChannel).len == 0
    rm2.cleanup()

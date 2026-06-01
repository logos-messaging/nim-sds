import results, std/[tables, sets, times]
import sds
import ./async_unittest
import ./in_memory_persistence

converter toParticipantID(s: string): SdsParticipantID =
  s.SdsParticipantID

const testChannel = "testChannel"

# Helper: build a ReliabilityManager wired only to the V2 in-memory
# persistence (no legacy backend). Mirrors how production callers will
# construct the manager once phase 3 deletes the legacy field.
proc newV2Manager(
    store: InMemoryStore, config = defaultConfig()
): ReliabilityManager =
  newReliabilityManager(
      participantId = "alice",
      config = config,
      persistence = newInMemoryPersistence(store),
    )
    .get()

suite "Persistence: write → restart → read-back":
  asyncTest "outgoing buffer survives restart":
    let store = newInMemoryStore()
    let rm1 = newV2Manager(store)
    check (await rm1.ensureChannel(testChannel)).isOk()
    let wrapped = await rm1.wrapOutgoingMessage(@[1.byte, 2, 3], "msg-1", testChannel)
    check wrapped.isOk()
    check store.outgoing[testChannel].len == 1
    check "msg-1" in store.outgoing[testChannel]
    await rm1.cleanup()

    # Simulate restart: fresh manager, same backend.
    let rm2 = newV2Manager(store)
    check (await rm2.ensureChannel(testChannel)).isOk()
    let buf = await rm2.getOutgoingBuffer(testChannel)
    check buf.len == 1
    check buf[0].message.messageId == "msg-1"
    await rm2.cleanup()

  asyncTest "lamport clock survives restart":
    let store = newInMemoryStore()
    let rm1 = newV2Manager(store)
    check (await rm1.ensureChannel(testChannel)).isOk()
    check (await rm1.updateLamportTimestamp(42, testChannel)).isOk()
    # updateLamportTimestamp is now pure; the mutation is persisted by the
    # next op-end save. Drive a wrap to force a trySaveMeta.
    discard await rm1.wrapOutgoingMessage(@[byte(1)], "tick", testChannel)
    # max(42,0)+1 then max(getTime().toUnix, 43)+1; whatever wrap sets is
    # what we'll see. We just assert it stayed monotonic.
    check store.lamports[testChannel] >= 43
    let savedLamport = store.lamports[testChannel]
    await rm1.cleanup()

    let rm2 = newV2Manager(store)
    check (await rm2.ensureChannel(testChannel)).isOk()
    check rm2.channels[testChannel].lamportTimestamp == savedLamport

  asyncTest "delivered messages survive restart and rebuild bloom":
    let store = newInMemoryStore()
    let rm1 = newV2Manager(store)
    check (await rm1.ensureChannel(testChannel)).isOk()
    let msg = SdsMessage.init(
      messageId = "delivered-1",
      lamportTimestamp = 1,
      causalHistory = @[],
      channelId = testChannel,
      content = @[9.byte, 9],
      bloomFilter = @[],
      senderId = "alice",
    )
    check (await rm1.addToHistory(msg, testChannel)).isOk()
    # New design: addToHistory queues; tryUpdateHistory flushes. Tests
    # that drive addToHistory directly must follow with an explicit flush
    # (in production, the public protocol op issues the flush at op end).
    await rm1.tryUpdateHistory(testChannel)
    check store.log[testChannel].len == 1
    await rm1.cleanup()

    let rm2 = newV2Manager(store)
    check (await rm2.ensureChannel(testChannel)).isOk()
    let ch = rm2.channels[testChannel]
    check ch.messageHistory.len == 1
    check "delivered-1" in ch.messageHistory
    # Bloom filter rebuilt from log on bootstrap.
    check ch.bloomFilter.contains("delivered-1")

  asyncTest "ack removes outgoing entry from persistence":
    let store = newInMemoryStore()
    let rm = newV2Manager(store)
    check (await rm.ensureChannel(testChannel)).isOk()
    discard await rm.wrapOutgoingMessage(@[1.byte], "msg-x", testChannel)
    check "msg-x" in store.outgoing[testChannel]

    # Synthesize an incoming message that ACKs msg-x via causal history.
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
    discard await rm.unwrapReceivedMessage(serialized)
    check "msg-x" notin store.outgoing[testChannel]
    await rm.cleanup()

  asyncTest "removeChannel issues exactly one dropChannel call and wipes all state":
    # Regression for PR #66 review: removal must be a single transactional
    # drop, not N per-row removes.
    let store = newInMemoryStore()
    let rm = newV2Manager(store)
    check (await rm.ensureChannel(testChannel)).isOk()
    discard await rm.wrapOutgoingMessage(@[1.byte], "msg-r", testChannel)
    check store.outgoing[testChannel].len == 1
    check store.lamports[testChannel] > 0

    check (await rm.removeChannel(testChannel)).isOk()
    check store.dropChannelCalls.getOrDefault(testChannel) == 1
    check testChannel notin store.outgoing
    check testChannel notin store.lamports
    check testChannel notin store.log
    check testChannel notin store.incoming
    check testChannel notin store.outgoingRepair
    check testChannel notin store.incomingRepair
    await rm.cleanup()

  asyncTest "noOpPersistence keeps existing manager working":
    let rm = newReliabilityManager(participantId = "alice").get()
      # default no-op persistence (both legacy and V2)
    check (await rm.ensureChannel(testChannel)).isOk()
    let wrapped = await rm.wrapOutgoingMessage(@[1.byte], "msg-n", testChannel)
    check wrapped.isOk()
    let buf = await rm.getOutgoingBuffer(testChannel)
    check buf.len == 1
    await rm.cleanup()

  asyncTest "continue operating after restart: lamport stays monotonic":
    let store = newInMemoryStore()
    let rm1 = newV2Manager(store)
    check (await rm1.ensureChannel(testChannel)).isOk()
    discard await rm1.wrapOutgoingMessage(@[1.byte], "m1", testChannel)
    let lamportAfterSession1 = store.lamports[testChannel]
    check lamportAfterSession1 > 0
    await rm1.cleanup()

    # Restart and send another message — lamport must not regress.
    let rm2 = newV2Manager(store)
    check (await rm2.ensureChannel(testChannel)).isOk()
    check rm2.channels[testChannel].lamportTimestamp == lamportAfterSession1
    discard await rm2.wrapOutgoingMessage(@[2.byte], "m2", testChannel)
    check store.lamports[testChannel] > lamportAfterSession1
    let buf = await rm2.getOutgoingBuffer(testChannel)
    check buf.len == 2
    await rm2.cleanup()

  asyncTest "multiple restart cycles preserve state":
    let store = newInMemoryStore()
    for i in 1 .. 3:
      let rm = newV2Manager(store)
      check (await rm.ensureChannel(testChannel)).isOk()
      discard await rm.wrapOutgoingMessage(@[byte(i)], "m" & $i, testChannel)
      await rm.cleanup()

    # Final session: all three messages must be in the buffer.
    let rmFinal = newV2Manager(store)
    check (await rmFinal.ensureChannel(testChannel)).isOk()
    let buf = await rmFinal.getOutgoingBuffer(testChannel)
    check buf.len == 3
    var ids = newSeq[string]()
    for unack in buf:
      ids.add(unack.message.messageId.string)
    check "m1" in ids
    check "m2" in ids
    check "m3" in ids
    await rmFinal.cleanup()

  asyncTest "incoming dep-waiting buffer survives restart with missingDeps intact":
    let store = newInMemoryStore()
    let rm1 = newV2Manager(store)
    check (await rm1.ensureChannel(testChannel)).isOk()

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
    discard await rm1.unwrapReceivedMessage(serialized)
    check "msg-with-deps" in store.incoming[testChannel]
    await rm1.cleanup()

    # Restart — buffered message and its missing-deps set must be back.
    let rm2 = newV2Manager(store)
    check (await rm2.ensureChannel(testChannel)).isOk()
    let inbuf = await rm2.getIncomingBuffer(testChannel)
    check "msg-with-deps" in inbuf
    check "missing-dep" in inbuf["msg-with-deps"].missingDeps
    await rm2.cleanup()

  asyncTest "removeChannel + recreate does not inherit stale lamport":
    let store = newInMemoryStore()
    let rm1 = newV2Manager(store)
    check (await rm1.ensureChannel(testChannel)).isOk()
    discard await rm1.wrapOutgoingMessage(@[1.byte], "m-old", testChannel)
    check store.lamports[testChannel] > 0
    check (await rm1.removeChannel(testChannel)).isOk()
    check testChannel notin store.lamports
    await rm1.cleanup()

    # Recreate the same channelId after a restart — must start fresh.
    let rm2 = newV2Manager(store)
    check (await rm2.ensureChannel(testChannel)).isOk()
    check rm2.channels[testChannel].lamportTimestamp == 0
    let buf = await rm2.getOutgoingBuffer(testChannel)
    check buf.len == 0
    await rm2.cleanup()

  asyncTest "SDS-R outgoing repair buffer survives restart with absolute t_req_at":
    let store = newInMemoryStore()
    let rm1 = newV2Manager(store)
    check (await rm1.ensureChannel(testChannel)).isOk()

    let depMsg = SdsMessage.init(
      messageId = "msg-needs-repair",
      lamportTimestamp = 5,
      causalHistory = @[HistoryEntry.init("missing-dep", @[])],
      channelId = testChannel,
      content = @[1.byte],
      bloomFilter = @[],
      senderId = "bob",
    )
    discard await rm1.unwrapReceivedMessage(serializeMessage(depMsg).get())
    check "missing-dep" in store.outgoingRepair[testChannel]
    let originalTReqAt =
      store.outgoingRepair[testChannel]["missing-dep"].minTimeRepairReq
    check originalTReqAt.toUnix > 0
    await rm1.cleanup()

    # Restart — repair entry must be back with the SAME absolute time.
    # Codec serialises Time as int64 unix milliseconds (PLAN §1.5), so the
    # restored Time may differ by sub-millisecond precision from the
    # original. Compare at second resolution which is what the protocol
    # actually relies on.
    let rm2 = newV2Manager(store)
    check (await rm2.ensureChannel(testChannel)).isOk()
    let buf = rm2.channels[testChannel].outgoingRepairBuffer
    check "missing-dep" in buf
    check buf["missing-dep"].minTimeRepairReq.toUnix == originalTReqAt.toUnix
    await rm2.cleanup()

  asyncTest "FIFO eviction state survives restart":
    let store = newInMemoryStore()
    var smallCfg = defaultConfig()
    smallCfg.maxMessageHistory = 3
    smallCfg.bloomFilterCapacity = 3

    let rm1 = newV2Manager(store, smallCfg)
    check (await rm1.ensureChannel(testChannel)).isOk()
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
      check (await rm1.addToHistory(m, testChannel)).isOk()
      await rm1.tryUpdateHistory(testChannel)
    check store.log[testChannel].len == 3
    check "m1" notin store.log[testChannel]
    check "m2" notin store.log[testChannel]
    await rm1.cleanup()

    # Restart — evicted entries must NOT come back; survivors keep order.
    let rm2 = newV2Manager(store, smallCfg)
    check (await rm2.ensureChannel(testChannel)).isOk()
    let history = rm2.channels[testChannel].messageHistory
    check history.len == 3
    check "m1" notin history
    check "m2" notin history
    check "m3" in history
    check "m5" in history
    # FIFO continues correctly after restart: adding m6 evicts m3.
    let m6 = SdsMessage.init(
      messageId = "m6",
      lamportTimestamp = 6,
      causalHistory = @[],
      channelId = testChannel,
      content = @[6.byte],
      bloomFilter = @[],
      senderId = "alice",
    )
    check (await rm2.addToHistory(m6, testChannel)).isOk()
    await rm2.tryUpdateHistory(testChannel)
    check "m3" notin store.log[testChannel]
    check "m6" in store.log[testChannel]
    await rm2.cleanup()

  asyncTest "dep-clear cascade resumes correctly across a restart":
    let store = newInMemoryStore()
    let rm1 = newV2Manager(store)
    check (await rm1.ensureChannel(testChannel)).isOk()

    # Receive c (deps on b), then b (deps on a). Both must buffer.
    let msgC = SdsMessage.init(
      messageId = "c",
      lamportTimestamp = 30,
      causalHistory = @[HistoryEntry.init("b", @[])],
      channelId = testChannel,
      content = @[3.byte],
      bloomFilter = @[],
      senderId = "carol",
    )
    let msgB = SdsMessage.init(
      messageId = "b",
      lamportTimestamp = 20,
      causalHistory = @[HistoryEntry.init("a", @[])],
      channelId = testChannel,
      content = @[2.byte],
      bloomFilter = @[],
      senderId = "bob",
    )
    discard await rm1.unwrapReceivedMessage(serializeMessage(msgC).get())
    discard await rm1.unwrapReceivedMessage(serializeMessage(msgB).get())
    check "c" in store.incoming[testChannel]
    check "b" in store.incoming[testChannel]
    await rm1.cleanup()

    # Restart — both still buffered with intact missingDeps.
    let rm2 = newV2Manager(store)
    check (await rm2.ensureChannel(testChannel)).isOk()
    let inbuf = await rm2.getIncomingBuffer(testChannel)
    check "c" in inbuf
    check "b" in inbuf

    # Now receive a (root) — should cascade-deliver a, b, c.
    let msgA = SdsMessage.init(
      messageId = "a",
      lamportTimestamp = 10,
      causalHistory = @[],
      channelId = testChannel,
      content = @[1.byte],
      bloomFilter = @[],
      senderId = "alice",
    )
    discard await rm2.unwrapReceivedMessage(serializeMessage(msgA).get())
    let history = rm2.channels[testChannel].messageHistory
    check "a" in history
    check "b" in history
    check "c" in history
    let inbufFinal = await rm2.getIncomingBuffer(testChannel)
    check inbufFinal.len == 0
    await rm2.cleanup()

suite "Persistence: failure policy":
  asyncTest "loadChannel failure surfaces as rePersistenceError on bootstrap":
    # Bootstrap durability is the semantic intent of getOrCreateChannel —
    # the caller asked us to materialise a channel and we can't do that
    # without knowing prior state. So this op DOES propagate err on load
    # failure (PLAN §8).
    let store = newInMemoryStore()
    store.failingOps.incl("loadChannel")
    let rm = newReliabilityManager(
        participantId = "alice", persistence = newInMemoryPersistence(store)
      )
      .get()
    let res = await rm.ensureChannel(testChannel)
    check res.isErr()
    check res.error == ReliabilityError.rePersistenceError

  asyncTest "saveChannelMeta failure during send does NOT surface — non-fatal policy":
    # PLAN §8: persistence failures during foreground ops are logged but
    # MUST NOT abort the op. The in-memory state is the source of truth;
    # the next op's snapshot will re-synchronise on-disk state. This test
    # is the inversion of the legacy "write failure surfaces as err" —
    # the new policy is deliberate.
    let store = newInMemoryStore()
    let rm = newReliabilityManager(
        participantId = "alice", persistence = newInMemoryPersistence(store)
      )
      .get()
    check (await rm.ensureChannel(testChannel)).isOk()
    store.failingOps.incl("saveChannelMeta")
    let res = await rm.wrapOutgoingMessage(@[byte(1)], "m1", testChannel)
    # Op succeeds: bytes were produced, protocol state is correct in
    # memory, the FFI caller is unaffected.
    check res.isOk()
    # In-memory state is correct even though disk save was rejected.
    let buf = await rm.getOutgoingBuffer(testChannel)
    check buf.len == 1
    check buf[0].message.messageId == "m1"
    # Recovery: clear the failure, drive another op, disk catches up.
    store.failingOps.excl("saveChannelMeta")
    let res2 = await rm.wrapOutgoingMessage(@[byte(2)], "m2", testChannel)
    check res2.isOk()
    check "m1" in store.outgoing[testChannel]
    check "m2" in store.outgoing[testChannel]

  asyncTest "updateHistory failure during send does NOT surface — non-fatal policy":
    # Same policy applied to the history-update path.
    let store = newInMemoryStore()
    let rm = newReliabilityManager(
        participantId = "alice", persistence = newInMemoryPersistence(store)
      )
      .get()
    check (await rm.ensureChannel(testChannel)).isOk()
    store.failingOps.incl("updateHistory")
    let res = await rm.wrapOutgoingMessage(@[byte(1)], "m1", testChannel)
    check res.isOk()
    check rm.channels[testChannel].messageHistory.len == 1

  asyncTest "updateHistory failure is retried via R2 pending-write queue":
    # Fix for PR #72 review comment #1: a failed history write must not
    # silently drop the delta. The pending-write queue parks failed
    # entries and retries them on the next op end. Once the backend
    # recovers, the disk catches up automatically — no caller action
    # needed, no err surfaced.
    let store = newInMemoryStore()
    let rm = newReliabilityManager(
        participantId = "alice", persistence = newInMemoryPersistence(store)
      )
      .get()
    check (await rm.ensureChannel(testChannel)).isOk()

    # Failure 1: send m1 while updateHistory is broken.
    store.failingOps.incl("updateHistory")
    discard await rm.wrapOutgoingMessage(@[byte(1)], "m1", testChannel)
    # In-memory state is correct; disk has no log entry for m1 yet.
    check rm.channels[testChannel].messageHistory.len == 1
    check testChannel notin store.log or "m1" notin store.log[testChannel]
    # Pending queue should be holding m1 for retry.
    check rm.channels[testChannel].pendingHistoryAppends.len == 1
    check "m1" in rm.channels[testChannel].pendingHistoryAppends

    # Failure 2: send m2 while still broken. Pending should now hold both.
    discard await rm.wrapOutgoingMessage(@[byte(2)], "m2", testChannel)
    check rm.channels[testChannel].pendingHistoryAppends.len == 2
    check "m1" in rm.channels[testChannel].pendingHistoryAppends
    check "m2" in rm.channels[testChannel].pendingHistoryAppends
    # Still nothing on disk.
    check testChannel notin store.log or store.log[testChannel].len == 0

    # Recovery: clear the backend failure, send m3. The op-end flush
    # should drain ALL pending entries plus the new one in a single call.
    store.failingOps.excl("updateHistory")
    discard await rm.wrapOutgoingMessage(@[byte(3)], "m3", testChannel)
    check rm.channels[testChannel].pendingHistoryAppends.len == 0
    check "m1" in store.log[testChannel]
    check "m2" in store.log[testChannel]
    check "m3" in store.log[testChannel]

  asyncTest "evict-then-re-add merge rule preserves the re-added message on disk":
    # Regression: with the original "evict-wins" merge rule, a message
    # re-added (e.g. via SDS-R repair) after being evicted during a
    # backend outage would have its append silently dropped because the
    # id was still in pendingHistoryEvicts. The "latest-wins" rule fixes
    # this — the re-add cancels the pending evict.
    let store = newInMemoryStore()
    var smallCfg = defaultConfig()
    smallCfg.maxMessageHistory = 2
    smallCfg.bloomFilterCapacity = 2
    let rm = newReliabilityManager(
        participantId = "alice",
        config = smallCfg,
        persistence = newInMemoryPersistence(store),
      )
      .get()
    check (await rm.ensureChannel(testChannel)).isOk()

    proc mkMsg(id: string, ts: int64): SdsMessage =
      SdsMessage.init(
        messageId = id,
        lamportTimestamp = ts,
        causalHistory = @[],
        channelId = testChannel,
        content = @[byte(ts)],
        bloomFilter = @[],
        senderId = "alice",
      )

    # Break the backend, then fill the channel past maxMessageHistory so
    # m1 gets evicted while we have no successful flush yet.
    store.failingOps.incl("updateHistory")
    check (await rm.addToHistory(mkMsg("m1", 1), testChannel)).isOk()
    await rm.tryUpdateHistory(testChannel) # fails — m1 queued
    check (await rm.addToHistory(mkMsg("m2", 2), testChannel)).isOk()
    check (await rm.addToHistory(mkMsg("m3", 3), testChannel)).isOk()
    # m1 evicted by FIFO; pending should now have m2,m3 as appends and m1 as evict.
    check "m1" notin rm.channels[testChannel].messageHistory
    check "m1" in rm.channels[testChannel].pendingHistoryEvicts
    check "m1" notin rm.channels[testChannel].pendingHistoryAppends

    # SDS-R-style re-delivery of m1. With latest-wins, this MUST cancel
    # the pending evict and re-queue the append.
    check (await rm.addToHistory(mkMsg("m1", 4), testChannel)).isOk()
    check "m1" in rm.channels[testChannel].messageHistory
    check "m1" notin rm.channels[testChannel].pendingHistoryEvicts
    check "m1" in rm.channels[testChannel].pendingHistoryAppends

    # Recover and flush. m1 must land on disk.
    store.failingOps.excl("updateHistory")
    await rm.tryUpdateHistory(testChannel)
    check "m1" in store.log[testChannel]

  asyncTest "pending queue survives idle ops (flush on next op without history changes)":
    # Even if the next op makes no history changes of its own, it must
    # still flush the pending queue at op end — otherwise a failed write
    # could sit indefinitely if the application only ever does
    # mark-deps-met-style ops after a failure.
    let store = newInMemoryStore()
    let rm = newReliabilityManager(
        participantId = "alice", persistence = newInMemoryPersistence(store)
      )
      .get()
    check (await rm.ensureChannel(testChannel)).isOk()

    # Stage a pending entry by failing one send.
    store.failingOps.incl("updateHistory")
    discard await rm.wrapOutgoingMessage(@[byte(1)], "m1", testChannel)
    check rm.channels[testChannel].pendingHistoryAppends.len == 1

    # Now clear the failure and drive a markDependenciesMet on a no-op
    # input — it has no history changes of its own but its op-end flush
    # must still retry the queue.
    store.failingOps.excl("updateHistory")
    check (await rm.markDependenciesMet(@["nonexistent"], testChannel)).isOk()
    check rm.channels[testChannel].pendingHistoryAppends.len == 0
    check "m1" in store.log[testChannel]

  asyncTest "dropChannel failure during removeChannel surfaces as rePersistenceError":
    # Durability is the semantic intent of removeChannel — the caller
    # asked us to confirm a disk wipe. We cannot silently lie. So this op
    # DOES propagate err on failure (PLAN §8).
    let store = newInMemoryStore()
    let rm = newReliabilityManager(
        participantId = "alice", persistence = newInMemoryPersistence(store)
      )
      .get()
    check (await rm.ensureChannel(testChannel)).isOk()
    store.failingOps.incl("dropChannel")
    let res = await rm.removeChannel(testChannel)
    check res.isErr()
    check res.error == ReliabilityError.rePersistenceError

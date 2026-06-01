## Round-trip tests for the snapshot persistence codec.
## Each `encode` → `decode` cycle must preserve every field exactly.

import std/[times, sets, unittest]
import results
import ../sds/snapshot_codec
import
  ../sds/types/[
    sds_message, sds_message_id, history_entry, unacknowledged_message,
    incoming_message, repair_entry,
  ]

converter toParticipantID(s: string): SdsParticipantID =
  s.SdsParticipantID

proc mkMsg(id: string, ts: int64 = 1, content: seq[byte] = @[]): SdsMessage =
  SdsMessage.init(
    messageId = id,
    lamportTimestamp = ts,
    causalHistory = @[],
    channelId = "chan",
    content = content,
    bloomFilter = @[],
    senderId = "alice",
    repairRequest = @[],
  )

proc mkHistEntry(id: string): HistoryEntry =
  HistoryEntry.init(messageId = id, senderId = "alice")

suite "snapshot codec — ChannelMeta":
  test "empty meta round-trips":
    let m = ChannelMeta.init()
    let buf = encode(m).buffer
    let dec = ChannelMeta.decode(buf).get()
    check:
      dec.schemaVersion == ChannelMetaSchemaVersion
      dec.lamportTimestamp == 0
      dec.outgoingBuffer.len == 0
      dec.incomingBuffer.len == 0
      dec.outgoingRepairBuffer.len == 0
      dec.incomingRepairBuffer.len == 0

  test "meta with lamport and single outgoing entry":
    var m = ChannelMeta.init()
    m.lamportTimestamp = 42
    m.outgoingBuffer.add(
      UnacknowledgedMessage.init(
        message = mkMsg("m1", 42, @[1.byte, 2, 3]),
        sendTime = fromUnix(1_700_000_000),
        resendAttempts = 2,
      )
    )
    let buf = encode(m).buffer
    let dec = ChannelMeta.decode(buf).get()
    check:
      dec.lamportTimestamp == 42
      dec.outgoingBuffer.len == 1
      dec.outgoingBuffer[0].message.messageId == "m1"
      dec.outgoingBuffer[0].message.content == @[1.byte, 2, 3]
      dec.outgoingBuffer[0].resendAttempts == 2
      dec.outgoingBuffer[0].sendTime.toUnix == 1_700_000_000

  test "meta with incoming entry carrying missing deps":
    var m = ChannelMeta.init()
    var deps = initHashSet[SdsMessageID]()
    deps.incl("dep1")
    deps.incl("dep2")
    m.incomingBuffer.add(
      IncomingMessage.init(message = mkMsg("m2"), missingDeps = deps)
    )
    let buf = encode(m).buffer
    let dec = ChannelMeta.decode(buf).get()
    check:
      dec.incomingBuffer.len == 1
      dec.incomingBuffer[0].message.messageId == "m2"
      dec.incomingBuffer[0].missingDeps == deps

  test "meta with both repair buffers populated":
    var m = ChannelMeta.init()
    m.outgoingRepairBuffer.add(
      OutgoingRepairKV(
        messageId: "missing1",
        entry: OutgoingRepairEntry.init(
          outHistEntry = mkHistEntry("missing1"),
          minTimeRepairReq = fromUnix(1_700_000_100),
        ),
      )
    )
    m.incomingRepairBuffer.add(
      IncomingRepairKV(
        messageId: "requested1",
        entry: IncomingRepairEntry.init(
          inHistEntry = mkHistEntry("requested1"),
          cachedMessage = @[9.byte, 8, 7, 6],
          minTimeRepairResp = fromUnix(1_700_000_200),
        ),
      )
    )
    let buf = encode(m).buffer
    let dec = ChannelMeta.decode(buf).get()
    check:
      dec.outgoingRepairBuffer.len == 1
      dec.outgoingRepairBuffer[0].messageId == "missing1"
      dec.outgoingRepairBuffer[0].entry.minTimeRepairReq.toUnix ==
        1_700_000_100
      dec.incomingRepairBuffer.len == 1
      dec.incomingRepairBuffer[0].messageId == "requested1"
      dec.incomingRepairBuffer[0].entry.cachedMessage == @[9.byte, 8, 7, 6]
      dec.incomingRepairBuffer[0].entry.minTimeRepairResp.toUnix ==
        1_700_000_200

  test "fully-populated meta — multiple entries each buffer":
    var m = ChannelMeta.init()
    m.lamportTimestamp = 999
    for i in 0 ..< 5:
      m.outgoingBuffer.add(
        UnacknowledgedMessage.init(
          message = mkMsg("o" & $i, int64(i), @[byte(i)]),
          sendTime = fromUnix(1_700_000_000 + i.int64),
          resendAttempts = i,
        )
      )
    for i in 0 ..< 3:
      var deps = initHashSet[SdsMessageID]()
      deps.incl("dep" & $i)
      m.incomingBuffer.add(
        IncomingMessage.init(
          message = mkMsg("i" & $i, int64(100 + i)), missingDeps = deps
        )
      )
    for i in 0 ..< 4:
      m.outgoingRepairBuffer.add(
        OutgoingRepairKV(
          messageId: "or" & $i,
          entry: OutgoingRepairEntry.init(
            outHistEntry = mkHistEntry("or" & $i),
            minTimeRepairReq = fromUnix(1_700_000_300 + i.int64),
          ),
        )
      )
    for i in 0 ..< 2:
      m.incomingRepairBuffer.add(
        IncomingRepairKV(
          messageId: "ir" & $i,
          entry: IncomingRepairEntry.init(
            inHistEntry = mkHistEntry("ir" & $i),
            cachedMessage = @[byte(i), byte(i + 1)],
            minTimeRepairResp = fromUnix(1_700_000_400 + i.int64),
          ),
        )
      )
    let buf = encode(m).buffer
    let dec = ChannelMeta.decode(buf).get()
    check:
      dec.lamportTimestamp == 999
      dec.outgoingBuffer.len == 5
      dec.incomingBuffer.len == 3
      dec.outgoingRepairBuffer.len == 4
      dec.incomingRepairBuffer.len == 2
      dec.outgoingBuffer[4].message.messageId == "o4"
      dec.outgoingBuffer[4].resendAttempts == 4
      dec.outgoingRepairBuffer[3].messageId == "or3"
      dec.incomingRepairBuffer[1].entry.cachedMessage == @[1.byte, 2]

  test "decoder rejects unknown schemaVersion":
    var m = ChannelMeta.init()
    m.schemaVersion = 999'u32
    let buf = encode(m).buffer
    check ChannelMeta.decode(buf).isErr

suite "snapshot codec — ChannelData":
  test "empty channel data round-trips":
    let d = ChannelData.init()
    let buf = encode(d).buffer
    let dec = ChannelData.decode(buf).get()
    check:
      dec.meta.schemaVersion == ChannelMetaSchemaVersion
      dec.messageHistory.len == 0

  test "channel data with meta and history preserves order":
    var d = ChannelData.init()
    d.meta.lamportTimestamp = 17
    d.messageHistory.add(mkMsg("h1", 1))
    d.messageHistory.add(mkMsg("h2", 2))
    d.messageHistory.add(mkMsg("h3", 3))
    let buf = encode(d).buffer
    let dec = ChannelData.decode(buf).get()
    check:
      dec.meta.lamportTimestamp == 17
      dec.messageHistory.len == 3
      dec.messageHistory[0].messageId == "h1"
      dec.messageHistory[1].messageId == "h2"
      dec.messageHistory[2].messageId == "h3"

suite "snapshot codec — HistoryUpdate":
  test "empty update reports isEmpty (callers skip persistence)":
    # By contract (HistoryUpdate doc): when both append and evict are
    # empty, callers MUST skip the persistence call entirely. The codec
    # is not required to round-trip an empty update — minprotobuf's
    # finish() refuses an empty buffer, by design.
    let u = HistoryUpdate.init()
    check u.isEmpty

  test "append-only update":
    var u = HistoryUpdate.init()
    u.append.add(mkMsg("a1"))
    u.append.add(mkMsg("a2"))
    let buf = encode(u).buffer
    let dec = HistoryUpdate.decode(buf).get()
    check:
      dec.append.len == 2
      dec.append[0].messageId == "a1"
      dec.append[1].messageId == "a2"
      dec.evict.len == 0

  test "evict-only update":
    var u = HistoryUpdate.init()
    u.evict = @["e1", "e2", "e3"]
    let buf = encode(u).buffer
    let dec = HistoryUpdate.decode(buf).get()
    check:
      dec.append.len == 0
      dec.evict == @["e1", "e2", "e3"]

  test "mixed append + evict update":
    var u = HistoryUpdate.init()
    u.append.add(mkMsg("new"))
    u.evict = @["old1", "old2"]
    let buf = encode(u).buffer
    let dec = HistoryUpdate.decode(buf).get()
    check:
      dec.append.len == 1
      dec.append[0].messageId == "new"
      dec.evict == @["old1", "old2"]

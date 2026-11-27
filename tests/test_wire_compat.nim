## Verifies the SDS message wire stays backward-compatible with pre-SDS-R nodes
## (v0.2.x/v0.3.x): causalHistory is a repeated string of message IDs in field 3,
## and the richer per-entry metadata (senderId, retrievalHint) rides in the
## additive field 8, which older nodes skip.

import std/unittest
import protobuf_serialization
import protobuf_serialization/pkg/results
import ../sds/protobuf
import ../sds/types/[sds_message, history_entry, sds_message_id]

converter toParticipantID(s: string): SdsParticipantID =
  s.SdsParticipantID

func toStr(b: seq[byte]): string =
  var str = newString(b.len)
  if b.len > 0:
    copyMem(addr str[0], unsafeAddr b[0], b.len)
  return str

func toBytes(s: string): seq[byte] =
  var bytes = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr bytes[0], unsafeAddr s[0], s.len)
  return bytes

# How a pre-SDS-R node sees the message: field 3 is a repeated string of message
# IDs; it knows nothing of the additive field 8.
type OldSdsMessagePB {.proto3.} = object
  messageId {.fieldNumber: 1.}: Opt[seq[byte]]
  causalHistory {.fieldNumber: 3.}: seq[seq[byte]]
  channelId {.fieldNumber: 4.}: Opt[seq[byte]]
  content {.fieldNumber: 5.}: Opt[seq[byte]]

suite "SDS v0.4 wire backward-compatibility":
  test "old node reads causal history IDs from a v0.4-encoded message":
    let msg = SdsMessage.init(
      messageId = "0xdeadbeef",
      lamportTimestamp = 7,
      causalHistory = @[
        HistoryEntry.init("0xaaa", @[byte 1, 2, 3], "0xsender".SdsParticipantID),
        HistoryEntry.init("0xbbb"),
      ],
      channelId = "0xchannel",
      content = @[byte 9, 9, 9],
      bloomFilter = @[],
      senderId = "0xmsgsender".SdsParticipantID,
      repairRequest = @[],
    )

    let wire = serializeMessage(msg).get()

    # An old node recovers the EXACT message IDs from field 3 and never sees the
    # senderId/hint that ride in field 8.
    let old = Protobuf.decode(wire, OldSdsMessagePB)
    check old.causalHistory.len == 2
    check old.causalHistory[0].toStr == "0xaaa"
    check old.causalHistory[1].toStr == "0xbbb"
    check old.channelId.get(@[]).toStr == "0xchannel"
    check old.content.get(@[]) == @[byte 9, 9, 9]

  test "v0.4 round-trips message IDs, hints and senderIds":
    let msg = SdsMessage.init(
      messageId = "0xfeed",
      lamportTimestamp = 3,
      causalHistory = @[
        HistoryEntry.init("0xaaa", @[byte 1, 2, 3], "0xsender".SdsParticipantID),
        HistoryEntry.init("0xbbb"),
      ],
      channelId = "0xchannel",
      content = @[byte 1],
      bloomFilter = @[],
    )

    let decoded = deserializeMessage(serializeMessage(msg).get()).get()
    check decoded.causalHistory.len == 2
    check decoded.causalHistory[0].messageId == "0xaaa"
    check decoded.causalHistory[0].retrievalHint == @[byte 1, 2, 3]
    check decoded.causalHistory[0].senderId.string == "0xsender"
    check decoded.causalHistory[1].messageId == "0xbbb"
    check decoded.causalHistory[1].retrievalHint.len == 0
    check decoded.causalHistory[1].senderId.string.len == 0

  test "v0.4 decodes a legacy message (field 3 IDs only, no field 8)":
    # Build a message the way a pre-SDS-R node would: field 3 = bare ID strings.
    let legacy = OldSdsMessagePB(
      messageId: Opt.some("0xlegacy".toBytes),
      causalHistory: @["0xaaa".toBytes, "0xbbb".toBytes],
      channelId: Opt.some("0xchannel".toBytes),
      content: Opt.some(@[byte 5]),
    )
    let decoded = deserializeMessage(Protobuf.encode(legacy)).get()
    check decoded.causalHistory.len == 2
    check decoded.causalHistory[0].messageId == "0xaaa"
    check decoded.causalHistory[0].retrievalHint.len == 0
    check decoded.causalHistory[0].senderId.string.len == 0
    check decoded.causalHistory[1].messageId == "0xbbb"

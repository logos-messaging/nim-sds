## SDS network wire codec.
##
## Messages are described as annotated protobuf types and (de)serialised with
## `nim-protobuf-serialization`'s type-driven `Protobuf.encode/decode`. The
## domain types (`SdsMessage`, `HistoryEntry`) keep their distinct/`requiresInit`
## shape; small `*PB` mirrors carry the field annotations and a trivial
## conversion bridges the two. The mirror string-ish fields are `seq[byte]`
## (not `pstring`) so message/channel/sender ids stay opaque bytes — no UTF-8
## validation — and the distinct `SdsParticipantID` needs no special support.

{.push raises: [].}

import endians
import results
import protobuf_serialization
import ./types/[sds_message_id, history_entry, sds_message, reliability_error]
import ./bloom

# ---------------------------------------------------------------------------
# Wire types
# ---------------------------------------------------------------------------

type
  HistoryEntryPB* {.proto3.} = object
    messageId* {.fieldNumber: 1.}: seq[byte]
    retrievalHint* {.fieldNumber: 2.}: seq[byte]
    senderId* {.fieldNumber: 3.}: seq[byte]

  SdsMessagePB* {.proto3.} = object
    messageId* {.fieldNumber: 1.}: seq[byte]
    lamportTimestamp* {.fieldNumber: 2, pint.}: int64
    causalHistory* {.fieldNumber: 3.}: seq[HistoryEntryPB]
    channelId* {.fieldNumber: 4.}: seq[byte]
    content* {.fieldNumber: 5.}: seq[byte]
    bloomFilter* {.fieldNumber: 6.}: seq[byte]
    senderId* {.fieldNumber: 7.}: seq[byte]
    repairRequest* {.fieldNumber: 13.}: seq[HistoryEntryPB]

  BloomFilterPB {.proto3.} = object
    data {.fieldNumber: 1.}: seq[byte]
    capacity {.fieldNumber: 2, pint.}: uint64
    errorRate {.fieldNumber: 3, pint.}: uint64
    kHashes {.fieldNumber: 4, pint.}: uint64
    mBits {.fieldNumber: 5, pint.}: uint64

# ---------------------------------------------------------------------------
# string <-> bytes (opaque, no UTF-8 validation)
# ---------------------------------------------------------------------------

func toBytes(s: string): seq[byte] =
  var b = newSeq[byte](s.len)
  if s.len > 0:
    copyMem(addr b[0], unsafeAddr s[0], s.len)
  return b

func toStr(b: seq[byte]): string =
  var s = newString(b.len)
  if b.len > 0:
    copyMem(addr s[0], unsafeAddr b[0], b.len)
  return s

# ---------------------------------------------------------------------------
# Domain <-> wire conversion
# ---------------------------------------------------------------------------

func toPB*(e: HistoryEntry): HistoryEntryPB =
  return HistoryEntryPB(
    messageId: e.messageId.toBytes,
    retrievalHint: e.retrievalHint,
    senderId: e.senderId.string.toBytes,
  )

func fromPB*(e: HistoryEntryPB): HistoryEntry =
  return HistoryEntry(
    messageId: e.messageId.toStr,
    retrievalHint: e.retrievalHint,
    senderId: e.senderId.toStr.SdsParticipantID,
  )

func toPB*(m: SdsMessage): SdsMessagePB =
  var pb = SdsMessagePB(
    messageId: m.messageId.toBytes,
    lamportTimestamp: m.lamportTimestamp,
    channelId: m.channelId.toBytes,
    content: m.content,
    bloomFilter: m.bloomFilter,
    senderId: m.senderId.string.toBytes,
  )
  for e in m.causalHistory:
    pb.causalHistory.add(e.toPB)
  for e in m.repairRequest:
    pb.repairRequest.add(e.toPB)
  return pb

func fromPB*(pb: SdsMessagePB): SdsMessage =
  var causal: seq[HistoryEntry]
  for e in pb.causalHistory:
    causal.add(e.fromPB)
  var repair: seq[HistoryEntry]
  for e in pb.repairRequest:
    repair.add(e.fromPB)
  return SdsMessage.init(
    messageId = pb.messageId.toStr,
    lamportTimestamp = pb.lamportTimestamp,
    causalHistory = causal,
    channelId = pb.channelId.toStr,
    content = pb.content,
    bloomFilter = pb.bloomFilter,
    senderId = pb.senderId.toStr.SdsParticipantID,
    repairRequest = repair,
  )

# ---------------------------------------------------------------------------
# Message (de)serialisation
# ---------------------------------------------------------------------------

proc serializeMessage*(msg: SdsMessage): Result[seq[byte], ReliabilityError] =
  try:
    return ok(Protobuf.encode(msg.toPB))
  except CatchableError:
    return err(ReliabilityError.reSerializationError)

proc deserializeMessage*(data: seq[byte]): Result[SdsMessage, ReliabilityError] =
  try:
    return ok(Protobuf.decode(data, SdsMessagePB).fromPB)
  except CatchableError:
    return err(ReliabilityError.reDeserializationError)

proc extractChannelId*(data: seq[byte]): Result[SdsChannelID, ReliabilityError] =
  ## Channel ID without retaining the rest of the decoded message.
  try:
    return ok(Protobuf.decode(data, SdsMessagePB).channelId.toStr)
  except CatchableError:
    return err(ReliabilityError.reDeserializationError)

# Single `HistoryEntry` (de)serialisation, used by the snapshot codec for the
# repair-buffer entries it embeds. Kept here so all `Protobuf.decode` calls live
# in this module.

proc serializeHistoryEntry*(e: HistoryEntry): Result[seq[byte], ReliabilityError] =
  try:
    return ok(Protobuf.encode(e.toPB))
  except CatchableError:
    return err(ReliabilityError.reSerializationError)

proc deserializeHistoryEntry*(data: seq[byte]): Result[HistoryEntry, ReliabilityError] =
  try:
    return ok(Protobuf.decode(data, HistoryEntryPB).fromPB)
  except CatchableError:
    return err(ReliabilityError.reDeserializationError)

# ---------------------------------------------------------------------------
# Bloom filter (de)serialisation
# ---------------------------------------------------------------------------

proc serializeBloomFilter*(filter: BloomFilter): Result[seq[byte], ReliabilityError] =
  try:
    var bytes = newSeq[byte](filter.intArray.len * sizeof(int))
    for i, val in filter.intArray:
      var leVal: int
      littleEndian64(addr leVal, unsafeAddr val)
      copyMem(addr bytes[i * sizeof(int)], addr leVal, sizeof(int))

    let pb = BloomFilterPB(
      data: bytes,
      capacity: uint64(filter.capacity),
      errorRate: uint64(filter.errorRate * 1_000_000),
      kHashes: uint64(filter.kHashes),
      mBits: uint64(filter.mBits),
    )
    return ok(Protobuf.encode(pb))
  except CatchableError:
    return err(ReliabilityError.reSerializationError)

proc deserializeBloomFilter*(data: seq[byte]): Result[BloomFilter, ReliabilityError] =
  if data.len == 0:
    return err(ReliabilityError.reDeserializationError)
  try:
    let pb = Protobuf.decode(data, BloomFilterPB)
    var intArray = newSeq[int](pb.data.len div sizeof(int))
    for i in 0 ..< intArray.len:
      var leVal: int
      copyMem(addr leVal, unsafeAddr pb.data[i * sizeof(int)], sizeof(int))
      littleEndian64(addr intArray[i], addr leVal)

    return ok(
      BloomFilter.init(
        capacity = int(pb.capacity),
        errorRate = float(pb.errorRate) / 1_000_000,
        kHashes = int(pb.kHashes),
        mBits = int(pb.mBits),
        intArray = intArray,
      )
    )
  except CatchableError:
    return err(ReliabilityError.reDeserializationError)

{.pop.}

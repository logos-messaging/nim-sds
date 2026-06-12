## SDS network wire codec.
##
## Messages are described as annotated protobuf types and (de)serialised with
## `nim-protobuf-serialization`'s type-driven `Protobuf.encode/decode`. The
## domain types (`SdsMessage`, `HistoryEntry`) keep their distinct/`requiresInit`
## shape; small `*PB` mirrors carry the field annotations and a trivial
## conversion bridges the two. The mirror string-ish fields are `seq[byte]`
## (not `pstring`) so message/channel/sender ids stay opaque bytes — no UTF-8
## validation — and the distinct `SdsParticipantID` needs no special support.
##
## Singular fields use the proto3 `optional` label (`Opt[T]`), which is the
## recommended form for forward-compatibility; presence is exposed but the
## actual validity of mandatory identifiers is checked at the application layer
## after decoding (proto3 has no `required`).

{.push raises: [].}

import endians
import protobuf_serialization
import protobuf_serialization/pkg/results
import ./types/[sds_message_id, history_entry, sds_message, reliability_error]
import ./bloom

# ---------------------------------------------------------------------------
# Wire types
# ---------------------------------------------------------------------------

type
  HistoryEntryPB* {.proto3.} = object
    messageId* {.fieldNumber: 1.}: Opt[seq[byte]]
    retrievalHint* {.fieldNumber: 2.}: Opt[seq[byte]]
    senderId* {.fieldNumber: 3.}: Opt[seq[byte]]

  SdsMessagePB* {.proto3.} = object
    messageId* {.fieldNumber: 1.}: Opt[seq[byte]]
    lamportTimestamp* {.fieldNumber: 2, pint.}: Opt[int64]
    causalHistory* {.fieldNumber: 3.}: seq[HistoryEntryPB]
    channelId* {.fieldNumber: 4.}: Opt[seq[byte]]
    content* {.fieldNumber: 5.}: Opt[seq[byte]]
    bloomFilter* {.fieldNumber: 6.}: Opt[seq[byte]]
    senderId* {.fieldNumber: 7.}: Opt[seq[byte]]
    repairRequest* {.fieldNumber: 13.}: seq[HistoryEntryPB]

  BloomFilterPB {.proto3.} = object
    data {.fieldNumber: 1.}: Opt[seq[byte]]
    capacity {.fieldNumber: 2, pint.}: Opt[uint64]
    errorRate {.fieldNumber: 3, pint.}: Opt[uint64]
    kHashes {.fieldNumber: 4, pint.}: Opt[uint64]
    mBits {.fieldNumber: 5, pint.}: Opt[uint64]

# ---------------------------------------------------------------------------
# string <-> bytes (opaque, no UTF-8 validation) and optional-bytes helper
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

func optBytes(b: seq[byte]): Opt[seq[byte]] =
  ## Present only when non-empty, so empty optionals stay off the wire.
  if b.len > 0:
    return Opt.some(b)
  return Opt.none(seq[byte])

# ---------------------------------------------------------------------------
# Domain <-> wire conversion
# ---------------------------------------------------------------------------

func toPB*(e: HistoryEntry): HistoryEntryPB =
  return HistoryEntryPB(
    messageId: optBytes(e.messageId.toBytes),
    retrievalHint: optBytes(e.retrievalHint),
    senderId: optBytes(e.senderId.string.toBytes),
  )

func fromPB*(e: HistoryEntryPB): HistoryEntry =
  return HistoryEntry(
    messageId: e.messageId.valueOr(@[]).toStr,
    retrievalHint: e.retrievalHint.valueOr(@[]),
    senderId: e.senderId.valueOr(@[]).toStr.SdsParticipantID,
  )

func toPB*(m: SdsMessage): SdsMessagePB =
  var pb = SdsMessagePB(
    messageId: optBytes(m.messageId.toBytes),
    lamportTimestamp: Opt.some(m.lamportTimestamp),
    channelId: optBytes(m.channelId.toBytes),
    content: optBytes(m.content),
    bloomFilter: optBytes(m.bloomFilter),
    senderId: optBytes(m.senderId.string.toBytes),
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
    messageId = pb.messageId.valueOr(@[]).toStr,
    lamportTimestamp = pb.lamportTimestamp.valueOr(0'i64),
    causalHistory = causal,
    channelId = pb.channelId.valueOr(@[]).toStr,
    content = pb.content.valueOr(@[]),
    bloomFilter = pb.bloomFilter.valueOr(@[]),
    senderId = pb.senderId.valueOr(@[]).toStr.SdsParticipantID,
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
  ## proto3 has no required fields, so the mandatory identifiers are validated
  ## by hand after decoding. `content`/`bloomFilter`/`lamportTimestamp` may
  ## legitimately be empty/zero (e.g. periodic sync messages).
  try:
    let msg = Protobuf.decode(data, SdsMessagePB).fromPB
    if msg.messageId.len == 0 or msg.channelId.len == 0:
      return err(ReliabilityError.reDeserializationError)
    for e in msg.causalHistory:
      if e.messageId.len == 0:
        return err(ReliabilityError.reDeserializationError)
    for e in msg.repairRequest:
      if e.messageId.len == 0:
        return err(ReliabilityError.reDeserializationError)
    return ok(msg)
  except CatchableError:
    return err(ReliabilityError.reDeserializationError)

proc extractChannelId*(data: seq[byte]): Result[SdsChannelID, ReliabilityError] =
  ## Channel ID without retaining the rest of the decoded message.
  try:
    return ok(Protobuf.decode(data, SdsMessagePB).channelId.valueOr(@[]).toStr)
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
      data: optBytes(bytes),
      capacity: Opt.some(uint64(filter.capacity)),
      errorRate: Opt.some(uint64(filter.errorRate * 1_000_000)),
      kHashes: Opt.some(uint64(filter.kHashes)),
      mBits: Opt.some(uint64(filter.mBits)),
    )
    return ok(Protobuf.encode(pb))
  except CatchableError:
    return err(ReliabilityError.reSerializationError)

proc deserializeBloomFilter*(data: seq[byte]): Result[BloomFilter, ReliabilityError] =
  if data.len == 0:
    return err(ReliabilityError.reDeserializationError)
  try:
    let pb = Protobuf.decode(data, BloomFilterPB)
    let rawData = pb.data.valueOr(@[])
    var intArray = newSeq[int](rawData.len div sizeof(int))
    for i in 0 ..< intArray.len:
      var leVal: int
      copyMem(addr leVal, unsafeAddr rawData[i * sizeof(int)], sizeof(int))
      littleEndian64(addr intArray[i], addr leVal)

    return ok(
      BloomFilter.init(
        capacity = int(pb.capacity.valueOr(0'u64)),
        errorRate = float(pb.errorRate.valueOr(0'u64)) / 1_000_000,
        kHashes = int(pb.kHashes.valueOr(0'u64)),
        mBits = int(pb.mBits.valueOr(0'u64)),
        intArray = intArray,
      )
    )
  except CatchableError:
    return err(ReliabilityError.reDeserializationError)

{.pop.}

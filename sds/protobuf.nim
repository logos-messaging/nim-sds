import libp2p/protobuf/minprotobuf
import endians
import ./types/[sds_message_id, history_entry, sds_message, reliability_error]
import ./protobufutil
import ./bloom
import ./sds_utils

proc encodeHistoryEntry*(entry: HistoryEntry): ProtoBuffer =
  var entryPb = initProtoBuffer()
  entryPb.write(1, entry.messageId)
  if entry.retrievalHint.len > 0:
    entryPb.write(2, entry.retrievalHint)
  if entry.senderId.len > 0:
    entryPb.write(3, entry.senderId)
  entryPb.finish()
  entryPb

proc decodeHistoryEntry*(entryPb: ProtoBuffer): ProtobufResult[HistoryEntry] =
  var entry = HistoryEntry.init("")
  if not ?entryPb.getField(1, entry.messageId):
    return err(ProtobufError.missingRequiredField("HistoryEntry.messageId"))
  discard entryPb.getField(2, entry.retrievalHint)
  discard entryPb.getField(3, entry.senderId)
  ok(entry)

proc encode*(msg: SdsMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.messageId)
  pb.write(2, uint64(msg.lamportTimestamp))

  for entry in msg.causalHistory:
    let entryPb = encodeHistoryEntry(entry)
    pb.write(3, entryPb.buffer)

  pb.write(4, msg.channelId)
  pb.write(5, msg.content)
  pb.write(6, msg.bloomFilter)

  if msg.senderId.len > 0:
    pb.write(7, msg.senderId)

  for entry in msg.repairRequest:
    let entryPb = encodeHistoryEntry(entry)
    pb.write(13, entryPb.buffer)

  pb.finish()

  return pb

proc decode*(T: type SdsMessage, buffer: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buffer)
  var msg = SdsMessage.init("", 0, @[], "", @[], @[])

  if not ?pb.getField(1, msg.messageId):
    return err(ProtobufError.missingRequiredField("messageId"))

  var timestamp: uint64
  if not ?pb.getField(2, timestamp):
    return err(ProtobufError.missingRequiredField("lamportTimestamp"))
  msg.lamportTimestamp = int64(timestamp)

  # Handle both old and new causal history formats
  var historyBuffers: seq[seq[byte]]
  if pb.getRepeatedField(3, historyBuffers).isOk():
    # New format: repeated HistoryEntry
    for histBuffer in historyBuffers:
      let entryPb = initProtoBuffer(histBuffer)
      let entry = ?decodeHistoryEntry(entryPb)
      msg.causalHistory.add(entry)
  else:
    # Try old format: repeated string
    var causalHistory: seq[SdsMessageID]
    let histResult = pb.getRepeatedField(3, causalHistory)
    if histResult.isOk():
      msg.causalHistory = toCausalHistory(causalHistory)

  if not ?pb.getField(4, msg.channelId):
    return err(ProtobufError.missingRequiredField("channelId"))

  if not ?pb.getField(5, msg.content):
    return err(ProtobufError.missingRequiredField("content"))

  if not ?pb.getField(6, msg.bloomFilter):
    msg.bloomFilter = @[] # Empty if not present

  # SDS-R: decode senderId (field 7, optional)
  discard pb.getField(7, msg.senderId)

  # SDS-R: decode repair request (field 13, optional)
  var repairBuffers: seq[seq[byte]]
  if pb.getRepeatedField(13, repairBuffers).isOk():
    for repairBuffer in repairBuffers:
      let entryPb = initProtoBuffer(repairBuffer)
      let entry = ?decodeHistoryEntry(entryPb)
      msg.repairRequest.add(entry)

  return ok(msg)

proc extractChannelId*(data: seq[byte]): Result[SdsChannelID, ReliabilityError] =
  ## For extraction of channel ID without full message deserialization
  try:
    let pb = initProtoBuffer(data)
    var channelId: SdsChannelID
    let fieldOk = pb.getField(4, channelId).valueOr:
      return err(ReliabilityError.reDeserializationError)
    if not fieldOk:
      return err(ReliabilityError.reDeserializationError)
    return ok(channelId)
  except:
    return err(ReliabilityError.reDeserializationError)

proc serializeMessage*(msg: SdsMessage): Result[seq[byte], ReliabilityError] =
  let pb = encode(msg)
  return ok(pb.buffer)

proc deserializeMessage*(data: seq[byte]): Result[SdsMessage, ReliabilityError] =
  let msg = SdsMessage.decode(data).valueOr:
    return err(ReliabilityError.reDeserializationError)
  return ok(msg)

proc serializeBloomFilter*(filter: BloomFilter): Result[seq[byte], ReliabilityError] =
  var pb = initProtoBuffer()

  try:
    var bytes = newSeq[byte](filter.intArray.len * sizeof(int))
    for i, val in filter.intArray:
      var leVal: int
      littleEndian64(addr leVal, unsafeAddr val)
      let start = i * sizeof(int)
      copyMem(addr bytes[start], addr leVal, sizeof(int))

    pb.write(1, bytes)
    pb.write(2, uint64(filter.capacity))
    pb.write(3, uint64(filter.errorRate * 1_000_000))
    pb.write(4, uint64(filter.kHashes))
    pb.write(5, uint64(filter.mBits))
  except:
    return err(ReliabilityError.reSerializationError)

  pb.finish()
  return ok(pb.buffer)

proc deserializeBloomFilter*(data: seq[byte]): Result[BloomFilter, ReliabilityError] =
  if data.len == 0:
    return err(ReliabilityError.reDeserializationError)

  let pb = initProtoBuffer(data)
  var bytes: seq[byte]
  var cap, errRate, kHashes, mBits: uint64

  try:
    let
      field1_Ok = pb.getField(1, bytes).valueOr:
        return err(ReliabilityError.reDeserializationError)
      field2_Ok = pb.getField(2, cap).valueOr:
        return err(ReliabilityError.reDeserializationError)
      field3_Ok = pb.getField(3, errRate).valueOr:
        return err(ReliabilityError.reDeserializationError)
      field4_Ok = pb.getField(4, kHashes).valueOr:
        return err(ReliabilityError.reDeserializationError)
      field5_Ok = pb.getField(5, mBits).valueOr:
        return err(ReliabilityError.reDeserializationError)

    if not field1_Ok or not field2_Ok or not field3_Ok or not field4_Ok or not field5_Ok:
      return err(ReliabilityError.reDeserializationError)

    var intArray = newSeq[int](bytes.len div sizeof(int))
    for i in 0 ..< intArray.len:
      var leVal: int
      let start = i * sizeof(int)
      copyMem(addr leVal, unsafeAddr bytes[start], sizeof(int))
      littleEndian64(addr intArray[i], addr leVal)

    return ok(
      BloomFilter.init(
        capacity = int(cap),
        errorRate = float(errRate) / 1_000_000,
        kHashes = int(kHashes),
        mBits = int(mBits),
        intArray = intArray,
      )
    )
  except:
    return err(ReliabilityError.reDeserializationError)

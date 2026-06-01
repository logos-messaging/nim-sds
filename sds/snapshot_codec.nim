## Storage encoding for the snapshot persistence types.
##
## This is the codec nim-sds runs on its side of the persistence boundary
## to turn a `ChannelMeta` (or `ChannelData`, or `HistoryUpdate`) into the
## opaque `seq[byte]` blob the KV persistence backend stores. The KV
## backend treats the blob as fully opaque. See PLAN_SNAPSHOT_PERSISTENCE.md
## §1.5 for why this codec exists at all and §6 for the choice of protobuf.
##
## This is NOT the SDS network wire format — that lives in `sds/protobuf.nim`
## and is unchanged. Encoders for `SdsMessage` and `HistoryEntry` are reused
## from there to avoid maintaining two codecs for the same shape.

{.push raises: [].}

import std/[sets, times]
import libp2p/protobuf/minprotobuf
import ./types/[
  channel_meta, history_update, sds_message, sds_message_id, history_entry,
  unacknowledged_message, incoming_message, repair_entry, reliability_error,
]
import ./protobufutil
import ./protobuf as wire

export channel_meta, history_update

# ---------------------------------------------------------------------------
# Time <-> int64 unix milliseconds
# ---------------------------------------------------------------------------
# The protocol uses `getTime()` (wall clock). For wire stability we encode
# as unix milliseconds in int64 (zigzag not needed — pre-1970 values do not
# occur in practice). Sub-millisecond precision is intentionally dropped:
# the protocol's repair backoff windows are seconds-scale.

proc toUnixMs(t: Time): int64 =
  t.toUnix * 1000'i64 + int64(t.nanosecond div 1_000_000)

proc fromUnixMs(ms: int64): Time =
  let secs = ms div 1000
  let nanos = (ms mod 1000).int * 1_000_000
  initTime(secs, nanos)

# ---------------------------------------------------------------------------
# UnacknowledgedMessage
# ---------------------------------------------------------------------------

proc encodeUnacked(u: UnacknowledgedMessage): ProtoBuffer =
  var pb = initProtoBuffer()
  let msgPb = wire.encode(u.message)
  pb.write(1, msgPb.buffer)
  pb.write(2, uint64(u.sendTime.toUnixMs))
  pb.write(3, uint32(u.resendAttempts))
  pb.finish()
  pb

proc decodeUnacked(buf: seq[byte]): ProtobufResult[UnacknowledgedMessage] =
  let pb = initProtoBuffer(buf)
  var msgBytes: seq[byte]
  if not ?pb.getField(1, msgBytes):
    return err(ProtobufError.missingRequiredField("UnacknowledgedMessage.message"))
  let msg = SdsMessage.decode(msgBytes).valueOr:
    return err(ProtobufError.missingRequiredField("UnacknowledgedMessage.message"))
  var sendMs: uint64
  if not ?pb.getField(2, sendMs):
    return err(ProtobufError.missingRequiredField("UnacknowledgedMessage.sendTime"))
  var attempts: uint32
  discard pb.getField(3, attempts)
  ok(
    UnacknowledgedMessage.init(
      message = msg,
      sendTime = fromUnixMs(int64(sendMs)),
      resendAttempts = int(attempts),
    )
  )

# ---------------------------------------------------------------------------
# IncomingMessage
# ---------------------------------------------------------------------------

proc encodeIncoming(m: IncomingMessage): ProtoBuffer =
  var pb = initProtoBuffer()
  let msgPb = wire.encode(m.message)
  pb.write(1, msgPb.buffer)
  for dep in m.missingDeps:
    pb.write(2, dep) # SdsMessageID is string
  pb.finish()
  pb

proc decodeIncoming(buf: seq[byte]): ProtobufResult[IncomingMessage] =
  let pb = initProtoBuffer(buf)
  var msgBytes: seq[byte]
  if not ?pb.getField(1, msgBytes):
    return err(ProtobufError.missingRequiredField("IncomingMessage.message"))
  let msg = SdsMessage.decode(msgBytes).valueOr:
    return err(ProtobufError.missingRequiredField("IncomingMessage.message"))
  var deps: seq[SdsMessageID]
  discard pb.getRepeatedField(2, deps)
  var depSet = initHashSet[SdsMessageID]()
  for d in deps:
    depSet.incl(d)
  ok(IncomingMessage.init(message = msg, missingDeps = depSet))

# ---------------------------------------------------------------------------
# OutgoingRepairEntry / OutgoingRepairKV
# ---------------------------------------------------------------------------

proc encodeOutRepairEntry(e: OutgoingRepairEntry): ProtoBuffer =
  var pb = initProtoBuffer()
  let histPb = wire.encodeHistoryEntry(e.outHistEntry)
  pb.write(1, histPb.buffer)
  pb.write(2, uint64(e.minTimeRepairReq.toUnixMs))
  pb.finish()
  pb

proc decodeOutRepairEntry(buf: seq[byte]): ProtobufResult[OutgoingRepairEntry] =
  let pb = initProtoBuffer(buf)
  var histBytes: seq[byte]
  if not ?pb.getField(1, histBytes):
    return err(ProtobufError.missingRequiredField("OutgoingRepairEntry.outHistEntry"))
  let histPb = initProtoBuffer(histBytes)
  let entry = ?wire.decodeHistoryEntry(histPb)
  var ms: uint64
  if not ?pb.getField(2, ms):
    return err(ProtobufError.missingRequiredField("OutgoingRepairEntry.minTimeRepairReq"))
  ok(
    OutgoingRepairEntry.init(
      outHistEntry = entry, minTimeRepairReq = fromUnixMs(int64(ms))
    )
  )

proc encodeOutRepairKV(kv: OutgoingRepairKV): ProtoBuffer =
  var pb = initProtoBuffer()
  pb.write(1, kv.messageId)
  let entryPb = encodeOutRepairEntry(kv.entry)
  pb.write(2, entryPb.buffer)
  pb.finish()
  pb

proc decodeOutRepairKV(buf: seq[byte]): ProtobufResult[OutgoingRepairKV] =
  let pb = initProtoBuffer(buf)
  var msgId: SdsMessageID
  if not ?pb.getField(1, msgId):
    return err(ProtobufError.missingRequiredField("OutgoingRepairKV.messageId"))
  var entryBytes: seq[byte]
  if not ?pb.getField(2, entryBytes):
    return err(ProtobufError.missingRequiredField("OutgoingRepairKV.entry"))
  let entry = ?decodeOutRepairEntry(entryBytes)
  ok(OutgoingRepairKV(messageId: msgId, entry: entry))

# ---------------------------------------------------------------------------
# IncomingRepairEntry / IncomingRepairKV
# ---------------------------------------------------------------------------

proc encodeInRepairEntry(e: IncomingRepairEntry): ProtoBuffer =
  var pb = initProtoBuffer()
  let histPb = wire.encodeHistoryEntry(e.inHistEntry)
  pb.write(1, histPb.buffer)
  pb.write(2, e.cachedMessage)
  pb.write(3, uint64(e.minTimeRepairResp.toUnixMs))
  pb.finish()
  pb

proc decodeInRepairEntry(buf: seq[byte]): ProtobufResult[IncomingRepairEntry] =
  let pb = initProtoBuffer(buf)
  var histBytes: seq[byte]
  if not ?pb.getField(1, histBytes):
    return err(ProtobufError.missingRequiredField("IncomingRepairEntry.inHistEntry"))
  let histPb = initProtoBuffer(histBytes)
  let entry = ?wire.decodeHistoryEntry(histPb)
  var cached: seq[byte]
  if not ?pb.getField(2, cached):
    return err(ProtobufError.missingRequiredField("IncomingRepairEntry.cachedMessage"))
  var ms: uint64
  if not ?pb.getField(3, ms):
    return err(ProtobufError.missingRequiredField("IncomingRepairEntry.minTimeRepairResp"))
  ok(
    IncomingRepairEntry.init(
      inHistEntry = entry,
      cachedMessage = cached,
      minTimeRepairResp = fromUnixMs(int64(ms)),
    )
  )

proc encodeInRepairKV(kv: IncomingRepairKV): ProtoBuffer =
  var pb = initProtoBuffer()
  pb.write(1, kv.messageId)
  let entryPb = encodeInRepairEntry(kv.entry)
  pb.write(2, entryPb.buffer)
  pb.finish()
  pb

proc decodeInRepairKV(buf: seq[byte]): ProtobufResult[IncomingRepairKV] =
  let pb = initProtoBuffer(buf)
  var msgId: SdsMessageID
  if not ?pb.getField(1, msgId):
    return err(ProtobufError.missingRequiredField("IncomingRepairKV.messageId"))
  var entryBytes: seq[byte]
  if not ?pb.getField(2, entryBytes):
    return err(ProtobufError.missingRequiredField("IncomingRepairKV.entry"))
  let entry = ?decodeInRepairEntry(entryBytes)
  ok(IncomingRepairKV(messageId: msgId, entry: entry))

# ---------------------------------------------------------------------------
# ChannelMeta (top-level snapshot)
# ---------------------------------------------------------------------------

proc encode*(meta: ChannelMeta): ProtoBuffer =
  var pb = initProtoBuffer()
  pb.write(1, meta.schemaVersion)
  pb.write(2, uint64(meta.lamportTimestamp))
  for u in meta.outgoingBuffer:
    let entryPb = encodeUnacked(u)
    pb.write(3, entryPb.buffer)
  for m in meta.incomingBuffer:
    let entryPb = encodeIncoming(m)
    pb.write(4, entryPb.buffer)
  for kv in meta.outgoingRepairBuffer:
    let entryPb = encodeOutRepairKV(kv)
    pb.write(5, entryPb.buffer)
  for kv in meta.incomingRepairBuffer:
    let entryPb = encodeInRepairKV(kv)
    pb.write(6, entryPb.buffer)
  pb.finish()
  pb

proc decode*(T: type ChannelMeta, buf: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buf)
  var meta = ChannelMeta.init()

  var ver: uint32
  if not ?pb.getField(1, ver):
    return err(ProtobufError.missingRequiredField("ChannelMeta.schemaVersion"))
  if ver != ChannelMetaSchemaVersion:
    # Per the contract: refuse loudly rather than silently truncating.
    return err(ProtobufError.missingRequiredField(
      "ChannelMeta.schemaVersion(unsupported)"
    ))
  meta.schemaVersion = ver

  var lts: uint64
  if not ?pb.getField(2, lts):
    return err(ProtobufError.missingRequiredField("ChannelMeta.lamportTimestamp"))
  meta.lamportTimestamp = int64(lts)

  var outBufs, inBufs, outRepBufs, inRepBufs: seq[seq[byte]]
  discard pb.getRepeatedField(3, outBufs)
  for b in outBufs:
    meta.outgoingBuffer.add(?decodeUnacked(b))
  discard pb.getRepeatedField(4, inBufs)
  for b in inBufs:
    meta.incomingBuffer.add(?decodeIncoming(b))
  discard pb.getRepeatedField(5, outRepBufs)
  for b in outRepBufs:
    meta.outgoingRepairBuffer.add(?decodeOutRepairKV(b))
  discard pb.getRepeatedField(6, inRepBufs)
  for b in inRepBufs:
    meta.incomingRepairBuffer.add(?decodeInRepairKV(b))
  ok(meta)

proc serialize*(meta: ChannelMeta): Result[seq[byte], ReliabilityError] =
  ok(encode(meta).buffer)

proc deserializeChannelMeta*(
    data: seq[byte]
): Result[ChannelMeta, ReliabilityError] =
  let m = ChannelMeta.decode(data).valueOr:
    return err(ReliabilityError.reDeserializationError)
  ok(m)

# ---------------------------------------------------------------------------
# ChannelData (bootstrap payload)
# ---------------------------------------------------------------------------

proc encode*(d: ChannelData): ProtoBuffer =
  var pb = initProtoBuffer()
  let metaPb = encode(d.meta)
  pb.write(1, metaPb.buffer)
  for m in d.messageHistory:
    let msgPb = wire.encode(m)
    pb.write(2, msgPb.buffer)
  pb.finish()
  pb

proc decode*(T: type ChannelData, buf: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buf)
  var d = ChannelData.init()
  var metaBytes: seq[byte]
  if not ?pb.getField(1, metaBytes):
    return err(ProtobufError.missingRequiredField("ChannelData.meta"))
  d.meta = ?ChannelMeta.decode(metaBytes)
  var histBufs: seq[seq[byte]]
  discard pb.getRepeatedField(2, histBufs)
  for b in histBufs:
    let m = SdsMessage.decode(b).valueOr:
      return err(ProtobufError.missingRequiredField("ChannelData.messageHistory[i]"))
    d.messageHistory.add(m)
  ok(d)

# ---------------------------------------------------------------------------
# HistoryUpdate
# ---------------------------------------------------------------------------

proc encode*(u: HistoryUpdate): ProtoBuffer =
  var pb = initProtoBuffer()
  for m in u.append:
    let msgPb = wire.encode(m)
    pb.write(1, msgPb.buffer)
  for id in u.evict:
    pb.write(2, id)
  pb.finish()
  pb

proc decode*(T: type HistoryUpdate, buf: seq[byte]): ProtobufResult[T] =
  let pb = initProtoBuffer(buf)
  var u = HistoryUpdate.init()
  var appBufs: seq[seq[byte]]
  discard pb.getRepeatedField(1, appBufs)
  for b in appBufs:
    let m = SdsMessage.decode(b).valueOr:
      return err(ProtobufError.missingRequiredField("HistoryUpdate.append[i]"))
    u.append.add(m)
  var ev: seq[SdsMessageID]
  discard pb.getRepeatedField(2, ev)
  u.evict = ev
  ok(u)

{.pop.}

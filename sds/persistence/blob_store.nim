## Persistence over opaque blobs, for backends that only store bytes.
##
## A `BlobStore` is four procs over `seq[byte]` (a key/value table, a file per
## channel, a database row, ...). `newBlobPersistence` supplies the SDS
## encoding on top of it and returns the `Persistence` that
## `newReliabilityManager` expects, so a Nim consumer does not have to touch
## the snapshot or wire codecs.
##
## Blob formats:
## - `saveChannelMeta`: the `ChannelMeta` snapshot (`snapshot_codec`).
## - `updateHistory`: JSON `{"append": [{"messageId", "lamportTimestamp",
##   "data": base64 of the SDS wire message}], "evict": [messageId]}`.
## - `loadChannel`: JSON `{"meta": base64 snapshot, "messageHistory": [base64
##   SDS wire message]}`; an empty blob means the channel is new.

import std/[base64, json, options]
import chronos, results
import stew/byteutils
import ../types/persistence
import ../protobuf as wire
import ../snapshot_codec

export persistence

type BlobStore* = object
  saveChannelMeta*: proc(
    channelId: SdsChannelID, blob: seq[byte]
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
  updateHistory*: proc(
    channelId: SdsChannelID, blob: seq[byte]
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
  loadChannel*: proc(channelId: SdsChannelID): Future[Result[seq[byte], string]] {.
    async: (raises: []), gcsafe
  .}
  dropChannel*: proc(channelId: SdsChannelID): Future[Result[void, string]] {.
    async: (raises: []), gcsafe
  .}

type HistoryEntryBlob = object
  messageId: string
  lamportTimestamp: int64
  data: string

type HistoryUpdateBlob = object
  append: seq[HistoryEntryBlob]
  evict: seq[string]

type ChannelDataBlob = object
  meta: Option[string]
  messageHistory: Option[seq[string]]

proc decodeChannel(blob: seq[byte]): Result[ChannelData, string] =
  var channel = ChannelData.init()
  if blob.len == 0:
    return ok(channel)
  try:
    let data = parseJson(string.fromBytes(blob)).to(ChannelDataBlob)
    if data.meta.isSome() and data.meta.get().len > 0:
      channel.meta = ChannelMeta.decode(base64.decode(data.meta.get()).toBytes()).valueOr:
        return err("failed to decode persisted SDS channel metadata: " & $error)
    if data.messageHistory.isSome():
      for encoded in data.messageHistory.get():
        let message = wire.deserializeMessage(base64.decode(encoded).toBytes()).valueOr:
          return err("failed to decode persisted SDS history message: " & $error)
        channel.messageHistory.add(message)
  except CatchableError as exc:
    return err("failed to load persisted SDS channel: " & exc.msg)
  return ok(channel)

proc newBlobPersistence*(store: BlobStore): Persistence =
  return Persistence(
    saveChannelMeta: proc(
        channelId: SdsChannelID, meta: ChannelMeta
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
      return await store.saveChannelMeta(channelId, encode(meta).buffer),
    updateHistory: proc(
        channelId: SdsChannelID, update: HistoryUpdate
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
      var appended = newSeqOfCap[HistoryEntryBlob](update.append.len)
      for message in update.append:
        let serialized = wire.serializeMessage(message).valueOr:
          return err("failed to serialize SDS history message: " & $error)
        appended.add(
          HistoryEntryBlob(
            messageId: message.messageId,
            lamportTimestamp: message.lamportTimestamp,
            data: base64.encode(serialized),
          )
        )
      let blob = HistoryUpdateBlob(append: appended, evict: update.evict)
      return await store.updateHistory(channelId, toBytes($(%blob))),
    loadChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[ChannelData, string]] {.async: (raises: []), gcsafe.} =
      let loaded = (await store.loadChannel(channelId)).valueOr:
        return err("could not load SDS channel: " & error)
      return decodeChannel(loaded),
    dropChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
      return await store.dropChannel(channelId),
  )

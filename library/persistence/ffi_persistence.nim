## Persistence for the C API: a `BlobStore` whose four operations are served
## by the single native callback registered with `sds_set_persistence_callback`.
##
## The callback runs synchronously on the worker thread that owns the context,
## so it must return quickly and must not call back into the SDS API.

import chronos, results
import stew/byteutils
import ffi
import sds/persistence/blob_store

# Frees memory allocated by native callbacks with malloc. Must match that
# allocator — Nim's deallocShared here corrupts Nim's own heap.
proc c_free*(p: pointer) {.importc: "free", header: "<stdlib.h>".}

type SdsPersistenceCallback* = proc(
  operation: cint,
  channelId: ptr byte,
  channelIdLen: csize_t,
  payload: ptr byte,
  payloadLen: csize_t,
  response: ptr cstring,
  responseLen: ptr csize_t,
  userData: pointer,
): cint {.cdecl, gcsafe, raises: [].}

type PersistenceOperation = enum
  SaveChannelMeta = 1
  UpdateHistory = 2
  LoadChannel = 3
  DropChannel = 4

# Per worker thread (one thread per context).
var persistenceCb {.threadvar.}: pointer
var persistenceUserData {.threadvar.}: pointer

proc setFfiPersistenceCallback*(callback: pointer, userData: pointer) =
  persistenceCb = callback
  persistenceUserData = if callback.isNil(): nil else: userData

proc invoke(
    operation: PersistenceOperation, channelId: string, payload: openArray[byte]
): Result[seq[byte], string] =
  if persistenceCb.isNil():
    return err("SDS persistence callback is not registered")

  var channelIdPtr: ptr byte
  if channelId.len > 0:
    channelIdPtr = cast[ptr byte](unsafeAddr channelId[0])
  var payloadPtr: ptr byte
  if payload.len > 0:
    payloadPtr = unsafeAddr payload[0]

  var response: cstring
  var responseLen: csize_t
  let ret = cast[SdsPersistenceCallback](persistenceCb)(
    cint(ord(operation)),
    channelIdPtr,
    csize_t(channelId.len),
    payloadPtr,
    csize_t(payload.len),
    addr response,
    addr responseLen,
    persistenceUserData,
  )
  var responseBytes = newSeq[byte](0)
  if not response.isNil():
    if responseLen > 0:
      responseBytes = newSeq[byte](int(responseLen))
      copyMem(addr responseBytes[0], response, int(responseLen))
    c_free(response)
  if ret != RET_OK:
    return err(
      if responseBytes.len == 0:
        "SDS persistence callback failed"
      else:
        string.fromBytes(responseBytes)
    )
  return ok(responseBytes)

proc newFfiBlobStore*(): BlobStore =
  return BlobStore(
    saveChannelMeta: proc(
        channelId: SdsChannelID, blob: seq[byte]
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
      invoke(PersistenceOperation.SaveChannelMeta, $channelId, blob).isOkOr:
        return err("could not save SDS channel meta: " & error)
      return ok(),
    updateHistory: proc(
        channelId: SdsChannelID, blob: seq[byte]
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
      invoke(PersistenceOperation.UpdateHistory, $channelId, blob).isOkOr:
        return err("could not update SDS channel history: " & error)
      return ok(),
    loadChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[seq[byte], string]] {.async: (raises: []), gcsafe.} =
      return invoke(PersistenceOperation.LoadChannel, $channelId, []),
    dropChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
      invoke(PersistenceOperation.DropChannel, $channelId, []).isOkOr:
        return err("could not drop SDS channel: " & error)
      return ok(),
  )

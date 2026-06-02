import std/[strutils, sequtils, json, base64, locks]
import ffi
import sds
import ./events/[
  json_message_ready_event, json_message_sent_event, json_missing_dependencies_event,
  json_periodic_sync_event, json_repair_ready_event,
]

# Emit the library bootstrap: the {.exported.}/{.callback.} pragmas, the
# `-fPIC`/soname linker flags, the `libsdsNimMain` import and the
# `initializeLibrary()` proc the exported entry points call on every hop.
declareLibraryBase("sds")

# C callback typedefs (mirrors libsds.h). `SdsCallBack` is structurally the
# nim-ffi `FFICallBack`; the alias keeps the exported signatures readable.
type SdsCallBack* = FFICallBack

type SdsRetrievalHintProvider* = proc(
  messageId: cstring, hint: ptr cstring, hintLen: ptr csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

# One pool per library type; the macros that would normally declare it
# (ffiCtor/ffiDtor) are not used here because we hand-write the entry points
# to preserve the exact C ABI, so we declare it explicitly.
var ReliabilityManagerFFIPool: FFIContextPool[ReliabilityManager]

# registerReqFFI inspects each request field's type via `$node`, which only
# handles plain identifiers — a bracketed `SharedSeq[byte]` makes it choke. The
# aliases give the generated request structs non-bracketed field types.
type
  SdsSharedBytes = SharedSeq[byte]
  SdsSharedCstrs = SharedSeq[cstring]

################################################################################
### Retrieval-hint provider registry
###
### The retrieval-hint provider is a synchronous request/response callback
### (the C side returns bytes inline), so it does not fit the fire-and-forget
### event model. nim-ffi's FFIContext has no slot for it, so we keep a small
### per-context registry here. A fixed array of plain (non-GC) records keeps
### the lookup callable from the {.gcsafe.} hint closure running on the FFI
### thread.

type RetrievalHintSlot = object
  ctx: pointer
  cb: pointer
  userData: pointer

var retrievalHintSlots: array[MaxFFIContexts, RetrievalHintSlot]
var retrievalHintsLock: Lock
retrievalHintsLock.initLock()

proc setRetrievalHint(ctx: pointer, cb: pointer, userData: pointer) =
  withLock retrievalHintsLock:
    var free = -1
    for i in 0 ..< MaxFFIContexts:
      if retrievalHintSlots[i].ctx == ctx:
        retrievalHintSlots[i] = RetrievalHintSlot(ctx: ctx, cb: cb, userData: userData)
        return
      if free < 0 and retrievalHintSlots[i].ctx.isNil:
        free = i
    if free >= 0:
      retrievalHintSlots[free] = RetrievalHintSlot(ctx: ctx, cb: cb, userData: userData)

proc getRetrievalHint(ctx: pointer): tuple[cb: pointer, userData: pointer] {.gcsafe.} =
  withLock retrievalHintsLock:
    for i in 0 ..< MaxFFIContexts:
      if retrievalHintSlots[i].ctx == ctx:
        return (retrievalHintSlots[i].cb, retrievalHintSlots[i].userData)
  return (nil, nil)

proc clearRetrievalHint(ctx: pointer) =
  withLock retrievalHintsLock:
    for i in 0 ..< MaxFFIContexts:
      if retrievalHintSlots[i].ctx == ctx:
        retrievalHintSlots[i] = RetrievalHintSlot()
        return

################################################################################
### Shared-memory copy helpers
###
### Request payloads carrying binary/pointer data must be deep-copied into
### shared memory on the caller thread, because the FFI thread acks receipt
### before it reads the payload — the caller may free its buffer in between.
### cstring fields are deep-copied by the generated `ffiNewReq`; raw byte and
### `char**` arrays are not, so we copy them here.

proc copyToSharedSeqByte(p: pointer, len: int): SharedSeq[byte] =
  if p.isNil or len <= 0:
    return (cast[ptr UncheckedArray[byte]](nil), 0)
  let data = allocShared(len)
  copyMem(data, p, len)
  return (cast[ptr UncheckedArray[byte]](data), len)

proc copyToSharedSeqCstr(p: pointer, count: int): SharedSeq[cstring] =
  if p.isNil or count <= 0:
    return (cast[ptr UncheckedArray[cstring]](nil), 0)
  let data = cast[ptr UncheckedArray[cstring]](allocShared(sizeof(cstring) * count))
  let src = cast[ptr UncheckedArray[cstring]](p)
  for i in 0 ..< count:
    data[i] = src[i].alloc()
  return (data, count)

proc freeSharedSeqCstr(s: var SharedSeq[cstring]) =
  if not s.data.isNil():
    for i in 0 ..< s.len:
      if not s.data[i].isNil:
        deallocShared(s.data[i])
    deallocShared(s.data)
  s.len = 0

################################################################################
### Event callbacks
###
### These build the AppCallbacks closures handed to the ReliabilityManager.
### They run on the FFI worker thread and forward JSON event payloads to the
### C callback registered via SdsSetEventCallback (stored on the context).

proc onMessageReady(ctx: ptr FFIContext[ReliabilityManager]): MessageReadyCallback =
  return proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
    callEventCallback(ctx, "onMessageReady"):
      $JsonMessageReadyEvent.new(messageId, channelId)

proc onMessageSent(ctx: ptr FFIContext[ReliabilityManager]): MessageSentCallback =
  return proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
    callEventCallback(ctx, "onMessageSent"):
      $JsonMessageSentEvent.new(messageId, channelId)

proc onMissingDependencies(
    ctx: ptr FFIContext[ReliabilityManager]
): MissingDependenciesCallback =
  return proc(
      messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.} =
    callEventCallback(ctx, "onMissingDependencies"):
      $JsonMissingDependenciesEvent.new(messageId, missingDeps, channelId)

proc onPeriodicSync(ctx: ptr FFIContext[ReliabilityManager]): PeriodicSyncCallback =
  return proc() {.gcsafe.} =
    callEventCallback(ctx, "onPeriodicSync"):
      $JsonPeriodicSyncEvent.new()

proc onRepairReady(ctx: ptr FFIContext[ReliabilityManager]): RepairReadyCallback =
  return proc(message: seq[byte], channelId: SdsChannelID) {.gcsafe.} =
    callEventCallback(ctx, "onRepairReady"):
      $JsonRepairReadyEvent.new(message, channelId)

proc onRetrievalHint(ctx: ptr FFIContext[ReliabilityManager]): RetrievalHintProvider =
  return proc(messageId: SdsMessageID): seq[byte] {.gcsafe.} =
    let (cb, userData) = getRetrievalHint(cast[pointer](ctx))
    if cb.isNil():
      return @[]

    var hint: cstring
    var hintLen: csize_t
    cast[SdsRetrievalHintProvider](cb)(
      messageId.cstring, addr hint, addr hintLen, userData
    )

    if not hint.isNil() and hintLen > 0:
      var hintBytes = newSeq[byte](hintLen)
      copyMem(addr hintBytes[0], hint, hintLen)
      deallocShared(hint)
      return hintBytes

    return @[]

################################################################################
### Request handlers (executed on the FFI worker thread)

registerReqFFI(SdsCreateRmReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(): Future[Result[string, string]] {.async.} =
    # TODO: thread `participantId` through SdsNewReliabilityManager FFI input
    # and remove this hardcoded "". Empty id silently disables SDS-R; this is
    # acceptable as a temporary FFI-only fallback until sds-go-bindings and
    # logos-delivery's C-side caller are updated to supply the identity.
    let rm = newReliabilityManager(participantId = "".SdsParticipantID).valueOr:
      error "Failed creating reliability manager", error = error
      return err("Failed creating reliability manager: " & $error)

    await rm.setCallbacks(
      onMessageReady(ctx), onMessageSent(ctx), onMissingDependencies(ctx),
      onPeriodicSync(ctx), onRetrievalHint(ctx), onRepairReady(ctx),
    )

    ctx.myLib[] = rm
    return ok("")

registerReqFFI(SdsResetRmReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(): Future[Result[string, string]] {.async.} =
    (await resetReliabilityManager(ctx.myLib[])).isOkOr:
      error "RESET_RELIABILITY_MANAGER failed", error = error
      return err("error processing RESET_RELIABILITY_MANAGER request: " & $error)
    return ok("")

registerReqFFI(SdsStartPeriodicTasksReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(): Future[Result[string, string]] {.async.} =
    ctx.myLib[].startPeriodicTasks()
    return ok("")

registerReqFFI(SdsWrapMessageReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(
      message: SdsSharedBytes, messageId: cstring, channelId: cstring
  ): Future[Result[string, string]] {.async.} =
    var msg = message
    defer:
      deallocSharedSeq(msg)

    let wrappedMessage = (
      await wrapOutgoingMessage(ctx.myLib[], message.toSeq(), $messageId, $channelId)
    ).valueOr:
      error "WRAP_MESSAGE failed", error = error
      return err("error processing WRAP_MESSAGE request: " & $error)

    # returns a comma-separated string of bytes
    return ok(wrappedMessage.mapIt($it).join(","))

registerReqFFI(SdsUnwrapMessageReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(message: SdsSharedBytes): Future[Result[string, string]] {.async.} =
    var msg = message
    defer:
      deallocSharedSeq(msg)

    let (unwrappedMessage, missingDeps, extractedChannelId) = (
      await unwrapReceivedMessage(ctx.myLib[], message.toSeq())
    ).valueOr:
      return err("error processing UNWRAP_MESSAGE request: " & $error)

    # return the result as a json string
    var node = newJObject()
    node["message"] = %*unwrappedMessage
    node["channelId"] = %*extractedChannelId
    var missingDepsNode = newJArray()
    for dep in missingDeps:
      var depNode = newJObject()
      depNode["messageId"] = %*dep.messageId
      depNode["retrievalHint"] = %*encode(dep.retrievalHint)
      missingDepsNode.add(depNode)
    node["missingDeps"] = missingDepsNode
    return ok($node)

registerReqFFI(SdsMarkDepsReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(
      messageIds: SdsSharedCstrs, channelId: cstring
  ): Future[Result[string, string]] {.async.} =
    var ids = messageIds
    defer:
      freeSharedSeqCstr(ids)

    let messageIdSeq = ids.toSeq().mapIt($it)
    (await markDependenciesMet(ctx.myLib[], messageIdSeq, $channelId)).isOkOr:
      error "MARK_DEPENDENCIES_MET failed", error = error
      return err("error processing MARK_DEPENDENCIES_MET request: " & $error)
    return ok("")

################################################################################
### Dispatch helper
###
### Sends a request to the FFI worker thread and returns RET_OK/RET_ERR,
### reporting any failure through the callback. The try/except keeps the
### exported entry points `raises: []` (sendRequestToFFIThread can raise),
### which `processReq` alone would not guarantee.

template dispatchReq(
    ctx: untyped, callback: FFICallBack, userData: pointer, reqExpr: untyped
) =
  let sendRes =
    try:
      ffi_context.sendRequestToFFIThread(ctx, reqExpr)
    except Exception as exc:
      Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
  if sendRes.isErr():
    let m = "libsds error: " & sendRes.error
    callback(RET_ERR, unsafeAddr m[0], cast[csize_t](m.len), userData)
    return RET_ERR
  return RET_OK

################################################################################
### Exported C entry points (called from the application thread)
###
### Signatures must match library/libsds.h exactly. Each one validates the
### context against the pool (rejecting nil/dangling pointers at the boundary),
### checks the callback, deep-copies any pointer payloads into shared memory,
### then dispatches a request to the FFI worker thread.

proc SdsNewReliabilityManager(
    callback: FFICallBack, userData: pointer
): pointer {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()

  if isNil(callback):
    echo "error: missing callback in SdsNewReliabilityManager"
    return nil

  let ctx = ReliabilityManagerFFIPool.createFFIContext().valueOr:
    let msg = "Error creating SDS FFI context: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return nil

  let sendRes =
    try:
      ffi_context.sendRequestToFFIThread(ctx, SdsCreateRmReq.ffiNewReq(callback, userData))
    except Exception as exc:
      Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
  if sendRes.isErr():
    let msg = "error creating reliability manager: " & sendRes.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    discard ReliabilityManagerFFIPool.destroyFFIContext(ctx)
    return nil

  return cast[pointer](ctx)

proc SdsSetEventCallback(
    ctx: ptr FFIContext[ReliabilityManager], callback: FFICallBack, userData: pointer
) {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    echo "error: invalid context in SdsSetEventCallback"
    return
  ctx[].callbackState.callback = cast[pointer](callback)
  ctx[].callbackState.userData = userData

proc SdsSetRetrievalHintProvider(
    ctx: ptr FFIContext[ReliabilityManager],
    callback: SdsRetrievalHintProvider,
    userData: pointer,
) {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    echo "error: invalid context in SdsSetRetrievalHintProvider"
    return
  setRetrievalHint(cast[pointer](ctx), cast[pointer](callback), userData)

proc SdsCleanupReliabilityManager(
    ctx: ptr FFIContext[ReliabilityManager], callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    return RET_ERR
  if isNil(callback):
    return RET_MISSING_CALLBACK

  clearRetrievalHint(cast[pointer](ctx))

  let res = ReliabilityManagerFFIPool.destroyFFIContext(ctx)
  if res.isErr():
    let msg = "error cleaning up reliability manager: " & res.error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  callback(RET_OK, nil, 0, userData)
  return RET_OK

proc SdsResetReliabilityManager(
    ctx: ptr FFIContext[ReliabilityManager], callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    return RET_ERR
  if isNil(callback):
    return RET_MISSING_CALLBACK
  dispatchReq(ctx, callback, userData, SdsResetRmReq.ffiNewReq(callback, userData))

proc SdsWrapOutgoingMessage(
    ctx: ptr FFIContext[ReliabilityManager],
    message: pointer,
    messageLen: csize_t,
    messageId: cstring,
    channelId: cstring,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    return RET_ERR
  if isNil(callback):
    return RET_MISSING_CALLBACK

  if message == nil and messageLen > 0:
    let msg = "libsds error: message pointer is NULL but length > 0"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  if messageId == nil:
    let msg = "libsds error: message ID pointer is NULL"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  if channelId == nil:
    let msg = "libsds error: channel ID pointer is NULL"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  if $channelId == "":
    let msg = "libsds error: channel ID is empty string"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  let sharedMsg = copyToSharedSeqByte(message, messageLen.int)
  dispatchReq(
    ctx, callback, userData,
    SdsWrapMessageReq.ffiNewReq(callback, userData, sharedMsg, messageId, channelId),
  )

proc SdsUnwrapReceivedMessage(
    ctx: ptr FFIContext[ReliabilityManager],
    message: pointer,
    messageLen: csize_t,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    return RET_ERR
  if isNil(callback):
    return RET_MISSING_CALLBACK

  if message == nil and messageLen > 0:
    let msg = "libsds error: message pointer is NULL but length > 0"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  let sharedMsg = copyToSharedSeqByte(message, messageLen.int)
  dispatchReq(ctx, callback, userData, SdsUnwrapMessageReq.ffiNewReq(callback, userData, sharedMsg))

proc SdsMarkDependenciesMet(
    ctx: ptr FFIContext[ReliabilityManager],
    messageIds: pointer,
    count: csize_t,
    channelId: cstring,
    callback: FFICallBack,
    userData: pointer,
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    return RET_ERR
  if isNil(callback):
    return RET_MISSING_CALLBACK

  if messageIds == nil and count > 0:
    let msg = "libsds error: MessageIDs pointer is NULL but count > 0"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  if channelId == nil:
    let msg = "libsds error: channel ID pointer is NULL"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  if $channelId == "":
    let msg = "libsds error: channel ID is empty string"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](msg.len), userData)
    return RET_ERR

  let sharedIds = copyToSharedSeqCstr(messageIds, count.int)
  dispatchReq(
    ctx, callback, userData,
    SdsMarkDepsReq.ffiNewReq(callback, userData, sharedIds, channelId),
  )

proc SdsStartPeriodicTasks(
    ctx: ptr FFIContext[ReliabilityManager], callback: FFICallBack, userData: pointer
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    return RET_ERR
  if isNil(callback):
    return RET_MISSING_CALLBACK
  dispatchReq(ctx, callback, userData, SdsStartPeriodicTasksReq.ffiNewReq(callback, userData))

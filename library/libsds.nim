## C-compatible FFI wrapper around the SDS ReliabilityManager.
##
## Built on the `nim-ffi` package's high-level macros: `declareLibrary` emits the
## bootstrap + `sds_set_event_callback`; `{.ffiCtor.}`/`{.ffi.}`/`{.ffiDtor.}`
## generate the C entry points, marshalling parameters and return values as JSON.
## Exported C names are snake_case (`sds_wrap_outgoing_message`, …); see
## `library/libsds.h`. The Go bindings (sds-go-bindings) must match this API.
##
## The one exception is `sds_set_retrieval_hint_provider`: it takes a C function
## pointer, which has no sensible JSON representation, so it is hand-written and
## dispatched to the worker thread to store the provider in a thread-local.

import std/[base64, json, sequtils]
import ffi
import sds
import ./events/[
  json_message_ready_event, json_message_sent_event, json_missing_dependencies_event,
  json_periodic_sync_event, json_repair_ready_event,
]

# Bootstrap (pragmas, linker flags, libsdsNimMain, initializeLibrary) plus the
# `sds_set_event_callback(ctx, callback, userData)` C export.
declareLibrary("sds", ReliabilityManager)

type SdsRetrievalHintProvider* = proc(
  messageId: cstring, hint: ptr cstring, hintLen: ptr csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

# The active retrieval-hint provider, stored per worker thread (one thread per
# context). Set by sds_set_retrieval_hint_provider via a dispatched request so
# the write lands on the worker thread, where the manager's hint closure reads
# it during message processing.
var sdsRetrievalHintCb {.threadvar.}: pointer
var sdsRetrievalHintUserData {.threadvar.}: pointer

################################################################################
### JSON-marshalled request/response types

type SdsConfig* {.ffi.} = object
  participantId: string ## empty disables SDS-R (see newReliabilityManager)

type SdsWrapRequest* {.ffi.} = object
  message: seq[byte]
  messageId: string
  channelId: string

type SdsWrapResponse* {.ffi.} = object
  message: seq[byte]

type SdsUnwrapRequest* {.ffi.} = object
  message: seq[byte]

type SdsMarkDependenciesRequest* {.ffi.} = object
  messageIds: seq[string]
  channelId: string

################################################################################
### Constructor — creates the FFI context and the ReliabilityManager.
###
### The AppCallbacks closures run on the worker thread and forward events to the
### C callback registered via sds_set_event_callback (dispatchFfiEvent reads the
### per-thread callback state, so no context handle is needed here).

proc sdsCreate*(
    config: SdsConfig
): Future[Result[ReliabilityManager, string]] {.ffiCtor.} =
  let rm = newReliabilityManager(participantId = config.participantId.SdsParticipantID).valueOr:
    error "Failed creating reliability manager", error = error
    return err("Failed creating reliability manager: " & $error)

  let messageReadyCb = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    dispatchFfiEvent("message_ready"):
      $JsonMessageReadyEvent.new(messageId, channelId)

  let messageSentCb = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    dispatchFfiEvent("message_sent"):
      $JsonMessageSentEvent.new(messageId, channelId)

  let missingDependenciesCb = proc(
      messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.} =
    dispatchFfiEvent("missing_dependencies"):
      $JsonMissingDependenciesEvent.new(messageId, missingDeps, channelId)

  let periodicSyncCb = proc() {.gcsafe.} =
    dispatchFfiEvent("periodic_sync"):
      $JsonPeriodicSyncEvent.new()

  let repairReadyCb = proc(message: seq[byte], channelId: SdsChannelID) {.gcsafe.} =
    dispatchFfiEvent("repair_ready"):
      $JsonRepairReadyEvent.new(message, channelId)

  let retrievalHintProvider = proc(messageId: SdsMessageID): seq[byte] {.gcsafe.} =
    if sdsRetrievalHintCb.isNil():
      return @[]
    var hint: cstring
    var hintLen: csize_t
    cast[SdsRetrievalHintProvider](sdsRetrievalHintCb)(
      messageId.cstring, addr hint, addr hintLen, sdsRetrievalHintUserData
    )
    if not hint.isNil() and hintLen > 0:
      var hintBytes = newSeq[byte](hintLen)
      copyMem(addr hintBytes[0], hint, hintLen)
      deallocShared(hint)
      return hintBytes
    return @[]

  await rm.setCallbacks(
    messageReadyCb, messageSentCb, missingDependenciesCb, periodicSyncCb,
    retrievalHintProvider, repairReadyCb,
  )

  return ok(rm)

################################################################################
### Async methods — each runs its body on the worker thread.

proc sdsWrapOutgoingMessage*(
    rm: ReliabilityManager, req: SdsWrapRequest
): Future[Result[SdsWrapResponse, string]] {.ffi.} =
  let wrapped = (
    await wrapOutgoingMessage(
      rm, req.message, req.messageId.SdsMessageID, req.channelId.SdsChannelID
    )
  ).valueOr:
    error "WRAP_MESSAGE failed", error = error
    return err("error processing wrap request: " & $error)
  return ok(SdsWrapResponse(message: wrapped))

proc sdsUnwrapReceivedMessage*(
    rm: ReliabilityManager, req: SdsUnwrapRequest
): Future[Result[string, string]] {.ffi.} =
  # The response carries nested objects (missingDeps) which the framework's
  # object serializer cannot emit, so the JSON is built by hand and returned as
  # a string. Shape matches the legacy unwrap response.
  let (unwrapped, missingDeps, channelId) = (
    await unwrapReceivedMessage(rm, req.message)
  ).valueOr:
    return err("error processing unwrap request: " & $error)

  var node = newJObject()
  node["message"] = %*unwrapped
  node["channelId"] = %*channelId
  var missingDepsNode = newJArray()
  for dep in missingDeps:
    var depNode = newJObject()
    depNode["messageId"] = %*dep.messageId
    depNode["retrievalHint"] = %*encode(dep.retrievalHint)
    missingDepsNode.add(depNode)
  node["missingDeps"] = missingDepsNode
  return ok($node)

proc sdsMarkDependenciesMet*(
    rm: ReliabilityManager, req: SdsMarkDependenciesRequest
): Future[Result[string, string]] {.ffi.} =
  let messageIds = req.messageIds.mapIt(it.SdsMessageID)
  (await markDependenciesMet(rm, messageIds, req.channelId.SdsChannelID)).isOkOr:
    error "MARK_DEPENDENCIES_MET failed", error = error
    return err("error processing mark-dependencies request: " & $error)
  return ok("")

proc sdsReset*(rm: ReliabilityManager): Future[Result[string, string]] {.ffi.} =
  (await resetReliabilityManager(rm)).isOkOr:
    error "RESET failed", error = error
    return err("error processing reset request: " & $error)
  return ok("")

proc sdsStartPeriodicTasks*(
    rm: ReliabilityManager
): Future[Result[string, string]] {.ffi.} =
  # The empty await forces the macro down its async path so the body runs on the
  # worker thread — startPeriodicTasks schedules futures on that thread's loop.
  await sleepAsync(chronos.milliseconds(0))
  rm.startPeriodicTasks()
  return ok("")

################################################################################
### Destructor — runs library cleanup then tears down the FFI context.

proc sdsDestroy*(rm: ReliabilityManager) {.ffiDtor.} =
  discard

################################################################################
### Retrieval-hint provider (hand-written: a C function pointer cannot be passed
### as JSON). The setter dispatches a request so the provider is stored in the
### worker thread's thread-local, where sdsCreate's hint closure reads it.

proc sdsNoopCallback(
    callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

registerReqFFI(SdsSetHintReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(cbPtr: pointer, udPtr: pointer): Future[Result[string, string]] {.async.} =
    sdsRetrievalHintCb = cbPtr
    sdsRetrievalHintUserData = udPtr
    return ok("")

proc sds_set_retrieval_hint_provider(
    ctx: ptr FFIContext[ReliabilityManager],
    callback: SdsRetrievalHintProvider,
    userData: pointer,
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  if not ReliabilityManagerFFIPool.isValidCtx(cast[pointer](ctx)):
    return RET_ERR

  let sendRes =
    try:
      ffi_context.sendRequestToFFIThread(
        ctx,
        SdsSetHintReq.ffiNewReq(
          sdsNoopCallback, nil, cast[pointer](callback), userData
        ),
      )
    except Exception as exc:
      Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
  if sendRes.isErr():
    return RET_ERR
  return RET_OK

# Emit binding metadata (no-op unless -d:ffiGenBindings). Must follow every
# {.ffi.}/{.ffiCtor.}/{.ffiDtor.} annotation.
genBindings()

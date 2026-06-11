## C-compatible FFI wrapper around the SDS ReliabilityManager.
##
## Built on nim-ffi (v0.2.0+): `declareLibrary` emits the bootstrap plus the
## event-listener ABI (`sds_add_event_listener` / `sds_remove_event_listener`);
## `{.ffiCtor.}`/`{.ffi.}`/`{.ffiDtor.}` generate the C entry points; and
## `{.ffiEvent.}` declares library-initiated events. Requests, responses and
## events are marshalled as CBOR (see library/libsds.h). Exported C names are
## snake_case. The Go bindings (sds-go-bindings) must match this API.
##
## The one hand-written export is `sds_set_retrieval_hint_provider`: it takes a
## C function pointer (no CBOR representation), so it dispatches a request that
## stores the provider in a worker-thread thread-local.

import std/[sequtils]
import ffi
import sds

# Bootstrap + sds_add_event_listener / sds_remove_event_listener.
declareLibrary("sds", ReliabilityManager)

type SdsRetrievalHintProvider* = proc(
  messageId: cstring, hint: ptr cstring, hintLen: ptr csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

# Active retrieval-hint provider, per worker thread (one thread per context).
# Set by sds_set_retrieval_hint_provider through a dispatched request so the
# write lands on the worker thread, where the manager's hint closure reads it.
var sdsRetrievalHintCb {.threadvar.}: pointer
var sdsRetrievalHintUserData {.threadvar.}: pointer

################################################################################
### CBOR-marshalled request/response types

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

type SdsMissingDep* {.ffi.} = object
  messageId: string
  retrievalHint: seq[byte]

type SdsUnwrapResponse* {.ffi.} = object
  message: seq[byte]
  channelId: string
  missingDeps: seq[SdsMissingDep]

type SdsMarkDependenciesRequest* {.ffi.} = object
  messageIds: seq[string]
  channelId: string

################################################################################
### Library-initiated events
###
### Each {.ffiEvent.} proc is an emitter: calling it from a worker-thread
### handler dispatches a CBOR EventEnvelope to every listener subscribed (via
### sds_add_event_listener) to the matching wire name.

type SdsMessageReadyPayload* {.ffi.} = object
  messageId: string
  channelId: string

type SdsMessageSentPayload* {.ffi.} = object
  messageId: string
  channelId: string

type SdsMissingDependenciesPayload* {.ffi.} = object
  messageId: string
  channelId: string
  missingDeps: seq[SdsMissingDep]

type SdsPeriodicSyncPayload* {.ffi.} = object
  placeholder: bool ## events need a payload type; periodic sync carries no data

type SdsRepairReadyPayload* {.ffi.} = object
  message: seq[byte]
  channelId: string

proc emitMessageReady*(p: SdsMessageReadyPayload) {.ffiEvent: "message_ready".}
proc emitMessageSent*(p: SdsMessageSentPayload) {.ffiEvent: "message_sent".}
proc emitMissingDependencies*(
  p: SdsMissingDependenciesPayload
) {.ffiEvent: "missing_dependencies".}
proc emitPeriodicSync*(p: SdsPeriodicSyncPayload) {.ffiEvent: "periodic_sync".}
proc emitRepairReady*(p: SdsRepairReadyPayload) {.ffiEvent: "repair_ready".}

################################################################################
### Constructor — creates the FFI context and the ReliabilityManager.
###
### The AppCallbacks closures run on the worker thread; they build typed
### payloads and fire the {.ffiEvent.} emitters, which reach the C listeners.

proc sdsCreate*(
    config: SdsConfig
): Future[Result[ReliabilityManager, string]] {.ffiCtor.} =
  let rm = newReliabilityManager(participantId = config.participantId.SdsParticipantID).valueOr:
    error "Failed creating reliability manager", error = error
    return err("Failed creating reliability manager: " & $error)

  let messageReadyCb = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    {.cast(gcsafe).}:
      emitMessageReady(
        SdsMessageReadyPayload(messageId: $messageId, channelId: $channelId)
      )

  let messageSentCb = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    {.cast(gcsafe).}:
      emitMessageSent(
        SdsMessageSentPayload(messageId: $messageId, channelId: $channelId)
      )

  let missingDependenciesCb = proc(
      messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.} =
    {.cast(gcsafe).}:
      let deps = missingDeps.mapIt(
        SdsMissingDep(messageId: $it.messageId, retrievalHint: it.retrievalHint)
      )
      emitMissingDependencies(
        SdsMissingDependenciesPayload(
          messageId: $messageId, channelId: $channelId, missingDeps: deps
        )
      )

  let periodicSyncCb = proc() {.gcsafe.} =
    {.cast(gcsafe).}:
      emitPeriodicSync(SdsPeriodicSyncPayload(placeholder: false))

  let repairReadyCb = proc(message: seq[byte], channelId: SdsChannelID) {.gcsafe.} =
    {.cast(gcsafe).}:
      emitRepairReady(SdsRepairReadyPayload(message: message, channelId: $channelId))

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
): Future[Result[SdsUnwrapResponse, string]] {.ffi.} =
  sdsdbg("libsds.sdsUnwrap: body entered (decode+dispatch OK) msgLen=" & $req.message.len)
  let (unwrapped, missingDeps, channelId) = (
    await unwrapReceivedMessage(rm, req.message)
  ).valueOr:
    return err("error processing unwrap request: " & $error)
  sdsdbg("libsds.sdsUnwrap: unwrapReceivedMessage returned missingDeps=" & $missingDeps.len)

  let deps = missingDeps.mapIt(
    SdsMissingDep(messageId: $it.messageId, retrievalHint: it.retrievalHint)
  )
  sdsdbg("libsds.sdsUnwrap: built response, encoding")
  return ok(
    SdsUnwrapResponse(message: unwrapped, channelId: $channelId, missingDeps: deps)
  )

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
### Retrieval-hint provider.
###
### The provider is a C function pointer, which has no CBOR representation, so
### it is passed as integer addresses. The body runs on the worker thread (the
### empty await forces the async path) and stores the pointers in the
### thread-local that sdsCreate's hint closure reads. The caller passes the
### function pointer and user-data as uint64 addresses.

type SdsHintProviderRequest* {.ffi.} = object
  callbackAddr: uint64
  userDataAddr: uint64

proc sdsSetRetrievalHintProvider*(
    rm: ReliabilityManager, req: SdsHintProviderRequest
): Future[Result[string, string]] {.ffi.} =
  discard rm
  await sleepAsync(chronos.milliseconds(0))
  sdsRetrievalHintCb = cast[pointer](req.callbackAddr)
  sdsRetrievalHintUserData = cast[pointer](req.userDataAddr)
  return ok("")

# Emit binding metadata (no-op unless -d:ffiGenBindings). Must follow every
# {.ffi.}/{.ffiCtor.}/{.ffiDtor.}/{.ffiEvent.} annotation.
genBindings()

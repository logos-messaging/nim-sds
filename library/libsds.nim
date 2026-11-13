## C-compatible FFI wrapper around the SDS ReliabilityManager.
##
## Built on the `nim-ffi` package's high-level macros: `declareLibrary` emits the
## bootstrap + `sds_set_event_callback`; `{.ffiCtor.}`/`{.ffi.}`/`{.ffiDtor.}`
## generate the C entry points, marshalling parameters and return values as JSON.
## Exported C names are snake_case (`sds_wrap_outgoing_message`, …); see
## `library/libsds.h`.
##
## The exceptions are `sds_set_retrieval_hint_provider` and
## `sds_set_persistence_callback`: they take C function pointers, which have no
## sensible JSON representation, so they are hand-written and dispatched to the
## worker thread.

when not compileOption("threads"):
  {.error: "libsds needs --threads:on".}

import std/[base64, json, options, times]
import ffi
import sds
import sds/types/persistence
import sds/protobuf as wire
import sds/snapshot_codec
import stew/byteutils
import ./json_responses
import
  ./events/[
    json_message_ready_event, json_message_sent_event, json_missing_dependencies_event,
    json_periodic_sync_event, json_repair_ready_event, json_message_expired_event,
  ]

# Frees memory allocated by native callbacks with malloc. Must match that
# allocator — Nim's deallocShared here corrupts Nim's own heap.
proc c_free(p: pointer) {.importc: "free", header: "<stdlib.h>".}

# Bootstrap (pragmas, linker flags, libsdsNimMain, initializeLibrary) plus the
# `sds_set_event_callback(ctx, callback, userData)` C export. It also declares
# the per-type `ReliabilityManagerFFIPool` used by the hand-written entry point
# below (the ffiCtor/ffiDtor macros declare it too, guarded by `when not
# declared`).
declareLibrary("sds", ReliabilityManager)

type SdsRetrievalHintProvider* = proc(
  messageId: cstring, hint: ptr cstring, hintLen: ptr csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

type SdsChannelRetrievalHintProvider* = proc(
  messageId: cstring, channelId: ptr byte, channelIdLen: csize_t,
  hint: ptr cstring, hintLen: ptr csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].}

type SdsPersistenceCallback* = proc(
  operation: cint,
  channelId: ptr byte,
  channelIdLen: csize_t,
  payload: ptr byte,
  payloadLen: csize_t,
  response: ptr cstring,
  responseLen: ptr csize_t,
  userData: pointer,
) : cint {.cdecl, gcsafe, raises: [].}

type PersistenceOperation = enum
  SaveChannelMeta = 1
  UpdateHistory = 2
  LoadChannel = 3
  DropChannel = 4

# The active retrieval-hint provider, stored per worker thread (one thread per
# context). Set by sds_set_retrieval_hint_provider via a dispatched request so
# the write lands on the worker thread, where the manager's hint closure reads
# it during message processing.
var sdsRetrievalHintCb {.threadvar.}: pointer
var sdsRetrievalHintUserData {.threadvar.}: pointer
var sdsChannelRetrievalHintCb {.threadvar.}: pointer
var sdsChannelRetrievalHintUserData {.threadvar.}: pointer
var sdsPersistenceCb {.threadvar.}: pointer
var sdsPersistenceUserData {.threadvar.}: pointer

################################################################################
### JSON-marshalled request/response types

type SdsConfig* {.ffi.} = object
  participantId: string ## empty disables SDS-R (see newReliabilityManager)
  persistenceEnabled: bool
  syncMessageIntervalMs: int64 ## test-only override; zero uses the default

type SdsWrapRequest* {.ffi.} = object
  message: seq[byte]
  messageId: string
  channelId: string

type SdsChannelRequest* {.ffi.} = object
  channelId: string

type SdsWrapResponse* {.ffi.} = object
  message: seq[byte]

type SdsUnwrapRequest* {.ffi.} = object
  message: seq[byte]

type SdsMarkDependenciesRequest* {.ffi.} = object
  messageIds: seq[string]
  channelId: string

type PersistenceHistoryEntry = object
  messageId: string
  lamportTimestamp: int64
  data: string

type PersistenceHistoryUpdate = object
  append: seq[PersistenceHistoryEntry]
  evict: seq[string]

type PersistenceChannelData = object
  meta: Option[string]
  messageHistory: Option[seq[string]]

proc invokePersistence(
    operation: PersistenceOperation,
    channelId: string,
    payload: ptr byte,
    payloadLen: csize_t,
): Result[string, string] =
  if sdsPersistenceCb.isNil():
    return err("SDS persistence callback is not registered")

  var channelIdPtr: ptr byte
  if channelId.len > 0:
    channelIdPtr = cast[ptr byte](unsafeAddr channelId[0])

  var response: cstring
  var responseLen: csize_t

  let ret = cast[SdsPersistenceCallback](sdsPersistenceCb)(
    cint(ord(operation)),
    channelIdPtr,
    csize_t(channelId.len),
    payload,
    payloadLen,
    addr response,
    addr responseLen,
    sdsPersistenceUserData,
  )
  var responseText = ""
  if not response.isNil() and responseLen > 0:
    responseText = newString(int(responseLen))
    copyMem(addr responseText[0], response, int(responseLen))
  if not response.isNil():
    c_free(response)
  if ret != RET_OK:
    return err(if responseText.len == 0: "SDS persistence callback failed" else: responseText)
  ok(responseText)

proc invokePersistence(
    operation: PersistenceOperation, channelId: string, payload: openArray[byte]
): Result[string, string] =
  var payloadPtr: ptr byte
  if payload.len > 0:
    payloadPtr = unsafeAddr payload[0]
  invokePersistence(operation, channelId, payloadPtr, csize_t(payload.len))

proc invokePersistence(
    operation: PersistenceOperation, channelId, payload: string
): Result[string, string] =
  var payloadPtr: ptr byte
  if payload.len > 0:
    payloadPtr = cast[ptr byte](unsafeAddr payload[0])
  invokePersistence(operation, channelId, payloadPtr, csize_t(payload.len))

proc ffiPersistence(): Persistence =
  result.saveChannelMeta = proc(
      channelId: SdsChannelID, meta: ChannelMeta
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
    let saved = invokePersistence(
      PersistenceOperation.SaveChannelMeta, $channelId, encode(meta).buffer
    )
    if saved.isErr():
      return err("could not save SDS channel meta: " & saved.error)
    return ok()

  result.updateHistory = proc(
      channelId: SdsChannelID, update: HistoryUpdate
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
    var appended = newSeqOfCap[PersistenceHistoryEntry](update.append.len)
    for message in update.append:
      let serializedMessageBytes = wire.serializeMessage(message).valueOr:
        return err("failed to serialize SDS history message: " & $error)
      appended.add(
        PersistenceHistoryEntry(
          messageId: message.messageId,
          lamportTimestamp: message.lamportTimestamp,
          data: encode(serializedMessageBytes),
        )
      )
    let request = PersistenceHistoryUpdate(append: appended, evict: update.evict)
    let requestJson = $(%request)
    let saved = invokePersistence(PersistenceOperation.UpdateHistory, $channelId, requestJson)
    if saved.isErr():
      return err("could not update SDS channel history: " & saved.error)
    return ok()

  result.loadChannel = proc(
      channelId: SdsChannelID
  ): Future[Result[ChannelData, string]] {.async: (raises: []), gcsafe.} =
    let loaded = invokePersistence(PersistenceOperation.LoadChannel, $channelId, [])
    if loaded.isErr():
      return err("could not load SDS channel: " & loaded.error)
    try:
      let data = parseJson(loaded.value).to(PersistenceChannelData)
      var channel = ChannelData.init()
      if data.meta.isSome() and data.meta.get().len > 0:
        let decoded = ChannelMeta.decode(decode(data.meta.get()).toBytes()).valueOr:
          return err("failed to decode persisted SDS channel metadata")
        channel.meta = decoded
      if data.messageHistory.isSome():
        for encodedMessage in data.messageHistory.get():
          let message = wire.deserializeMessage(decode(encodedMessage).toBytes()).valueOr:
            return err("failed to decode persisted SDS history message")
          channel.messageHistory.add(message)
      return ok(channel)
    except CatchableError as exc:
      return err("failed to load persisted SDS channel: " & exc.msg)

  result.dropChannel = proc(
      channelId: SdsChannelID
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.} =
    let dropped = invokePersistence(PersistenceOperation.DropChannel, $channelId, [])
    if dropped.isErr():
      return err("could not drop SDS channel: " & dropped.error)
    return ok()

################################################################################
### Constructor — creates the FFI context and the ReliabilityManager.
###
### The event closures run on the worker thread and forward JSON payloads to the
### C callback registered via sds_set_event_callback (dispatchFfiEvent reads the
### per-thread callback state, so no context handle is needed here).

proc sdsCreate*(
    config: SdsConfig
): Future[Result[ReliabilityManager, string]] {.ffiCtor.} =
  # The ctor body runs on the (possibly recycled) worker thread. Drop any
  # retrieval-hint provider left over from a previous owner of this thread so a
  # stale C function pointer is never invoked.
  sdsRetrievalHintCb = nil
  sdsRetrievalHintUserData = nil
  sdsChannelRetrievalHintCb = nil
  sdsChannelRetrievalHintUserData = nil
  sdsPersistenceCb = nil
  sdsPersistenceUserData = nil

  let persistence = if config.persistenceEnabled: ffiPersistence() else: noOpPersistence()
  var reliabilityConfig = defaultConfig()
  if config.syncMessageIntervalMs > 0:
    reliabilityConfig.syncMessageInterval =
      initDuration(milliseconds = config.syncMessageIntervalMs)

  let rm = newReliabilityManager(
    participantId = config.participantId.SdsParticipantID,
    config = reliabilityConfig,
    persistence = persistence,
  ).valueOr:
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

  let messageExpiredCb = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ) {.gcsafe.} =
    dispatchFfiEvent("message_expired"):
      $JsonMessageExpiredEvent.new(messageId, channelId)

  let periodicSyncCb: PeriodicSyncCallback = proc() {.gcsafe, raises: [].} =
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
      # The provider allocates `hint` with malloc and hands us ownership; free
      # it with libc free. Nim's deallocShared here corrupts its allocator.
      c_free(hint)
      return hintBytes
    return @[]

  let channelRetrievalHintProvider = proc(
      messageId: SdsMessageID, channelId: SdsChannelID
  ): seq[byte] {.gcsafe.} =
    if sdsChannelRetrievalHintCb.isNil():
      return retrievalHintProvider(messageId)
    var hint: cstring
    var hintLen: csize_t
    var channelIdPtr: ptr byte
    if channelId.len > 0:
      channelIdPtr = cast[ptr byte](unsafeAddr channelId[0])
    cast[SdsChannelRetrievalHintProvider](sdsChannelRetrievalHintCb)(
      messageId.cstring, channelIdPtr, csize_t(channelId.len), addr hint, addr hintLen,
      sdsChannelRetrievalHintUserData
    )
    if not hint.isNil():
      if hintLen > 0:
        result = newSeq[byte](hintLen)
        copyMem(addr result[0], hint, hintLen)
      c_free(hint)

  await rm.setCallbacks(
    messageReadyCb, messageSentCb, missingDependenciesCb, periodicSyncCb,
    retrievalHintProvider, repairReadyCb, messageExpiredCb, channelRetrievalHintProvider,
  )

  return ok(rm)

################################################################################
### Async methods — each runs its body on the worker thread.

proc sdsWrapOutgoingMessage*(
    rm: ReliabilityManager, req: SdsWrapRequest
): Future[Result[SdsWrapResponse, string]] {.ffi.} =
  let wrapped = (
    await wrapOutgoingMessage(rm, req.message, req.messageId, req.channelId)
  ).valueOr:
    error "WRAP_MESSAGE failed", error = error
    return err("error processing wrap request: " & $error)
  return ok(SdsWrapResponse(message: wrapped))

proc sdsEnsureChannel*(
    rm: ReliabilityManager, req: SdsChannelRequest
): Future[Result[string, string]] {.ffi.} =
  (await rm.ensureChannel(req.channelId)).isOkOr:
    return err("error ensuring SDS channel: " & $error)
  return ok("")

proc sdsTick*(rm: ReliabilityManager): Future[Result[string, string]] {.ffi.} =
  return ok(tickResponse(await rm.tick()))

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

  return ok(unwrapResponse(unwrapped, missingDeps, channelId))

proc sdsMarkDependenciesMet*(
    rm: ReliabilityManager, req: SdsMarkDependenciesRequest
): Future[Result[string, string]] {.ffi.} =
  (await markDependenciesMet(rm, req.messageIds, req.channelId)).isOkOr:
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
  sdsRetrievalHintCb = nil
  sdsRetrievalHintUserData = nil
  sdsChannelRetrievalHintCb = nil
  sdsChannelRetrievalHintUserData = nil
  sdsPersistenceCb = nil
  sdsPersistenceUserData = nil

################################################################################
### Retrieval-hint provider (hand-written: a C function pointer cannot be passed
### as JSON). The setter dispatches a request so the provider is stored in the
### worker thread's thread-local, where sdsCreate's hint closure reads it.

proc sdsNoopCallback(
    callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  discard

# Request params are CBOR-encoded, so the in-process pointers cross as integers.
registerReqFFI(SdsSetHintReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(cbAddr: uint64, udAddr: uint64): Future[Result[string, string]] {.async.} =
    sdsRetrievalHintCb = cast[pointer](cbAddr)
    sdsRetrievalHintUserData = cast[pointer](udAddr)
    return ok("")

proc sds_set_retrieval_hint_provider(
    ctxToken: FFICtxToken, callback: SdsRetrievalHintProvider, userData: pointer
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  let ctx = ReliabilityManagerFFIPool.resolveCtx(ctxToken)
  if ctx.isNil():
    return RET_ERR

  let sendRes =
    try:
      ffi_context.sendRequestToFFIThread(
        ctx,
        SdsSetHintReq.ffiNewReq(
          sdsNoopCallback, nil, cast[uint64](callback), cast[uint64](userData)
        ),
        ctxToken.tokenGeneration(),
      )
    except Exception as exc:
      Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
  if sendRes.isErr():
    return RET_ERR
  return RET_OK

registerReqFFI(SdsSetChannelHintReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(cbAddr: uint64, udAddr: uint64): Future[Result[string, string]] {.async.} =
    sdsChannelRetrievalHintCb = cast[pointer](cbAddr)
    sdsChannelRetrievalHintUserData =
      if cbAddr == 0: nil else: cast[pointer](udAddr)
    return ok("")

proc sds_set_channel_retrieval_hint_provider(
    ctxToken: FFICtxToken, callback: SdsChannelRetrievalHintProvider, userData: pointer
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  let ctx = ReliabilityManagerFFIPool.resolveCtx(ctxToken)
  if ctx.isNil():
    return RET_ERR
  let sendRes =
    try:
      ffi_context.sendRequestToFFIThread(
        ctx,
        SdsSetChannelHintReq.ffiNewReq(
          sdsNoopCallback, nil, cast[uint64](callback), cast[uint64](userData)
        ),
        ctxToken.tokenGeneration(),
      )
    except Exception as exc:
      Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
  if sendRes.isErr():
    return RET_ERR
  return RET_OK

registerReqFFI(SdsSetPersistenceReq, ctx: ptr FFIContext[ReliabilityManager]):
  proc(cbAddr: uint64, udAddr: uint64): Future[Result[string, string]] {.async.} =
    sdsPersistenceCb = cast[pointer](cbAddr)
    sdsPersistenceUserData =
      if cbAddr == 0: nil else: cast[pointer](udAddr)
    return ok("")

proc sds_set_persistence_callback(
    ctxToken: FFICtxToken, callback: SdsPersistenceCallback, userData: pointer
): cint {.dynlib, exportc, cdecl, raises: [].} =
  initializeLibrary()
  let ctx = ReliabilityManagerFFIPool.resolveCtx(ctxToken)
  if ctx.isNil():
    return RET_ERR

  let sendRes =
    try:
      ffi_context.sendRequestToFFIThread(
        ctx,
        SdsSetPersistenceReq.ffiNewReq(
          sdsNoopCallback, nil, cast[uint64](callback), cast[uint64](userData)
        ),
        ctxToken.tokenGeneration(),
      )
    except Exception as exc:
      Result[void, string].err("sendRequestToFFIThread exception: " & exc.msg)
  if sendRes.isErr():
    return RET_ERR
  return RET_OK

# Emit binding metadata (no-op unless -d:ffiGenBindings). Must follow every
# {.ffi.}/{.ffiCtor.}/{.ffiDtor.} annotation.
genBindings()

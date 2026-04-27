{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

when defined(linux):
  {.passl: "-Wl,-soname,libsds.so".}

import std/[typetraits, tables, atomics, locks], chronos, chronicles
import
  ./sds_thread/sds_thread,
  ./alloc,
  ./ffi_types,
  ./sds_thread/inter_thread_communication/sds_thread_request,
  ./sds_thread/inter_thread_communication/requests/
    [sds_lifecycle_request, sds_message_request, sds_dependencies_request],
  sds,
  ./events/[
    json_message_ready_event, json_message_sent_event, json_missing_dependencies_event,
    json_periodic_sync_event,
  ]

################################################################################
### Wrapper around the reliability manager
################################################################################

################################################################################
### Not-exported components

template checkLibsdsParams*(
    ctx: ptr SdsContext, callback: SdsCallBack, userData: pointer
) =
  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK

template callEventCallback(ctx: ptr SdsContext, eventName: string, body: untyped) =
  if isNil(ctx[].eventCallback):
    error eventName & " - eventCallback is nil"
    return

  if isNil(ctx[].eventUserData):
    error eventName & " - eventUserData is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[SdsCallBack](ctx[].eventCallback)(
        RET_OK, unsafeAddr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[SdsCallBack](ctx[].eventCallback)(
        RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

var
  ctxPool: seq[ptr SdsContext]
  ctxPoolLock: Lock

proc acquireCtx(callback: SdsCallBack, userData: pointer): ptr SdsContext =
  ctxPoolLock.acquire()
  defer: ctxPoolLock.release()
  if ctxPool.len > 0:
    result = ctxPool.pop()
  else:
    result = sds_thread.createSdsThread().valueOr:
      let msg = "Error in createSdsThread: " & $error
      callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
      return nil

proc releaseCtx(ctx: ptr SdsContext) =
  ctxPoolLock.acquire()
  defer: ctxPoolLock.release()
  ctx.userData = nil
  ctx.eventCallback = nil
  ctx.eventUserData = nil
  ctxPool.add(ctx)

proc handleRequest(
    ctx: ptr SdsContext,
    requestType: RequestType,
    content: pointer,
    callback: SdsCallBack,
    userData: pointer,
): cint =
  sds_thread.sendRequestToSdsThread(ctx, requestType, content, callback, userData).isOkOr:
    let msg = "libsds error: " & $error
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_OK

proc onMessageReady(ctx: ptr SdsContext): MessageReadyCallback =
  return proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
    callEventCallback(ctx, "onMessageReady"):
      $JsonMessageReadyEvent.new(messageId, channelId)

proc onMessageSent(ctx: ptr SdsContext): MessageSentCallback =
  return proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.} =
    callEventCallback(ctx, "onMessageSent"):
      $JsonMessageSentEvent.new(messageId, channelId)

proc onMissingDependencies(ctx: ptr SdsContext): MissingDependenciesCallback =
  return proc(messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID) {.gcsafe.} =
    callEventCallback(ctx, "onMissingDependencies"):
      $JsonMissingDependenciesEvent.new(messageId, missingDeps, channelId)

proc onPeriodicSync(ctx: ptr SdsContext): PeriodicSyncCallback =
  return proc() {.gcsafe.} =
    callEventCallback(ctx, "onPeriodicSync"):
      $JsonPeriodicSyncEvent.new()

proc onRetrievalHint(ctx: ptr SdsContext): RetrievalHintProvider =
  return proc(messageId: SdsMessageID): seq[byte] {.gcsafe.} =
    if isNil(ctx.retrievalHintProvider):
      return @[]

    var hint: cstring
    var hintLen: csize_t
    cast[SdsRetrievalHintProvider](ctx.retrievalHintProvider)(
      messageId.cstring, addr hint, addr hintLen, ctx.retrievalHintUserData
    )

    if not isNil(hint) and hintLen > 0:
      var hintBytes = newSeq[byte](hintLen)
      copyMem(addr hintBytes[0], hint, hintLen)
      deallocShared(hint)
      return hintBytes
    
    return @[]

### End of not-exported components
################################################################################

################################################################################
### Library setup

# Every Nim library must have this function called - the name is derived from
# the `--nimMainPrefix` command line option
when isMainModule:
  proc libsdsNimMain() {.importc.}

# To control when the library has been initialized
var initialized: Atomic[bool]

if defined(android):
  # Redirect chronicles to Android System logs
  when compiles(defaultChroniclesStream.outputs[0].writer):
    defaultChroniclesStream.outputs[0].writer = proc(
        logLevel: LogLevel, msg: LogOutputStr
    ) {.raises: [].} =
      echo logLevel, msg

proc initializeLibrary() {.exported.} =
  if not initialized.exchange(true):
    ## Every Nim library needs to call `<yourprefix>NimMain` once exactly, to initialize the Nim runtime.
    ## Being `<yourprefix>` the value given in the optional compilation flag --nimMainPrefix:yourprefix
    when isMainModule:
      libsdsNimMain()
    ctxPoolLock.initLock() # ensure the lock is initialized once (fix Windows crash)
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  when declared(nimGC_setStackBottom):
    var locals {.volatile, noinit.}: pointer
    locals = addr(locals)
    nimGC_setStackBottom(locals)

### End of library setup
################################################################################

################################################################################
### Exported procs

proc SdsNewReliabilityManager(
    callback: SdsCallBack, userData: pointer
): pointer {.dynlib, exportc, cdecl.} =
  initializeLibrary()

  ## Creates a new instance of the Reliability Manager.
  if isNil(callback):
    echo "error: missing callback in NewReliabilityManager"
    return nil

  ## Create or reuse the SDS thread that will keep waiting for req from the main thread.
  var ctx = acquireCtx(callback, userData)
  if ctx.isNil():
    return nil

  ctx.userData = userData

  let appCallbacks = AppCallbacks(
    messageReadyCb: onMessageReady(ctx),
    messageSentCb: onMessageSent(ctx),
    missingDependenciesCb: onMissingDependencies(ctx),
    periodicSyncCb: onPeriodicSync(ctx),
    retrievalHintProvider: onRetrievalHint(ctx),
  )

  let retCode = handleRequest(
    ctx,
    RequestType.LIFECYCLE,
    SdsLifecycleRequest.createShared(
      SdsLifecycleMsgType.CREATE_RELIABILITY_MANAGER, nil, appCallbacks
    ),
    callback,
    userData,
  )

  if retCode == RET_ERR:
    return nil

  return ctx

proc SdsSetEventCallback(
    ctx: ptr SdsContext, callback: SdsCallBack, userData: pointer
) {.dynlib, exportc.} =
  initializeLibrary()
  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

proc SdsSetRetrievalHintProvider(
    ctx: ptr SdsContext, callback: SdsRetrievalHintProvider, userData: pointer
) {.dynlib, exportc.} =
  initializeLibrary()
  ctx[].retrievalHintProvider = cast[pointer](callback)
  ctx[].retrievalHintUserData = userData

proc SdsCleanupReliabilityManager(
    ctx: ptr SdsContext, callback: SdsCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibsdsParams(ctx, callback, userData)

  let resetRes = handleRequest(
    ctx,
    RequestType.LIFECYCLE,
    SdsLifecycleRequest.createShared(SdsLifecycleMsgType.RESET_RELIABILITY_MANAGER),
    callback,
    userData,
  )

  if resetRes == RET_ERR:
    return RET_ERR

  releaseCtx(ctx)

  # handleRequest already invoked the callback; nothing else to signal here.
  return RET_OK

proc SdsResetReliabilityManager(
    ctx: ptr SdsContext, callback: SdsCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibsdsParams(ctx, callback, userData)
  handleRequest(
    ctx,
    RequestType.LIFECYCLE,
    SdsLifecycleRequest.createShared(SdsLifecycleMsgType.RESET_RELIABILITY_MANAGER),
    callback,
    userData,
  )

proc SdsWrapOutgoingMessage(
    ctx: ptr SdsContext,
    message: pointer,
    messageLen: csize_t,
    messageId: cstring,
    channelId: cstring,
    callback: SdsCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibsdsParams(ctx, callback, userData)

  if message == nil and messageLen > 0:
    let msg = "libsds error: " & "message pointer is NULL but length > 0"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  if messageId == nil:
    let msg = "libsds error: " & "message ID pointer is NULL"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  if channelId == nil:
    let msg = "libsds error: " & "channel ID pointer is NULL"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  if channelId != nil and $channelId == "":
    let msg = "libsds error: " & "channel ID is empty string"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  handleRequest(
    ctx,
    RequestType.MESSAGE,
    SdsMessageRequest.createShared(
      SdsMessageMsgType.WRAP_MESSAGE, message, messageLen, messageId, channelId
    ),
    callback,
    userData,
  )

proc SdsUnwrapReceivedMessage(
    ctx: ptr SdsContext,
    message: pointer,
    messageLen: csize_t,
    callback: SdsCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibsdsParams(ctx, callback, userData)

  if message == nil and messageLen > 0:
    let msg = "libsds error: " & "message pointer is NULL but length > 0"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  handleRequest(
    ctx,
    RequestType.MESSAGE,
    SdsMessageRequest.createShared(
      SdsMessageMsgType.UNWRAP_MESSAGE, message, messageLen
    ),
    callback,
    userData,
  )

proc SdsMarkDependenciesMet(
    ctx: ptr SdsContext,
    messageIds: pointer,
    count: csize_t,
    channelId: cstring,
    callback: SdsCallBack,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibsdsParams(ctx, callback, userData)

  if messageIds == nil and count > 0:
    let msg = "libsds error: " & "MessageIDs pointer is NULL but count > 0"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  if channelId == nil:
    let msg = "libsds error: " & "channel ID pointer is NULL"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  if channelId != nil and $channelId == "":
    let msg = "libsds error: " & "channel ID is empty string"
    callback(RET_ERR, unsafeAddr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  handleRequest(
    ctx,
    RequestType.DEPENDENCIES,
    SdsDependenciesRequest.createShared(
      SdsDependenciesMsgType.MARK_DEPENDENCIES_MET, messageIds, count, channelId
    ),
    callback,
    userData,
  )

proc SdsStartPeriodicTasks(
    ctx: ptr SdsContext, callback: SdsCallBack, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibsdsParams(ctx, callback, userData)
  handleRequest(
    ctx,
    RequestType.LIFECYCLE,
    SdsLifecycleRequest.createShared(SdsLifecycleMsgType.START_PERIODIC_TASKS),
    callback,
    userData,
  )

### End of exported procs
################################################################################

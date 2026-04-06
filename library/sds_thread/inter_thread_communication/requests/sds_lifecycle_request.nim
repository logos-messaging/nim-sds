import std/json
import chronos, chronicles, results

import library/alloc
import sds

type SdsLifecycleMsgType* = enum
  CREATE_RELIABILITY_MANAGER
  RESET_RELIABILITY_MANAGER
  START_PERIODIC_TASKS

type SdsLifecycleRequest* = object
  operation: SdsLifecycleMsgType
  channelId: cstring
  appCallbacks: AppCallbacks

proc createShared*(
    T: type SdsLifecycleRequest,
    op: SdsLifecycleMsgType,
    channelId: cstring = "",
    appCallbacks: AppCallbacks = nil,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].appCallbacks = appCallbacks
  ret[].channelId = channelId.alloc()
  return ret

proc destroyShared(self: ptr SdsLifecycleRequest) =
  deallocShared(self[].channelId)
  deallocShared(self)

proc createReliabilityManager(
    appCallbacks: AppCallbacks = nil
): Future[Result[ReliabilityManager, string]] {.async.} =
  let rm = newReliabilityManager().valueOr:
    error "Failed creating reliability manager", error = error
    return err("Failed creating reliability manager: " & $error)

  rm.setCallbacks(
    appCallbacks.messageReadyCb, appCallbacks.messageSentCb,
    appCallbacks.missingDependenciesCb, appCallbacks.periodicSyncCb,
    appCallbacks.retrievalHintProvider, appCallbacks.repairReadyCb,
  )

  return ok(rm)

proc process*(
    self: ptr SdsLifecycleRequest, rm: ptr ReliabilityManager
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of CREATE_RELIABILITY_MANAGER:
    rm[] = (await createReliabilityManager(self.appCallbacks)).valueOr:
      error "CREATE_RELIABILITY_MANAGER failed", error = error
      return err("error processing CREATE_RELIABILITY_MANAGER request: " & $error)
  of RESET_RELIABILITY_MANAGER:
    resetReliabilityManager(rm[]).isOkOr:
      error "RESET_RELIABILITY_MANAGER failed", error = error
      return err("error processing RESET_RELIABILITY_MANAGER request: " & $error)
  of START_PERIODIC_TASKS:
    rm[].startPeriodicTasks()

  return ok("")

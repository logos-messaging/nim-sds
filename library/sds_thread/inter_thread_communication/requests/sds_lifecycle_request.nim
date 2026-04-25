import std/json
import chronos, chronicles, results

import library/alloc
import library/config_json
import sds

type SdsLifecycleMsgType* = enum
  CREATE_RELIABILITY_MANAGER
  RESET_RELIABILITY_MANAGER
  START_PERIODIC_TASKS
  REMOVE_CHANNEL

type SdsLifecycleRequest* = object
  operation: SdsLifecycleMsgType
  channelId: cstring
  appCallbacks: AppCallbacks
  participantId: cstring
  configJson: cstring

proc createShared*(
    T: type SdsLifecycleRequest,
    op: SdsLifecycleMsgType,
    channelId: cstring = "",
    appCallbacks: AppCallbacks = nil,
    participantId: cstring = "",
    configJson: cstring = "",
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].appCallbacks = appCallbacks
  ret[].channelId = channelId.alloc()
  ret[].participantId = participantId.alloc()
  ret[].configJson = configJson.alloc()
  return ret

proc destroyShared(self: ptr SdsLifecycleRequest) =
  deallocShared(self[].channelId)
  deallocShared(self[].participantId)
  deallocShared(self[].configJson)
  deallocShared(self)

proc createReliabilityManager(
    participantId: string,
    configJson: string,
    appCallbacks: AppCallbacks = nil,
): Future[Result[ReliabilityManager, string]] {.async.} =
  let config = parseReliabilityConfig(configJson).valueOr:
    error "Failed to parse reliability config", error = error
    return err("Failed to parse reliability config: " & error)

  let rm = newReliabilityManager(config, participantId).valueOr:
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
    rm[] = (
      await createReliabilityManager(
        $self.participantId, $self.configJson, self.appCallbacks
      )
    ).valueOr:
      error "CREATE_RELIABILITY_MANAGER failed", error = error
      return err("error processing CREATE_RELIABILITY_MANAGER request: " & $error)
  of RESET_RELIABILITY_MANAGER:
    resetReliabilityManager(rm[]).isOkOr:
      error "RESET_RELIABILITY_MANAGER failed", error = error
      return err("error processing RESET_RELIABILITY_MANAGER request: " & $error)
  of START_PERIODIC_TASKS:
    rm[].startPeriodicTasks()
  of REMOVE_CHANNEL:
    removeChannel(rm[], $self.channelId).isOkOr:
      error "REMOVE_CHANNEL failed", error = error
      return err("error processing REMOVE_CHANNEL request: " & $error)

  return ok("")

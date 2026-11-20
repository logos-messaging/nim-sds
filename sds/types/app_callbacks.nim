import ./callbacks
export callbacks

type AppCallbacks* = ref object
  messageReadyCb*: MessageReadyCallback
  messageSentCb*: MessageSentCallback
  missingDependenciesCb*: MissingDependenciesCallback
  retrievalHintProvider*: RetrievalHintProvider
  repairReadyCb*: RepairReadyCallback

proc new*(
    T: type AppCallbacks,
    messageReadyCb: MessageReadyCallback = nil,
    messageSentCb: MessageSentCallback = nil,
    missingDependenciesCb: MissingDependenciesCallback = nil,
    retrievalHintProvider: RetrievalHintProvider = nil,
    repairReadyCb: RepairReadyCallback = nil,
): T =
  return T(
    messageReadyCb: messageReadyCb,
    messageSentCb: messageSentCb,
    missingDependenciesCb: missingDependenciesCb,
    retrievalHintProvider: retrievalHintProvider,
    repairReadyCb: repairReadyCb,
  )

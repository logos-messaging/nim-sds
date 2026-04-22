import ./callbacks
export callbacks

type AppCallbacks* = ref object
  messageReadyCb*: MessageReadyCallback
  messageSentCb*: MessageSentCallback
  missingDependenciesCb*: MissingDependenciesCallback
  periodicSyncCb*: PeriodicSyncCallback
  retrievalHintProvider*: RetrievalHintProvider

proc new*(
    T: type AppCallbacks,
    messageReadyCb: MessageReadyCallback = nil,
    messageSentCb: MessageSentCallback = nil,
    missingDependenciesCb: MissingDependenciesCallback = nil,
    periodicSyncCb: PeriodicSyncCallback = nil,
    retrievalHintProvider: RetrievalHintProvider = nil,
): T =
  T(
    messageReadyCb: messageReadyCb,
    messageSentCb: messageSentCb,
    missingDependenciesCb: missingDependenciesCb,
    periodicSyncCb: periodicSyncCb,
    retrievalHintProvider: retrievalHintProvider,
  )

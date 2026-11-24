type ReliabilityError* {.pure.} = enum
  reInvalidArgument
  reOutOfMemory
  reInternalError
  reSerializationError
  reDeserializationError
  reMessageTooLarge
  rePersistenceError ## A persistence backend operation (read or write) failed.
  reMessageRejected ## The authorizer denied the incoming message.
  reAuthorizationError ## The authorizer could not authorize the incoming message.

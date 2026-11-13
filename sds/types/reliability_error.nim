type ReliabilityError* {.pure.} = enum
  reInvalidArgument
  reOutOfMemory
  reInternalError
  reSerializationError
  reDeserializationError
  reMessageTooLarge
  rePersistenceError ## A persistence backend operation (read or write) failed.
  reMessageRejected ## The validator denied the incoming message.
  reValidationError ## The validator could not authorize the incoming message.

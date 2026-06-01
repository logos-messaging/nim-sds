type ReliabilityError* {.pure.} = enum
  reInvalidArgument
  reOutOfMemory
  reInternalError
  reSerializationError
  reDeserializationError
  reMessageTooLarge
  rePersistenceError ## A persistence backend operation (read or write) failed.

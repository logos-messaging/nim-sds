type ReliabilityError* {.pure.} = enum
  reInvalidArgument
  reOutOfMemory
  reInternalError
  reSerializationError
  reDeserializationError
  reMessageTooLarge

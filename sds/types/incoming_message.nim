import std/sets
import ./sds_message_id
import ./sds_message
export sds_message_id, sds_message

type IncomingMessage* {.requiresInit.} = object
  message*: SdsMessage
  missingDeps*: HashSet[SdsMessageID]

proc init*(
    T: type IncomingMessage, message: SdsMessage, missingDeps: HashSet[SdsMessageID]
): T =
  return T(message: message, missingDeps: missingDeps)

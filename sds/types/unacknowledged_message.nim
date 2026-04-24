import std/times
import ./sds_message
export sds_message

type UnacknowledgedMessage* = object
  message*: SdsMessage
  sendTime*: Time
  resendAttempts*: int

proc init*(
    T: type UnacknowledgedMessage, message: SdsMessage, sendTime: Time, resendAttempts: int
): T =
  return T(message: message, sendTime: sendTime, resendAttempts: resendAttempts)

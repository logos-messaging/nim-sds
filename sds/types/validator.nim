import results
import ./sds_message
export results, sds_message

type Validator* = object
  ## Optional, synchronous authorization gate for a decoded incoming message.
  ## A nil validate proc preserves the existing trusted-channel behavior.
  ## Implementations must not mutate the message or re-enter the manager.
  validate*: proc(message: SdsMessage): Result[bool, string] {.gcsafe, raises: [].}
    ## ok(true) accepts, ok(false) rejects, and err fails validation.

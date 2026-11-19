import results
import ./sds_message
export results, sds_message

type Authorizer* = object
  ## Optional, synchronous authorization gate for a decoded incoming message.
  ## A nil authorize proc preserves the existing trusted-channel behavior.
  ## Implementations must not mutate the message or re-enter the manager.
  authorize*: proc(
      message: SdsMessage, authorizationContext: seq[byte]
  ): Result[bool, string] {.gcsafe, raises: [].}
    ## ok(true) accepts, ok(false) rejects, and err fails authorization.

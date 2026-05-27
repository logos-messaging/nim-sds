import chronos, results
import ./sds_message_id
import ./sds_message
import ./unacknowledged_message
import ./incoming_message
import ./repair_entry
export
  results, sds_message_id, sds_message, unacknowledged_message, incoming_message,
  repair_entry

## SDS state persistence interface (issue #64).
##
## Defines WHAT operations a persistence backend must provide. The actual
## storage technology (SQLite, encrypted file, in-memory) is supplied by the
## caller — nim-sds knows nothing about it. Every state-mutating proc in the
## protocol calls into one of these procs immediately after the in-memory
## change, so on-disk state stays in lockstep with in-memory state.
##
## All proc fields are async (return `Future`) so backends can do real I/O
## without blocking the Chronos event loop the manager runs on.
##
## Every field returns a `Result` so backend failures are propagated to nim-sds
## rather than swallowed by the backend. Mutating ops return
## `Result[void, string]`; the getter (`loadAllForChannel`) returns
## `Result[ChannelSnapshot, string]`. The error is a backend-supplied message;
## nim-sds maps it to `ReliabilityError.rePersistenceError` and surfaces it on
## the corresponding public API call. The contract still forbids raising
## (`raises: []`): failure must travel through the `Result`, not an exception.
##
## Bloom filter is intentionally not persisted: it is rebuilt from the local
## history log on bootstrap. Async timers are likewise recomputed from the
## absolute timestamps stored in the repair buffer entries.

type
  ChannelSnapshot* = object
    ## Returned by `loadAllForChannel` on bootstrap. Carries the entire
    ## per-channel state needed to repopulate a `ChannelContext`. The bloom
    ## filter is NOT in the snapshot — callers rebuild it from `messageHistory`.
    lamportTimestamp*: int64
    messageHistory*: seq[SdsMessage]
      ## MUST be ordered oldest-first. FIFO eviction relies on insertion order;
      ## skipping ORDER BY corrupts the log across restarts.
    outgoingBuffer*: seq[UnacknowledgedMessage]
    incomingBuffer*: seq[IncomingMessage]
    outgoingRepairBuffer*: seq[(SdsMessageID, OutgoingRepairEntry)]
    incomingRepairBuffer*: seq[(SdsMessageID, IncomingRepairEntry)]

  Persistence* = object
    ## Pluggable persistence contract. The caller supplies an instance of this
    ## type at `newReliabilityManager` construction time. Each proc field is
    ## invoked by nim-sds at the corresponding state-mutation point.
    ## All fields are async; nim-sds awaits each call to keep on-disk and
    ## in-memory state in lockstep without blocking the event loop.

    # Per-channel lamport clock
    saveLamport*: proc(
      channelId: SdsChannelID, lamport: int64
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}

    # Local log (delivered messages)
    appendLogEntry*: proc(
      channelId: SdsChannelID, msg: SdsMessage
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    removeLogEntry*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    setRetrievalHint*: proc(
      msgId: SdsMessageID, hint: seq[byte]
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}

    # Outgoing unacknowledged buffer
    saveOutgoing*: proc(
      channelId: SdsChannelID, msg: UnacknowledgedMessage
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    removeOutgoing*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}

    # Incoming dependency-waiting buffer
    saveIncoming*: proc(
      channelId: SdsChannelID, msg: IncomingMessage
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    removeIncoming*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}

    # SDS-R outgoing repair buffer
    saveOutgoingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID, entry: OutgoingRepairEntry
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    removeOutgoingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}

    # SDS-R incoming repair buffer
    saveIncomingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID, entry: IncomingRepairEntry
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    removeIncomingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}

    # Wipe all persisted state for a channel in one transactional call.
    # Called by removeChannel / resetReliabilityManager. Backends should
    # implement this atomically (e.g. one BEGIN/COMMIT) — a per-row loop on
    # the nim-sds side would mean N fsyncs per drop.
    dropChannel*: proc(channelId: SdsChannelID): Future[Result[void, string]] {.
      async: (raises: []), gcsafe
    .}

    # Bootstrap on `addChannel` / `getOrCreateChannel`.
    loadAllForChannel*: proc(
      channelId: SdsChannelID
    ): Future[Result[ChannelSnapshot, string]] {.async: (raises: []), gcsafe.}

proc noOpPersistence*(): Persistence =
  ## Default backend that discards every write and returns an empty snapshot.
  ## Used so existing callers (and tests) that don't care about durability
  ## keep working without supplying a real backend.
  Persistence(
    saveLamport: proc(
        channelId: SdsChannelID, lamport: int64
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    appendLogEntry: proc(
        channelId: SdsChannelID, msg: SdsMessage
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    removeLogEntry: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    setRetrievalHint: proc(
        msgId: SdsMessageID, hint: seq[byte]
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    saveOutgoing: proc(
        channelId: SdsChannelID, msg: UnacknowledgedMessage
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    removeOutgoing: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    saveIncoming: proc(
        channelId: SdsChannelID, msg: IncomingMessage
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    removeIncoming: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    saveOutgoingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: OutgoingRepairEntry
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    removeOutgoingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    saveIncomingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: IncomingRepairEntry
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    removeIncomingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    dropChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    loadAllForChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[ChannelSnapshot, string]] {.async: (raises: []).} =
      ok(ChannelSnapshot()),
  )

import chronos
import ./sds_message_id
import ./sds_message
import ./unacknowledged_message
import ./incoming_message
import ./repair_entry
export
  sds_message_id, sds_message, unacknowledged_message, incoming_message, repair_entry

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
    saveLamport*: proc(channelId: SdsChannelID, lamport: int64): Future[void] {.
      async: (raises: []), gcsafe
    .}

    # Local log (delivered messages)
    appendLogEntry*: proc(channelId: SdsChannelID, msg: SdsMessage): Future[void] {.
      async: (raises: []), gcsafe
    .}
    removeLogEntry*: proc(channelId: SdsChannelID, msgId: SdsMessageID): Future[void] {.
      async: (raises: []), gcsafe
    .}
    setRetrievalHint*: proc(msgId: SdsMessageID, hint: seq[byte]): Future[void] {.
      async: (raises: []), gcsafe
    .}

    # Outgoing unacknowledged buffer
    saveOutgoing*: proc(
      channelId: SdsChannelID, msg: UnacknowledgedMessage
    ): Future[void] {.async: (raises: []), gcsafe.}
    removeOutgoing*: proc(channelId: SdsChannelID, msgId: SdsMessageID): Future[void] {.
      async: (raises: []), gcsafe
    .}

    # Incoming dependency-waiting buffer
    saveIncoming*: proc(channelId: SdsChannelID, msg: IncomingMessage): Future[void] {.
      async: (raises: []), gcsafe
    .}
    removeIncoming*: proc(channelId: SdsChannelID, msgId: SdsMessageID): Future[void] {.
      async: (raises: []), gcsafe
    .}

    # SDS-R outgoing repair buffer
    saveOutgoingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID, entry: OutgoingRepairEntry
    ) {.async: (raises: []).}
    removeOutgoingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[void] {.async: (raises: []), gcsafe.}

    # SDS-R incoming repair buffer
    saveIncomingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID, entry: IncomingRepairEntry
    ) {.async: (raises: []).}
    removeIncomingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[void] {.async: (raises: []), gcsafe.}

    # Wipe all persisted state for a channel in one transactional call.
    # Called by removeChannel / resetReliabilityManager. Backends should
    # implement this atomically (e.g. one BEGIN/COMMIT) — a per-row loop on
    # the nim-sds side would mean N fsyncs per drop.
    dropChannel*:
      proc(channelId: SdsChannelID): Future[void] {.async: (raises: []), gcsafe.}

    # Bootstrap on `addChannel` / `getOrCreateChannel`.
    loadAllForChannel*: proc(channelId: SdsChannelID): Future[ChannelSnapshot] {.
      async: (raises: []), gcsafe
    .}

proc noOpPersistence*(): Persistence =
  ## Default backend that discards every write and returns an empty snapshot.
  ## Used so existing callers (and tests) that don't care about durability
  ## keep working without supplying a real backend.
  Persistence(
    saveLamport: proc(channelId: SdsChannelID, lamport: int64) {.async: (raises: []).} =
      discard,
    appendLogEntry: proc(
        channelId: SdsChannelID, msg: SdsMessage
    ) {.async: (raises: []).} =
      discard,
    removeLogEntry: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ) {.async: (raises: []).} =
      discard,
    setRetrievalHint: proc(
        msgId: SdsMessageID, hint: seq[byte]
    ) {.async: (raises: []).} =
      discard,
    saveOutgoing: proc(
        channelId: SdsChannelID, msg: UnacknowledgedMessage
    ) {.async: (raises: []).} =
      discard,
    removeOutgoing: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ) {.async: (raises: []).} =
      discard,
    saveIncoming: proc(
        channelId: SdsChannelID, msg: IncomingMessage
    ) {.async: (raises: []).} =
      discard,
    removeIncoming: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ) {.async: (raises: []).} =
      discard,
    saveOutgoingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: OutgoingRepairEntry
    ) {.async: (raises: []).} =
      discard,
    removeOutgoingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ) {.async: (raises: []).} =
      discard,
    saveIncomingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: IncomingRepairEntry
    ) {.async: (raises: []).} =
      discard,
    removeIncomingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ) {.async: (raises: []).} =
      discard,
    dropChannel: proc(channelId: SdsChannelID) {.async: (raises: []).} =
      discard,
    loadAllForChannel: proc(
        channelId: SdsChannelID
    ): Future[ChannelSnapshot] {.async: (raises: []).} =
      return ChannelSnapshot(),
  )

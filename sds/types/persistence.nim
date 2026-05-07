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

    # Per-channel lamport clock
    saveLamport*:
      proc(channelId: SdsChannelID, lamport: int64) {.gcsafe, raises: [].}

    # Local log (delivered messages)
    appendLogEntry*:
      proc(channelId: SdsChannelID, msg: SdsMessage) {.gcsafe, raises: [].}
    removeLogEntry*:
      proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].}
    setRetrievalHint*:
      proc(msgId: SdsMessageID, hint: seq[byte]) {.gcsafe, raises: [].}

    # Outgoing unacknowledged buffer
    saveOutgoing*:
      proc(channelId: SdsChannelID, msg: UnacknowledgedMessage) {.gcsafe, raises: [].}
    removeOutgoing*:
      proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].}

    # Incoming dependency-waiting buffer
    saveIncoming*:
      proc(channelId: SdsChannelID, msg: IncomingMessage) {.gcsafe, raises: [].}
    removeIncoming*:
      proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].}

    # SDS-R outgoing repair buffer
    saveOutgoingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID, entry: OutgoingRepairEntry
    ) {.gcsafe, raises: [].}
    removeOutgoingRepair*:
      proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].}

    # SDS-R incoming repair buffer
    saveIncomingRepair*: proc(
      channelId: SdsChannelID, msgId: SdsMessageID, entry: IncomingRepairEntry
    ) {.gcsafe, raises: [].}
    removeIncomingRepair*:
      proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].}

    # Wipe all persisted state for a channel in one transactional call.
    # Called by removeChannel / resetReliabilityManager. Backends should
    # implement this atomically (e.g. one BEGIN/COMMIT) — a per-row loop on
    # the nim-sds side would mean N fsyncs per drop.
    dropChannel*:
      proc(channelId: SdsChannelID) {.gcsafe, raises: [].}

    # Bootstrap on `addChannel` / `getOrCreateChannel`.
    loadAllForChannel*:
      proc(channelId: SdsChannelID): ChannelSnapshot {.gcsafe, raises: [].}

proc noOpPersistence*(): Persistence =
  ## Default backend that discards every write and returns an empty snapshot.
  ## Used so existing callers (and tests) that don't care about durability
  ## keep working without supplying a real backend.
  Persistence(
    saveLamport: proc(channelId: SdsChannelID, lamport: int64) =
      discard,
    appendLogEntry: proc(channelId: SdsChannelID, msg: SdsMessage) =
      discard,
    removeLogEntry: proc(channelId: SdsChannelID, msgId: SdsMessageID) =
      discard,
    setRetrievalHint: proc(msgId: SdsMessageID, hint: seq[byte]) =
      discard,
    saveOutgoing: proc(channelId: SdsChannelID, msg: UnacknowledgedMessage) =
      discard,
    removeOutgoing: proc(channelId: SdsChannelID, msgId: SdsMessageID) =
      discard,
    saveIncoming: proc(channelId: SdsChannelID, msg: IncomingMessage) =
      discard,
    removeIncoming: proc(channelId: SdsChannelID, msgId: SdsMessageID) =
      discard,
    saveOutgoingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: OutgoingRepairEntry
    ) =
      discard,
    removeOutgoingRepair: proc(channelId: SdsChannelID, msgId: SdsMessageID) =
      discard,
    saveIncomingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: IncomingRepairEntry
    ) =
      discard,
    removeIncomingRepair: proc(channelId: SdsChannelID, msgId: SdsMessageID) =
      discard,
    dropChannel: proc(channelId: SdsChannelID) =
      discard,
    loadAllForChannel: proc(channelId: SdsChannelID): ChannelSnapshot =
      ChannelSnapshot(),
  )

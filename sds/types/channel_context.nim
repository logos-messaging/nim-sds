import std/[sets, tables]
import ./sds_message_id
import ./sds_message
import ./rolling_bloom_filter
import ./unacknowledged_message
import ./incoming_message
import ./repair_entry
export
  sds_message_id, sds_message, rolling_bloom_filter, unacknowledged_message,
  incoming_message, repair_entry

type ChannelContext* = ref object
  lamportTimestamp*: int64
  messageHistory*: OrderedTable[SdsMessageID, SdsMessage]
    ## Single source of truth for delivered messages. Holds the deserialized
    ## SdsMessage (which carries senderId, lamportTimestamp, content, etc.) so
    ## causal history, sender lookup, and SDS-R repair responses can all be
    ## answered from one place. OrderedTable preserves insertion order for
    ## causal-history tail access and FIFO eviction at maxMessageHistory.
  bloomFilter*: RollingBloomFilter
  outgoingBuffer*: seq[UnacknowledgedMessage]
  incomingBuffer*: Table[SdsMessageID, IncomingMessage]
  ## SDS-R buffers
  outgoingRepairBuffer*: Table[SdsMessageID, OutgoingRepairEntry]
  incomingRepairBuffer*: Table[SdsMessageID, IncomingRepairEntry]
  ## R2 pending-write queue for history (see PLAN §8 + PR #72 review).
  ## When `updateHistory` fails, the failed (append, evict) batch is parked
  ## here and merged with the next op's batch on the next `tryUpdateHistory`
  ## call. Cleared on successful flush. NOT persisted — runtime-only state;
  ## on a crash the in-memory `messageHistory` is also lost and the next
  ## `loadChannel` brings whatever made it to disk.
  ##
  ## INVARIANT (relied on by the flush): every id in `pendingHistoryAppends`
  ## is also present in `messageHistory`. The full `SdsMessage` is NOT
  ## stored here — it is looked up from `messageHistory` at flush time.
  ## Storing only the id avoids the ~1 KB-per-entry duplication of
  ## SdsMessage that an OrderedTable would carry.
  pendingHistoryAppends*: OrderedSet[SdsMessageID]
    ## Pending appends, in insertion order so the on-disk log stays
    ## oldest-first across retries.
  pendingHistoryEvicts*: HashSet[SdsMessageID]
    ## Pending evictions. Set semantics — evicting the same id twice is a
    ## no-op.
    ##
    ## Merge rule with `pendingHistoryAppends`: **latest operation wins.**
    ## Queuing an append cancels any pending evict for the same id;
    ## queuing an evict cancels any pending append. This handles the
    ## "evict-then-re-add" sequence correctly (e.g. SDS-R repair
    ## re-delivers a message that was previously evicted while the
    ## backend was unreachable).

proc new*(T: type ChannelContext, bloomFilter: RollingBloomFilter): T =
  return T(
    lamportTimestamp: 0,
    messageHistory: initOrderedTable[SdsMessageID, SdsMessage](),
    bloomFilter: bloomFilter,
    outgoingBuffer: @[],
    incomingBuffer: initTable[SdsMessageID, IncomingMessage](),
    outgoingRepairBuffer: initTable[SdsMessageID, OutgoingRepairEntry](),
    incomingRepairBuffer: initTable[SdsMessageID, IncomingRepairEntry](),
    pendingHistoryAppends: initOrderedSet[SdsMessageID](),
    pendingHistoryEvicts: initHashSet[SdsMessageID](),
  )

## Atomic snapshot types for the per-channel protocol state.
##
## These types replace the fine-grained mutation operations of the original
## Persistence interface with a single self-contained blob per channel.
## See PLAN_SNAPSHOT_PERSISTENCE.md §1 for the rationale, §6 for the codec
## choice, §7 for size estimates.
##
## Bloom filter is intentionally absent — rebuilt from the message log on
## bootstrap. Message history is also absent — persisted separately via
## `HistoryUpdate` because it is large and append-mostly.

import ./sds_message_id
import ./sds_message
import ./unacknowledged_message
import ./incoming_message
import ./repair_entry
export
  sds_message_id, sds_message, unacknowledged_message, incoming_message,
  repair_entry

const ChannelMetaSchemaVersion* = 1'u32
  ## On-disk format version for ChannelMeta. Decoders MUST refuse to load a
  ## blob whose version they don't know how to interpret, rather than
  ## silently truncating or zero-filling unknown fields.

type
  OutgoingRepairKV* = object
    ## Flattened (key, value) entry from the in-memory
    ## `outgoingRepairBuffer: Table[SdsMessageID, OutgoingRepairEntry]`.
    ## Protobuf has no first-class map type in the minprotobuf subset we
    ## use; even proto3 `map<K,V>` is wire-encoded as repeated KV messages.
    ## Flattening to a `seq[KV]` makes that shape explicit.
    messageId*: SdsMessageID
    entry*: OutgoingRepairEntry

  IncomingRepairKV* = object
    ## Flattened (key, value) entry from
    ## `incomingRepairBuffer: Table[SdsMessageID, IncomingRepairEntry]`.
    messageId*: SdsMessageID
    entry*: IncomingRepairEntry

  ChannelMeta* = object
    ## Atomic snapshot of the fast-changing per-channel protocol state.
    ## Persisted as one blob per `saveChannelMeta` call. The `Table`-backed
    ## buffers in `ChannelContext` are flattened to `seq`s here for stable
    ## serialization and deterministic ordering on disk.
    schemaVersion*: uint32
    lamportTimestamp*: int64
    outgoingBuffer*: seq[UnacknowledgedMessage]
      ## Sent-but-not-yet-acked. Order matches insertion order in
      ## ChannelContext.outgoingBuffer; preserved on save/load.
    incomingBuffer*: seq[IncomingMessage]
      ## Received-but-not-yet-deliverable; key in memory is
      ## `message.messageId`, so no KV wrapper is needed.
    outgoingRepairBuffer*: seq[OutgoingRepairKV]
    incomingRepairBuffer*: seq[IncomingRepairKV]

  ChannelData* = object
    ## Returned by `loadChannel` on `getOrCreateChannel` bootstrap.
    ## Carries everything needed to rebuild the in-memory `ChannelContext`
    ## from a clean restart.
    meta*: ChannelMeta
    messageHistory*: seq[SdsMessage]
      ## MUST be ordered oldest-first (lamportTimestamp ASC, tie-break
      ## msg_id ASC). Bloom filter is rebuilt from this on load; FIFO
      ## eviction at maxMessageHistory relies on this ordering. Backend
      ## contract; the loader SHOULD validate.

proc init*(T: type ChannelMeta): T =
  ## Empty snapshot with current schema version. Used as the bootstrap
  ## payload when no on-disk state exists for a channel.
  T(
    schemaVersion: ChannelMetaSchemaVersion,
    lamportTimestamp: 0,
    outgoingBuffer: @[],
    incomingBuffer: @[],
    outgoingRepairBuffer: @[],
    incomingRepairBuffer: @[],
  )

proc init*(T: type ChannelData): T =
  T(meta: ChannelMeta.init(), messageHistory: @[])

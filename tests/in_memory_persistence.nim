import std/tables
import sds

## Test-only Persistence backend backed by Nim tables. Lets tests verify the
## full write → restart → read-back loop without depending on SQLite (or any
## real storage technology). Exposes the underlying store so tests can assert
## on what got saved.

type InMemoryStore* = ref object
  lamports*: Table[SdsChannelID, int64]
  log*: Table[SdsChannelID, OrderedTable[SdsMessageID, SdsMessage]]
  hints*: Table[SdsMessageID, seq[byte]]
  outgoing*: Table[SdsChannelID, OrderedTable[SdsMessageID, UnacknowledgedMessage]]
  incoming*: Table[SdsChannelID, OrderedTable[SdsMessageID, IncomingMessage]]
  outgoingRepair*: Table[SdsChannelID, OrderedTable[SdsMessageID, OutgoingRepairEntry]]
  incomingRepair*: Table[SdsChannelID, OrderedTable[SdsMessageID, IncomingRepairEntry]]
  dropChannelCalls*: Table[SdsChannelID, int]
    ## Per-channel counter; lets tests assert dropChannel is invoked exactly
    ## once per logical drop (not N times — see PR #66 review).

proc newInMemoryStore*(): InMemoryStore =
  InMemoryStore()

proc newInMemoryPersistence*(store: InMemoryStore): Persistence =
  Persistence(
    saveLamport: proc(channelId: SdsChannelID, lamport: int64) {.gcsafe, raises: [].} =
      store.lamports[channelId] = lamport,

    appendLogEntry: proc(channelId: SdsChannelID, msg: SdsMessage) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId notin store.log:
          store.log[channelId] = initOrderedTable[SdsMessageID, SdsMessage]()
        store.log[channelId][msg.messageId] = msg,

    removeLogEntry: proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId in store.log:
          store.log[channelId].del(msgId),

    setRetrievalHint: proc(msgId: SdsMessageID, hint: seq[byte]) {.gcsafe, raises: [].} =
      store.hints[msgId] = hint,

    saveOutgoing: proc(channelId: SdsChannelID, msg: UnacknowledgedMessage) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId notin store.outgoing:
          store.outgoing[channelId] =
            initOrderedTable[SdsMessageID, UnacknowledgedMessage]()
        store.outgoing[channelId][msg.message.messageId] = msg,

    removeOutgoing: proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId in store.outgoing:
          store.outgoing[channelId].del(msgId),

    saveIncoming: proc(channelId: SdsChannelID, msg: IncomingMessage) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId notin store.incoming:
          store.incoming[channelId] =
            initOrderedTable[SdsMessageID, IncomingMessage]()
        store.incoming[channelId][msg.message.messageId] = msg,

    removeIncoming: proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId in store.incoming:
          store.incoming[channelId].del(msgId),

    saveOutgoingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: OutgoingRepairEntry
    ) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId notin store.outgoingRepair:
          store.outgoingRepair[channelId] =
            initOrderedTable[SdsMessageID, OutgoingRepairEntry]()
        store.outgoingRepair[channelId][msgId] = entry,

    removeOutgoingRepair: proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId in store.outgoingRepair:
          store.outgoingRepair[channelId].del(msgId),

    saveIncomingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: IncomingRepairEntry
    ) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId notin store.incomingRepair:
          store.incomingRepair[channelId] =
            initOrderedTable[SdsMessageID, IncomingRepairEntry]()
        store.incomingRepair[channelId][msgId] = entry,

    removeIncomingRepair: proc(channelId: SdsChannelID, msgId: SdsMessageID) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        if channelId in store.incomingRepair:
          store.incomingRepair[channelId].del(msgId),

    dropChannel: proc(channelId: SdsChannelID) {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        store.lamports.del(channelId)
        store.log.del(channelId)
        store.outgoing.del(channelId)
        store.incoming.del(channelId)
        store.outgoingRepair.del(channelId)
        store.incomingRepair.del(channelId)
        store.dropChannelCalls[channelId] =
          store.dropChannelCalls.getOrDefault(channelId) + 1,

    loadAllForChannel: proc(channelId: SdsChannelID): ChannelSnapshot {.gcsafe, raises: [].} =
      {.cast(raises: []).}:
        var snap = ChannelSnapshot()
        if channelId in store.lamports:
          snap.lamportTimestamp = store.lamports[channelId]
        if channelId in store.log:
          for msg in store.log[channelId].values:
            snap.messageHistory.add(msg)
        if channelId in store.outgoing:
          for unack in store.outgoing[channelId].values:
            snap.outgoingBuffer.add(unack)
        if channelId in store.incoming:
          for incoming in store.incoming[channelId].values:
            snap.incomingBuffer.add(incoming)
        if channelId in store.outgoingRepair:
          for msgId, entry in store.outgoingRepair[channelId]:
            snap.outgoingRepairBuffer.add((msgId, entry))
        if channelId in store.incomingRepair:
          for msgId, entry in store.incomingRepair[channelId]:
            snap.incomingRepairBuffer.add((msgId, entry))
        snap,
  )

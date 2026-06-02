## Test-only Persistence backend backed by Nim tables. Adapts the
## snapshot-based `Persistence` interface onto a denormalised
## `InMemoryStore` shape so test assertions can inspect individual buffers
## (`store.outgoing`, `store.log`, etc.) directly. The adapter
## decomposes the meta blob on save and reconstructs it on load.
##
## `failingOps` injects backend failures. Op names match the `Persistence`
## field names: "saveChannelMeta", "updateHistory", "loadChannel",
## "dropChannel".

import std/[tables, sets]
import chronos
import sds

type InMemoryStore* = ref object
  lamports*: Table[SdsChannelID, int64]
  log*: Table[SdsChannelID, OrderedTable[SdsMessageID, SdsMessage]]
  outgoing*: Table[SdsChannelID, OrderedTable[SdsMessageID, UnacknowledgedMessage]]
  incoming*: Table[SdsChannelID, OrderedTable[SdsMessageID, IncomingMessage]]
  outgoingRepair*: Table[SdsChannelID, OrderedTable[SdsMessageID, OutgoingRepairEntry]]
  incomingRepair*: Table[SdsChannelID, OrderedTable[SdsMessageID, IncomingRepairEntry]]
  dropChannelCalls*: Table[SdsChannelID, int]
    ## Per-channel counter; lets tests assert dropChannel is invoked
    ## exactly once per logical drop.
  failingOps*: HashSet[string] ## Op names that should return an injected backend error.

proc newInMemoryStore*(): InMemoryStore =
  InMemoryStore(failingOps: initHashSet[string]())

proc newInMemoryPersistence*(store: InMemoryStore): Persistence =
  Persistence(
    saveChannelMeta: proc(
        channelId: SdsChannelID, meta: ChannelMeta
    ): Future[Result[void, string]] {.async: (raises: []).} =
      if "saveChannelMeta" in store.failingOps:
        return err("injected backend failure: saveChannelMeta")
      {.cast(raises: []).}:
        # Lamport.
        store.lamports[channelId] = meta.lamportTimestamp

        # Outgoing buffer — replace existing rows wholesale (snapshot is
        # the complete state, not a delta).
        store.outgoing[channelId] =
          initOrderedTable[SdsMessageID, UnacknowledgedMessage]()
        for u in meta.outgoingBuffer:
          store.outgoing[channelId][u.message.messageId] = u

        # Incoming buffer.
        store.incoming[channelId] = initOrderedTable[SdsMessageID, IncomingMessage]()
        for m in meta.incomingBuffer:
          store.incoming[channelId][m.message.messageId] = m

        # Repair buffers.
        store.outgoingRepair[channelId] =
          initOrderedTable[SdsMessageID, OutgoingRepairEntry]()
        for kv in meta.outgoingRepairBuffer:
          store.outgoingRepair[channelId][kv.messageId] = kv.entry
        store.incomingRepair[channelId] =
          initOrderedTable[SdsMessageID, IncomingRepairEntry]()
        for kv in meta.incomingRepairBuffer:
          store.incomingRepair[channelId][kv.messageId] = kv.entry
      ok(),
    updateHistory: proc(
        channelId: SdsChannelID, update: HistoryUpdate
    ): Future[Result[void, string]] {.async: (raises: []).} =
      if "updateHistory" in store.failingOps:
        return err("injected backend failure: updateHistory")
      {.cast(raises: []).}:
        if channelId notin store.log:
          store.log[channelId] = initOrderedTable[SdsMessageID, SdsMessage]()
        for m in update.append:
          store.log[channelId][m.messageId] = m
        for id in update.evict:
          store.log[channelId].del(id)
      ok(),
    loadChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[ChannelData, string]] {.async: (raises: []).} =
      if "loadChannel" in store.failingOps:
        return err("injected backend failure: loadChannel")
      {.cast(raises: []).}:
        var data = ChannelData.init()
        if channelId in store.lamports:
          data.meta.lamportTimestamp = store.lamports[channelId]
        if channelId in store.outgoing:
          for u in store.outgoing[channelId].values:
            data.meta.outgoingBuffer.add(u)
        if channelId in store.incoming:
          for m in store.incoming[channelId].values:
            data.meta.incomingBuffer.add(m)
        if channelId in store.outgoingRepair:
          for id, e in store.outgoingRepair[channelId].pairs:
            data.meta.outgoingRepairBuffer.add(
              OutgoingRepairKV(messageId: id, entry: e)
            )
        if channelId in store.incomingRepair:
          for id, e in store.incomingRepair[channelId].pairs:
            data.meta.incomingRepairBuffer.add(
              IncomingRepairKV(messageId: id, entry: e)
            )
        if channelId in store.log:
          for m in store.log[channelId].values:
            data.messageHistory.add(m)
        return ok(data),
    dropChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      if "dropChannel" in store.failingOps:
        return err("injected backend failure: dropChannel")
      {.cast(raises: []).}:
        store.lamports.del(channelId)
        store.log.del(channelId)
        store.outgoing.del(channelId)
        store.incoming.del(channelId)
        store.outgoingRepair.del(channelId)
        store.incomingRepair.del(channelId)
        store.dropChannelCalls[channelId] =
          store.dropChannelCalls.getOrDefault(channelId) + 1
      ok(),
  )

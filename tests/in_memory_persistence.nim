import std/[tables, sets]
import chronos
import sds

## Test-only Persistence backend backed by Nim tables. Lets tests verify the
## full write → restart → read-back loop without depending on SQLite (or any
## real storage technology). Exposes the underlying store so tests can assert
## on what got saved.
##
## `failingOps` injects backend failures: any op whose name is in the set
## returns `err(...)` instead of performing the operation, so tests can verify
## that nim-sds propagates the failure as `rePersistenceError`. Op names match
## the `Persistence` field names (e.g. "appendLogEntry", "loadAllForChannel").

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
  failingOps*: HashSet[string]
    ## Op names that should return an injected backend error. See module doc.

proc newInMemoryStore*(): InMemoryStore =
  InMemoryStore(failingOps: initHashSet[string]())

proc failInjected(store: InMemoryStore, op: string): Result[void, string] =
  ## Returns err(...) when `op` is registered in `failingOps`, ok() otherwise.
  if op in store.failingOps:
    return err("injected backend failure: " & op)
  ok()

proc newInMemoryPersistence*(store: InMemoryStore): Persistence =
  Persistence(
    saveLamport: proc(
        channelId: SdsChannelID, lamport: int64
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("saveLamport")
      store.lamports[channelId] = lamport
      ok(),
    appendLogEntry: proc(
        channelId: SdsChannelID, msg: SdsMessage
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("appendLogEntry")
      {.cast(raises: []).}:
        if channelId notin store.log:
          store.log[channelId] = initOrderedTable[SdsMessageID, SdsMessage]()
        store.log[channelId][msg.messageId] = msg
      ok(),
    removeLogEntry: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("removeLogEntry")
      {.cast(raises: []).}:
        if channelId in store.log:
          store.log[channelId].del(msgId)
      ok(),
    setRetrievalHint: proc(
        msgId: SdsMessageID, hint: seq[byte]
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("setRetrievalHint")
      store.hints[msgId] = hint
      ok(),
    saveOutgoing: proc(
        channelId: SdsChannelID, msg: UnacknowledgedMessage
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("saveOutgoing")
      {.cast(raises: []).}:
        if channelId notin store.outgoing:
          store.outgoing[channelId] =
            initOrderedTable[SdsMessageID, UnacknowledgedMessage]()
        store.outgoing[channelId][msg.message.messageId] = msg
      ok(),
    removeOutgoing: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("removeOutgoing")
      {.cast(raises: []).}:
        if channelId in store.outgoing:
          store.outgoing[channelId].del(msgId)
      ok(),
    saveIncoming: proc(
        channelId: SdsChannelID, msg: IncomingMessage
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("saveIncoming")
      {.cast(raises: []).}:
        if channelId notin store.incoming:
          store.incoming[channelId] = initOrderedTable[SdsMessageID, IncomingMessage]()
        store.incoming[channelId][msg.message.messageId] = msg
      ok(),
    removeIncoming: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("removeIncoming")
      {.cast(raises: []).}:
        if channelId in store.incoming:
          store.incoming[channelId].del(msgId)
      ok(),
    saveOutgoingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: OutgoingRepairEntry
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("saveOutgoingRepair")
      {.cast(raises: []).}:
        if channelId notin store.outgoingRepair:
          store.outgoingRepair[channelId] =
            initOrderedTable[SdsMessageID, OutgoingRepairEntry]()
        store.outgoingRepair[channelId][msgId] = entry
      ok(),
    removeOutgoingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("removeOutgoingRepair")
      {.cast(raises: []).}:
        if channelId in store.outgoingRepair:
          store.outgoingRepair[channelId].del(msgId)
      ok(),
    saveIncomingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID, entry: IncomingRepairEntry
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("saveIncomingRepair")
      {.cast(raises: []).}:
        if channelId notin store.incomingRepair:
          store.incomingRepair[channelId] =
            initOrderedTable[SdsMessageID, IncomingRepairEntry]()
        store.incomingRepair[channelId][msgId] = entry
      ok(),
    removeIncomingRepair: proc(
        channelId: SdsChannelID, msgId: SdsMessageID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("removeIncomingRepair")
      {.cast(raises: []).}:
        if channelId in store.incomingRepair:
          store.incomingRepair[channelId].del(msgId)
      ok(),
    dropChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ?store.failInjected("dropChannel")
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
    loadAllForChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[ChannelSnapshot, string]] {.async: (raises: []).} =
      if "loadAllForChannel" in store.failingOps:
        return err("injected backend failure: loadAllForChannel")
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
        return ok(snap),
  )

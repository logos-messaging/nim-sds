## Snapshot-based persistence interface (5 procs).
##
## This is the target interface for the refactor described in
## PLAN_SNAPSHOT_PERSISTENCE.md. It coexists with the legacy 13-proc
## `Persistence` (in `./persistence.nim`) during phase 2 of the refactor:
## protocol ops are migrated one at a time. Phase 3 deletes the old
## interface and renames `PersistenceV2` to `Persistence`.
##
## Why 5 procs instead of 13: every protocol op now issues at most ONE
## meta save + ONE history update at the end of the op, eliminating
## per-mutation persistence calls and the partial-write divergence they
## made unavoidable. See PLAN_SNAPSHOT_PERSISTENCE.md §2 and §8.

import chronos, results
import ./sds_message_id
import ./channel_meta
import ./history_update
export results, sds_message_id, channel_meta, history_update

type PersistenceV2* = object
  ## Snapshot-based persistence contract. Supplied at
  ## `newReliabilityManager` construction time. Each proc field is invoked
  ## by nim-sds AT MOST ONCE per protocol op, at the end of the op, under
  ## the channel lock.
  ##
  ## Atomicity expectation: nim-sds issues `saveChannelMeta` and (when
  ## non-empty) `updateHistory` back-to-back with NO intervening
  ## `await`-of-other-work. The backend MAY treat the pair as one
  ## transaction. The pair is keyed on the same `channelId`.
  ##
  ## Failure policy: a failed `saveChannelMeta` or `updateHistory` MUST NOT
  ## abort the protocol op. The next op's save is fully self-contained and
  ## will re-synchronise on-disk state. See PLAN §8.

  saveChannelMeta*: proc(
    channelId: SdsChannelID, meta: ChannelMeta
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    ## Persist the complete current per-channel snapshot. Idempotent: the
    ## blob is the full state, so a missed write is recovered by any later
    ## successful write.

  updateHistory*: proc(
    channelId: SdsChannelID, update: HistoryUpdate
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    ## Append newly-delivered messages and evict oldest ones past the
    ## maxMessageHistory cap. Callers SHOULD skip this call entirely when
    ## `update.isEmpty`.

  loadChannel*: proc(
    channelId: SdsChannelID
  ): Future[Result[ChannelData, string]] {.async: (raises: []), gcsafe.}
    ## Bootstrap on `getOrCreateChannel`. Returns the full prior state, or
    ## an empty `ChannelData` if the channel is new on disk.

  dropChannel*: proc(
    channelId: SdsChannelID
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    ## Wipe all persisted state for a channel. Called by `removeChannel` /
    ## `resetReliabilityManager`. Backends SHOULD execute atomically.

  setRetrievalHint*: proc(
    msgId: SdsMessageID, hint: seq[byte]
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
    ## Record a retrieval hint for a message id. Called from
    ## `getRecentHistoryEntries` when an application-supplied hint provider
    ## returns a non-empty hint. Out-of-band from the snapshot/history
    ## write path because hints are populated lazily during read.

proc noOpPersistenceV2*(): PersistenceV2 =
  ## Default backend: discards all writes, returns an empty snapshot on
  ## load. Used when no real backend is supplied (existing tests and
  ## non-durability-needing callers).
  PersistenceV2(
    saveChannelMeta: proc(
        channelId: SdsChannelID, meta: ChannelMeta
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    updateHistory: proc(
        channelId: SdsChannelID, update: HistoryUpdate
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    loadChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[ChannelData, string]] {.async: (raises: []).} =
      ok(ChannelData.init()),
    dropChannel: proc(
        channelId: SdsChannelID
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
    setRetrievalHint: proc(
        msgId: SdsMessageID, hint: seq[byte]
    ): Future[Result[void, string]] {.async: (raises: []).} =
      ok(),
  )

## Snapshot-based persistence interface (5 procs).
##
## Each protocol op issues AT MOST one `saveChannelMeta` and one
## `updateHistory` call at the end of the op, under the channel lock. The
## meta blob is the complete current per-channel state (lamport clock,
## outgoing/incoming buffers, SDS-R repair buffers); the history update
## carries (append, evict) for the message log. Bloom filter is rebuilt
## from history on bootstrap, never persisted.
##
## Atomicity expectation: nim-sds issues `saveChannelMeta` and (when
## non-empty) `updateHistory` back-to-back with NO intervening
## `await`-of-other-work. The backend MAY treat the pair as one
## transaction. The pair is keyed on the same `channelId`.
##
## Failure policy: a failed `saveChannelMeta` or `updateHistory` MUST NOT
## abort the protocol op. The next op's save is fully self-contained and
## will re-synchronise on-disk state. See PLAN_SNAPSHOT_PERSISTENCE.md §8.
## `loadChannel` and `dropChannel` DO surface errors — they're the
## durability-intent ops.

import chronos, results
import ./sds_message_id
import ./channel_meta
import ./history_update
export results, sds_message_id, channel_meta, history_update

type Persistence* = object
  ## Pluggable durability backend. Supplied at `newReliabilityManager`
  ## construction time; defaults to `noOpPersistence()` when not given.
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

  loadChannel*: proc(channelId: SdsChannelID): Future[Result[ChannelData, string]] {.
    async: (raises: []), gcsafe
  .}
    ## Bootstrap on `getOrCreateChannel`. Returns the full prior state, or
    ## an empty `ChannelData` if the channel is new on disk. Failure
    ## propagates to the caller — bootstrap is a durability-intent op.

  dropChannel*: proc(channelId: SdsChannelID): Future[Result[void, string]] {.
    async: (raises: []), gcsafe
  .}
    ## Wipe all persisted state for a channel. Called by `removeChannel` /
    ## `resetReliabilityManager`. Backends SHOULD execute atomically.
    ## Failure propagates to the caller — the caller asked us to confirm a
    ## disk wipe and we cannot silently lie.

proc noOpPersistence*(): Persistence =
  ## Default backend: discards all writes, returns an empty snapshot on
  ## load. Used when no real backend is supplied (existing tests and
  ## non-durability-needing callers).
  Persistence(
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
  )

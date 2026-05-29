import std/tables
import chronos
import ./sds_message_id
import ./history_entry
import ./callbacks
import ./reliability_config
import ./channel_context
import ./persistence
import ./persistence_v2
export
  sds_message_id, history_entry, callbacks, reliability_config, channel_context,
  persistence, persistence_v2

type ReliabilityManager* = ref object
  channels*: Table[SdsChannelID, ChannelContext]
  config*: ReliabilityConfig
  participantId*: SdsParticipantID
  persistence*: Persistence
    ## Legacy fine-grained persistence interface. Phase 1 of the refactor
    ## (see PLAN_SNAPSHOT_PERSISTENCE.md) keeps this alongside `persistenceV2`
    ## so protocol ops can be migrated one at a time.
  persistenceV2*: PersistenceV2
    ## Snapshot-based persistence interface. Defaults to a no-op when not
    ## supplied. During phase 2 of the refactor, individual protocol ops
    ## are migrated from `persistence.X` to `persistenceV2.X`.
  lock*: AsyncLock
    ## Single-threaded Chronos cooperative lock. Serializes mutators against
    ## one another at await points; the manager assumes all calls come from
    ## the same Chronos event loop (the FFI worker thread). Multi-OS-thread
    ## use is the caller's responsibility.
  periodicTasks*: seq[FutureBase]
    ## Handles to the background loops started by `startPeriodicTasks` so
    ## `cleanup` can cancel them on shutdown instead of leaking them.
  onMessageReady*: proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.}
  onMessageSent*: proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.}
  onMissingDependencies*: proc(
    messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.}
  onPeriodicSync*: PeriodicSyncCallback
  onRetrievalHint*: RetrievalHintProvider
  onRepairReady*: RepairReadyCallback

proc new*(
    T: type ReliabilityManager,
    participantId: SdsParticipantID,
    config: ReliabilityConfig,
    persistence: Persistence = noOpPersistence(),
    persistenceV2: PersistenceV2 = noOpPersistenceV2(),
): T =
  ## `participantId` is REQUIRED — it is the per-manager identity SDS-R uses
  ## to populate response groups and decide which incoming repair requests
  ## this manager is authoritative for. The Reliable Channel API spec
  ## (`senderId`) likewise lists it as required. An empty id silently
  ## disables SDS-R; callers that genuinely want plain SDS without repair
  ## must pass `""` explicitly.
  let rm = T(
    channels: initTable[SdsChannelID, ChannelContext](),
    config: config,
    participantId: participantId,
    persistence: persistence,
    persistenceV2: persistenceV2,
    lock: newAsyncLock(),
    periodicTasks: @[],
  )
  return rm

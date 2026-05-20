import std/tables
import chronos
import ./sds_message_id
import ./history_entry
import ./callbacks
import ./reliability_config
import ./channel_context
import ./persistence
export
  sds_message_id, history_entry, callbacks, reliability_config, channel_context,
  persistence

type ReliabilityManager* = ref object
  channels*: Table[SdsChannelID, ChannelContext]
  config*: ReliabilityConfig
  participantId*: SdsParticipantID
  persistence*: Persistence
    ## Pluggable durability backend; defaults to a no-op when not supplied.
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
    lock: newAsyncLock(),
    periodicTasks: @[],
  )
  return rm

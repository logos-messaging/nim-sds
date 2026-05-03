import std/[tables, locks]
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
  lock*: Lock
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
    config: ReliabilityConfig,
    participantId: SdsParticipantID = "".SdsParticipantID,
    persistence: Persistence = noOpPersistence(),
): T =
  let rm = T(
    channels: initTable[SdsChannelID, ChannelContext](),
    config: config,
    participantId: participantId,
    persistence: persistence,
  )
  rm.lock.initLock()
  return rm

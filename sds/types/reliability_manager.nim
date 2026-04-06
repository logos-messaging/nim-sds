import std/[tables, locks]
import ./sds_message_id
import ./history_entry
import ./callbacks
import ./reliability_config
import ./channel_context
export sds_message_id, history_entry, callbacks, reliability_config, channel_context

type ReliabilityManager* = ref object
  channels*: Table[SdsChannelID, ChannelContext]
  config*: ReliabilityConfig
  participantId*: SdsParticipantID
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
    participantId: SdsParticipantID = "",
): T =
  let rm = T(
    channels: initTable[SdsChannelID, ChannelContext](),
    config: config,
    participantId: participantId,
  )
  rm.lock.initLock()
  return rm

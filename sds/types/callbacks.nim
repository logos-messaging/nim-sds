import ./sds_message_id
import ./history_entry
export sds_message_id, history_entry

type
  MessageReadyCallback* =
    proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.}

  MessageSentCallback* =
    proc(messageId: SdsMessageID, channelId: SdsChannelID) {.gcsafe.}

  MissingDependenciesCallback* = proc(
    messageId: SdsMessageID, missingDeps: seq[HistoryEntry], channelId: SdsChannelID
  ) {.gcsafe.}

  RetrievalHintProvider* = proc(messageId: SdsMessageID): seq[byte] {.gcsafe.}

  PeriodicSyncCallback* = proc() {.gcsafe, raises: [].}

  RepairReadyCallback* = proc(message: seq[byte], channelId: SdsChannelID) {.gcsafe.}

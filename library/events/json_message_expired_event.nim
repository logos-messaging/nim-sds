import std/json
import ./json_base_event, sds/[message]

type JsonMessageExpiredEvent* = ref object of JsonEvent
  messageId*: SdsMessageID
  channelId*: SdsChannelID

proc new*(
    T: type JsonMessageExpiredEvent, messageId: SdsMessageID, channelId: SdsChannelID
): T =
  return JsonMessageExpiredEvent(
    eventType: "message_expired", messageId: messageId, channelId: channelId
  )

method `$`*(jsonMessageExpired: JsonMessageExpiredEvent): string {.raises: [].} =
  $(%*jsonMessageExpired)

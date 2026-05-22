import std/json
import ./json_base_event, sds/[message]

type JsonMessageSentEvent* = ref object of JsonEvent
  messageId*: SdsMessageID
  channelId*: SdsChannelID

proc new*(
    T: type JsonMessageSentEvent, messageId: SdsMessageID, channelId: SdsChannelID
): T =
  return JsonMessageSentEvent(
    eventType: "message_sent", messageId: messageId, channelId: channelId
  )

method `$`*(jsonMessageSent: JsonMessageSentEvent): string =
  $(%*jsonMessageSent)

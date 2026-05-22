import std/json
import ./json_base_event, sds/[message]

type JsonMessageReadyEvent* = ref object of JsonEvent
  messageId*: SdsMessageID
  channelId*: SdsChannelID

proc new*(
    T: type JsonMessageReadyEvent, messageId: SdsMessageID, channelId: SdsChannelID
): T =
  return JsonMessageReadyEvent(
    eventType: "message_ready", messageId: messageId, channelId: channelId
  )

method `$`*(jsonMessageReady: JsonMessageReadyEvent): string =
  $(%*jsonMessageReady)

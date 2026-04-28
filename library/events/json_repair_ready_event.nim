import std/[json, base64]
import ./json_base_event, sds/[message]

type JsonRepairReadyEvent* = ref object of JsonEvent
  channelId*: SdsChannelID
  message*: seq[byte]

proc new*(
    T: type JsonRepairReadyEvent, message: seq[byte], channelId: SdsChannelID
): T =
  return JsonRepairReadyEvent(
    eventType: "repair_ready", message: message, channelId: channelId
  )

method `$`*(jsonRepairReady: JsonRepairReadyEvent): string =
  var node = newJObject()
  node["eventType"] = %*jsonRepairReady.eventType
  node["channelId"] = %*jsonRepairReady.channelId
  node["message"] = %*encode(jsonRepairReady.message)
  $node

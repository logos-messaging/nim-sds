import std/[base64, json, jsonutils, options]
import sds

proc toJsonHook(event: TickEvent): JsonNode =
  result = newJObject()
  result["channelId"] = toJson(event.channelId)
  if event.error.isSome():
    result["error"] = toJson($event.error.get())
  else:
    result["payload"] = toJson(encode(event.payload))

proc toJsonHook(tick: TickResult): JsonNode =
  result = newJObject()
  result["events"] = toJson(tick.events)
  if tick.error.isSome():
    result["error"] = toJson($tick.error.get())

proc tickResponse*(tick: TickResult): string =
  $toJson(tick)

proc unwrapResponse*(
    message: Option[seq[byte]], missingDeps: seq[HistoryEntry], channelId: SdsChannelID
): string =
  var node = newJObject()
  node["message"] = if message.isSome(): %*encode(message.get()) else: newJNull()
  node["channelId"] = %*channelId
  var missingDepsNode = newJArray()
  for dep in missingDeps:
    var depNode = newJObject()
    depNode["messageId"] = %*dep.messageId
    depNode["retrievalHint"] = %*encode(dep.retrievalHint)
    missingDepsNode.add(depNode)
  node["missingDeps"] = missingDepsNode
  $node

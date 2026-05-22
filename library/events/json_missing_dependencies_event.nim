import std/json
import ./json_base_event, sds/[message], std/base64

type JsonMissingDependenciesEvent* = ref object of JsonEvent
  messageId*: SdsMessageID
  missingDeps*: seq[HistoryEntry]
  channelId*: SdsChannelID

proc new*(
    T: type JsonMissingDependenciesEvent,
    messageId: SdsMessageID,
    missingDeps: seq[HistoryEntry],
    channelId: SdsChannelID,
): T =
  return JsonMissingDependenciesEvent(
    eventType: "missing_dependencies",
    messageId: messageId,
    missingDeps: missingDeps,
    channelId: channelId,
  )

method `$`*(jsonMissingDependencies: JsonMissingDependenciesEvent): string =
  var node = newJObject()
  node["eventType"] = %*jsonMissingDependencies.eventType
  node["messageId"] = %*jsonMissingDependencies.messageId
  node["channelId"] = %*jsonMissingDependencies.channelId
  var missingDepsNode = newJArray()
  for dep in jsonMissingDependencies.missingDeps:
    var depNode = newJObject()
    depNode["messageId"] = %*dep.messageId
    depNode["retrievalHint"] = %*encode(dep.retrievalHint)
    missingDepsNode.add(depNode)
  node["missingDeps"] = missingDepsNode
  $node

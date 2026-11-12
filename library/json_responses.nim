import std/[base64, json, options]
import sds

proc tickResponse*(events: seq[TickEvent]): string =
  var node = newJArray()
  for event in events:
    var entry = newJObject()
    entry["channelId"] = %*event.channelId
    if event.error.isSome():
      entry["error"] = %*($event.error.get())
    else:
      entry["payload"] = %*encode(event.payload)
    node.add(entry)
  $node

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

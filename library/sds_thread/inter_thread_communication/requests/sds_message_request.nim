import std/[json, strutils, net, sequtils, base64]
import chronos, chronicles, results

import library/alloc
import sds

type SdsMessageMsgType* = enum
  WRAP_MESSAGE
  UNWRAP_MESSAGE

type SdsMessageRequest* = object
  operation: SdsMessageMsgType
  message: SharedSeq[byte]
  messageLen: csize_t
  messageId: cstring
  channelId: cstring

type SdsUnwrapResponse* = object
  message*: seq[byte]
  missingDeps*: seq[HistoryEntry]
  channelId*: string

proc createShared*(
    T: type SdsMessageRequest,
    op: SdsMessageMsgType,
    message: pointer,
    messageLen: csize_t = 0,
    messageId: cstring = "",
    channelId: cstring = "",
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].messageLen = messageLen
  ret[].messageId = messageId.alloc()
  ret[].channelId = channelId.alloc()
  ret[].message = allocSharedSeqFromCArray(cast[ptr byte](message), messageLen.int)

  return ret

proc destroyShared(self: ptr SdsMessageRequest) =
  deallocSharedSeq(self[].message)
  deallocShared(self[].messageId)
  deallocShared(self[].channelId)
  deallocShared(self)

proc process*(
    self: ptr SdsMessageRequest, rm: ptr ReliabilityManager
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of WRAP_MESSAGE:
    let messageBytes = self.message.toSeq()

    let wrappedMessage = (
      await wrapOutgoingMessage(rm[], messageBytes, $self.messageId, $self.channelId)
    ).valueOr:
      error "WRAP_MESSAGE failed", error = error
      return err("error processing WRAP_MESSAGE request: " & $error)

    # returns a comma-separates string of bytes
    return ok(wrappedMessage.mapIt($it).join(","))
  of UNWRAP_MESSAGE:
    let messageBytes = self.message.toSeq()

    let (unwrappedMessage, missingDeps, extractedChannelId) = (
      await unwrapReceivedMessage(rm[], messageBytes)
    ).valueOr:
      return err("error processing UNWRAP_MESSAGE request: " & $error)

    let res = SdsUnwrapResponse(
      message: unwrappedMessage, missingDeps: missingDeps, channelId: extractedChannelId
    )

    # return the result as a json string
    var node = newJObject()
    node["message"] = %*res.message
    node["channelId"] = %*extractedChannelId
    var missingDepsNode = newJArray()
    for dep in res.missingDeps:
      var depNode = newJObject()
      depNode["messageId"] = %*dep.messageId
      depNode["retrievalHint"] = %*encode(dep.retrievalHint)
      missingDepsNode.add(depNode)
    node["missingDeps"] = missingDepsNode
    return ok($node)

  return ok("")

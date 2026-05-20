import std/[json, strutils, net, sequtils]
import chronos, chronicles, results

import library/alloc
import sds

type SdsDependenciesMsgType* = enum
  MARK_DEPENDENCIES_MET

type SdsDependenciesRequest* = object
  operation: SdsDependenciesMsgType
  messageIds: SharedSeq[cstring]
  count: csize_t
  channelId: cstring

proc createShared*(
    T: type SdsDependenciesRequest,
    op: SdsDependenciesMsgType,
    messageIds: pointer,
    count: csize_t = 0,
    channelId: cstring = "",
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].count = count
  ret[].channelId = channelId.alloc()
  ret[].messageIds = allocSharedSeqFromCArray(cast[ptr cstring](messageIds), count.int)
  return ret

proc destroyShared(self: ptr SdsDependenciesRequest) =
  deallocSharedSeq(self[].messageIds)
  deallocShared(self[].channelId)
  deallocShared(self)

proc process*(
    self: ptr SdsDependenciesRequest, rm: ptr ReliabilityManager
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of MARK_DEPENDENCIES_MET:
    let messageIdsC = self.messageIds.toSeq()
    let messageIds = messageIdsC.mapIt($it)

    (await markDependenciesMet(rm[], messageIds, $self.channelId)).isOkOr:
      error "MARK_DEPENDENCIES_MET failed", error = error
      return err("error processing MARK_DEPENDENCIES_MET request: " & $error)

    return ok("")

  return ok("")

import std/times
import ./history_entry
export history_entry

type
  OutgoingRepairEntry* {.requiresInit.} = object
    ## Entry in the outgoing repair request buffer (SDS-R).
    ## Tracks a missing message we want to request repair for.
    outHistEntry*: HistoryEntry ## The missing history entry
    minTimeRepairReq*: Time
      ## Earliest time at which we will include this in a repair request (T_REQ in spec)

  IncomingRepairEntry* {.requiresInit.} = object
    ## Entry in the incoming repair request buffer (SDS-R).
    ## Tracks a repair request from a remote peer that we might respond to.
    inHistEntry*: HistoryEntry ## The requested history entry
    cachedMessage*: seq[byte] ## Full serialized SDS message for rebroadcast
    minTimeRepairResp*: Time
      ## Earliest time at which we will rebroadcast (T_RESP in spec)

proc init*(
    T: type OutgoingRepairEntry, outHistEntry: HistoryEntry, minTimeRepairReq: Time
): T =
  return T(outHistEntry: outHistEntry, minTimeRepairReq: minTimeRepairReq)

proc init*(
    T: type IncomingRepairEntry,
    inHistEntry: HistoryEntry,
    cachedMessage: seq[byte],
    minTimeRepairResp: Time,
): T =
  return T(
    inHistEntry: inHistEntry,
    cachedMessage: cachedMessage,
    minTimeRepairResp: minTimeRepairResp,
  )

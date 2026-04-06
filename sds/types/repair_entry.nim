import std/times
import ./history_entry
export history_entry

type
  OutgoingRepairEntry* = object
    ## Entry in the outgoing repair request buffer (SDS-R).
    ## Tracks a missing message we want to request repair for.
    entry*: HistoryEntry ## The missing history entry
    tReq*: Time ## Timestamp after which we will include this in a repair request

  IncomingRepairEntry* = object
    ## Entry in the incoming repair request buffer (SDS-R).
    ## Tracks a repair request from a remote peer that we might respond to.
    entry*: HistoryEntry ## The requested history entry
    cachedMessage*: seq[byte] ## Full serialized SDS message for rebroadcast
    tResp*: Time ## Timestamp after which we will rebroadcast

proc init*(T: type OutgoingRepairEntry, entry: HistoryEntry, tReq: Time): T =
  return T(entry: entry, tReq: tReq)

proc init*(
    T: type IncomingRepairEntry,
    entry: HistoryEntry,
    cachedMessage: seq[byte],
    tResp: Time,
): T =
  return T(entry: entry, cachedMessage: cachedMessage, tResp: tResp)

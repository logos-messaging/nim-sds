## Combined append/evict payload for the persistence message log.
##
## One protocol operation may deliver multiple messages in sequence (e.g.
## `unwrapReceivedMessage` followed by a `processIncomingBuffer` cascade
## that unblocks several buffered messages), and may also evict the oldest
## entries past `maxMessageHistory` in the same operation. Bundling all of
## those into a single `HistoryUpdate` lets the persistence backend execute
## the append + evict as one atomic batch alongside the matching
## `saveChannelMeta` call.

import ./sds_message_id
import ./sds_message
export sds_message_id, sds_message

type HistoryUpdate* = object
  ## When BOTH `append` and `evict` are empty, callers SHOULD skip the
  ## persistence call entirely. The Persistence interface treats an
  ## "empty" update as a no-op but the round-trip is not free.
  append*: seq[SdsMessage]
    ## New delivered messages, in delivery order. Order matters for the
    ## backend's append-only log; nim-sds preserves causal ordering when
    ## populating this list.
  evict*: seq[SdsMessageID]
    ## Oldest messages now past `maxMessageHistory`. Backend deletes by id.

proc init*(T: type HistoryUpdate): T =
  T(append: @[], evict: @[])

proc isEmpty*(u: HistoryUpdate): bool =
  u.append.len == 0 and u.evict.len == 0

import std/hashes

type
  SdsMessageID* = string
  SdsChannelID* = string
  SdsParticipantID* = distinct string

proc `==`*(a, b: SdsParticipantID): bool {.borrow.}
proc `$`*(p: SdsParticipantID): string {.borrow.}
proc len*(p: SdsParticipantID): int {.borrow.}
proc hash*(p: SdsParticipantID): Hash {.borrow.}

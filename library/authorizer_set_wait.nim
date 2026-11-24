import std/locks
import ffi/ret_codes

type AuthorizerSetWait* = object
  lock*: Lock
  cond*: Cond
  completed*: bool
  result*: cint

proc authorizerSetComplete*(
    callerRet: cint, msg: ptr cchar, len: csize_t, userData: pointer
) {.cdecl, gcsafe, raises: [].} =
  if userData.isNil():
    return
  if callerRet == RET_STALE_WARN:
    return
  let state = cast[ptr AuthorizerSetWait](userData)
  acquire(state.lock)
  state.result = callerRet
  state.completed = true
  signal(state.cond)
  release(state.lock)

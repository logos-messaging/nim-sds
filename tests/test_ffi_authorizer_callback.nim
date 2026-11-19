import std/[locks, unittest]
import ffi/ret_codes
import ../library/authorizer_set_wait

suite "Authorizer FFI callback":
  test "stale warnings do not complete the setter wait":
    var state: AuthorizerSetWait
    initLock(state.lock)
    initCond(state.cond)
    defer:
      deinitCond(state.cond)
      deinitLock(state.lock)

    authorizerSetComplete(RET_STALE_WARN, nil, 0, addr state)
    check not state.completed

    authorizerSetComplete(RET_ERR, nil, 0, addr state)
    check state.completed
    check state.result == RET_ERR

## Shared async-aware wrappers around `unittest` so tests in this repo can
## `await` directly in setup/test/teardown blocks instead of sprinkling
## `waitFor` at each call site.
##
## Usage:
##
## ```nim
## import ./async_unittest
##
## suite "X":
##   var rm: ReliabilityManager
##
##   asyncSetup:
##     rm = newReliabilityManager(...).get()
##     check (await rm.ensureChannel("ch")).isOk()
##
##   asyncTeardown:
##     if not rm.isNil:
##       await rm.cleanup()
##
##   asyncTest "Y":
##     await rm.wrapOutgoingMessage(...)
## ```
##
## All three blocks run inside the same async proc (per test). unittest's
## own `setup:`/`teardown:` still work for purely synchronous fixtures.

import unittest, chronos
export unittest, chronos

template asyncSetup*(body: untyped) {.dirty.} =
  ## Async counterpart to unittest's `setup:`. Runs inside each asyncTest's
  ## async proc, so `await` works.
  template asyncTestSetupIMPL(): untyped {.dirty.} =
    body

template asyncTeardown*(body: untyped) {.dirty.} =
  ## Async counterpart to unittest's `teardown:`. Runs in a `finally` so it
  ## executes even when the test body (or setup) raises.
  template asyncTestTeardownIMPL(): untyped {.dirty.} =
    body

template asyncTest*(name: string, body: untyped) =
  ## Wraps a unittest `test` body in an async proc so `await` works on the
  ## now-async ReliabilityManager API. unittest's `check` raises Exception,
  ## which is wider than chronos's default CatchableError; the exception is
  ## caught inside the async body, stashed, and re-raised after waitFor so
  ## unittest's normal failure handling sees it.
  ##
  ## `cast(gcsafe)` is needed because suite-level vars (e.g. `var rm`) look
  ## like globals to the async closure, but the FFI runtime is single-thread
  ## so the "not gcsafe" warning isn't a real hazard here.
  test name:
    var asyncTestErr {.inject.}: ref Exception = nil
    proc inner() {.async.} =
      {.cast(gcsafe).}:
        try:
          when declared(asyncTestSetupIMPL):
            asyncTestSetupIMPL()
          try:
            body
          finally:
            when declared(asyncTestTeardownIMPL):
              asyncTestTeardownIMPL()
        except Exception as e:
          asyncTestErr = e

    waitFor inner()
    if asyncTestErr != nil:
      raise asyncTestErr

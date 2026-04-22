import std/times

const
  DefaultMaxMessageHistory* = 1000
  DefaultMaxCausalHistory* = 10
  DefaultResendInterval* = initDuration(seconds = 60)
  DefaultMaxResendAttempts* = 5
  DefaultSyncMessageInterval* = initDuration(seconds = 30)
  DefaultBufferSweepInterval* = initDuration(seconds = 60)
  MaxMessageSize* = 1024 * 1024 # 1 MB

import ./rolling_bloom_filter
export rolling_bloom_filter

type ReliabilityConfig* {.requiresInit.} = object
  bloomFilterCapacity*: int
  bloomFilterErrorRate*: float
  maxMessageHistory*: int
  maxCausalHistory*: int
  resendInterval*: Duration
  maxResendAttempts*: int
  syncMessageInterval*: Duration
  bufferSweepInterval*: Duration

proc init*(
    T: type ReliabilityConfig,
    bloomFilterCapacity: int = DefaultBloomFilterCapacity,
    bloomFilterErrorRate: float = DefaultBloomFilterErrorRate,
    maxMessageHistory: int = DefaultMaxMessageHistory,
    maxCausalHistory: int = DefaultMaxCausalHistory,
    resendInterval: Duration = DefaultResendInterval,
    maxResendAttempts: int = DefaultMaxResendAttempts,
    syncMessageInterval: Duration = DefaultSyncMessageInterval,
    bufferSweepInterval: Duration = DefaultBufferSweepInterval,
): T =
  T(
    bloomFilterCapacity: bloomFilterCapacity,
    bloomFilterErrorRate: bloomFilterErrorRate,
    maxMessageHistory: maxMessageHistory,
    maxCausalHistory: maxCausalHistory,
    resendInterval: resendInterval,
    maxResendAttempts: maxResendAttempts,
    syncMessageInterval: syncMessageInterval,
    bufferSweepInterval: bufferSweepInterval,
  )

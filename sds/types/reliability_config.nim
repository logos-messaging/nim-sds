import std/times

const
  DefaultMaxMessageHistory* = 1000
  DefaultMaxCausalHistory* = 10
  DefaultResendInterval* = initDuration(seconds = 60)
  DefaultMaxResendAttempts* = 5
  DefaultSyncMessageInterval* = initDuration(seconds = 30)
  DefaultBufferSweepInterval* = initDuration(seconds = 60)
  DefaultRepairTMin* = initDuration(seconds = 30)
  DefaultRepairTMax* = initDuration(seconds = 300)
  DefaultNumResponseGroups* = 1
  DefaultMaxRepairRequests* = 3
  DefaultRepairSweepInterval* = initDuration(seconds = 5)
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
  ## SDS-R config
  repairTMin*: Duration
  repairTMax*: Duration
  numResponseGroups*: int
  maxRepairRequests*: int
  repairSweepInterval*: Duration

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
    repairTMin: Duration = DefaultRepairTMin,
    repairTMax: Duration = DefaultRepairTMax,
    numResponseGroups: int = DefaultNumResponseGroups,
    maxRepairRequests: int = DefaultMaxRepairRequests,
    repairSweepInterval: Duration = DefaultRepairSweepInterval,
): T =
  return T(
    bloomFilterCapacity: bloomFilterCapacity,
    bloomFilterErrorRate: bloomFilterErrorRate,
    maxMessageHistory: maxMessageHistory,
    maxCausalHistory: maxCausalHistory,
    resendInterval: resendInterval,
    maxResendAttempts: maxResendAttempts,
    syncMessageInterval: syncMessageInterval,
    bufferSweepInterval: bufferSweepInterval,
    repairTMin: repairTMin,
    repairTMax: repairTMax,
    numResponseGroups: numResponseGroups,
    maxRepairRequests: maxRepairRequests,
    repairSweepInterval: repairSweepInterval,
  )

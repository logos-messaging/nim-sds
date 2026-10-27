import std/times
import chronicles

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
  # Bloom is rebuilt by replaying messageHistory on restart and is also the
  # outgoing summary peers see. A bloom smaller than the log causes continuous
  # clean() churn and incomplete summaries to peers, with no compensating gain.
  if maxMessageHistory > bloomFilterCapacity:
    warn "maxMessageHistory > bloomFilterCapacity will cause continuous bloom rebuilds and incomplete summaries to peers; reduce maxMessageHistory or increase bloomFilterCapacity unless you have a specific reason",
      maxMessageHistory = maxMessageHistory, bloomFilterCapacity = bloomFilterCapacity
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

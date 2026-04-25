## JSON parser for ReliabilityConfig — used by the FFI constructor
## SdsNewReliabilityManagerWithConfig.
##
## Schema: a JSON object where every field is optional. Missing fields fall
## back to the Default* constants in sds/types/reliability_config.nim.
## Duration fields use the suffix "Ms" and are integer milliseconds.
##
## Empty input ("" or NULL on the C side) returns the default config.

import std/[json, times]
import results
import sds/types/reliability_config

proc getJsonInt(node: JsonNode, key: string, default: int): int =
  if node.hasKey(key) and node[key].kind == JInt:
    return node[key].getInt()
  return default

proc getJsonFloat(node: JsonNode, key: string, default: float): float =
  if not node.hasKey(key):
    return default
  case node[key].kind
  of JFloat: node[key].getFloat()
  of JInt: node[key].getInt().float
  else: default

proc getJsonDurationMs(
    node: JsonNode, key: string, default: Duration
): Duration =
  if node.hasKey(key) and node[key].kind == JInt:
    return initDuration(milliseconds = node[key].getInt())
  return default

proc parseReliabilityConfig*(
    jsonStr: string
): Result[ReliabilityConfig, string] =
  ## Parses a JSON string into a ReliabilityConfig. Empty input returns the
  ## default config. Unknown keys are ignored. Type-mismatched values fall
  ## back to defaults rather than failing.
  if jsonStr.len == 0:
    return ok(ReliabilityConfig.init())

  var node: JsonNode
  try:
    node = parseJson(jsonStr)
  except JsonParsingError, ValueError, Exception:
    return err("invalid JSON: " & getCurrentExceptionMsg())

  if node.isNil or node.kind != JObject:
    return err("config must be a JSON object")

  ok(
    ReliabilityConfig.init(
      bloomFilterCapacity =
        getJsonInt(node, "bloomFilterCapacity", DefaultBloomFilterCapacity),
      bloomFilterErrorRate =
        getJsonFloat(node, "bloomFilterErrorRate", DefaultBloomFilterErrorRate),
      maxMessageHistory =
        getJsonInt(node, "maxMessageHistory", DefaultMaxMessageHistory),
      maxCausalHistory =
        getJsonInt(node, "maxCausalHistory", DefaultMaxCausalHistory),
      resendInterval =
        getJsonDurationMs(node, "resendIntervalMs", DefaultResendInterval),
      maxResendAttempts =
        getJsonInt(node, "maxResendAttempts", DefaultMaxResendAttempts),
      syncMessageInterval = getJsonDurationMs(
        node, "syncMessageIntervalMs", DefaultSyncMessageInterval
      ),
      bufferSweepInterval = getJsonDurationMs(
        node, "bufferSweepIntervalMs", DefaultBufferSweepInterval
      ),
      repairTMin = getJsonDurationMs(node, "repairTMinMs", DefaultRepairTMin),
      repairTMax = getJsonDurationMs(node, "repairTMaxMs", DefaultRepairTMax),
      numResponseGroups =
        getJsonInt(node, "numResponseGroups", DefaultNumResponseGroups),
      maxRepairRequests =
        getJsonInt(node, "maxRepairRequests", DefaultMaxRepairRequests),
      repairSweepInterval = getJsonDurationMs(
        node, "repairSweepIntervalMs", DefaultRepairSweepInterval
      ),
    )
  )

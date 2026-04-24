import chronos
import chronicles
import ./bloom
import ./types/rolling_bloom_filter
export rolling_bloom_filter

proc init*(
    T: type RollingBloomFilter,
    capacity: int = DefaultBloomFilterCapacity,
    errorRate: float = DefaultBloomFilterErrorRate,
): T {.gcsafe.} =
  let targetCapacity = if capacity <= 0: DefaultBloomFilterCapacity else: capacity
  let targetError =
    if errorRate <= 0.0 or errorRate >= 1.0: DefaultBloomFilterErrorRate else: errorRate

  let filterResult = initializeBloomFilter(targetCapacity, targetError)
  if filterResult.isErr:
    error "Failed to initialize bloom filter", error = filterResult.error
    if capacity != DefaultBloomFilterCapacity or errorRate != DefaultBloomFilterErrorRate:
      let defaultResult =
        initializeBloomFilter(DefaultBloomFilterCapacity, DefaultBloomFilterErrorRate)
      if defaultResult.isErr:
        error "Failed to initialize bloom filter with default parameters",
          error = defaultResult.error

      let minCapacity = (
        DefaultBloomFilterCapacity.float * (100 - CapacityFlexPercent).float / 100.0
      ).int
      let maxCapacity = (
        DefaultBloomFilterCapacity.float * (100 + CapacityFlexPercent).float / 100.0
      ).int

      info "Successfully initialized bloom filter with default parameters",
        capacity = DefaultBloomFilterCapacity,
        minCapacity = minCapacity,
        maxCapacity = maxCapacity

      return RollingBloomFilter.init(
        filter = defaultResult.get(),
        capacity = DefaultBloomFilterCapacity,
        minCapacity = minCapacity,
        maxCapacity = maxCapacity,
      )
    else:
      error "Could not create bloom filter", error = filterResult.error

  let minCapacity =
    (targetCapacity.float * (100 - CapacityFlexPercent).float / 100.0).int
  let maxCapacity =
    (targetCapacity.float * (100 + CapacityFlexPercent).float / 100.0).int

  info "Successfully initialized bloom filter",
    capacity = targetCapacity, minCapacity = minCapacity, maxCapacity = maxCapacity

  return RollingBloomFilter.init(
    filter = filterResult.get(),
    capacity = targetCapacity,
    minCapacity = minCapacity,
    maxCapacity = maxCapacity,
  )

proc clean*(rbf: var RollingBloomFilter) {.gcsafe.} =
  try:
    if rbf.messages.len <= rbf.maxCapacity:
      return # Don't clean unless we exceed max capacity

    # Initialize new filter
    var newFilter = initializeBloomFilter(rbf.maxCapacity, rbf.filter.errorRate).valueOr:
      error "Failed to create new bloom filter", error = $error
      return

    # Keep most recent messages up to minCapacity
    let keepCount = rbf.minCapacity
    let startIdx = max(0, rbf.messages.len - keepCount)
    var newMessages: seq[SdsMessageID] = @[]

    for i in startIdx ..< rbf.messages.len:
      newMessages.add(rbf.messages[i])
      newFilter.insert(cast[string](rbf.messages[i]))

    rbf.messages = newMessages
    rbf.filter = newFilter
  except Exception:
    error "Failed to clean bloom filter", error = getCurrentExceptionMsg()

proc add*(rbf: var RollingBloomFilter, messageId: SdsMessageID) {.gcsafe.} =
  ## Adds a message ID to the rolling bloom filter.
  rbf.filter.insert(cast[string](messageId))
  rbf.messages.add(messageId)

  if rbf.messages.len > rbf.maxCapacity:
    rbf.clean()

proc contains*(rbf: RollingBloomFilter, messageId: SdsMessageID): bool =
  ## Checks if a message ID is in the rolling bloom filter.
  return rbf.filter.lookup(cast[string](messageId))

from math import ceil, ln, pow, round
import hashes
import strutils
import results
import private/probabilities
import ./types/bloom_filter
export bloom_filter

{.push overflowChecks: off.} # Turn off overflow checks for hashing operations

proc hashN(item: string, n: int, maxValue: int): int =
  ## Get the nth hash using Nim's built-in hash function using
  ## the double hashing technique from Kirsch and Mitzenmacher, 2008:
  ## http://www.eecs.harvard.edu/~kirsch/pubs/bbbf/rsa.pdf
  let
    hashA = abs(hash(item)) mod maxValue # Use abs to handle negative hashes
    hashB = abs(hash(item & " b")) mod maxValue # string concatenation
  abs((hashA + n * hashB)) mod maxValue

{.pop.}

proc getMOverNBitsForK*(
    k: int, targetError: float, probabilityTable = kErrors
): Result[int, string] =
  ## Returns the optimal number of m/n bits for a given k.
  if k notin 0 .. 12:
    return err("K must be <= 12 if forceNBitsPerElem is not also specified.")

  for mOverN in 2 .. probabilityTable[k].high:
    if probabilityTable[k][mOverN] < targetError:
      return ok(mOverN)

  err(
    "Specified value of k and error rate not achievable using less than 4 bytes / element."
  )

proc initializeBloomFilter*(
    capacity: int, errorRate: float, k = 0, forceNBitsPerElem = 0
): Result[BloomFilter, string] =
  ## Initializes a Bloom filter with specified parameters.
  ##
  ## Parameters:
  ## - capacity: Expected number of elements to be inserted
  ## - errorRate: Desired false positive rate (e.g., 0.01 for 1%)
  ## - k: Optional number of hash functions. If 0, calculated optimally
  ## See http://pages.cs.wisc.edu/~cao/papers/summary-cache/node8.html for
  ## useful tables on k and m/n (n bits per element) combinations.
  ## - forceNBitsPerElem: Optional override for bits per element
  var
    kHashes: int
    nBitsPerElem: int

  if k < 1: # Calculate optimal k and use that
    let bitsPerElem = ceil(-1.0 * (ln(errorRate) / (pow(ln(2.float), 2))))
    kHashes = round(ln(2.float) * bitsPerElem).int
    nBitsPerElem = round(bitsPerElem).int
  else: # Use specified k if possible
    if forceNBitsPerElem < 1: # Use lookup table
      let mOverNRes = getMOverNBitsForK(k = k, targetError = errorRate)
      if mOverNRes.isErr:
        return err(mOverNRes.error)
      nBitsPerElem = mOverNRes.value
    else:
      nBitsPerElem = forceNBitsPerElem
    kHashes = k

  let
    mBits = capacity * nBitsPerElem
    mInts = 1 + mBits div (sizeof(int) * 8)

  ok(
    BloomFilter.init(
      capacity = capacity,
      errorRate = errorRate,
      kHashes = kHashes,
      mBits = mBits,
      intArray = newSeq[int](mInts),
    )
  )

proc `$`*(bf: BloomFilter): string =
  ## Prints the configuration of the Bloom filter.
  "Bloom filter with $1 capacity, $2 error rate, $3 hash functions, and requiring $4 bits of memory." %
  [
    $bf.capacity,
    formatFloat(bf.errorRate, format = ffScientific, precision = 1),
    $bf.kHashes,
    $(bf.mBits div bf.capacity),
  ]

proc computeHashes(bf: BloomFilter, item: string): seq[int] =
  var hashes = newSeq[int](bf.kHashes)
  for i in 0 ..< bf.kHashes:
    hashes[i] = hashN(item, i, bf.mBits)
  hashes

proc insert*(bf: var BloomFilter, item: string) =
  ## Insert an item (string) into the Bloom filter.
  let hashSet = bf.computeHashes(item)
  for h in hashSet:
    let
      intAddress = h div (sizeof(int) * 8)
      bitOffset = h mod (sizeof(int) * 8)
    bf.intArray[intAddress] = bf.intArray[intAddress] or (1 shl bitOffset)

proc lookup*(bf: BloomFilter, item: string): bool =
  ## Lookup an item (string) in the Bloom filter.
  ## If the item is present, ``lookup`` is guaranteed to return ``true``.
  ## If the item is not present, ``lookup`` will return ``false``
  ## with a probability 1 - ``bf.errorRate``.
  let hashSet = bf.computeHashes(item)
  for h in hashSet:
    let
      intAddress = h div (sizeof(int) * 8)
      bitOffset = h mod (sizeof(int) * 8)
      currentInt = bf.intArray[intAddress]
    if currentInt != (currentInt or (1 shl bitOffset)):
      return false
  true

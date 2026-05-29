# SDS Snapshot Persistence — Design & Refactor Plan

Companion to `ANALYSIS_SDS_PERSISTENCE.md` (problem statement) and
`ANALYSIS_SNAPSHOT_SAVE_POINTS.md` (where & how often we save).

This document defines:
1. **Data structures** to be persisted (snapshot + history)
2. **New `Persistence` interface** (5 procs replacing the current 13)
3. **Refactor plan** — phased, test-gated, backward-compatible interim state

---

## 1. Data Structure Design

### 1.1 Design principles

| Principle | Reason |
|-----------|--------|
| Snapshot is **one atomic blob** | Eliminates partial-write divergence (the root cause from ANALYSIS_SDS_PERSISTENCE.md §4) |
| Snapshot is **small** (buffers only, no history) | Keeps per-op write cost ≤ a few KB; foldable into one SQLite txn |
| History is **separate, append-batched** | Large data, append-mostly, queryable by msg_id for SDS-R |
| Bloom filter is **not persisted** | Already the case — rebuilt from history on bootstrap |
| **Versioned wire format** | Allow future schema evolution without breaking on-disk data |
| **Protobuf** serialization | Project already uses it (`sds/protobuf.nim`); keeps one codec |

### 1.2 `ChannelMeta` — the snapshot payload

```nim
# sds/types/channel_meta.nim  (new file)

import std/[tables, times]
import ./sds_message_id
import ./unacknowledged_message
import ./incoming_message
import ./repair_entry
export
  sds_message_id, unacknowledged_message, incoming_message, repair_entry

const ChannelMetaSchemaVersion* = 1'u32

type ChannelMeta* = object
  ## Atomic snapshot of the fast-changing per-channel protocol state.
  ## Persisted as one blob per `saveChannelMeta` call. Bloom filter is
  ## intentionally absent — rebuilt from the message log on bootstrap.
  ## Message history is also absent — persisted separately via `updateHistory`
  ## because it is large and append-mostly.
  schemaVersion*: uint32
    ## On-disk format version. Backends MUST refuse to load a meta whose
    ## version they don't know how to decode rather than silently truncating
    ## or zero-filling unknown fields.

  lamportTimestamp*: int64

  outgoingBuffer*: seq[UnacknowledgedMessage]
    ## Sent-but-not-yet-acked messages. Order matters: the protocol iterates
    ## in insertion order for resend-attempt accounting.

  incomingBuffer*: seq[IncomingMessage]
    ## Received-but-not-yet-deliverable messages, each carrying its
    ## still-missing dependency set. Order is irrelevant; flattened from
    ## the in-memory `Table` for wire-friendliness.

  outgoingRepairBuffer*: seq[OutgoingRepairKV]
  incomingRepairBuffer*: seq[IncomingRepairKV]
    ## SDS-R repair buffers, flattened from in-memory `Table` to seq of
    ## (key, value) for stable serialization.

type
  OutgoingRepairKV* = object
    messageId*: SdsMessageID
    entry*: OutgoingRepairEntry

  IncomingRepairKV* = object
    messageId*: SdsMessageID
    entry*: IncomingRepairEntry
```

**Why flatten the `Table`s to `seq`s?**
Protobuf has no native map of `SdsMessageID → object`. Flattening to `seq` of KV
objects gives deterministic encoding and trivial decode-time rebuild of the
in-memory `Table`. The cost is one extra alloc per entry on encode/decode —
negligible vs. the I/O it replaces.

**Why an explicit `schemaVersion`?**
The current interface has no version field. Adding fields later (e.g., a new
SDS-R counter) silently truncates old data on load. The version makes
incompatibility explicit; backends fail loud instead of corrupting state.

### 1.3 `HistoryAppend` — the history-write payload

```nim
# extension to sds/types/persistence.nim or new history_update.nim

type HistoryUpdate* = object
  ## Combined append/evict for one protocol operation. Empty `append` and
  ## empty `evict` ⇒ caller should skip the call entirely.
  append*: seq[SdsMessage]
    ## New delivered messages, in delivery order (matters for SDS-R retrieval
    ## hint correctness and FIFO eviction on the backend side).
  evict*: seq[SdsMessageID]
    ## Oldest messages now past `maxMessageHistory`. Backend deletes by id.
```

`append` is a `seq` (not a single `SdsMessage`) because `processIncomingBuffer`
can deliver a chain of unblocked messages in one call to the parent op
(`unwrapReceivedMessage` / `markDependenciesMet`). Sending them all in one
`updateHistory` call keeps the "one save per protocol op" guarantee.

### 1.4 `ChannelData` — the bootstrap payload

```nim
type ChannelData* = object
  ## Returned by `loadChannel` on `getOrCreateChannel` bootstrap.
  ## Carries everything needed to rebuild the in-memory `ChannelContext`
  ## from a clean restart.
  meta*: ChannelMeta
  messageHistory*: seq[SdsMessage]
    ## MUST be ordered oldest-first (lamportTimestamp ASC, tie-break msg_id
    ## ASC). Bloom filter is rebuilt from this on load; FIFO eviction relies
    ## on this ordering. Backend contract; validated by nim-sds on load.
```

### 1.5 Storage encoding (internal to nim-sds — not the SDS network wire format)

**Disambiguation.** The SDS **network** wire format (bytes peers exchange) is
handled by the existing `sds/protobuf.nim` and is untouched by this plan.
What this section defines is the **storage** encoding: the codec nim-sds uses
to turn a `ChannelMeta` Nim object into the opaque `seq[byte]` blob it hands
to `saveChannelMeta`. The KV persistence worker treats that blob as
fully opaque — it stores `(key: bytes) → (value: bytes)` and does its own
buffering/batching of writes. Whether nim-sds uses protobuf, CBOR, or
anything else is invisible to the worker.

**Why this codec exists at all.** The worker stores bytes; something must
produce those bytes from the in-memory `ChannelMeta`. That responsibility
sits inside nim-sds, on the producer side of the persistence boundary. It
runs synchronously inside `saveChannelMeta`, before the blob crosses to the
worker.

**Choice: protobuf, reusing the existing toolchain.**
- `sds/protobuf.nim` is already a dependency and already encodes `SdsMessage`
- Field-number versioning composes naturally with the explicit `schemaVersion`
- Encoders for the new types compose on top of the existing `SdsMessage` one
  — no new codec to maintain

**Encoders to add:**
- `UnacknowledgedMessage` (wraps `SdsMessage` + `sendTime: int64` unix-ms + `resendAttempts: uint32`)
- `IncomingMessage` (wraps `SdsMessage` + `missingDeps: repeated bytes`)
- `OutgoingRepairEntry` / `IncomingRepairEntry` (HistoryEntry + Time + optional cachedMessage)
- `OutgoingRepairKV` / `IncomingRepairKV` (msgId + entry — flattened map; see §6)
- `ChannelMeta` (top-level)

`Time` is serialized as `int64` unix milliseconds. The wall-clock semantics
are already used by the protocol itself (`getTime()` in `wrapOutgoingMessage`).

**On durability.** Because the worker buffers blobs, `saveChannelMeta`
returning `ok()` means "the blob was accepted by the worker," not "the blob
is fsynced." That is the worker's contract to manage. nim-sds's own
invariant — one snapshot save per protocol op, after all in-memory mutation
completes — is satisfied as soon as the worker accepts the blob, because
on recovery the worker replays its own buffer in order, so the snapshot
nim-sds last issued is the snapshot nim-sds will see on next `loadChannel`.

---

## 2. New `Persistence` Interface

Replace the current 13 procs in `sds/types/persistence.nim` with **5**:

```nim
type Persistence* = object
  saveChannelMeta*: proc(
    channelId: SdsChannelID, meta: ChannelMeta
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}

  updateHistory*: proc(
    channelId: SdsChannelID, update: HistoryUpdate
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}

  loadChannel*: proc(
    channelId: SdsChannelID
  ): Future[Result[ChannelData, string]] {.async: (raises: []), gcsafe.}

  dropChannel*: proc(
    channelId: SdsChannelID
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}

  setRetrievalHint*: proc(
    msgId: SdsMessageID, hint: seq[byte]
  ): Future[Result[void, string]] {.async: (raises: []), gcsafe.}
```

### Atomicity contract (documented in the interface comment)

> Backends SHOULD execute `saveChannelMeta` and the immediately following
> `updateHistory` call within a single transaction when both arrive together
> from the same protocol op. nim-sds always issues them back-to-back under
> the channel lock, with no `await`-of-other-work in between, so the backend
> can either (a) buffer `saveChannelMeta` until the next `updateHistory` or
> `flush`, or (b) use a `txn(channelId)` handle. Variant (b) is cleaner; see
> §3.2 for the optional `beginTxn`/`commitTxn` extension.

### Backend assumption: schema-agnostic KV blob store

The target backend is the existing schema-agnostic KV persistence module in
the sibling repo. It stores opaque `(key: bytes) → (value: bytes)` blobs with
its own crash-consistency guarantees. Therefore:

- nim-sds owns the wire format end-to-end (no SQL schema to coordinate)
- The "single transaction per op" requirement reduces to "two KV puts per
  op": `meta:<channelId>` and `history:<channelId>:<msgId>` (one or more)
- The backend's existing batch/atomicity primitives are what guarantee
  crash consistency — nim-sds doesn't need transaction-handle plumbing

---

## 3. Refactor Plan

### Phase 0 — Pre-work (no behavior change)

| Step | File(s) | Verify |
|------|---------|--------|
| 0.1 Add `ChannelMeta`, `HistoryUpdate`, `ChannelData` types | new `sds/types/channel_meta.nim`, `sds/types/history_update.nim` | `nimble c sds.nim` compiles |
| 0.2 Add protobuf encoders/decoders for new types | extend `sds/protobuf.nim` | round-trip unit tests |
| 0.3 Add `tests/test_snapshot_codec.nim` | new test file | `nimble test` passes; covers empty, single-entry, full-buffer, repair-heavy cases |

### Phase 1 — New interface alongside old

| Step | File(s) | Verify |
|------|---------|--------|
| 1.1 Add new 5-proc `Persistence` type as `PersistenceV2` (rename later) | `sds/types/persistence.nim` | compiles; old interface still works |
| 1.2 Add `noOpPersistenceV2()` for tests | same | `nimble test` passes |
| 1.3 Add `ReliabilityManager.persistenceV2` field, optional | `sds/types/reliability_manager.nim` | one of `persistence` / `persistenceV2` is in use; assert at construction |

### Phase 2 — Migrate protocol ops, one at a time

For each op, the pattern is:
1. Add a `dirty: bool` local accumulator
2. Replace inner `await rm.persistence.X` calls with in-memory mutation + set `dirty = true`
3. At the end of the op (under lock, before `return`), emit at most one `saveChannelMeta` and at most one `updateHistory` call

Order (least risky → highest risk):

| Step | Op | File:line | Verify |
|------|-----|-----------|--------|
| 2.1 | `runRepairSweep` | sds.nim:510 | repair sweep unit test, with failure injection |
| 2.2 | `checkUnacknowledgedMessages` | sds.nim:445 | resend-flow integration test |
| 2.3 | `processIncomingBuffer` → pure (no persistence) | sds.nim:176 | callers will persist; covered by 2.4/2.5 |
| 2.4 | `reviewAckStatus` → pure (no persistence) | sds.nim:36 | covered by 2.5 |
| 2.5 | `unwrapReceivedMessage` | sds.nim:235 | full receive-path tests (paths A/B/C); duplicate early-return must skip save |
| 2.6 | `wrapOutgoingMessage` | sds.nim:87 | send-path tests |
| 2.7 | `markDependenciesMet` | sds.nim:378 | dep-resolution tests |
| 2.8 | `addToHistory` → return appended/evicted lists instead of persisting | sds_utils.nim:81 | covered by 2.5/2.6/2.7 |
| 2.9 | `updateLamportTimestamp` → pure (no persistence) | sds_utils.nim:108 | covered |
| 2.10 | `getOrCreateChannel` use `loadChannel` | sds_utils.nim:289 | bootstrap unit test |
| 2.11 | `removeChannel`, `resetReliabilityManager` → `dropChannel` | sds_utils.nim, sds.nim | wipe tests |

Each step is a small commit. After every step: `nimble test` + `gitnexus_detect_changes` to confirm scope.

### Phase 3 — Remove the old interface

| Step | File(s) | Verify |
|------|---------|--------|
| 3.1 Delete old 13-proc `Persistence` fields | `sds/types/persistence.nim` | compile fails on stragglers — fix |
| 3.2 Rename `PersistenceV2` → `Persistence` | all call sites | full test suite |
| 3.3 Delete `noOpPersistence` (old), keep `noOpPersistenceV2` as `noOpPersistence` | same | tests pass |
| 3.4 Update `library/` FFI thread to construct the new `Persistence` | `library/sds_thread/...` | FFI smoke test on macOS + Linux |
| 3.5 Update `Broker_FFI_API.md` and any docs referencing the old contract | docs | review |

### Phase 4 — (removed)

A reference backend is **not** part of this plan. The schema-agnostic KV
persistence module in the sibling repo is the production backend. Its
authors own the integration adapter that maps the 5 `Persistence` procs onto
KV puts/gets. nim-sds only needs to expose the interface and a working
`noOpPersistence` for its own tests.

---

## 4. Risk Mitigation During Refactor

| Risk | Mitigation |
|------|------------|
| Mid-refactor inconsistency (some ops on new interface, some on old) | Phase 2 keeps both interfaces wired — only one is active per RM via a constructor switch; integration tests run against both |
| Behavior change masked by passing tests | Add `tests/test_persistence_contract.nim` that asserts exact call count per protocol op (before vs after must match the table in `ANALYSIS_SNAPSHOT_SAVE_POINTS.md`) |
| Memory-first mutation pattern preserved by accident | Move *all* persistence calls to the end of the op, after the lock-held mutation block completes. The dirty flag is set *during* mutation; the save fires *after*. If save fails, the in-memory state is still the source of truth for the next op — but now there's only one possible point of divergence per op, not 10. |
| FFI thread breakage | Phase 3.4 is the FFI cutover; smoke test on both `--mm:refc` and `--mm:orc`, macOS and Linux, before declaring done. ASAN run on the FFI example. |
| Snapshot blob growth surprises | Add a `len()` log on `saveChannelMeta` for the first week of integration; fail-loud if any blob exceeds (configurable) 1 MB |

---

## 5. Acceptance Criteria

- [ ] All existing `nimble test` cases pass against the new interface
- [ ] New `tests/test_persistence_contract.nim` enforces exactly the call counts from `ANALYSIS_SNAPSHOT_SAVE_POINTS.md` §"Save Points" table
- [ ] New `tests/test_snapshot_codec.nim` round-trips every `ChannelMeta` variant
- [ ] Failure-injection test: kill persistence between `saveChannelMeta` and `updateHistory` → on restart, the manager loads a self-consistent snapshot (no orphan history entries; no dangling buffer references)
- [ ] FFI smoke (`liblogosdelivery`-style) runs clean on macOS+refc, macOS+orc, Linux+refc, Linux+orc
- [ ] `Broker_FFI_API.md` reflects the new contract
- [ ] Bench: snapshot save rate matches the predicted `S + R` (foreground) and ≤ 0.2/s/channel background floor (with dirty-guard) under a synthetic 50-msg/s workload
- [ ] Snapshot blob size on the bench workload matches the estimate in §7 within 2×; outliers logged

---

## 6. Codec & flattening — where protobuf comes in

### Codec choice

The KV backend stores opaque blobs. The codec that produces the blob is
**internal to nim-sds**. Protobuf is the natural choice because:

- The project already uses protobuf for the SDS wire format
  (`sds/protobuf.nim` encodes `SdsMessage`). One codec, one toolchain.
- Field-number versioning gives forward/backward compatibility for free —
  pairs naturally with the `schemaVersion` field.
- Repeated message fields encode efficiently and round-trip cleanly.

Concretely: `ChannelMeta` is a top-level protobuf message; `saveChannelMeta`
serializes it to `seq[byte]` and the backend writes that under
`meta:<channelId>`. On load, the backend returns the bytes; nim-sds
deserializes.

### Why flatten `Table[Id, Entry]` to `seq[KV]`

Protobuf's wire format has no first-class "map of bytes-key → message-value"
type in the minimal subset used by `sds/protobuf.nim` (the
`nim-libp2p`-style `minprotobuf`). Even the full proto3 `map<K, V>` is
encoded on the wire as **repeated KV messages anyway** — the map syntax is
just sugar over `repeated Entry { key = 1; value = 2; }`.

So flattening is making the wire shape explicit:

```
ChannelMeta {
  ...
  repeated OutgoingRepairKV outgoingRepairBuffer = 5;
  repeated IncomingRepairKV incomingRepairBuffer = 6;
}

OutgoingRepairKV {
  bytes messageId = 1;
  OutgoingRepairEntry entry = 2;
}
```

The `Table` exists only in memory; the wire and disk form is the flat seq.
Decode rebuilds the `Table` by iterating the seq. Cost: one alloc per entry
on encode/decode — negligible against the I/O it replaces.

`outgoingBuffer` (already a `seq`) and `incomingBuffer` (a `Table` flattened
to `seq[IncomingMessage]` — the key is `message.messageId` so no separate KV
wrapper is needed) follow the same logic.

---

## 7. Snapshot size estimates

Assumptions (call out — every number below derives from these):

| Quantity | Assumed bytes | Source |
|----------|---------------|--------|
| `SdsMessageID` | 32 | typical content-addressed id |
| `SdsParticipantID` | 32 | same |
| `SdsChannelID` | 32 | same |
| `bloomFilter` (serialized, in an `SdsMessage`) | 256 | derived from default `bloomFilterCapacity` × `errorRate` |
| `causalHistory` | 10 entries × ~40 B | `maxCausalHistory = 10` from `reliability_config.nim` |
| `repairRequest` in a wire SdsMessage | up to 3 × ~40 B | `maxRepairRequests = 3` |
| Application payload (`content`) — small | 100 B | typical short chat payload |
| Application payload — medium | 1 KB | richer payload |
| Protobuf framing | ~10% overhead | tag bytes + varints |

**One `SdsMessage` on the wire (no content):** ~700 B
**One `SdsMessage` with 100 B content:** ~800 B
**One `SdsMessage` with 1 KB content:** ~1.7 KB

Per-entry sizes inside `ChannelMeta`:

| Entry | Size (100 B payload) | Size (1 KB payload) | Notes |
|-------|----------------------|---------------------|-------|
| `UnacknowledgedMessage` | ~820 B | ~1.7 KB | SdsMessage + sendTime + resendAttempts |
| `IncomingMessage` | ~950 B | ~1.9 KB | SdsMessage + missingDeps (avg 3 × 32 B) |
| `OutgoingRepairKV` | ~110 B | ~110 B | no cached message, payload-independent |
| `IncomingRepairKV` | ~920 B | ~1.8 KB | **cached serialized SdsMessage dominates** |

Fixed overhead per `ChannelMeta`: ~30 B (schemaVersion + lamportTimestamp + framing).

### Per-channel snapshot size by load

| Profile | outBuf | inBuf | outRepair | inRepair | Size (100 B payload) | Size (1 KB payload) |
|---------|--------|-------|-----------|----------|----------------------|---------------------|
| Idle | 0 | 0 | 0 | 0 | **~30 B** | ~30 B |
| Light chat | 2 | 0 | 0 | 0 | **~1.7 KB** | ~3.5 KB |
| Steady | 5 | 1 | 1 | 1 | **~6 KB** | ~12 KB |
| Busy | 10 | 3 | 3 | 3 | **~14 KB** | ~28 KB |
| Heavy, lossy network (SDS-R churning) | 30 | 10 | 20 | 10 | **~45 KB** | ~95 KB |
| Pathological (resend window full, big repair caches) | 50 | 20 | 30 | 20 | **~75 KB** | ~155 KB |

### Where the bytes go

| Load profile | Dominant contributor |
|--------------|----------------------|
| Idle / light | Fixed overhead + outgoingBuffer |
| Steady / busy | outgoingBuffer (each entry ~1 KB+) |
| Heavy / lossy | **incomingRepairBuffer** — each KV entry caches a full serialized message for rebroadcast. This is the single biggest amplifier; 20 entries with 1 KB payloads ≈ 36 KB on their own. |

### Implications

1. **Typical write is small (1–30 KB).** Comfortably foldable into the
   per-op KV write cost; the backend's blob-write cost is bounded.
2. **`IncomingRepairEntry.cachedMessage` is the size lever to watch.**
   Under heavy SDS-R activity it dominates the snapshot. If snapshot size
   becomes a bottleneck, the optimization is to drop the cache from the
   snapshot and re-serialize from `messageHistory` on demand — at the cost
   of more CPU and the corner case where the requested message has been
   evicted from history between snapshot save and repair sweep firing.
3. **Heavy profile (~95 KB) at the predicted 6/s/ch save rate = ~570 KB/s
   per channel.** A 10-channel heavy node is then ~5.7 MB/s of snapshot
   churn — well within KV backend throughput, but worth a real bench
   before declaring it OK.
4. **The 1 MB hard cap** suggested in §4 stays appropriate; pathological
   profile at 1 KB payload is ~155 KB, leaving healthy headroom.

---

## 8. Persistence failure policy — non-fatal, best-effort

**Change from current branch.** The current implementation treats every
`rePersistenceError` as fatal: the protocol op returns `err()`, the caller
sees a failure, and normal SDS operation breaks even though the in-memory
state is fine. This is wrong for the snapshot model.

**New policy.**
- In-memory state is the **source of truth** for protocol correctness.
  Lamport clock, buffers, history, bloom filter — all live in
  `ChannelContext` and are mutated under the lock before any persistence
  call. SDS message processing never depends on disk state for correctness
  within a session.
- Persistence is **best-effort durability**. A failed `saveChannelMeta` or
  `updateHistory` does **not** abort the operation, does not return `err`
  to the FFI caller, and does not corrupt protocol semantics. The next op
  will issue its own snapshot — if that succeeds, on-disk state is
  re-synchronised; if it also fails, the one after that tries again.
- Snapshot writes are **idempotent and self-contained.** Each
  `saveChannelMeta` blob is the complete current `ChannelMeta`. A missed
  write is fully recovered by any later successful write — no log of
  deltas to replay, no compensating action needed.
- Bootstrap loss tolerance: if `loadChannel` fails or returns stale state
  on restart, the manager starts from whatever it could load (possibly
  empty). Peer traffic and SDS-R repair will re-populate it. This is the
  expected behaviour of the bloom-rebuilt-from-history design extended to
  the meta blob.

**Implementation pattern.** At each save point:

```nim
# end of wrapOutgoingMessage / unwrapReceivedMessage / etc.
if dirty:
  let saveRes = await rm.persistence.saveChannelMeta(channelId, snapshot)
  if saveRes.isErr:
    warn "snapshot save failed; in-memory state unaffected, next op will retry",
      channelId = channelId, detail = saveRes.error
    # DO NOT return err; protocol op succeeded.
if appended.len > 0 or evicted.len > 0:
  let histRes = await rm.persistence.updateHistory(channelId,
                  HistoryUpdate(append: appended, evict: evicted))
  if histRes.isErr:
    warn "history update failed; in-memory log authoritative, next op will retry",
      channelId = channelId, detail = histRes.error
return ok(serializedMessage)  # protocol op succeeded regardless
```

**What still returns `err(rePersistenceError)`.** Only operations whose
**semantic intent** is durability:
- `removeChannel`, `resetReliabilityManager` → must confirm `dropChannel`
  succeeded; otherwise the caller may assume disk is clean when it isn't.
- `getOrCreateChannel` on first bootstrap → if `loadChannel` errors (vs.
  returns empty), surface it so the caller can decide between "start
  fresh in memory" and "abort init".

**Impact on §5 acceptance criteria.** Add: failure-injection test must
prove that `wrapOutgoingMessage`, `unwrapReceivedMessage`,
`markDependenciesMet`, `checkUnacknowledgedMessages`, `runRepairSweep` all
return `ok` under 100%-failing persistence, with correct in-memory
behaviour and a recovered on-disk state after persistence is restored.

**Why this is safe.** Each snapshot is a full self-contained blob;
partial-write divergence (the original ANALYSIS §4 critical risk) is
already eliminated by the atomic-blob design. Once that's true, treating
persistence failure as fatal is pure downside — it propagates a
recoverable I/O hiccup into a user-visible protocol failure for no
correctness gain.

---

## 9. What this plan deliberately does NOT do

- Does not add transaction handles — the KV backend's batch primitive is sufficient
- Does not ship a reference backend — the schema-agnostic KV module in the sibling repo is the production backend
- Does not change the bloom filter persistence policy (still rebuilt from history)
- Does not introduce SDS-R repair extension changes
- Does not touch the FFI surface shape beyond construction of `Persistence` — the existing C API is unchanged
- Does not auto-migrate on-disk data from an older format (no production data exists yet; schemaVersion=1 starts clean)

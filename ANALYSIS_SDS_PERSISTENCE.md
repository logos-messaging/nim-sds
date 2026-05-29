# SDS Workflow & Persistence Layer — Honest Analysis

## 1. Architecture Overview

The SDS protocol lives in two layers:

| Layer | Files | Responsibility |
|-------|-------|---------------|
| **Core types + helpers** | `sds/sds_utils.nim`, `sds/types/*.nim` | State types, Lamport clock, history management, bloom filter, dependency checking |
| **Protocol orchestration** | `sds.nim` (root module) | `wrapOutgoingMessage`, `unwrapReceivedMessage`, `markDependenciesMet`, periodic tasks |

The `Persistence` interface (`sds/types/persistence.nim`) is a struct of 13 async proc fields. It is injected at `newReliabilityManager` construction time. Default: `noOpPersistence()` — discards all writes, returns empty snapshots.

## 2. SDS Workflow (excluding `library/`)

### Send path (`sds.nim:87–174` — `wrapOutgoingMessage`)

```
acquire lock
  → getOrCreateChannel (loads from persistence if first time)
  → updateLamportTimestamp → saveLamport
  → serialize bloom filter
  → collect expired SDS-R repair requests → removeOutgoingRepair (per entry)
  → build causal history → setRetrievalHint (per entry, if hint provider set)
  → construct SdsMessage
  → add to outgoingBuffer → saveOutgoing
  → add to bloom filter (memory only)
  → addToHistory → appendLogEntry + removeLogEntry (eviction)
  → serialize → return bytes
release lock
```

**Persistence calls per send**: 3–5+ depending on repair buffer and history eviction.

### Receive path (`sds.nim:235–376` — `unwrapReceivedMessage`)

```
extractChannelId + deserialize
getOrCreateChannel (may loadAllForChannel)
→ cleanup repair buffers: removeOutgoingRepair, removeIncomingRepair
→ duplicate check (return early if in history)
→ add to bloom filter (memory only)
→ updateLamportTimestamp → saveLamport
→ reviewAckStatus → removeOutgoing (per acked message)
→ process SDS-R repair requests → removeOutgoingRepair + saveIncomingRepair (per entry)
→ check dependencies:
    - all met, no buffer deps: addToHistory → appendLogEntry; unblock buffered → saveIncoming per; processIncomingBuffer
    - all met, but deps in buffer: saveIncoming
    - missing deps: saveIncoming; create SDS-R outgoing entries → saveOutgoingRepair per
return
```

**Persistence calls per receive**: 4–15+ depending on repair entries, ack status, and dependency resolution depth.

### Background tasks (`sds.nim:487–571`)

| Task | Interval | Persistence calls |
|------|----------|-------------------|
| `periodicBufferSweep` | `bufferSweepInterval` | `saveOutgoing` or `removeOutgoing` per resend/expiry |
| `periodicSyncMessage` | `syncMessageInterval` | None (callback only) |
| `periodicRepairSweep` | `repairSweepInterval` | `removeIncomingRepair`, `removeOutgoingRepair` per expired entry |

Background tasks **discard** persistence errors (`discard await rm.runRepairSweep()` at line 568, `discard await rm.checkUnacknowledgedMessages(channelId)` at line 494).

### Bootstrap (`sds/sds_utils.nim:289–322` — `getOrCreateChannel`)

```
loadAllForChannel → ChannelSnapshot
  → populate lamportTimestamp
  → populate messageHistory + rebuild bloom filter from it
  → populate outgoingBuffer, incomingBuffer
  → populate outgoingRepairBuffer, incomingRepairBuffer
```

**Bloom filter is never persisted** — rebuilt from message history. This is documented and intentional.

## 3. Persistence Interface Shape (SQLite Backend Perspective)

The 13 operations map naturally to SQLite tables:

| Operation | SQLite analogue |
|-----------|----------------|
| `saveLamport` | `UPSERT INTO lamport_clocks (channel_id, ts)` |
| `appendLogEntry` | `INSERT INTO message_log (channel_id, msg_id, blob)` |
| `removeLogEntry` | `DELETE FROM message_log WHERE msg_id = ?` |
| `setRetrievalHint` | `UPDATE message_log SET hint = ? WHERE msg_id = ?` |
| `saveOutgoing` | `UPSERT INTO outgoing_buffer (channel_id, msg_id, blob)` |
| `removeOutgoing` | `DELETE FROM outgoing_buffer WHERE msg_id = ?` |
| `saveIncoming` | `UPSERT INTO incoming_buffer (channel_id, msg_id, blob)` |
| `removeIncoming` | `DELETE FROM incoming_buffer WHERE msg_id = ?` |
| `saveOutgoingRepair` | `UPSERT INTO outgoing_repair (channel_id, msg_id, blob)` |
| `removeOutgoingRepair` | `DELETE FROM outgoing_repair WHERE msg_id = ?` |
| `saveIncomingRepair` | `UPSERT INTO incoming_repair (channel_id, msg_id, blob)` |
| `removeIncomingRepair` | `DELETE FROM incoming_repair WHERE msg_id = ?` |
| `dropChannel` | `DELETE FROM * WHERE channel_id = ?` (all tables) |
| `loadAllForChannel` | `SELECT * FROM * WHERE channel_id = ?` (all tables) |

Minimum schema: 5 tables (lamport_clocks, message_log, outgoing_buffer, incoming_buffer, repair_entries with a direction column — or 6 if outgoing/incoming repair are separated).

---

## 4. Risk Analysis

### CRITICAL — No Transactional Atomicity Across Persistence Calls

**Risk level: HIGH**

Every protocol operation makes **multiple independent persistence calls**. Example from `unwrapReceivedMessage`:

```
removeOutgoingRepair   ← succeeds
removeIncomingRepair   ← succeeds
saveLamport            ← succeeds
removeOutgoing         ← succeeds
appendLogEntry         ← FAILS
```

If `appendLogEntry` fails mid-way, the in-memory state has already been mutated (bloom filter updated, buffers modified, Lamport clock advanced). The function returns `err()` to the caller, but:

1. **In-memory state is now ahead of disk state.** The message is in the bloom filter and history in memory but not on disk.
2. **On restart, the snapshot will be stale.** `loadAllForChannel` rebuilds from disk — the message won't be in history, bloom filter will be rebuilt without it, but other nodes may already consider it delivered.
3. **There is no rollback of prior successful persistence calls.** The Lamport clock is already persisted at the new value, repair buffer entries are already deleted.

**Impact**: After a crash following a partial persistence failure, the node's state diverges from what peers believe. Causal ordering assumptions break. Duplicate delivery or permanent buffering of dependent messages becomes possible.

**Mitigation for a SQLite backend**: Wrap all persistence calls within a single protocol operation in one `BEGIN … COMMIT` transaction. The current interface design (individual proc fields) makes this structurally impossible — there's no transaction boundary concept.

### HIGH — In-Memory Mutation Before Persistence Confirmation

**Risk level: HIGH**

Throughout the codebase, the pattern is:

```nim
# mutate in-memory state
channel.outgoingRepairBuffer.del(msg.messageId)       # memory mutated
# then persist
(await rm.persistence.removeOutgoingRepair(...)).isOkOr:
  return err(...)                                       # too late to undo memory
```

This appears in `unwrapReceivedMessage` (lines 256–261), `wrapOutgoingMessage` (lines 131–133), `reviewAckStatus` (lines 77–81), and throughout `processIncomingBuffer`.

If persistence fails, the function returns an error, but the in-memory state has already been modified. The caller cannot retry because the state is now inconsistent.

**Exception**: `addToHistory` (sds_utils.nim:91–92) correctly mutates memory first then persists, but on failure, the memory mutation is **not rolled back**.

### HIGH — Background Tasks Silently Swallow Persistence Errors

**Risk level: MEDIUM-HIGH**

```nim
# sds.nim:494
discard await rm.checkUnacknowledgedMessages(channelId)

# sds.nim:568
discard await rm.runRepairSweep()
```

`checkUnacknowledgedMessages` modifies `channel.outgoingBuffer` (line 478: `channel.outgoingBuffer = newOutgoingBuffer`) and persists entries. If persistence fails partway through, the in-memory buffer has already been rewritten. The `discard` means the error isn't even visible to any caller.

The comment says "next tick retries" — but next tick operates on the already-mutated in-memory state, not the stale disk state. After a restart, disk state wins and the divergence materializes.

### MEDIUM — History Eviction Is Multi-Step Without Atomicity

**Risk level: MEDIUM**

`addToHistory` (sds_utils.nim:81–106):

```nim
channel.messageHistory[msg.messageId] = msg        # insert
(await rm.persistence.appendLogEntry(...)).isOkOr:  # persist insert
  return err(...)
while channel.messageHistory.len > max:
  # evict oldest
  channel.messageHistory.del(firstKey)
  (await rm.persistence.removeLogEntry(...)).isOkOr:  # persist eviction
    return err(...)
```

If the append succeeds but an eviction `removeLogEntry` fails: on restart, the history will contain entries beyond `maxMessageHistory`. Not catastrophic but violates the capacity invariant and could grow unbounded over repeated failures.

### MEDIUM — `dropChannel` Atomicity Depends Entirely on Backend

```nim
# sds_utils.nim:27-35
(await rm.persistence.dropChannel(channelId)).isOkOr:
  return err(reliabilityErr(error))
```

The comment on `persistence.nim:103-106` says "Backends should implement this atomically (e.g. one BEGIN/COMMIT)." Good — but there's no enforcement. A naive SQLite backend that does `DELETE FROM t1; DELETE FROM t2; ...` without a transaction could leave partial state.

### MEDIUM — `ChannelSnapshot.messageHistory` Ordering Assumption

```nim
# persistence.nim:41-42
messageHistory*: seq[SdsMessage]
  ## MUST be ordered oldest-first.
```

The contract says "MUST be ordered oldest-first" — but there's no validation in `getOrCreateChannel`. If a SQLite backend returns messages in wrong order (e.g. missing `ORDER BY lamport_timestamp, message_id`), the `OrderedTable` insertion order will be wrong, corrupting causal history tail selection and FIFO eviction silently.

### LOW — Bloom Filter Rebuild Correctness

The bloom filter is rebuilt from `messageHistory` on bootstrap — which is capped at `maxMessageHistory` entries. Messages evicted from history won't be in the rebuilt bloom filter. This means:

- After restart, the bloom filter covers fewer messages than before the crash.
- Peers may believe we have messages (based on a pre-crash bloom snapshot they received) that we no longer claim to have.
- This can trigger unnecessary SDS-R repair requests.

This is a **known design tradeoff**, documented in `persistence.nim:30-32`. Impact is limited to repair overhead, not correctness.

### LOW — No Backend Exists in This Repo

There is no SQLite backend (or any real backend) in nim-sds. The `noOpPersistence()` default means:

- All tests run without durability.
- The persistence interface is untested against real I/O failure modes.
- Any bugs in the interface contract (ordering, atomicity) won't surface until a backend is integrated.

---

## 5. Summary Verdict

| Area | Grade | Notes |
|------|-------|-------|
| Interface design | **B+** | Clean, well-documented, 13 focused operations. Missing: transaction boundaries. |
| Error propagation | **B** | Consistent `Result[T, string]` → `rePersistenceError` mapping. But background tasks discard errors. |
| In-memory/disk consistency | **D** | No rollback on partial failure. Memory-first mutation pattern throughout. |
| Atomicity | **D** | Multi-call operations have no transaction concept. Partial writes are structurally possible. |
| Bootstrap correctness | **B-** | Works correctly IF backend orders history right. No validation. Bloom rebuild is lossy by design. |
| Test coverage of persistence | **F** | Zero tests exercise a real backend. All tests use noOpPersistence. |

### Recommendations

1. **Add a transaction/batch concept to the Persistence interface.** Even a simple `beginBatch`/`commitBatch` pair would let a SQLite backend wrap multi-step operations atomically.
2. **Reverse the mutation order**: persist first, mutate memory on success. This eliminates the in-memory-ahead-of-disk divergence.
3. **Don't discard background task results.** At minimum, log them. Better: track failure counts and surface them via a health check callback.
4. **Validate `ChannelSnapshot` ordering in `getOrCreateChannel`.** Assert `lamportTimestamp` monotonicity on the loaded `messageHistory`.
5. **Write integration tests with a real (in-memory SQLite) backend** that exercises failure injection — kill persistence mid-operation and verify recovery.

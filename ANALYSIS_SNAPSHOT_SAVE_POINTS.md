# SDS State Snapshot — Save Points & Call Rate

Snapshot = `saveChannelMeta(channelId, ChannelMeta)` carrying: `lamportTimestamp`,
`outgoingBuffer`, `incomingBuffer`, `outgoingRepairBuffer`, `incomingRepairBuffer`.
(Bloom filter excluded — rebuilt from history. History persisted separately via
`updateHistory(append, evict)`.)

**Rule: exactly one snapshot save per protocol operation, fired at the end, under
the lock, only if meta actually changed (dirty flag).**

## Save Points

| # | Operation | Save? | When | Condition |
|---|-----------|-------|------|-----------|
| 1 | `wrapOutgoingMessage` (sds.nim:163) | **1** | end, before `serializeMessage` | always (lamport + outgoingBuffer always mutate) |
| 2 | `unwrapReceivedMessage` (sds.nim:373) | **0 or 1** | end, before `return` | 0 on duplicate early-return (line 264); else 1 — covers all 3 paths |
| 3 | `markDependenciesMet` (sds.nim:415) | **1** | end, after `processIncomingBuffer` | if any dep matched |
| 4 | `checkUnacknowledgedMessages` (sds.nim:478) | **0 or 1** | end of pass | only if buffer changed (resend/expiry) |
| 5 | `runRepairSweep` (sds.nim:556) | **0..C** | per channel, end of channel loop | one per *dirty* channel only |

`processIncomingBuffer` and `reviewAckStatus` become pure in-memory helpers — they
never save; the calling op (2 or 3) persists once at the end.

## Rate Model (per channel)

Let `S` = sends/s, `R` = non-duplicate receives/s.

```
snapshot_rate ≈ S + R                       (foreground, dominant)
              + 1/repairSweepInterval        if repair buffers dirty  = 0.2/s
              + 1/bufferSweepInterval        if outgoing buffer dirty = 0.0167/s
```

`repairSweepInterval = 5s`, `bufferSweepInterval = 60s`.

### Background floor (zero traffic)
With dirty-flag guard: **0 saves/s** on a quiet channel (empty buffers → nothing to
persist). Without the guard, the 5s repair sweep alone would force 0.2 saves/s/channel
even when idle — so the dirty-flag guard is mandatory, not optional.

### Worked examples

| Scenario | Channels | Per-ch S+R | Foreground | Background | Total snapshot/s |
|----------|----------|-----------|-----------|-----------|------------------|
| Idle | 10 | 0 | 0 | 0 (guarded) | **0** |
| Light chat | 5 | 1 | 5 | ~0.2 | **~5** |
| Busy | 10 | 6 | 60 | ~2 | **~62** |
| Heavy / lossy (SDS-R churning) | 10 | 20 | 200 | ~2 | **~202** |

Background is negligible vs foreground whenever there is traffic. The snapshot rate
is essentially **one write per protocol message** — bounded by network throughput,
not by internal mutation count.

## Why this is safe for SQLite-on-a-thread

- 1 snapshot write per message → 1 cross-thread round-trip, 1 `UPSERT` of a single
  blob row, foldable into the same transaction as the `updateHistory` call.
- Snapshot blob is **small**: buffer sizes are bounded by traffic-in-flight, not by
  `maxMessageHistory`. Typical < a few KB even under load.
- vs. current fine-grained interface (10–15 calls/op), this is a **5–10× reduction**
  in cross-thread round-trips and SQLite operations, with atomic crash consistency.

## Snapshot vs History rate (separation payoff)

| | Snapshot (`saveChannelMeta`) | History (`updateHistory`) |
|---|---|---|
| Append rate | n/a | S + R_delivered (every delivered msg) |
| Evict | n/a | batched, only past maxMessageHistory=1000 |
| Save rate | S + R (every msg) | S + R_delivered |
| Blob size | small (buffers) | large but append-only |
| Coupling | both fire together at op end → 1 SQLite txn |

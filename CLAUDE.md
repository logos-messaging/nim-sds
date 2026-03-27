# nim-sds — Claude Code Guide

## Project Overview

**nim-sds** is a Nim implementation of the **Scalable Data Sync (SDS)** protocol ([spec](https://lip.logos.co/ift-ts/raw/sds.html), IFT LIP-109). SDS achieves end-to-end reliability when consolidating distributed logs in a decentralized manner — participants broadcast messages over a P2P transport, maintain per-channel append-only logs, and use causal ordering to reach consistent state across all nodes.

The library exposes its functionality via a C-compatible FFI so it can be embedded in applications on any platform. Go bindings are maintained in a separate repo: [logos-messaging/sds-go-bindings](https://github.com/logos-messaging/sds-go-bindings).

---

## Protocol Concepts

Understanding these is essential before modifying any core code.

### Message format

Each SDS message carries (`sds/message.nim`, `sds/protobuf.nim`):

| Field | Purpose |
|---|---|
| `message_id` | Globally unique, immutable identifier |
| `sender_id` | Originating participant |
| `channel_id` | Communication channel |
| `lamport_timestamp` | Logical clock for ordering |
| `causal_history` | IDs of the 2–3 most recent messages the sender has seen (dependencies) |
| `bloom_filter` | Compact summary of all message IDs the sender has received |
| `content` | Application payload |

### Sending a message (`sds/sds_utils.nim` → `wrapOutgoingMessage`)

1. Increment the per-channel Lamport timestamp to `max(current_time_ms, timestamp + 1)`.
2. Attach causal history from the local log tail.
3. Embed the current bloom filter snapshot.

### Receiving a message (`sds/sds_utils.nim` → `unwrapReceivedMessage`)

1. Deduplicate by `message_id`.
2. Check causal dependencies — if any predecessor is missing, buffer the message.
3. When all dependencies are met, deliver: insert into the ordered local log (Lamport timestamp, tie-break by ascending `message_id`).
4. Record `message_id` in the bloom filter.

### Periodic sync

A node periodically broadcasts a message with empty content carrying an updated Lamport timestamp and bloom filter. These sync messages are not persisted and are excluded from causal chains. They help peers detect gaps in their logs.

### SDS-R (Repair extension)

Defined in the spec but **not yet implemented** in this library.

### Bloom filter (`sds/bloom.nim`, `sds/rolling_bloom_filter.nim`)

Used to compactly summarise which messages a node has received, so peers can identify gaps without exchanging full ID lists. The rolling variant automatically resets when capacity is exceeded.

---

## Repository Layout

```
sds/                        # Core protocol (pure Nim, no FFI)
  message.nim               # SdsMessage, HistoryEntry, config constants
  sds_utils.nim             # ReliabilityManager — send/receive/buffer logic
  protobuf.nim              # Protobuf encode/decode for SdsMessage
  protobufutil.nim          # Low-level protobuf helpers
  bloom.nim                 # Bloom filter implementation
  rolling_bloom_filter.nim  # Adaptive rolling bloom filter
library/                    # C FFI wrapper around the core
  libsds.nim                # Exported C-compatible entry points
  libsds.h                  # C header
  ffi_types.nim             # C-compatible types and return codes
  alloc.nim                 # Memory allocation helpers
  sds_thread/               # Per-context Chronos async worker thread
  events/                   # JSON serialisation for event callbacks
tests/
  test_bloom.nim            # Bloom filter unit tests
  test_reliability.nim      # Protocol-level unit tests
sds.nim                     # Root module — re-exports public API
sds.nimble                  # Package manifest + build tasks
flake.nix / Makefile        # Reproducible cross-platform build system
```

---

## Key Types

| Type | File | Role |
|---|---|---|
| `ReliabilityManager` | `sds_utils.nim` | Per-channel protocol state: Lamport clock, bloom filter, log, buffers |
| `ReliabilityConfig` | `sds_utils.nim` | Tunable parameters (bloom capacity, history length, resend interval) |
| `SdsMessage` | `message.nim` | Wire message |
| `HistoryEntry` | `message.nim` | `message_id` + optional retrieval hint |
| `UnacknowledgedMessage` | `message.nim` | Outgoing message with resend counter |
| `IncomingMessage` | `message.nim` | Buffered message waiting on missing dependencies |

---

## FFI API (`library/libsds.nim`)

The C API wraps `ReliabilityManager` behind an opaque `SdsContext` handle:

| Export | Maps to |
|---|---|
| `SdsNewReliabilityManager` | Create context |
| `SdsWrapOutgoingMessage` | `wrapOutgoingMessage` |
| `SdsUnwrapReceivedMessage` | `unwrapReceivedMessage` |
| `SdsMarkDependenciesMet` | Notify buffered-message dependencies satisfied |
| `SdsSetEventCallback` | Register event handler (JSON payloads) |
| `SdsSetRetrievalHintProvider` | Register hint-provider callback |
| `SdsStartPeriodicTasks` | Start periodic sync loop |
| `SdsCleanupReliabilityManager` | Free context |
| `SdsResetReliabilityManager` | Reset state without freeing |

Each `SdsContext` runs a dedicated Chronos async loop on a worker thread; application threads communicate with it via SPSC channels.

---

## Running Tests

```bash
nimble test
```

Nix can also provide the environment if a local Nim install is not available:

```bash
nix develop --command nimble test
```

---

## Code Conventions

- **Types**: PascalCase (`ReliabilityManager`, `SdsMessage`)
- **Variables/procs**: camelCase
- **Public exports**: trailing `*`
- **Errors**: `Result[T, ReliabilityError]` — use `.valueOr`, `.isOk()`, `.isErr()`
- **Locks**: `withLock` macro (RAII); all exported procs are `{.gcsafe.}`
- **Constants**: `Default` prefix (e.g., `DefaultBloomFilterCapacity`)
- **Backward compat**: `sds/protobuf.nim` supports old and new causal history formats — do not remove the legacy decode path

---

## Building

**Nimble** is the primary build tool. Desktop library targets:

```bash
nimble libsdsDynamicMac      # macOS .dylib
nimble libsdsDynamicLinux    # Linux .so
nimble libsdsStaticMac       # macOS .a
nimble libsdsStaticLinux     # Linux .a
```

**Nix** (`flake.nix`) and **Make** (`Makefile`) are optional conveniences that wrap Nimble for reproducible and cross-platform (including Android/iOS) builds.

## Dependency Management

Nimble dependencies are locked in `nimble.lock`.

```bash
nimble setup -l          # local setup
nimble lock              # update lock after changing sds.nimble
```

If using Nix, also recalculate the fixed-output hash in `nix/deps.nix` after updating `nimble.lock` (run `nix build`, copy the expected hash from the error, paste into `outputHash`).

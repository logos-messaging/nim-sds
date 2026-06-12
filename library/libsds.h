
// C API for libsds, built on the nim-ffi framework (v0.2.0+).
//
// Requests, responses and events are marshalled as CBOR. Request payloads are
// passed as a (reqCbor, reqCborLen) byte buffer; results and events are
// delivered to the callback as a CBOR buffer (msg, len). Each request/response
// struct and event payload is defined in library/libsds.nim. Events are
// wrapped in a CBOR envelope { eventType: <wire name>, payload: <struct> }.
#ifndef __libsds__
#define __libsds__

#include <stddef.h>
#include <stdint.h>

// The possible returned values for the functions that return int
#define RET_OK                0
#define RET_ERR               1
#define RET_MISSING_CALLBACK  2

#ifdef __cplusplus
extern "C" {
#endif

// Result/event callback. `msg` is the CBOR payload of length `len`.
// callerRet is one of the RET_* codes above.
typedef void (*SdsCallBack) (int callerRet, const char* msg, size_t len, void* userData);

// Synchronous provider invoked by SDS-R to fetch a retrieval hint for a
// message id. The implementation allocates `*hint` (and sets `*hintLen`); the
// library takes ownership and frees it with deallocShared. Registered via
// sds_set_retrieval_hint_provider (see below).
typedef void (*SdsRetrievalHintProvider) (const char* messageId, char** hint, size_t* hintLen, void* userData);


// --- Lifecycle -------------------------------------------------------------

// Create a context + ReliabilityManager. reqCbor encodes SdsConfig
// { participantId: tstr } (empty participantId disables SDS-R). Returns the
// context handle, or NULL on failure; the callback also fires on completion.
void* sds_create(const uint8_t* reqCbor, size_t reqCborLen, SdsCallBack callback, void* userData);

// Recycle the context created by sds_create, returning it to the pool for
// reuse without stopping its worker threads (chronos never frees a dispatcher's
// kqueue fd, so tearing threads down per context would leak fds). NON-BLOCKING:
// returns RET_OK once the recycle is accepted; the real outcome (RET_OK drained
// / RET_ERR stuck) arrives via `callback`. Returns RET_ERR synchronously only
// for a null/invalid ctx or a rejected request.
int sds_destroy(void* ctx, SdsCallBack callback, void* userData);


// --- Events ----------------------------------------------------------------
// Subscribe `callback` to an event by wire name and receive a stable listener
// id (non-zero). Event wire names: "message_ready", "message_sent",
// "missing_dependencies", "periodic_sync", "repair_ready". Subscribe to each
// event separately. Payloads arrive as CBOR { eventType, payload }.
uint64_t sds_add_event_listener(void* ctx, const char* eventName, SdsCallBack callback, void* userData);

// Remove a listener by id. Returns 0 on success, non-zero if not found.
int sds_remove_event_listener(void* ctx, uint64_t listenerId);

// Register the SDS-R retrieval-hint provider. reqCbor encodes
// SdsHintProviderRequest { callbackAddr: uint, userDataAddr: uint } — the
// SdsRetrievalHintProvider function pointer and its user-data as integer
// addresses.
int sds_set_retrieval_hint_provider(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);


// --- Core API Functions ----------------------------------------------------
// Each takes a CBOR-encoded request buffer; the result is delivered to
// `callback` as CBOR.

// reqCbor: SdsWrapRequest { message: bytes, messageId: tstr, channelId: tstr }
// result:  SdsWrapResponse { message: bytes }
int sds_wrap_outgoing_message(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);

// reqCbor: SdsUnwrapRequest { message: bytes }
// result:  SdsUnwrapResponse { message: bytes, channelId: tstr,
//                              missingDeps: [{ messageId: tstr, retrievalHint: bytes }] }
int sds_unwrap_received_message(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);

// reqCbor: SdsMarkDependenciesRequest { messageIds: [tstr], channelId: tstr }
int sds_mark_dependencies_met(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);

// reqCbor: empty/unit payload (no fields).
int sds_reset(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);

// reqCbor: empty/unit payload (no fields).
int sds_start_periodic_tasks(void* ctx, SdsCallBack callback, void* userData, const uint8_t* reqCbor, size_t reqCborLen);


#ifdef __cplusplus
}
#endif

#endif /* __libsds__ */


// C API for libsds, built on the nim-ffi framework.
//
// Parameters and results are marshalled as JSON: each request/response struct
// in library/libsds.nim is a JSON object, passed in via the `*Json` cstring
// argument and returned to the callback as a JSON string. Binary fields
// (message bytes) are JSON arrays of byte values.
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

// Result/event callback. `msg` is the (JSON) payload of length `len`.
// callerRet is one of the RET_* codes above.
typedef void (*SdsCallBack) (int callerRet, const char* msg, size_t len, void* userData);

// Synchronous provider invoked by SDS-R to fetch a retrieval hint for a
// message id. The implementation allocates `*hint` (and sets `*hintLen`); the
// library takes ownership and frees it with deallocShared.
typedef void (*SdsRetrievalHintProvider) (const char* messageId, char** hint, size_t* hintLen, void* userData);


// --- Core API Functions ---


// Create a context + ReliabilityManager. configJson: {"participantId":"..."}
// (empty participantId disables SDS-R). Returns the context handle, or NULL on
// failure. The callback also fires on async completion.
void* sds_create(const char* configJson, SdsCallBack callback, void* userData);

// Register the event callback (message_ready, message_sent,
// missing_dependencies, periodic_sync, repair_ready). Payloads are JSON.
void sds_set_event_callback(void* ctx, SdsCallBack callback, void* userData);

// Register the retrieval-hint provider used by SDS-R.
int sds_set_retrieval_hint_provider(void* ctx, SdsRetrievalHintProvider callback, void* userData);

// reqJson: {"message":[..bytes..],"messageId":"..","channelId":".."}
// Result JSON: {"message":[..bytes..]}
int sds_wrap_outgoing_message(void* ctx, SdsCallBack callback, void* userData, const char* reqJson);

// reqJson: {"message":[..bytes..]}
// Result JSON: {"message":[..],"channelId":"..","missingDeps":[{"messageId":"..","retrievalHint":"<base64>"}]}
int sds_unwrap_received_message(void* ctx, SdsCallBack callback, void* userData, const char* reqJson);

// reqJson: {"messageIds":["..",".."],"channelId":".."}
int sds_mark_dependencies_met(void* ctx, SdsCallBack callback, void* userData, const char* reqJson);

int sds_reset(void* ctx, SdsCallBack callback, void* userData);

int sds_start_periodic_tasks(void* ctx, SdsCallBack callback, void* userData);

// Tear down the context created by sds_create.
int sds_destroy(void* ctx, SdsCallBack callback, void* userData);


#ifdef __cplusplus
}
#endif

#endif /* __libsds__ */

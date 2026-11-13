# nim-sds

Nim implementation of the e2e reliability protocol.

## Outgoing message events

`onMessageSent` (`message_sent` in the C FFI) reports acknowledgment evidence
from an incoming message's causal history or bloom filter. Unacknowledged
messages removed after the configured sweep budget instead trigger the optional
`onMessageExpired` callback (`message_expired`), with `messageId` and `channelId`.
Expiry is not delivery confirmation.

The existing sweep timing and accounting are unchanged: after `resendInterval`,
the sweep increments `resendAttempts` and resets `sendTime`, or expires the
message if `maxResendAttempts` has been reached. The sweep does not transmit
retries; these counters currently measure elapsed intervals, not transmissions.

## Periodic sync messages

Call `tick()` regularly to obtain due payloads for loaded channels. Each event
contains a channel ID and either a serialized payload to publish or an error.
SDS decides when a channel is due based on activity, the configured interval,
pending repair requests, and randomized backoff. Tick does not transmit messages.
Pending acknowledgement-summary payloads are generated within the sync interval
plus jitter (on the next tick), even while incoming traffic keeps the channel busy.
Call `ensureChannel` for channels to monitor, including after restart; persistence
loads channels on demand and does not enumerate them. Scheduling state is in
memory and starts afresh when a channel is loaded.
Channel IDs must be nonempty.

Syncs carry the channel's causal history, bloom filter and due repair requests.
Use the channel-aware retrieval hint provider when hints depend on channel.
Due repair requests included in syncs remain pending for a later sync, so a
failed publication does not discard them.
Selection rotates between requests without extending their expiry deadlines.
Their metadata processes acknowledgements and missing content on receipt, but
syncs never enter content history, bloom or acknowledgement buffers. An unwrap
result with no application payload (`none` in Nim, `message: null` in C JSON)
means metadata was consumed successfully; errors are returned separately.
Existing expiry and repair maintenance remains independent of `tick()`.
Self-originated syncs are ignored when the participant ID is nonempty, and
repeated repair requests cannot postpone an already scheduled response.
Generated payloads are not queued for retransmission if publication fails; a
later due sync contains a fresh summary.

## Incoming message validation

SDS assumes a trusted channel. Pass an optional `Validator` to
`unwrapReceivedMessage` to authorize the decoded message before SDS creates or
loads a channel, deduplicates, updates state, or emits events:

```nim
let validator = Validator(
  validate: proc(message: SdsMessage): Result[bool, string] {.gcsafe, raises: [].} =
    ok(isAuthorized(message))
)
let received = await manager.unwrapReceivedMessage(payload, validator)
```

`ok(true)` accepts the message; `ok(false)` returns `reMessageRejected`; an
`err` is logged and returns `reValidationError`. Both failures leave SDS state
untouched. A missing validator retains the existing behavior. Validation runs
for duplicates and empty-content sync messages too, including self syncs.
Validators must not mutate the decoded message or re-enter the same manager.

C hosts register the optional synchronous callback with `sds_set_validator`.
It receives the decoded channel ID, content, untrusted SDS sender ID, and the
unwrap request's optional opaque `validationContext` bytes. Use that context
to supply authenticated sender information; the wire `senderId` is not proof
of identity. Older unwrap requests may omit `validationContext`.
Rejection and validation errors propagate through the normal unwrap error
response, never as a successful empty-content result or a decoding error.
See `library/libsds.h` for return values and callback lifetime requirements.

## Prerequisites

- [Nix](https://nixos.org/download/) package manager

## Quick start

```bash
git clone https://github.com/logos-messaging/nim-sds.git
cd nim-sds

# Build the shared library
nix build '.#libsds'

# Run tests
nix develop --command nimble test
```

## Building

### Desktop

```bash
nix build --print-out-paths '.#libsds'
```

### Android

```bash
nix build --print-out-paths '.#libsds-android-arm64'
nix build --print-out-paths '.#libsds-android-amd64'
nix build --print-out-paths '.#libsds-android-x86'
nix build --print-out-paths '.#libsds-android-arm'
```

### iOS

```bash
nix build --print-out-paths '.#libsds-ios'
```

### Without Nix

With [Nimble](https://github.com/nim-lang/nimble) 0.26 or later, for the current platform:

```bash
nimble setup
nimble libsds    # short for: nimble shell nim c library/libsds.nim
```

This builds the shared library into `build/`, with the headers `libsds.h` includes in
`build/generated/`. `nimble shell` runs the Nim that `nimble.lock` pins, and the root
`config.nims` passes it the locked dependencies. For a static library, add
`--app:staticlib --out:build/libsds.a`.

<details>
<summary>Development shell</summary>

Enter the dev shell:
```bash
nix develop
```

Build for the current platform:
```bash
nim c library/libsds.nim                                               # shared library
nim c --app:staticlib --out:build/libsds.a library/libsds.nim          # static library
```

Run tests:
```bash
nimble test
```

The built library is output to `build/`.

</details>

<details>
<summary>Android (without Nix)</summary>

Download the latest Android NDK:
```bash
cd ~
wget https://dl.google.com/android/repository/android-ndk-r27c-linux.zip
unzip android-ndk-r27c-linux.zip
```

Add to `~/.bashrc`:
```bash
export ANDROID_NDK_ROOT=$HOME/android-ndk-r27c
export PATH=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin:$PATH
```

Then pass the target to the build:
```bash
CC=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android28-clang
nim c -d:ffiOutputDir=$PWD/build/generated --app:lib --out:build/libsds.so --os:android --cpu:arm64 --cc:clang --clang.exe:$CC --clang.linkerexe:$CC library/libsds.nim
```

The API level comes from the compiler name, and the architecture from `--cpu` and the compiler name.

The library is output to `build/libsds.so`.

</details>

<details>
<summary>Dependency management</summary>

Dependencies are managed by [Nimble](https://github.com/nim-lang/nimble) and pinned via `nimble.lock`.

To set up dependencies locally:
```bash
nimble setup -l
```

To update dependencies:
```bash
nimble lock
```

After updating `nimble.lock`, the Nix `outputHash` in `nix/deps.nix` must be recalculated
by running `nix build` and updating the hash from the error output.

</details>

<details>
<summary>Embedding libsds in another project</summary>

A project builds the library from the installed package with plain `nim c`, passing everything about the build except what the library needs itself, which is in `library/config.nims`: the target, the policy (`--mm`, `--opt`, log level), the app type, the outputs and the `--path` of every dependency from its own resolution:

```bash
nim c --skipParentCfg --noNimblePath <target> <policy> $(tr '\n' ' ' < nimble.paths) \
  --app:lib --nimcache:out/nimcache -d:ffiOutputDir=$PWD/out/generated -o:out/libsds.so "$(nimble path sds)/library/libsds.nim"
```

The C API is `sds_*`, declared in `library/libsds.h`, which includes `generated/sds.h`: nim-ffi writes it during the compile into the directory `-d:ffiOutputDir` names (`build/generated` in the checkout by default, so an embedder passes its own).

</details>

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.

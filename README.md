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

`wrapSyncMessage(channelId)` builds an empty-content SDS sync message containing
the channel's current Lamport timestamp, causal history, bloom filter, and any
eligible repair requests. The sync has a reusable protocol-reserved message ID;
callers only need to provide its channel.

Sync messages process peer acknowledgements and missing-content dependencies
when received, but the sync itself is never added to the outgoing acknowledgement
buffer, bloom filter, incoming buffer, or persisted message history. The C FFI
exposes the same operation as `sds_wrap_sync_message`; its unwrap response
includes an `isSync` flag so callers can distinguish sync metadata from content.

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

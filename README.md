# nim-sds

Nim implementation of the e2e reliability protocol.

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

<details>
<summary>Development shell</summary>

Enter the dev shell:
```bash
nix develop
```

Build for the current platform:
```bash
nimble libsds        # shared library
nimble libsdsStatic  # static library
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
CC=$ANDROID_NDK_ROOT/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android30-clang
NIM_PARAMS="--os:android --cpu:arm64 --cc:clang --clang.exe:$CC --clang.linkerexe:$CC" nimble libsds
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

The caller chooses everything about the build except what the library needs itself, which is in `library/config.nims`:

| Variable | Meaning |
| -------- | ------- |
| `NIM` | The compiler. Defaults to `nim`. |
| `NIM_PARAMS` | Target and policy flags, plus the `--path` of every dependency. Goes last on every compile, so it wins. |
| `LIB_OUT_DIR` | Where the library, `libsds.h`, `generated/` and nimcache go. Defaults to `build/`. |
| `IOS_ARCH` | `libsdsIOS` only: the architecture to merge the objects for. Defaults to `arm64`. |

A project that resolves dependencies itself runs the tasks with plain `nim`, so its resolution stays in charge. `nimble` in this directory would resolve `nimble.lock` instead:

```bash
printf 'include "%s/sds.nimble"\n' "$PKG" > sds.nims
NIM_PARAMS="--skipParentCfg $(tr '\n' ' ' < nimble.paths)" nim --skipParentCfg libsds sds.nims
```

</details>

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.

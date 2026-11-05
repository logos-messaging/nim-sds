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
nim c --app:lib --out:build/libsds.dylib library/libsds.nim        # shared library (.so on Linux, .dll on Windows)
nim c --app:staticlib --out:build/libsds.a library/libsds.nim      # static library
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
nim c --app:lib --out:build/libsds.so --os:android --cpu:arm64 --cc:clang --clang.exe:$CC --clang.linkerexe:$CC library/libsds.nim
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
  --app:lib --nimcache:out/nimcache -o:out/libsds.so "$(nimble path sds)/library/libsds.nim"
```

The C API is `sds_*`, declared in `library/libsds.h`, which includes `generated/sds.h`: nim-ffi writes it during the compile into `<nimcache>/generated` (or `-d:ffiOutputDir`).

</details>

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.

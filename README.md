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

Build using nimble tasks:
```bash
# Dynamic library (auto-detects OS)
nimble libsdsDynamicMac    # macOS
nimble libsdsDynamicLinux  # Linux
nimble libsdsDynamicWindows # Windows

# Static library
nimble libsdsStaticMac     # macOS
nimble libsdsStaticLinux   # Linux
nimble libsdsStaticWindows # Windows
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

Then build:
```bash
ARCH=arm64 nimble libsdsAndroid
```

| Architecture | Command |
| ------------ | ------- |
| arm64 | `ARCH=arm64 nimble libsdsAndroid` |
| amd64 | `ARCH=amd64 nimble libsdsAndroid` |
| x86 | `ARCH=x86 nimble libsdsAndroid` |

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

## Embedding

A project that depends on this package through Nimble can build libsds from the
installed copy without writing into it. The tasks locate their sources from the
manifest and write to `build/` under the working directory, so run them from
where the output should go:

```bash
cd /abs/out
NIM_PARAMS="--noNimblePath --path:... --path:..." \
  nim libsdsDynamicLinux <package>/library/sds_tasks.nims
```

- `library/sds_tasks.nims` runs the manifest's tasks without Nimble, so nothing
  is re-resolved.
- `NIM_PARAMS` is appended to every `nim c`: pass the `--path` entries of your
  own resolution (your `nimble.paths`).
- The C API header is `library/libsds.h` in the package.

## License

Licensed under either of [Apache License, Version 2.0](LICENSE-APACHE) or [MIT license](LICENSE-MIT) at your option.

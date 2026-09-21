import strutils, os

# Package
version = "0.4.0"
author = "Logos Messaging Team"
description = "E2E Scalable Data Sync API"
license = "MIT"
srcDir = "sds"

# A dependent builds libsds from the installed package, so ship library/ too.
# Naming any directory turns off the default srcDir install, hence sds/ here.
installDirs = @["library", "sds"]

# Dependencies
requires "nim >= 2.2.6"
requires "chronos >= 4.0.4"
requires "protobuf_serialization >= 0.5.0"
requires "chronicles"
requires "stew"
requires "stint"
requires "metrics"
requires "results"
# nim-ffi imports taskpools/channels_spsc_single, dropped in 0.2.x, and asks
# for taskpools unconstrained. nimble.lock already resolves 0.1.0.
requires "taskpools < 0.2.0"
requires "https://github.com/logos-messaging/nim-ffi#v0.1.5"

proc buildLibrary(
    outLibNameAndExt: string,
    name: string,
    srcDir = "./",
    extra_params = "",
    `type` = "static",
) =
  if not dirExists "build":
    mkDir "build"

  # An embedder that resolves dependencies itself passes --path here.
  let params = extra_params & " " & getEnv("NIM_PARAMS")

  if `type` == "static":
    exec "nim c" & " --out:build/" & outLibNameAndExt &
      " --threads:on --app:staticlib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds -d:noSignalHandler " &
      params & " " & srcDir & name & ".nim"
  else:
    when defined(windows):
      exec "nim c" & " --out:build/" & outLibNameAndExt &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds -d:noSignalHandler " &
        params & " " & srcDir & name & ".nim"
    else:
      exec "nim c" & " --out:build/" & outLibNameAndExt &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds -d:noSignalHandler " &
        params & " " & srcDir & name & ".nim"

proc getMyCpu(): string =
  ## Returns a Nim-compatible CPU name (e.g. amd64, arm64) for the host.
  ## Respects the ARCH environment variable when set.
  let envArch = getEnv("ARCH")
  if envArch != "":
    return envArch
  when defined(arm64):
    return "arm64"
  elif defined(amd64):
    return "amd64"
  else:
    let (archFromUname, _) = gorgeEx("uname -m")
    let a = archFromUname.strip()
    return
      if a == "x86_64":
        "amd64"
      elif a == "aarch64":
        "arm64"
      else:
        a

# Tasks
task test, "Run the test suite":
  exec "nim c -r --outdir:build tests/test_bloom.nim"
  exec "nim c -r --outdir:build tests/test_reliability.nim"
  exec "nim c -r --outdir:build tests/test_persistence.nim"
  exec "nim c -r --outdir:build tests/test_snapshot_codec.nim"
  exec "nim c -r --outdir:build tests/test_wire_compat.nim"

const desktopParams =
  "-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE"

proc macArchFlags(): string =
  ## Returns the Nim and clang flags pinning a build to the host Mac's CPU and SDK.
  let cpu = getMyCpu()
  let clangArch = if cpu == "amd64": "x86_64" else: cpu
  let sdkPath = staticExec("xcrun --show-sdk-path").strip()
  return
    "--cpu:" & cpu & " --passC:\"-arch " & clangArch & "\" --passL:\"-arch " & clangArch &
    "\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""

proc buildDesktopLib(outLibNameAndExt, `type`: string, archFlags = "") =
  buildLibrary outLibNameAndExt, "libsds", "library/",
    archFlags & " " & desktopParams, `type`

task libsdsDynamicWindows, "Generate bindings":
  buildDesktopLib "libsds.dll", "dynamic"

task libsdsDynamicLinux, "Generate bindings":
  buildDesktopLib "libsds.so", "dynamic"

task libsdsDynamicMac, "Generate bindings":
  buildDesktopLib "libsds.dylib", "dynamic", macArchFlags()

task libsdsStaticWindows, "Generate bindings":
  buildDesktopLib "libsds.lib", "static"

task libsdsStaticLinux, "Generate bindings":
  buildDesktopLib "libsds.a", "static"

task libsdsStaticMac, "Generate bindings":
  buildDesktopLib "libsds.a", "static", macArchFlags()

# Build Mobile iOS
proc buildMobileIOS(srcDir = ".", sdkPath = "") =
  echo "Building iOS libsds library"

  let outDir = "build"
  let nimcacheDir = outDir & "/nimcache"
  if dirExists nimcacheDir:
    rmDir nimcacheDir
  if not dirExists outDir:
    mkDir outDir

  if sdkPath.len == 0:
    quit "Error: Xcode/iOS SDK not found"

  let aFile = outDir & "/libsds.a"
  let cpu = getMyCpu()
  let clangArch = if cpu == "amd64": "x86_64" else: cpu

  # 1) Generate C sources from Nim (no linking)
  # Use unique symbol prefix to avoid conflicts with other Nim libraries
  exec "nim c" & " --nimcache:" & nimcacheDir & " --os:ios --cpu:" & cpu &
    " --compileOnly:on" & " --noMain --mm:refc" & " --threads:on --opt:size --header" &
    " --nimMainPrefix:libsds" & " --cc:clang" & " -d:useMalloc" & " -d:noSignalHandler" &
    " " & srcDir & "/libsds.nim"

  # 2) Compile all generated C files to object files with hidden visibility
  # This prevents symbol conflicts with other Nim libraries (e.g., libnim_status_client)
  # nimbase.h lives in lib/, next to the resolved compiler's bin/.
  let (nimBin, _) = gorgeEx("which nim")
  let nimLibDir = parentDir(parentDir(nimBin.strip())) / "lib"
  if not fileExists(nimLibDir / "nimbase.h"):
    quit "Error: nimbase.h not found in " & nimLibDir
  let clangFlags =
    "-arch " & clangArch & " -isysroot " & sdkPath & " -I" & nimLibDir &
    " -fembed-bitcode -miphoneos-version-min=16.2 -O2" & " -fvisibility=hidden"

  var objectFiles: seq[string] = @[]
  for cFile in listFiles(nimcacheDir):
    if cFile.endsWith(".c"):
      let oFile = cFile.changeFileExt("o")
      exec "clang " & clangFlags & " -c " & cFile & " -o " & oFile
      objectFiles.add(oFile)

  # 3) Merge into one object exporting only the _Sds* API, so libsds's Nim runtime
  #    can't clash with other static Nim libs (e.g. libnim_status_client).
  #    (libtool -static ignores -exported_symbols_list on current Xcode; ld -r works.
  #    Objects go through a response file: too many long paths for one command line.)
  let objListFile = outDir & "/objects.txt"
  writeFile(objListFile, objectFiles.join("\n"))
  let mergedObj = outDir & "/libsds_merged.o"
  exec "xcrun ld -r -arch " & clangArch & " -exported_symbol '_sds_*' -o " & mergedObj &
    " -filelist " & objListFile
  exec "ar rcs " & aFile & " " & mergedObj
  exec "rm -f " & mergedObj & " " & objListFile

  echo "✔ iOS library created: " & aFile

task libsdsIOS, "Build the mobile bindings for iOS":
  let srcDir = "./library"
  var sdkPath = getEnv("IOS_SDK_PATH")
  if sdkPath.len == 0:
    let (detected, exitCode) = gorgeEx("xcrun --show-sdk-path --sdk iphoneos")
    if exitCode == 0:
      sdkPath = detected.strip()
  buildMobileIOS srcDir, sdkPath

### Mobile Android
proc checkAndroidNdk() =
  let ndkRoot = getEnv("ANDROID_NDK_ROOT")
  if ndkRoot.len == 0:
    quit """Error: ANDROID_NDK_ROOT is not set."""
  if not dirExists(ndkRoot):
    quit "Error: ANDROID_NDK_ROOT points to a non-existent directory: " & ndkRoot
  # source.properties contains Pkg.Revision — present in every NDK since r10.
  let propsFile = ndkRoot / "source.properties"
  if not fileExists(propsFile):
    quit "Error: " & ndkRoot & " does not look like a valid NDK (source.properties not found)."
  let (props, _) = gorgeEx("cat " & propsFile)
  var revision = ""
  for line in props.splitLines():
    if line.startsWith("Pkg.Revision"):
      let parts = line.split('=')
      if parts.len == 2:
        revision = parts[1].strip()
  if revision.len == 0:
    quit "Error: Could not read NDK version from " & propsFile
  echo "Android NDK version: " & revision

proc buildMobileAndroid(srcDir = ".", extra_params = "") =
  let cpu = getMyCpu()
  let ndkRoot = getEnv("ANDROID_NDK_ROOT")
  let androidTarget = "30"

  # Map Nim CPU name → NDK target triple and include dirname.
  let (androidArch, archDirname) =
    if cpu == "arm64":   ("aarch64-linux-android",  "aarch64-linux-android")
    elif cpu == "amd64": ("x86_64-linux-android",   "x86_64-linux-android")
    elif cpu == "i386":  ("i686-linux-android",      "i686-linux-android")
    else:                ("armv7a-linux-androideabi","arm-linux-androideabi")

  # NDK prebuilt toolchain — location differs by host OS.
  let (hostOS, _) = gorgeEx("uname -s")
  let ndkHostTag =
    if hostOS.strip() == "Darwin": "darwin-x86_64"
    else: "linux-x86_64"
  let toolchainDir = ndkRoot / "toolchains/llvm/prebuilt" / ndkHostTag
  let sysroot      = toolchainDir / "sysroot"
  let ndkClang     = toolchainDir / "bin" / (androidArch & androidTarget & "-clang")

  let outDir = "build"
  if not dirExists outDir:
    mkDir outDir

  exec "nim c" &
    " --out:" & outDir & "/libsds.so" &
    " --threads:on --app:lib --opt:size --noMain --mm:refc --nimMainPrefix:libsds" &
    " -d:noSignalHandler" &
    " --cc:clang" &
    " --clang.exe:\"" & ndkClang & "\"" &
    " --clang.linkerexe:\"" & ndkClang & "\"" &
    " --cpu:" & cpu &
    " --os:android" &
    " -d:androidNDK" &
    " -d:chronosEventEngine=epoll" &
    " --passC:\"--sysroot=" & sysroot & "\"" &
    " --passL:\"--sysroot=" & sysroot & "\"" &
    " --passC:\"--target=" & androidArch & androidTarget & "\"" &
    " --passL:\"--target=" & androidArch & androidTarget & "\"" &
    " --passC:\"-I" & sysroot & "/usr/include\"" &
    " --passC:\"-I" & sysroot & "/usr/include/" & archDirname & "\"" &
    " --passL:\"-L" & sysroot & "/usr/lib/" & archDirname & "/" & androidTarget & "\"" &
    " --passL:-llog" &
    " -d:chronicles_sinks=textlines[dynamic]" &
    " --header" &
    " " & extra_params &
    " " & srcDir & "/libsds.nim"

task libsdsAndroid, "Build the mobile bindings for Android (uses ARCH env var)":
  checkAndroidNdk()
  let srcDir = "./library"
  buildMobileAndroid srcDir, "-d:chronicles_log_level=ERROR"

task libsdsAndroidArm64, "Build Android arm64 bindings":
  checkAndroidNdk()
  putEnv("ARCH", "arm64")
  buildMobileAndroid "./library", "-d:chronicles_log_level=ERROR"

task libsdsAndroidAmd64, "Build Android amd64 bindings":
  checkAndroidNdk()
  putEnv("ARCH", "amd64")
  buildMobileAndroid "./library", "-d:chronicles_log_level=ERROR"

task libsdsAndroidX86, "Build Android x86 bindings":
  checkAndroidNdk()
  putEnv("ARCH", "i386")
  buildMobileAndroid "./library", "-d:chronicles_log_level=ERROR"

task libsdsAndroidArm, "Build Android arm bindings":
  checkAndroidNdk()
  putEnv("ARCH", "arm")
  buildMobileAndroid "./library", "-d:chronicles_log_level=ERROR"

task libsds, "Build the shared library for the current platform":
  when defined(macosx):
    buildDesktopLib "libsds.dylib", "dynamic", macArchFlags()
  elif defined(windows):
    buildDesktopLib "libsds.dll", "dynamic"
  else:
    buildDesktopLib "libsds.so", "dynamic"

task clean, "Remove build artifacts":
  if dirExists "build":
    rmDir "build"

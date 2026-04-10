import strutils, os

# Package
version = "0.2.4"
author = "Logos Messaging Team"
description = "E2E Scalable Data Sync API"
license = "MIT"
srcDir = "sds"

# Dependencies
requires "nim >= 2.2.4"
requires "chronos >= 4.0.4"
requires "libp2p >= 1.15.2"
requires "chronicles"
requires "stew"
requires "stint"
requires "metrics"
requires "results"
requires "taskpools >= 0.1.0" ## This should be removed when using nim-ffi dependency

proc buildLibrary(
    outLibNameAndExt: string,
    name: string,
    srcDir = "./",
    extra_params = "",
    `type` = "static",
) =
  if not dirExists "build":
    mkDir "build"

  if `type` == "static":
    exec "nim c" & " --out:build/" & outLibNameAndExt &
      " --threads:on --app:staticlib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds " &
      extra_params & " " & srcDir & name & ".nim"
  else:
    when defined(windows):
      exec "nim c" & " --out:build/" & outLibNameAndExt &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds " &
        extra_params & " " & srcDir & name & ".nim"
    else:
      exec "nim c" & " --out:build/" & outLibNameAndExt &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds " &
        extra_params & " " & srcDir & name & ".nim"

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
  exec "nim c -r tests/test_bloom.nim"
  exec "nim c -r tests/test_reliability.nim"

task libsdsDynamicWindows, "Generate bindings":
  let outLibNameAndExt = "libsds.dll"
  let name = "libsds"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "dynamic"

task libsdsDynamicLinux, "Generate bindings":
  let outLibNameAndExt = "libsds.so"
  let name = "libsds"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "dynamic"

task libsdsDynamicMac, "Generate bindings":
  let outLibNameAndExt = "libsds.dylib"
  let name = "libsds"

  let cpu = getMyCpu()
  let clangArch = if cpu == "amd64": "x86_64" else: cpu
  let sdkPath = staticExec("xcrun --show-sdk-path").strip()
  let archFlags =
    "--cpu:" & cpu & " --passC:\"-arch " & clangArch & "\" --passL:\"-arch " & clangArch &
    "\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
  buildLibrary outLibNameAndExt,
    name,
    "library/",
    archFlags &
      " -d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE",
    "dynamic"

task libsdsStaticWindows, "Generate bindings":
  let outLibNameAndExt = "libsds.lib"
  let name = "libsds"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "static"

task libsdsStaticLinux, "Generate bindings":
  let outLibNameAndExt = "libsds.a"
  let name = "libsds"
  buildLibrary outLibNameAndExt,
    name, "library/",
    """-d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE """,
    "static"

task libsdsStaticMac, "Generate bindings":
  let outLibNameAndExt = "libsds.a"
  let name = "libsds"

  let cpu = getMyCpu()
  let clangArch = if cpu == "amd64": "x86_64" else: cpu
  let sdkPath = staticExec("xcrun --show-sdk-path").strip()
  let archFlags =
    "--cpu:" & cpu & " --passC:\"-arch " & clangArch & "\" --passL:\"-arch " & clangArch &
    "\" --passC:\"-isysroot " & sdkPath & "\" --passL:\"-isysroot " & sdkPath & "\""
  buildLibrary outLibNameAndExt,
    name,
    "library/",
    archFlags &
      " -d:chronicles_line_numbers --warning:Deprecated:off --warning:UnusedImport:on -d:chronicles_log_level=TRACE",
    "static"

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
  let aFileTmp = outDir & "/libsds_tmp.a"
  let cpu = getMyCpu()
  let clangArch = if cpu == "amd64": "x86_64" else: cpu

  # 1) Generate C sources from Nim (no linking)
  # Use unique symbol prefix to avoid conflicts with other Nim libraries
  exec "nim c" & " --nimcache:" & nimcacheDir & " --os:ios --cpu:" & cpu &
    " --compileOnly:on" & " --noMain --mm:refc" & " --threads:on --opt:size --header" &
    " --nimMainPrefix:libsds" & " --cc:clang" & " -d:useMalloc" & " " & srcDir &
    "/libsds.nim"

  # 2) Compile all generated C files to object files with hidden visibility
  # This prevents symbol conflicts with other Nim libraries (e.g., libnim_status_client)
  # Locate nimbase.h: try next to the nim binary first (jiro4989/setup-nim-action
  # puts nim at .nim_runtime/bin/nim with lib/ alongside), then fall back to the
  # choosenim toolchain directory (~/.choosenim/toolchains/nim-VERSION/lib/).
  let (nimBin, _) = gorgeEx("which nim")
  let nimLibFromBin = parentDir(parentDir(nimBin.strip())) / "lib"
  let nimLibChoosenim = getHomeDir() / ".choosenim/toolchains/nim-" & NimVersion & "/lib"
  let nimLibDir =
    if fileExists(nimLibFromBin / "nimbase.h"): nimLibFromBin
    else: nimLibChoosenim
  let clangFlags =
    "-arch " & clangArch & " -isysroot " & sdkPath & " -I" & nimLibDir &
    " -fembed-bitcode -miphoneos-version-min=16.2 -O2" & " -fvisibility=hidden"

  var objectFiles: seq[string] = @[]
  for cFile in listFiles(nimcacheDir):
    if cFile.endsWith(".c"):
      let oFile = cFile.changeFileExt("o")
      exec "clang " & clangFlags & " -c " & cFile & " -o " & oFile
      objectFiles.add(oFile)

  # 3) Create static library from all object files
  exec "ar rcs " & aFileTmp & " " & objectFiles.join(" ")

  # 4) Use libtool to localize all non-public symbols
  # Keep only Sds* functions as global, hide everything else to prevent conflicts
  # with nim runtime symbols from libnim_status_client
  let keepSymbols =
    "_Sds*:_libsdsNimMain:_libsdsDatInit*:_libsdsInit*:_NimMainModule__libsds*"
  exec "xcrun libtool -static -o " & aFile & " " & aFileTmp &
    " -exported_symbols_list /dev/stdin <<< '" & keepSymbols & "' 2>/dev/null || cp " &
    aFileTmp & " " & aFile

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
    exec "nimble libsdsDynamicMac"
  elif defined(windows):
    exec "nimble libsdsDynamicWindows"
  else:
    exec "nimble libsdsDynamicLinux"

task clean, "Remove build artifacts":
  if dirExists "build":
    rmDir "build"

import std/[json, os, strutils]

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
# nimble.lock pins the untagged chronos commit nim-ffi needs; a pin here breaks dependents.
requires "chronos"
requires "protobuf_serialization >= 0.5.0"
requires "chronicles"
requires "stew"
requires "stint"
requires "metrics"
requires "results"
requires "https://github.com/logos-messaging/nim-ffi#d98f77141de9c95c0c543d191a79aee18e7536a4"

# An embedder runs these tasks without nimble, from a `.nims` file that includes this
# one. NIM picks the compiler, NIM_PARAMS goes last on every `nim c`, and LIB_OUT_DIR
# receives every output (nothing lands in the package dir).
const pkgDir = currentSourcePath().parentDir

proc nimExe(): string =
  ## The compiler from NIM, else the one running this task.
  let nim = getEnv("NIM")
  if nim.len > 0: nim else: getCurrentCompilerExe()

proc nimParams(): string =
  " " & getEnv("NIM_PARAMS")

proc outDir(): string =
  ## LIB_OUT_DIR as an absolute path, else build/ in the working directory.
  let dir = getEnv("LIB_OUT_DIR")
  if dir.len == 0: "build"
  elif dir.isAbsolute: dir
  else: getCurrentDir() / dir

proc embeddedParams(): string =
  ## With LIB_OUT_DIR, dependencies come only from the embedder's NIM_PARAMS --paths:
  ## skip user and parent configs (config.nims includes nimble.paths), and add
  ## the sds/ path it would have added.
  if getEnv("LIB_OUT_DIR").len == 0:
    return ""
  let params = getEnv("NIM_PARAMS")
  if "--path" notin params and "-p:" notin params and "-p=" notin params:
    quit "Error: LIB_OUT_DIR selects the embedded build: pass the dependency --paths in NIM_PARAMS"
  " --skipUserCfg --skipParentCfg --noNimblePath --path:" & quoteShell(pkgDir / "sds")

proc nimcacheParam(name: string): string =
  ## Keeps nimcache under LIB_OUT_DIR; without it nim.cfg's build/nimcache applies.
  if getEnv("LIB_OUT_DIR").len == 0: ""
  else: " --nimcache:" & quoteShell(outDir() / "nimcache" / name)

# Emits generated/sds.h (not checked in), which libsds.h includes: next to
# library/libsds.h by default, or under LIB_OUT_DIR next to a copy of libsds.h.
proc cBindingsFlags(): string =
  if getEnv("LIB_OUT_DIR").len == 0:
    " -d:ffiGenBindings -d:targetLang=c -d:ffiOutputDir=generated -d:ffiSrcPath=../libsds.nim"
  else:
    " -d:ffiGenBindings -d:targetLang=c -d:ffiOutputDir=" & quoteShell(outDir() / "generated")

proc copyHeader(srcDir: string) =
  if getEnv("LIB_OUT_DIR").len > 0:
    cpFile(srcDir / "libsds.h", outDir() / "libsds.h")

proc buildLibrary(
    outLibNameAndExt: string,
    name: string,
    srcDir = "./",
    extra_params = "",
    `type` = "static",
) =
  # An embedder that resolves dependencies itself passes --path here.
  let params = extra_params & embeddedParams() & nimcacheParam(name) & nimParams()
  let outDir = outDir()
  if not dirExists outDir:
    mkDir outDir

  if `type` == "static":
    exec nimExe().quoteShell & " c" & " --out:" & quoteShell(outDir / outLibNameAndExt) &
      " --threads:on --app:staticlib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds -d:noSignalHandler" & cBindingsFlags() & " " &
      params & " " & srcDir & name & ".nim"
  else:
    when defined(windows):
      exec nimExe().quoteShell & " c" & " --out:" & quoteShell(outDir / outLibNameAndExt) &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds -d:noSignalHandler" & cBindingsFlags() & " " &
        params & " " & srcDir & name & ".nim"
    else:
      exec nimExe().quoteShell & " c" & " --out:" & quoteShell(outDir / outLibNameAndExt) &
        " --threads:on --app:lib --opt:size --noMain --mm:refc --header --nimMainPrefix:libsds -d:noSignalHandler" & cBindingsFlags() & " " &
        params & " " & srcDir & name & ".nim"
  copyHeader(srcDir)

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
const testNames =
  ["test_bloom", "test_reliability", "test_persistence", "test_snapshot_codec", "test_wire_compat"]

task test, "Run the test suite":
  for name in testNames:
    exec nimExe().quoteShell & " c -r --outdir:" & quoteShell(outDir()) &
      embeddedParams() & nimcacheParam(name) & nimParams() & " " & quoteShell(pkgDir / "tests" / name & ".nim")

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
  buildLibrary outLibNameAndExt, "libsds", pkgDir / "library" & "/",
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

proc nimLibPath(): string =
  ## The compiler's lib/ (nimbase.h), as the compiler itself reports it, so a
  ## symlinked or shimmed NIM still finds the right one.
  let (dump, exitCode) = gorgeEx(nimExe().quoteShell &
    " --hints:off --skipUserCfg --skipParentCfg --skipProjCfg dump --dump.format:json libsds.nim")
  if exitCode != 0:
    quit "Error: `" & nimExe() & " dump` failed: " & dump
  parseJson(dump)["libpath"].getStr()

# Build Mobile iOS
proc buildMobileIOS(srcDir = ".", sdkPath = "") =
  echo "Building iOS libsds library"

  let embedded = embeddedParams()
  let outDir = outDir()
  let nimcacheDir = outDir / "nimcache"
  if dirExists nimcacheDir:
    rmDir nimcacheDir
  if not dirExists outDir:
    mkDir outDir

  if sdkPath.len == 0:
    quit "Error: Xcode/iOS SDK not found"

  let aFile = outDir / "libsds.a"
  # nimble exits 0 on a failed task: drop the old archive so a failure can't
  # leave a stale one for consumers to pick up.
  if fileExists aFile:
    rmFile aFile
  let cpu = getMyCpu()
  let clangArch = if cpu == "amd64": "x86_64" else: cpu

  # 1) Generate C sources from Nim (no linking)
  # Use unique symbol prefix to avoid conflicts with other Nim libraries
  exec nimExe().quoteShell & " c" & " --nimcache:" & quoteShell(nimcacheDir) & " --os:ios --cpu:" & cpu &
    " --compileOnly:on" & " --noMain --mm:refc" & " --threads:on --opt:size --header" &
    " --nimMainPrefix:libsds" & cBindingsFlags() & " --cc:clang" & " -d:useMalloc" & " -d:noSignalHandler" &
    embedded & nimParams() & " " & srcDir & "/libsds.nim"

  # 2) Compile all generated C files to object files with hidden visibility
  # This prevents symbol conflicts with other Nim libraries (e.g., libnim_status_client).
  # -fno-common: uninitialized globals (Nim's type info, e.g. NTIstring) would
  # otherwise be common symbols, which ld -r keeps global and the final link
  # merges with the host's own, letting this refc runtime overwrite them.
  let nimLibDir = nimLibPath()
  if not fileExists(nimLibDir / "nimbase.h"):
    quit "Error: nimbase.h not found in " & nimLibDir
  let clangFlags =
    "-arch " & clangArch & " -isysroot " & quoteShell(sdkPath) & " -I" & quoteShell(nimLibDir) &
    " -fembed-bitcode -miphoneos-version-min=16.2 -O2" & " -fvisibility=hidden -fno-common"

  var objectFiles: seq[string] = @[]
  for cFile in listFiles(nimcacheDir):
    if cFile.endsWith(".c"):
      let oFile = cFile.changeFileExt("o")
      exec "clang " & clangFlags & " -c " & quoteShell(cFile) & " -o " & quoteShell(oFile)
      objectFiles.add(oFile)

  # 3) Merge into one object exporting only the _Sds* API, so libsds's Nim runtime
  #    can't clash with other static Nim libs (e.g. libnim_status_client).
  #    (libtool -static ignores -exported_symbols_list on current Xcode; ld -r works.
  #    Objects go through a response file: too many long paths for one command line.)
  let objListFile = outDir / "objects.txt"
  writeFile(objListFile, objectFiles.join("\n"))
  let mergedObj = outDir / "libsds_merged.o"
  exec "xcrun ld -r -arch " & clangArch & " -exported_symbol '_sds_*' -o " & quoteShell(mergedObj) &
    " -filelist " & quoteShell(objListFile)
  let (commons, _) = gorgeEx("nm " & quoteShell(mergedObj) & " | grep ' C ' || true")
  if commons.strip.len > 0:
    quit "Error: libsds leaks common symbols:\n" & commons
  exec "ar rcs " & quoteShell(aFile) & " " & quoteShell(mergedObj)
  rmFile mergedObj
  rmFile objListFile
  copyHeader(srcDir)

  echo "✔ iOS library created: " & aFile

task libsdsIOS, "Build the mobile bindings for iOS":
  let srcDir = pkgDir / "library"
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

  let embedded = embeddedParams()
  let outDir = outDir()
  if not dirExists outDir:
    mkDir outDir

  exec nimExe().quoteShell & " c" &
    " --out:" & quoteShell(outDir / "libsds.so") &
    " --threads:on --app:lib --opt:size --noMain --mm:refc --nimMainPrefix:libsds" & cBindingsFlags() &
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
    embedded &
    nimcacheParam("libsds") &
    nimParams() &
    " " & srcDir & "/libsds.nim"
  copyHeader(srcDir)

task libsdsAndroid, "Build the mobile bindings for Android (uses ARCH env var)":
  checkAndroidNdk()
  let srcDir = pkgDir / "library"
  buildMobileAndroid srcDir, "-d:chronicles_log_level=ERROR"

task libsdsAndroidArm64, "Build Android arm64 bindings":
  checkAndroidNdk()
  putEnv("ARCH", "arm64")
  buildMobileAndroid pkgDir / "library", "-d:chronicles_log_level=ERROR"

task libsdsAndroidAmd64, "Build Android amd64 bindings":
  checkAndroidNdk()
  putEnv("ARCH", "amd64")
  buildMobileAndroid pkgDir / "library", "-d:chronicles_log_level=ERROR"

task libsdsAndroidX86, "Build Android x86 bindings":
  checkAndroidNdk()
  putEnv("ARCH", "i386")
  buildMobileAndroid pkgDir / "library", "-d:chronicles_log_level=ERROR"

task libsdsAndroidArm, "Build Android arm bindings":
  checkAndroidNdk()
  putEnv("ARCH", "arm")
  buildMobileAndroid pkgDir / "library", "-d:chronicles_log_level=ERROR"

task libsds, "Build the shared library for the current platform":
  when defined(macosx):
    buildDesktopLib "libsds.dylib", "dynamic", macArchFlags()
  elif defined(windows):
    buildDesktopLib "libsds.dll", "dynamic"
  else:
    buildDesktopLib "libsds.so", "dynamic"

task clean, "Remove build artifacts":
  if getEnv("LIB_OUT_DIR").len == 0:
    if dirExists "build":
      rmDir "build"
  else:
    # Only what the tasks write: LIB_OUT_DIR itself may hold other files.
    let dir = outDir()
    for name in ["generated", "nimcache"]:
      rmDir dir / name
    for name in ["libsds.h", "libsds.a", "libsds.so", "libsds.dylib", "libsds.dll", "libsds.lib"]:
      rmFile dir / name
    for name in testNames:
      rmFile dir / (when defined(windows): name & ".exe" else: name)

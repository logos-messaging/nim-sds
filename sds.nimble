import std/[os, strutils]

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

# The tasks follow the Nim library build contract: the caller picks the compiler
# (NIM), the target and policy flags plus dependency --paths (NIM_PARAMS, last on
# every compile), and the output directory (LIB_OUT_DIR). library/config.nims
# holds what the library itself needs.
#
# An embedder that resolves dependencies itself runs them with plain nim, so its
# resolution stays in charge:
#   printf 'include "%s/sds.nimble"\n' "$PKG" > sds.nims
#   nim --skipParentCfg libsds sds.nims
const pkgDir = currentSourcePath().parentDir

proc nimExe(): string =
  getEnv("NIM", "nim")

proc outDir(): string =
  absolutePath(getEnv("LIB_OUT_DIR", pkgDir / "build"))

proc compileLibrary(flags: string) =
  ## Compiles the library into outDir() and copies its C headers there.
  ## NIM_PARAMS goes after `flags`, so the caller wins.
  let dir = outDir()
  mkDir dir
  exec nimExe() & " c -d:ffiOutputDir=" & (dir / "generated").quoteShell &
    " --nimcache:" & (dir / "nimcache").quoteShell & " " & flags & " " &
    getEnv("NIM_PARAMS") & " " & (pkgDir / "library" / "libsds.nim").quoteShell
  cpFile pkgDir / "library" / "libsds.h", dir / "libsds.h"

task test, "Run the test suite":
  exec "nim c -r --outdir:build tests/test_bloom.nim"
  exec "nim c -r --outdir:build tests/test_reliability.nim"
  exec "nim c -r --outdir:build tests/test_persistence.nim"
  exec "nim c -r --outdir:build tests/test_snapshot_codec.nim"
  exec "nim c -r --outdir:build tests/test_wire_compat.nim"

task libsds, "Build the shared library; NIM_PARAMS selects another target":
  let name =
    when defined(windows): "libsds.dll"
    elif defined(macosx): "libsds.dylib"
    else: "libsds.so"
  compileLibrary "--app:lib --out:" & (outDir() / name).quoteShell

task libsdsStatic, "Build the static library; NIM_PARAMS selects another target":
  let name = when defined(windows): "libsds.lib" else: "libsds.a"
  let aFile = outDir() / name
  # nimble exits 0 on a failed task: drop the old archive so a failure can't
  # leave a stale one for consumers to pick up.
  rmFile aFile
  when defined(macosx):
    # Mach-O, for macOS and iOS: merge into one object exporting only the C API,
    # so libsds's Nim runtime can't clash with other static Nim libs in one link
    # (e.g. libnim_status_client). libtool -static ignores
    # -exported_symbols_list on current Xcode; ld -r works.
    # -fno-common: uninitialized globals (Nim's type info, e.g. NTIstring) would
    # otherwise be common symbols, which ld -r keeps global and the final link
    # merges with the host's own.
    rmDir outDir() / "nimcache"
    compileLibrary "--app:staticlib --out:" & aFile.quoteShell &
      " --passC:-fvisibility=hidden --passC:-fno-common"
    let arch = gorge("xcrun lipo -archs " & aFile.quoteShell).strip()
    # Objects go through a response file: too many long paths for one command line.
    var objects: seq[string]
    for file in listFiles(outDir() / "nimcache"):
      if file.endsWith(".o"):
        objects.add file
    let objList = outDir() / "objects.txt"
    let merged = outDir() / "libsds_merged.o"
    writeFile objList, objects.join("\n")
    exec "xcrun ld -r -arch " & arch & " -exported_symbol '_sds_*' -o " &
      merged.quoteShell & " -filelist " & objList.quoteShell
    let (commons, _) = gorgeEx("nm " & merged.quoteShell & " | grep ' C ' || true")
    if commons.strip.len > 0:
      quit "Error: libsds leaks common symbols:\n" & commons
    rmFile aFile
    exec "ar rcs " & aFile.quoteShell & " " & merged.quoteShell
    rmFile merged
    rmFile objList
  else:
    compileLibrary "--app:staticlib --out:" & aFile.quoteShell

task clean, "Remove build artifacts":
  if dirExists outDir():
    rmDir outDir()

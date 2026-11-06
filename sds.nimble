# Package
version = "0.4.0"
author = "Logos Messaging Team"
description = "E2E Scalable Data Sync API"
license = "MIT"
srcDir = "sds"

# A dependent builds libsds from the installed package
# (nim c <pkg>/library/libsds.nim), so ship library/ too.
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

task clean, "Remove build artifacts":
  if dirExists "build":
    rmDir "build"

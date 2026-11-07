# The default configuration of every build of libsds.nim. The target,
# compiler, policy (--mm, --opt, log level), app type, outputs and how the
# library is linked (sealing included) come from the caller.
--noMain
--header
--threads:on
# Defaults for a local build (`nim c library/libsds.nim`): a shared library and
# its headers in build/. A caller's flags override them.
--app:lib
switch("out", thisDir() & "/../build/" & (when defined(windows): "libsds.dll"
  elif defined(macosx) or defined(ios): "libsds.dylib" else: "libsds.so"))
switch("nimMainPrefix", "libsds")
switch("define", "noSignalHandler")

switch("define", "ffiGenBindings")
switch("define", "targetLang=c")
switch("define", "ffiSrcPath=../libsds.nim")
# libsds.h includes generated/sds.h, which nim-ffi writes during the compile
# into -d:ffiOutputDir. The default is not under nimcacheDir(): that is read
# here before the caller's --nimcache applies.
when not defined(ffiOutputDir):
  switch("define", "ffiOutputDir=" & thisDir() & "/../build/generated")

when defined(android):
  switch("define", "androidNDK")
  switch("define", "chronosEventEngine=epoll")
  switch("define", "chronicles_sinks=textlines[dynamic]")
  switch("passL", "-llog")

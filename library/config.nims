# The default configuration of every build of libsds.nim. The target,
# compiler, policy (--mm, --opt, log level), app type, outputs and how the
# library is linked (sealing included) come from the caller.
--noMain
--header
switch("nimMainPrefix", "libsds")
switch("define", "noSignalHandler")

switch("define", "ffiGenBindings")
switch("define", "targetLang=c")
switch("define", "ffiSrcPath=../libsds.nim")
# libsds.h includes generated/sds.h, which nim-ffi writes during the compile:
# into the caller's nimcache unless the caller names another directory.
when not defined(ffiOutputDir):
  switch("define", "ffiOutputDir=" & nimcacheDir() & "/generated")

when defined(android):
  switch("define", "androidNDK")
  switch("define", "chronosEventEngine=epoll")
  switch("define", "chronicles_sinks=textlines[dynamic]")
  switch("passL", "-llog")

# What libsds needs whoever compiles it. The target, compiler and policy flags
# (--app, --os, --cpu, --cc, --mm, --opt, log level) come from the caller.
--noMain
--header
switch("nimMainPrefix", "libsds")
switch("define", "noSignalHandler")

switch("define", "ffiGenBindings")
switch("define", "targetLang=c")
switch("define", "ffiSrcPath=../libsds.nim")

when defined(android):
  switch("define", "androidNDK")
  switch("define", "chronosEventEngine=epoll")
  switch("define", "chronicles_sinks=textlines[dynamic]")
  switch("passL", "-llog")

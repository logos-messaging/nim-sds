# The package's import root is its srcDir ("sds"), where the API module
# sds.nim lives. Put it on the path so in-repo consumers (tests/, library/)
# resolve `import sds` the same way nimble consumers of the package do.
switch("path", thisDir() & "/sds")

# begin Nimble config (version 2)
--noNimblePath
when withDir(thisDir(), system.fileExists("nimble.paths")):
  include "nimble.paths"
# end Nimble config

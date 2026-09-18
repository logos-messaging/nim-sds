# Runs the manifest's tasks without nimble, for an embedder that resolved the
# dependencies itself and builds from nimble's installed copy of this package:
#   cd <out> && NIM_PARAMS="--path:..." nim libsdsDynamicLinux <package>/library/sds_tasks.nims
# Lives under library/ because installDirs ships that directory.
include "../sds.nimble"

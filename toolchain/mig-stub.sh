#!/bin/sh
# Stand-in for `mig` when cross-building WebKit for Leopard from Linux.
#
# WTF/wtf/PlatformJSCOnly.cmake runs
#   mig -header mach_exc.h -user mach_excUser.c -sheader MachExceptionsServer.h
#       -server mach_excServer.c -DMACH_EXC_SERVER_TASKIDTOKEN_STATE [-isysroot X] MachExceptions.defs
# in the derived-sources directory. There is no mig on this host, so the four
# outputs were generated once ON MAC OS X 10.5 with Leopard's own migcom
#   MIGCC=/usr/bin/gcc /usr/bin/mig <same arguments> MachExceptions.defs
# (the wrapper's xcodebuild lookup fails without Xcode; MIGCC bypasses it)
# and are kept in mig-out/ next to this script. Regenerate them there if
# Source/WTF/wtf/mac/MachExceptions.defs changes.
#
# Pass as -DMig_EXECUTABLE=$PWD/toolchain/mig-stub.sh.
set -e
here="$(cd "$(dirname "$0")" && pwd)"
for f in mach_exc.h mach_excUser.c MachExceptionsServer.h mach_excServer.c; do
    cp "$here/mig-out/$f" "./$f"
done

#!/bin/sh
# Build the FrostByte shell (Cocoa WPEPlatform backend + minimal browser) for ppc64 Mac OS X 10.5.
#   frostbyte/build.sh            -> frostbyte/build/frostbyte-shell (entry point fixed, ready to copy)
#   LEOPARD_TARGET=g5 frostbyte/build.sh -> frostbyte/build-g5/ (toolchain/target.sh; t4240 is the default)
set -e
F="$(cd "$(dirname "$0")" && pwd)"
. "$F/../toolchain/wpe-env.sh"
export PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
CC1="${CC% *}"
# g5/generic: Automatic graphics picks the GPU tier on any accelerated renderer, and the open-file limit is raised
# from 256 before WebKit starts (fb-hardware.m).
TARGET_DEFS=""
[ "$LEOPARD_TARGET" = t4240 ] || TARGET_DEFS="-DFROSTBYTE_GL_ANY_ACCELERATED=1 -DFROSTBYTE_RAISE_FD_LIMIT=1"
# Software Update (fb-update.m) fetches this build's disk image from each release: t4240 -> the e6500 DMG,
# g5 -> the G5 DMG, generic -> a "generic" entry (none is published, so generic builds never update themselves:
# the G5 build would trap on an e6500, and the e6500 build needs ISA 2.06).
case "$LEOPARD_TARGET" in t4240) UPDATE_TARGET=e6500 ;; *) UPDATE_TARGET="$LEOPARD_TARGET" ;; esac
TARGET_DEFS="$TARGET_DEFS -DFROSTBYTE_UPDATE_TARGET=\"$UPDATE_TARGET\""
# toolchain/sdkfix: 10.5 SDK header bug fixes (LP64 CMSG_*), the same ones WebKit and the deps get.
CF="-m64 $LEOPARD_CPU_FLAGS $TARGET_DEFS -isystem $F/../toolchain/sdkfix -std=gnu11 -O2 -Wall -fno-strict-aliasing $(pkg-config --cflags wpe-webkit-2.0 wpe-platform-2.0 epoxy hogweed)"
# FROSTBYTE_OUT=<dir> builds elsewhere (test compiles that must not replace the deployed build).
O="${FROSTBYTE_OUT:-$F/build$LEOPARD_SUFFIX}"
mkdir -p "$O"
$CC1 $CF -fnext-runtime -fobjc-abi-version=2 -c "$F/platform/wpe-cocoa.m" -o "$O/wpe-cocoa.o"
$CC1 $CF -c "$F/platform/wpe-cocoa-egl.c" -o "$O/wpe-cocoa-egl.o"
SHELL_OBJS="$O/fb-webgl-probe.o"
$CC1 $CF -c "$F/shell/fb-webgl-probe.c" -o "$O/fb-webgl-probe.o"   # the --gl33-probe helper (plain C, libepoxy)
for m in frostbyte-shell fb-defaults fb-hardware fb-window fb-chrome fb-bookmarks fb-history fb-library fb-omnibox fb-preferences fb-about fb-update; do
    $CC1 $CF -c -fnext-runtime -fobjc-abi-version=2 "$F/shell/$m.m" -o "$O/$m.o"
    SHELL_OBJS="$SHELL_OBJS $O/$m.o"
done
$CC1 -m64 -o "$O/frostbyte-shell" $SHELL_OBJS "$O/wpe-cocoa.o" "$O/wpe-cocoa-egl.o" \
    $(pkg-config --libs wpe-webkit-2.0 wpe-platform-2.0 epoxy hogweed nettle) -framework Cocoa -framework OpenGL -framework IOKit \
    -framework ApplicationServices $LDFLAGS
python3 -I "$F/../tools/fix-ppc64-entry.py" "$O/frostbyte-shell"

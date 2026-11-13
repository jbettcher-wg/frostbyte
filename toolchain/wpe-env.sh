# Cross environment for the WPE dependency stack, WebKit and the FrostByte shell (ppc64 Mac OS X 10.5).
#   . toolchain/wpe-env.sh
# Libraries install with --prefix=/opt/wpe and DESTDIR=$WPE_STAGE; the app packaging step moves them
# into FrostByte.app and rewrites their install names, so /opt/wpe never exists on a user's Mac.
#
# Where things are (./build.sh sets them up; each can be overridden from the environment):
#   LEOPARD_ROOT       this checkout
#   LEOPARD_BUILD      build outputs (default <checkout>/build)
#   LEOPARD_DL         verified source archives (default ~/.cache/frostbyte/dl)
#   LEOPARD_TOOLCHAIN  the powerpc-apple-darwin9 toolchain   } recorded in $LEOPARD_BUILD/toolchain.env
#   LEOPARD_SDK        the Mac OS X 10.5 SDK                  } by the toolchain and sdk stages
#   LEOPARD_TARGET     t4240 | g5 | generic (toolchain/target.sh; default generic)
#
# This file is the public repository's own. The development tree's wpe-env.sh holds the same
# variables with fixed paths; tools/sync-from-devtree.sh maps the other scripts onto these names.
# POSIX sh cannot tell a sourced file where it is (and ${BASH_SOURCE[0]} is a fatal syntax error
# in dash), so: the environment, bash's BASH_SOURCE, then the callers' $S (repo root) or $F
# (frostbyte/), then this file's usual place relative to the working directory.
if [ -z "${LEOPARD_ROOT:-}" ] || [ ! -f "$LEOPARD_ROOT/toolchain/wpe-env.sh" ]; then
    LEOPARD_ROOT=
    if [ -n "${BASH_VERSION:-}" ]; then eval 'LEOPARD_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)'; fi
    for _r in "$LEOPARD_ROOT" "${S:-}" "${F:+$F/..}" "$PWD"; do
        if [ -n "$_r" ] && [ -f "$_r/toolchain/wpe-env.sh" ]; then LEOPARD_ROOT=$(cd "$_r" && pwd); break; fi
    done
    unset _r
    [ -n "$LEOPARD_ROOT" ] || { echo "wpe-env.sh: cannot find the FrostByte checkout; set LEOPARD_ROOT" >&2; return 2 2>/dev/null || exit 2; }
fi
export LEOPARD_ROOT
. "$LEOPARD_ROOT/toolchain/target.sh" || return 2 2>/dev/null || exit 2
export FROSTBYTE_CACHE="${FROSTBYTE_CACHE:-$HOME/.cache/frostbyte}"
export LEOPARD_BUILD="${LEOPARD_BUILD:-$LEOPARD_ROOT/build}"
export LEOPARD_DL="${LEOPARD_DL:-$FROSTBYTE_CACHE/dl}"
if [ -f "$LEOPARD_BUILD/toolchain.env" ]; then
    [ -n "${LEOPARD_TOOLCHAIN:-}" ] || LEOPARD_TOOLCHAIN=$(. "$LEOPARD_BUILD/toolchain.env"; echo "${LEOPARD_TOOLCHAIN:-}")
    [ -n "${LEOPARD_SDK:-}" ] || LEOPARD_SDK=$(. "$LEOPARD_BUILD/toolchain.env"; echo "${LEOPARD_SDK:-}")
fi
if [ -z "${LEOPARD_TOOLCHAIN:-}" ] || [ ! -x "$LEOPARD_TOOLCHAIN/bin/powerpc-apple-darwin9-gcc" ]; then
    echo "wpe-env.sh: no toolchain yet; run ./build.sh toolchain (or set LEOPARD_TOOLCHAIN)" >&2
fi
export LEOPARD_TOOLCHAIN LEOPARD_SDK
# WebGL (FrostByte 0.4): ON builds WebKit with ANGLE and WebGL (toolchain/configure-wpe.sh) and LeopardEGL's
# WebGL library (deps/build-deps.sh leopardegl). WebGL stays off at run time until it is chosen in
# Preferences > Hardware. LEOPARD_WEBGL=OFF builds the 0.3.x configuration.
export LEOPARD_WEBGL="${LEOPARD_WEBGL:-ON}"
case "$LEOPARD_WEBGL" in ON|OFF) ;; *) echo "wpe-env.sh: LEOPARD_WEBGL must be ON or OFF" >&2; return 2 2>/dev/null || exit 2 ;; esac
export WPE_PREFIX=/opt/wpe
# FB_STAGE_DIR: use another dependency stage (e.g. one built elsewhere) instead of this build's.
export WPE_STAGE="${FB_STAGE_DIR:-$LEOPARD_BUILD/stage-wpe$LEOPARD_SUFFIX}"
export WPE_SYSROOT=$WPE_STAGE$WPE_PREFIX
_tc="$LEOPARD_TOOLCHAIN/bin/powerpc-apple-darwin9"
export CC="$_tc-gcc -m64 $LEOPARD_CPU_FLAGS"
export CXX="$_tc-g++ -m64 $LEOPARD_CPU_FLAGS"
export CPP="$CC -E"
export AR=$_tc-ar RANLIB=$_tc-ranlib NM=$_tc-nm STRIP=$_tc-strip OTOOL=$_tc-otool
export INSTALL_NAME_TOOL=$_tc-install_name_tool LIPO=$_tc-lipo
unset _tc
export CFLAGS="-O2 -isystem $LEOPARD_ROOT/toolchain/include -include $LEOPARD_ROOT/toolchain/leopard-compat.h -I$WPE_SYSROOT/include"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-L$WPE_SYSROOT/lib -static-libgcc -static-libstdc++ -Wl,-headerpad_max_install_names"
export PKG_CONFIG_LIBDIR=$WPE_SYSROOT/lib/pkgconfig:$WPE_SYSROOT/share/pkgconfig
export PKG_CONFIG_SYSROOT_DIR=$WPE_STAGE
# Host tools built by ./build.sh hosttools (meson, gperf, unifdef, GLib's code generators).
export PATH="$LEOPARD_BUILD/host/bin:$PATH"
# meson --cross-file for this target, generated from toolchain/darwin9-ppc64.meson.in.
export LEOPARD_MESON_CROSS="$LEOPARD_BUILD/deps$LEOPARD_SUFFIX/darwin9-ppc64$LEOPARD_SUFFIX.meson"
mkdir -p "$WPE_SYSROOT/lib/pkgconfig" "$(dirname "$LEOPARD_MESON_CROSS")"
sed -e "s|@TOOLCHAIN@|$LEOPARD_TOOLCHAIN|g" -e "s|@CPU@|$LEOPARD_MESON_CPU|" -e "s|@TARGET@|$LEOPARD_TARGET|" \
    -e "s|@CPUFLAGS@|$(printf "'%s', " $LEOPARD_CPU_FLAGS | sed 's/, $//')|g" \
    "$LEOPARD_ROOT/toolchain/darwin9-ppc64.meson.in" > "$LEOPARD_MESON_CROSS.tmp"
if cmp -s "$LEOPARD_MESON_CROSS.tmp" "$LEOPARD_MESON_CROSS" 2>/dev/null; then rm -f "$LEOPARD_MESON_CROSS.tmp"
else mv "$LEOPARD_MESON_CROSS.tmp" "$LEOPARD_MESON_CROSS"; fi

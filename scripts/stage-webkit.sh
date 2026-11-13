#!/usr/bin/env bash
# Stage "webkit": configure, build and install WPE WebKit 2.54.1 (patched) into the stage.
#   scripts/stage-webkit.sh [--configure-only] [extra cmake args...]
#
# Configure: toolchain/configure-wpe.sh into $LEOPARD_BUILD/wpe-254<suffix>, re-run when the
# configure script, the CMake toolchain file, the target or the patched tree changes.
# Build and install: tools/wpe-ninja.sh (memory-capped, job count from RAM; see that file).
# FB_DRY_RUN=1 prints the commands instead.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$FB_ROOT/toolchain/wpe-env.sh"

configure_only=0
if [ "${1:-}" = --configure-only ]; then configure_only=1; shift; fi
SRC="$LEOPARD_BUILD/src/wpewebkit-2.54.1"
B="${WPE_BUILD_DIR:-$LEOPARD_BUILD/wpe-254$LEOPARD_SUFFIX}"
export WPE_SRC_DIR="$SRC" WPE_BUILD_DIR="$B"
[ -f "$SRC/.frostbyte-stamp" ] || die "no patched WebKit tree: run ./build.sh fetch"
[ -f "$WPE_SYSROOT/lib/pkgconfig/glib-2.0.pc" ] || [ "${FB_DRY_RUN:-0}" = 1 ] || die "the dependency stack is not built: run ./build.sh deps"

say "webkit ($LEOPARD_TARGET) -> $B"
want=$( { cat "$FB_ROOT/toolchain/configure-wpe.sh" "$FB_ROOT/toolchain/darwin9-ppc64.cmake" "$FB_ROOT/toolchain/target.sh";
          cat "$SRC/.frostbyte-stamp"; echo "$LEOPARD_TOOLCHAIN $LEOPARD_SDK webgl=$LEOPARD_WEBGL $*"; } | cksum | cut -d' ' -f1)
if [ ! -f "$B/build.ninja" ] || [ "$(cat "$B/.frostbyte-configured" 2>/dev/null)" != "$want" ]; then
    run "$FB_ROOT/toolchain/configure-wpe.sh" "$@"
    [ "${FB_DRY_RUN:-0}" = 1 ] || echo "$want" > "$B/.frostbyte-configured"
else
    ok "configured"
fi
[ "$configure_only" = 1 ] && exit 0

if [ "${FB_DRY_RUN:-0}" = 1 ]; then
    run "$FB_ROOT/tools/wpe-ninja.sh"
    run env DESTDIR="$WPE_STAGE" "$FB_ROOT/tools/wpe-ninja.sh" install
    run "$FB_ROOT/deps/build-deps.sh" fix-install-names
    exit 0
fi
note "$(ninja -C "$B" -n 2>/dev/null | tail -1)"
"$FB_ROOT/tools/wpe-ninja.sh"
DESTDIR="$WPE_STAGE" "$FB_ROOT/tools/wpe-ninja.sh" install > "$B/install.log"
"$FB_ROOT/deps/build-deps.sh" fix-install-names
ok "WebKit installed into $WPE_STAGE"

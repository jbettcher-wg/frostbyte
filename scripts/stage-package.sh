#!/usr/bin/env bash
# Stages "shell", "app" and "dmg".
#   scripts/stage-package.sh shell   build the FrostByte shell (frostbyte/build.sh)
#   scripts/stage-package.sh app     assemble a self-contained FrostByte.app and check it
#   scripts/stage-package.sh dmg     a drag-to-install disk image of the app (tools/make-dmg.sh)
#
# The app step runs tools/package-app.py (every /opt/wpe library moved into Contents/Frameworks
# with @loader_path install names, helpers in Contents/Libexec, fix-ppc64-entry on every
# executable), tools/collect-licenses.py, then tools/check-bundle.py (thin ppc64, load commands
# against the 10.5 SDK, entry points, no /opt/wpe, and for g5/generic an instruction scan with
# llvm-objdump). FB_STAGE_DIR and FB_SHELL_BIN package a stage and shell built elsewhere.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$FB_ROOT/toolchain/wpe-env.sh"
PY=$(fb_python)
OUT="$LEOPARD_BUILD/dist/FrostByte$LEOPARD_SUFFIX"
SHELL_BIN="${FB_SHELL_BIN:-$FB_ROOT/frostbyte/build$LEOPARD_SUFFIX/frostbyte-shell}"

case "${1:-}" in
shell)
    say "shell ($LEOPARD_TARGET)"
    [ -f "$WPE_SYSROOT/lib/pkgconfig/wpe-webkit-2.0.pc" ] || [ "${FB_DRY_RUN:-0}" = 1 ] || die "WebKit is not installed in the stage: run ./build.sh webkit"
    run "$FB_ROOT/frostbyte/build.sh"
    ok "$SHELL_BIN"
    ;;
app)
    say "app ($LEOPARD_TARGET) -> $OUT/FrostByte.app"
    [ -x "$SHELL_BIN" ] || [ "${FB_DRY_RUN:-0}" = 1 ] || die "no $SHELL_BIN: run ./build.sh shell"
    if [ "$LEOPARD_TARGET" != t4240 ] && ! have llvm-objdump; then
        die "check-bundle.py's instruction scan for $LEOPARD_TARGET needs llvm-objdump (LLVM) on PATH"
    fi
    case "$LEOPARD_TARGET" in g5) isa=g5 ;; generic) isa=generic ;; *) isa=none ;; esac
    run "$PY" -I "$FB_ROOT/tools/package-app.py" --stage "$WPE_SYSROOT" --shell "$SHELL_BIN" --out "$OUT"
    # NOTICE promises every component's licence text inside the app.
    run "$PY" -I "$FB_ROOT/tools/collect-licenses.py" "$OUT/FrostByte.app/Contents/Resources/Licenses"
    run "$PY" -I "$FB_ROOT/tools/check-bundle.py" --isa "$isa" --sdk "$LEOPARD_SDK" "$OUT/FrostByte.app"
    ok "$OUT/FrostByte.app"
    ;;
dmg)
    say "dmg"
    [ -d "$OUT/FrostByte.app" ] || [ "${FB_DRY_RUN:-0}" = 1 ] || die "no $OUT/FrostByte.app: run ./build.sh app"
    run "$FB_ROOT/tools/make-dmg.sh" "$OUT/FrostByte.app" "$LEOPARD_BUILD/dist"
    ;;
*) die "usage: stage-package.sh shell|app|dmg" ;;
esac

#!/usr/bin/env bash
# Stage "toolchain": find, download or build the powerpc-apple-darwin9 compiler, then smoke-test it.
#   scripts/stage-toolchain.sh [auto|prebuilt|source|<dir>]       (default: FB_TOOLCHAIN_MODE or auto)
#
#   auto      an installed toolchain if there is one; else the prebuilt tarball for this host if one
#             is published (config/toolchain.lock); else build from source.
#   prebuilt  download and install the tarball (FB_TOOLCHAIN_TARBALL=<file> installs a local one).
#   source    build it (toolchain/darwin-cross/build-toolchain.sh; about an hour on a fast machine).
#   <dir>     use the toolchain in <dir> (bin/powerpc-apple-darwin9-gcc and friends).
#
# A compiler split over two prefixes (GCC in one, cctools in another) can be adopted without rebuilding:
#   FB_TOOLCHAIN_GCC=<gcc prefix> FB_TOOLCHAIN_CCTOOLS=<cctools prefix> scripts/stage-toolchain.sh
#
# On Mac OS X 10.5 (native builds) the usual locations are searched first:
#   /usr/local/frostbyte-toolchain        (the darwin9-ppc64 tarball, or build-toolchain.sh --mode=native)
#   /usr/local/gcc-15 + /usr/local/cctools-877   (older native installs; accepted only if the GCC has
#                                          ppc64 libraries, and with a warning: it lacks the gcc15p patches)
#
# The SDK stage must have run first: the toolchain's sysroot is <toolchain>/sdk -> the imported SDK.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/host.sh"
fb_detect_host

T=$FB_TARGET_TRIPLE
ID=$(awk '$1=="id" {print $2}' "$FB_TOOLCHAIN_LOCK")
MODE="${1:-${FB_TOOLCHAIN_MODE:-auto}}"
SDK=${LEOPARD_SDK:-$(state_get LEOPARD_SDK)}
[ -n "$SDK" ] && [ -d "$SDK" ] || die "no SDK yet: run ./build.sh sdk --sdk=... first"
INSTALL="$FROSTBYTE_CACHE/toolchains/$ID-$FB_HOST_TAG"

say "toolchain ($FB_HOST_DESC)"

# smoke <dir>: C, C++ and Objective-C, ppc64, linked; ld64 is the patched 253.9.
smoke() {
    local tc="$1" t; t=$(mktemp -d "${TMPDIR:-/tmp}/fbtc.XXXXXX")
    printf '#include <stdio.h>\nint main(void){puts("hi");return 0;}\n' > "$t/a.c"
    printf '#include <string>\n#include <vector>\nint main(){std::vector<std::string> v{"a"};return (int)v.size()-1;}\n' > "$t/b.cc"
    printf '#import <Foundation/Foundation.h>\nint main(void){NSAutoreleasePool *p=[NSAutoreleasePool new];[p release];return 0;}\n' > "$t/c.m"
    "$tc/bin/$T-gcc" -m64 -O2 "$t/a.c" -o "$t/a" &&
    "$tc/bin/$T-g++" -m64 -O2 -std=gnu++20 -static-libgcc -static-libstdc++ "$t/b.cc" -o "$t/b" &&
    "$tc/bin/$T-gcc" -m64 -O2 -fnext-runtime -fobjc-abi-version=2 "$t/c.m" -o "$t/c" -framework Foundation &&
    "$tc/bin/$T-gcc" -m32 -O2 "$t/a.c" -o "$t/a32" || { rm -rf "$t"; return 1; }
    local cpu; cpu=$("$tc/bin/$T-otool" -h "$t/b" | awk 'NR==4 {print $2}')
    [ "$cpu" = 16777234 ] || { warn "smoke test: b is not ppc64 (cputype $cpu)"; rm -rf "$t"; return 1; }
    "$tc/bin/$T-ld" -v 2>&1 | grep -q "253.9" || { warn "smoke test: ld is not ld64-253.9"; rm -rf "$t"; return 1; }
    rm -rf "$t"
}

# The sysroot link and the include-fixed headers come from the user's SDK.
attach_sdk() { # <dir>
    local tc="$1"
    [ -w "$tc" ] || return 0
    ln -sfn "$SDK" "$tc/sdk"
    local conf="$tc/lib/gcc/$T/15.3.0/install-tools/mkheaders.conf" mk="$tc/libexec/gcc/$T/15.3.0/install-tools/mkheaders"
    if [ -f "$conf" ] && grep -q '@SDK@' "$conf"; then
        note "regenerating GCC's include-fixed headers from the SDK (mkheaders)"
        sed "s|@SDK@|$tc/sdk|" "$conf" > "$conf.new" && mv "$conf.new" "$conf"
        "$mk" "$tc" > "$tc/mkheaders.log" 2>&1 || die "mkheaders failed ($tc/mkheaders.log)"
        # GCC 15 installs limits.h/syslimits.h in include/; mkheaders (older than that change) also
        # copies them into include-fixed. Drop the copies so the layout is the one GCC built.
        # mkheaders' fixincludes leaves an empty DONE marker in the SDK (sysroot via symlink).
        [ -f "$SDK/usr/include/DONE" ] && [ ! -s "$SDK/usr/include/DONE" ] && rm -f "$SDK/usr/include/DONE"
        local h inc="$tc/lib/gcc/$T/15.3.0"
        for h in limits.h syslimits.h; do
            [ -f "$inc/include/$h" ] && rm -f "$inc/include-fixed/$h"
        done
    fi
}

use() { # <dir> <how>
    local tc; tc=$(cd "$1" && pwd)
    attach_sdk "$tc"
    note "smoke test (C, C++, Objective-C; ppc and ppc64)"
    smoke "$tc" || die "the toolchain in $tc failed its smoke test"
    state_set LEOPARD_TOOLCHAIN "$tc"
    ok "LEOPARD_TOOLCHAIN=$tc ($2)"
    exit 0
}

# Is <dir> a toolchain we made (or at least a complete one)?
complete() { [ -x "$1/bin/$T-gcc" ] && [ -x "$1/bin/$T-g++" ] && [ -x "$1/bin/$T-ld" ] && [ -x "$1/bin/$T-otool" ]; }

adopt_split() { # <gcc prefix> <cctools prefix> -> shim dir with one bin/
    local g="$1" c="$2" shim="$FROSTBYTE_CACHE/toolchains/adopted-$(printf '%s %s' "$1" "$2" | cksum | cut -d' ' -f1)" f
    [ -x "$g/bin/$T-gcc" ] || die "no $T-gcc in $g/bin"
    [ -x "$c/bin/$T-ld" ] || die "no $T-ld in $c/bin"
    rm -rf "$shim"; mkdir -p "$shim/bin"
    for f in "$c"/bin/$T-*; do ln -s "$f" "$shim/bin/"; done
    for f in "$g"/bin/$T-*; do ln -sfn "$f" "$shim/bin/"; done
    # The adopted GCC has its own built-in sysroot; it must be this same SDK.
    local sr; sr=$("$g/bin/$T-gcc" -print-sysroot)
    if [ -n "$sr" ] && [ "$(cd "$sr" && pwd -P)" != "$(cd "$SDK" && pwd -P)" ]; then
        local d1 d2 PY; PY=$(fb_python)
        d1=$("$PY" -I "$FB_ROOT/tools/sdk-digest.py" "$sr" | cut -d' ' -f1)
        d2=$("$PY" -I "$FB_ROOT/tools/sdk-digest.py" "$SDK" | cut -d' ' -f1)
        [ "$d1" = "$d2" ] || die "the adopted GCC's sysroot $sr is not the verified SDK"
        note "adopted GCC's sysroot $sr is identical to the verified SDK"
    fi
    printf 'id=adopted\ngcc=%s\ncctools=%s\n' "$g" "$c" > "$shim/FROSTBYTE-TOOLCHAIN"
    echo "$shim"
}

install_tarball() { # <file>
    local f="$1" top
    say "install $(basename "$f") -> $INSTALL"
    rm -rf "$INSTALL.new"; mkdir -p "$INSTALL.new"
    case "$f" in *.xz) xz -dc "$f" ;; *) gzip -dc "$f" ;; esac | tar -C "$INSTALL.new" -xf -
    top=$(ls "$INSTALL.new")
    [ -f "$INSTALL.new/$top/FROSTBYTE-TOOLCHAIN" ] || die "$f is not a FrostByte toolchain tarball"
    rm -rf "$INSTALL"; mv "$INSTALL.new/$top" "$INSTALL"; rmdir "$INSTALL.new"
}

# ---- explicit choices ---------------------------------------------------------------------------
if [ -n "${FB_TOOLCHAIN_GCC:-}${FB_TOOLCHAIN_CCTOOLS:-}" ]; then
    use "$(adopt_split "${FB_TOOLCHAIN_GCC:?set both FB_TOOLCHAIN_GCC and FB_TOOLCHAIN_CCTOOLS}" "${FB_TOOLCHAIN_CCTOOLS:?set both}")" adopted
fi
case "$MODE" in
auto|prebuilt|source) ;;
*) complete "$MODE" || die "$MODE has no $T-gcc/g++/ld/otool in bin/"; use "$MODE" "given" ;;
esac

# ---- already installed --------------------------------------------------------------------------
prev=$(state_get LEOPARD_TOOLCHAIN)
if [ "$MODE" = auto ]; then
    for c in "$prev" "$INSTALL"; do
        [ -n "$c" ] && complete "$c" && use "$c" "installed"
    done
    if [ "$FB_HOST_MODE" = native ]; then
        complete /usr/local/frostbyte-toolchain && use /usr/local/frostbyte-toolchain "native, /usr/local"
        if [ -x /usr/local/gcc-15/bin/gcc-15 ] && [ -x /usr/local/cctools-877/bin/ld ]; then
            if [ ! -e /usr/local/gcc-15/lib/ppc64/libstdc++.a ]; then
                warn "/usr/local/gcc-15 has no ppc64 libraries (it was built --disable-multilib), so it cannot link FrostByte."
            elif [ "${FB_ALLOW_UNPATCHED_GCC:-0}" = 1 ]; then
                shim="$FROSTBYTE_CACHE/toolchains/native-usr-local"; rm -rf "$shim"; mkdir -p "$shim/bin"
                for f in /usr/local/cctools-877/bin/$T-*; do ln -s "$f" "$shim/bin/"; done
                for t in gcc g++ cpp; do ln -sfn /usr/local/gcc-15/bin/$t-15 "$shim/bin/$T-$t"; done
                warn "using /usr/local/gcc-15 without the gcc15p ABI patches (FB_ALLOW_UNPATCHED_GCC=1)"
                use "$shim" "native, /usr/local/gcc-15"
            else
                warn "/usr/local/gcc-15 lacks the darwin64 ABI fixes FrostByte needs (patches/gcc/0101, 0102); set FB_ALLOW_UNPATCHED_GCC=1 to use it anyway."
            fi
        fi
    fi
fi

# ---- prebuilt -----------------------------------------------------------------------------------
read -r _ pfile psum purl < <(awk -v h="$FB_HOST_TAG" '$1==h' "$FB_TOOLCHAIN_LOCK") || true
if [ "$MODE" != source ]; then
    if [ -n "${FB_TOOLCHAIN_TARBALL:-}" ]; then
        [ -f "$FB_TOOLCHAIN_TARBALL" ] || die "FB_TOOLCHAIN_TARBALL=$FB_TOOLCHAIN_TARBALL does not exist"
        if [ -f "$FB_TOOLCHAIN_TARBALL.sha256" ]; then
            [ "$(sha256_file "$FB_TOOLCHAIN_TARBALL")" = "$(cut -d' ' -f1 "$FB_TOOLCHAIN_TARBALL.sha256")" ] \
                || die "$FB_TOOLCHAIN_TARBALL does not match its .sha256"
        fi
        install_tarball "$FB_TOOLCHAIN_TARBALL"
        use "$INSTALL" "prebuilt, local tarball"
    elif [ -n "${psum:-}" ] && [ "$psum" != - ]; then
        fetch_entry toolchain "$pfile" "$psum" "$purl"
        install_tarball "$LEOPARD_DL/toolchain/$pfile"
        attach_sdk "$INSTALL"
        if [ "$MODE" = auto ] && ! smoke "$INSTALL" 2>/dev/null; then
            # e.g. a Linux older than the one the tarball was built on (glibc, libstdc++)
            warn "the prebuilt toolchain does not run on this host; building it from source instead"
            rm -rf "$INSTALL"
        else
            use "$INSTALL" "prebuilt"
        fi
    elif [ "$MODE" = prebuilt ]; then
        die "no prebuilt toolchain is published for $FB_HOST_TAG yet (config/toolchain.lock); use --toolchain=source"
    else
        note "no prebuilt toolchain published for $FB_HOST_TAG; building it from source"
    fi
fi

# ---- from source --------------------------------------------------------------------------------
bmode=cross; [ "$FB_HOST_MODE" = native ] && bmode=native
[ "${FB_DRY_RUN:-0}" = 1 ] && { run "$FB_ROOT/toolchain/darwin-cross/build-toolchain.sh" --mode=$bmode --prefix="$INSTALL" --sdk="$SDK"; exit 0; }
capped "$FB_ROOT/toolchain/darwin-cross/build-toolchain.sh" --mode=$bmode --prefix="$INSTALL" --sdk="$SDK" --jobs="$(fb_jobs)"
use "$INSTALL" "built from source"

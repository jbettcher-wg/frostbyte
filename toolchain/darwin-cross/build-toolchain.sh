#!/usr/bin/env bash
# Build FrostByte's compiler from source: GCC 15.3.0 (with the patches in patches/gcc) and
# cctools 877.8 + ld64 253.9 (with the patches in patches/cctools), for powerpc-apple-darwin9,
# into ONE prefix:
#
#   <prefix>/bin/powerpc-apple-darwin9-{gcc,g++,as,ld,ar,ranlib,nm,otool,install_name_tool,lipo,...}
#   <prefix>/powerpc-apple-darwin9/bin/{as,ld,...}   where GCC's driver looks for them
#   <prefix>/sdk -> the Mac OS X 10.5 SDK            GCC's sysroot (relocatable: it is inside the prefix)
#   <prefix>/FROSTBYTE-TOOLCHAIN                     what was built, from what
#
#   build-toolchain.sh --prefix=DIR --sdk=SDK [--mode=cross|native|canadian] [--jobs=N] [--work=DIR]
#                      [--build-toolchain=DIR]   (canadian: a finished cross toolchain to build with)
#
# Modes:
#   cross     (default) the toolchain runs on this machine (Linux or macOS) and targets 10.5 PowerPC.
#   native    run ON Mac OS X 10.5 PowerPC: the toolchain runs there. Needs a working C++11 compiler
#             to build GCC (FB_BOOTSTRAP_CC/FB_BOOTSTRAP_CXX, default /usr/local/gcc-15/bin/gcc-15).
#   canadian  run on Linux with a finished cross toolchain: builds a toolchain that RUNS on 10.5
#             PowerPC (what the darwin9-ppc64 prebuilt tarball holds). Its prefix is fixed at
#             build time (default /usr/local/frostbyte-toolchain): its programs load GCC's
#             libstdc++ from <prefix>/lib.
#
# Notes on choices made here:
#   - one prefix for cctools and GCC, with as/ld in GCC's tool directory rather than
#     --with-as/--with-ld absolute paths, and the SDK as <prefix>/sdk, so the prefix can move;
#   - cctools without LTO support (no dependency on the build host's libLTO); ld64's version is given
#     to GCC with --with-ld64=253.9 rather than detected;
#   - a no-op powerpc-apple-darwin9-dsymutil in the prefix: collect2 runs dsymutil after a -g link,
#     and a host LLVM dsymutil found on PATH instead crashes it;
#   - GCC is multilib (ppc + ppc64) with C, C++ and Objective-C, because FrostByte is linked against
#     its ppc64 libstdc++.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../scripts/lib.sh"

T=powerpc-apple-darwin9
GCC_V=15.3.0
LD64_V=253.9
MODE=cross PREFIX= SDK= WORK= JOBS= BTC=
for a in "$@"; do
    case "$a" in
    --prefix=*) PREFIX=${a#*=} ;;
    --sdk=*) SDK=${a#*=} ;;
    --mode=*) MODE=${a#*=} ;;
    --jobs=*) JOBS=${a#*=} ;;
    --work=*) WORK=${a#*=} ;;
    --build-toolchain=*) BTC=${a#*=} ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) die "unknown option $a" ;;
    esac
done
[ -n "$PREFIX" ] || { [ "$MODE" = canadian ] && PREFIX=/usr/local/frostbyte-toolchain || die "--prefix is required"; }
[ -n "$SDK" ] && [ -d "$SDK" ] || die "--sdk=<MacOSX10.5.sdk> is required (scripts/stage-sdk.sh imports one)"
SDK=$(cd "$SDK" && pwd)
WORK=${WORK:-$LEOPARD_BUILD/toolchain-work/$MODE}
JOBS=${JOBS:-$(host_ncpu)}
case "$MODE" in cross|native|canadian) ;; *) die "--mode must be cross, native or canadian" ;; esac
if [ "$MODE" = canadian ]; then
    [ -x "$BTC/bin/$T-gcc" ] || die "--build-toolchain=<cross toolchain prefix> is required for --mode=canadian"
    DEST="$WORK/root"            # staged with DESTDIR, packed by make-toolchain-tarball.sh
else
    DEST=""
fi
P="$DEST$PREFIX"
mkdir -p "$WORK" "$P"
LOG="$WORK/build.log"
say "toolchain ($MODE) -> $PREFIX${DEST:+ (staged in $DEST)}; log $LOG"

# ---- sources ------------------------------------------------------------------------------------
fetch_file gcc-$GCC_V.tar.xz
for f in gmp-6.2.1.tar.bz2 mpfr-4.1.0.tar.bz2 mpc-1.2.1.tar.gz isl-0.24.tar.bz2 cctools-port-f01442232f18.tar.gz; do fetch_file $f; done

apply_patches() { # <tree> <patch>...: apply each once (a reverse dry run detects "already applied")
    local tree="$1" p d; shift
    for p in "$@"; do
        d="$tree"
        # 0004 was made inside cctools/ (paths without the cctools/ component)
        if [ -d "$tree/cctools" ] && ! grep -q '^+++ b/cctools/' "$p"; then d="$tree/cctools"; fi
        if patch -d "$d" -p1 -R --dry-run -s -f < "$p" >/dev/null 2>&1; then
            note "already applied: ${p##*/}"
        else
            note "patch ${p##*/}"
            patch -d "$d" -p1 -s --no-backup-if-mismatch < "$p"
        fi
    done
}

src_cctools() { # fresh tree with the patches for this mode
    local s="$WORK/src-cctools"
    rm -rf "$s"; mkdir -p "$s"
    tar -C "$s" --strip-components=1 -xf "$(dl_path cctools-port-f01442232f18.tar.gz)"
    local pp="$HERE/patches/cctools"
    apply_patches "$s" "$pp"/0004-*.patch "$pp"/0008-*.patch "$pp"/0009-*.patch "$pp"/0010-*.patch >&2
    if [ "$MODE" != cross ]; then apply_patches "$s" "$pp"/0012-*.patch "$pp"/0015-*.patch >&2; fi
    echo "$s/cctools"
}

src_gcc() {
    local s="$WORK/gcc-$GCC_V"
    if [ ! -f "$s/.frostbyte-patched" ]; then
        rm -rf "$s"
        tar -C "$WORK" -xf "$(dl_path gcc-$GCC_V.tar.xz)"
        # contrib/download_prerequisites, from the verified cache instead of the network
        local f d
        for f in gmp-6.2.1.tar.bz2 mpfr-4.1.0.tar.bz2 mpc-1.2.1.tar.gz isl-0.24.tar.bz2; do
            tar -C "$s" -xf "$(dl_path $f)"
            d=${f%.tar.*}; ln -sfn "$d" "$s/${d%%-*}"
        done
        apply_patches "$s" "$HERE"/patches/gcc/*.patch >&2
        touch "$s/.frostbyte-patched"
    fi
    echo "$s"
}

tooldir_links() { # as/ld/... where GCC's driver and collect2 look, and the no-op dsymutil
    local t
    mkdir -p "$P/$T/bin"
    cat > "$P/bin/$T-dsymutil" <<'EOF'
#!/bin/sh
# No-op dsymutil: collect2 runs dsymutil after any link with debug info. It only copies DWARF
# into a .dSYM bundle; the debug info stays in the objects either way. (A host LLVM dsymutil
# found on PATH instead crashes collect2.)
exit 0
EOF
    chmod 755 "$P/bin/$T-dsymutil"
    for t in as ld ar ranlib nm strip lipo otool libtool install_name_tool dsymutil; do
        [ -e "$P/bin/$T-$t" ] && ln -sfn "../../bin/$T-$t" "$P/$T/bin/$t"
    done
}

# ---- cctools ------------------------------------------------------------------------------------
build_cctools() {
    say "cctools 877.8 + ld64 $LD64_V"
    local c; c=$(src_cctools)
    ( cd "$c"
      ./autogen.sh >/dev/null 2>&1
      case "$MODE" in
      cross)
          # -std=gnu17: cctools' own `enum bool` breaks under C23.
          ./configure --prefix="$PREFIX" --target=$T --disable-lto-support \
              CFLAGS="-O2 -std=gnu17" CXXFLAGS="-O2 -std=gnu++14" ;;
      native)
          local compat="-include $HERE/leopard-compat/leopard-compat.h"
          ./configure ac_cv_lib_xar_xar_prop_create=no ac_cv_header_xar_xar_h=no --disable-lto-support \
              --prefix="$PREFIX" --target=$T \
              CC="${FB_BOOTSTRAP_CC}" CXX="${FB_BOOTSTRAP_CXX}" \
              CFLAGS="-O2 -std=gnu17 $compat" CXXFLAGS="-O2 -std=gnu++14 $compat" ;;
      canadian)
          # No libxar: on 10.5 it drags Apple's libstdc++ into ld64, whose weak symbols then clash with GCC 15's.
          local compat="-include $HERE/leopard-compat/leopard-compat.h"
          PATH="$BTC/bin:$PATH" ./configure ac_cv_lib_xar_xar_prop_create=no ac_cv_header_xar_xar_h=no \
              --disable-lto-support --build="$(./config.guess 2>/dev/null || echo x86_64-pc-linux-gnu)" \
              --host=$T --target=$T --prefix="$PREFIX" \
              CC=$T-gcc CXX=$T-g++ AR=$T-ar RANLIB=$T-ranlib NM=$T-nm STRIP=$T-strip LIPO=$T-lipo OTOOL=$T-otool \
              CFLAGS="-O2 -std=gnu17 $compat" CXXFLAGS="-O2 -std=gnu++14 $compat" ;;
      esac
      PATH="${BTC:+$BTC/bin:}$PATH" make -j"$JOBS"
      PATH="${BTC:+$BTC/bin:}$PATH" make install ${DEST:+DESTDIR="$DEST"}
    ) >> "$LOG" 2>&1 || die "cctools build failed (tail of $LOG):$(tail -30 "$LOG")"
    if [ "$MODE" != cross ]; then
        # configure prefixes every program even when host == target; GCC's driver wants plain names
        # as well, and native users expect them.
        local f
        for f in "$P"/bin/$T-*; do ln -sfn "$(basename "$f")" "$P/bin/$(basename "$f" | sed "s/^$T-//")"; done
    fi
    tooldir_links
    ok "cctools installed"
}

# ---- GCC ----------------------------------------------------------------------------------------
build_gcc() {
    say "GCC $GCC_V (patched, ppc + ppc64 multilib, C/C++/Objective-C)"
    local g obj="$WORK/obj-gcc"; g=$(src_gcc)
    ln -sfn "$SDK" "$P/sdk"
    rm -rf "$obj"; mkdir -p "$obj"
    local common=(--target=$T --prefix="$PREFIX" --with-sysroot="$PREFIX/sdk" --with-ld64=$LD64_V
        --enable-languages=c,c++,objc --disable-nls --enable-multilib
        --disable-libssp --disable-libquadmath --disable-libgomp --enable-libatomic --disable-libsanitizer
        --enable-shared --disable-bootstrap MAKEINFO=true)
    ( cd "$obj"
      # Do NOT put -std in CXXFLAGS: libcody's configure insists on exactly C++11 and an explicit -std
      # wins over its fallback, so all of libcody's probes fail.
      # GCC's configure probes the assembler and linker; name them (a canadian build probes the
      # build toolchain's copies, which run here and are the same version).
      if [ "$MODE" = canadian ]; then export gcc_cv_as="$BTC/bin/$T-as" gcc_cv_ld="$BTC/bin/$T-ld"
      else export gcc_cv_as="$P/$T/bin/as" gcc_cv_ld="$P/$T/bin/ld"; fi
      case "$MODE" in
      cross)
          export PATH="$P/bin:$PATH" CC="${FB_HOST_CC:-gcc}" CXX="${FB_HOST_CXX:-g++}"
          export CFLAGS="-O2 -std=gnu17" CXXFLAGS="-O2"
          export CFLAGS_FOR_BUILD="$CFLAGS" CXXFLAGS_FOR_BUILD="$CXXFLAGS"
          "$g/configure" "${common[@]}" ;;
      native)
          export PATH="$P/bin:$PATH" CC="$FB_BOOTSTRAP_CC" CXX="$FB_BOOTSTRAP_CXX"
          export CFLAGS="-O2 -fno-reorder-functions" CXXFLAGS="-O2 -fno-reorder-functions"
          "$g/configure" --build=$T --host=$T "${common[@]}" --program-prefix=$T- ;;
      canadian)
          # Build = this machine, host = target = darwin9, built with
          # the cross toolchain. -fno-reorder-functions keeps main in __text so crt1's bl reaches it
          # in a 28 MB cc1plus (needs gcc patch 0007).
          export PATH="$BTC/bin:$PATH"
          export CC=$T-gcc CXX=$T-g++ AR=$T-ar RANLIB=$T-ranlib NM=$T-nm STRIP=$T-strip LIPO=$T-lipo OTOOL=$T-otool
          export CFLAGS="-O2 -fno-reorder-functions" CXXFLAGS="-O2 -fno-reorder-functions"
          if [ "${FB_CANADIAN_HOST_BITS:-32}" = 64 ]; then CC="$CC -m64"; CXX="$CXX -m64"; fi
          export CC_FOR_BUILD=${FB_HOST_CC:-gcc} CXX_FOR_BUILD=${FB_HOST_CXX:-g++}
          export CFLAGS_FOR_BUILD="-O2 -std=gnu17" CXXFLAGS_FOR_BUILD="-O2"
          export CC_FOR_TARGET=$T-gcc CXX_FOR_TARGET=$T-g++ GCC_FOR_TARGET=$T-gcc
          export AR_FOR_TARGET=$T-ar RANLIB_FOR_TARGET=$T-ranlib NM_FOR_TARGET=$T-nm AS_FOR_TARGET=$T-as
          export LD_FOR_TARGET=$T-ld STRIP_FOR_TARGET=$T-strip LIPO_FOR_TARGET=$T-lipo OTOOL_FOR_TARGET=$T-otool
          "$g/configure" --build="$("$g/config.guess")" --host=$T "${common[@]}" --program-prefix=$T- ;;
      esac
      make -j"$JOBS"
      make install ${DEST:+DESTDIR="$DEST"}
    ) >> "$LOG" 2>&1 || die "GCC build failed (tail of $LOG):$(tail -40 "$LOG")"
    if [ "$MODE" = canadian ]; then fix_canadian_install_names; fi
    # fixincludes leaves an empty DONE marker in the sysroot's usr/include when the sysroot is
    # reached through a symlink (<prefix>/sdk); the SDK must stay byte-identical to Apple's.
    [ -f "$SDK/usr/include/DONE" ] && [ ! -s "$SDK/usr/include/DONE" ] && rm -f "$SDK/usr/include/DONE"
    ok "GCC installed"
}

# A canadian GCC's programs load libstdc++/libgcc_s from the BUILD toolchain's Linux path (on
# Darwin -static-libstdc++ does not take for them), and dyld refuses a missing path in silence. Point them at the copies inside the prefix
# through @loader_path (dyld has it since 10.4), so the toolchain works wherever it is unpacked.
fix_canadian_install_names() {
    local H="$BTC/$T/lib" f rel libdir=lib
    [ "${FB_CANADIAN_HOST_BITS:-32}" = 64 ] && libdir=lib/ppc64
    find "$P" -type f | while read -r f; do
        file -b "$f" | grep -q Mach-O || continue
        "$BTC/bin/$T-otool" -L "$f" 2>/dev/null | grep -q "$BTC" || continue
        rel=$(dirname "${f#$P/}" | awk -F/ '{ for (i = 1; i <= NF; i++) if ($i != ".") printf "../" }')
        "$BTC/bin/$T-install_name_tool" \
            -change "$H/libgcc_s.1.1.dylib" "@loader_path/${rel}$libdir/libgcc_s.1.1.dylib" \
            -change "$H/libstdc++.6.dylib" "@loader_path/${rel}$libdir/libstdc++.6.dylib" \
            -change "$H/ppc64/libgcc_s.1.1.dylib" "@loader_path/${rel}lib/ppc64/libgcc_s.1.1.dylib" \
            -change "$H/ppc64/libstdc++.6.dylib" "@loader_path/${rel}lib/ppc64/libstdc++.6.dylib" "$f"
    done
    if find "$P" -type f -exec "$BTC/bin/$T-otool" -L {} + 2>/dev/null | grep -q "$BTC"; then
        die "a canadian toolchain binary still loads from $BTC"
    fi
}

stamp() {
    {
        echo "id=$(awk '$1=="id" {print $2}' "$FB_TOOLCHAIN_LOCK")"
        echo "mode=$MODE"
        echo "host=$( [ "$MODE" = canadian ] && echo darwin9-ppc64 || { . "$FB_ROOT/scripts/host.sh"; fb_detect_host >/dev/null; echo "$FB_HOST_TAG"; } )"
        echo "prefix=$PREFIX"
        echo "gcc=$GCC_V patches: $(cd "$HERE/patches/gcc" && echo *.patch)"
        echo "cctools=877.8 ld64=$LD64_V cctools-port=f01442232f18 patches: $(cd "$HERE/patches/cctools" && if [ "$MODE" = cross ]; then echo 0004-*.patch 0008-*.patch 0009-*.patch 0010-*.patch; else echo *.patch; fi)"
        echo "built=$(date -u +%Y-%m-%dT%H:%MZ) on $(uname -sm)"
    } > "$P/FROSTBYTE-TOOLCHAIN"
}

if [ "$MODE" = native ]; then
    FB_BOOTSTRAP_CC=${FB_BOOTSTRAP_CC:-/usr/local/gcc-15/bin/gcc-15}
    FB_BOOTSTRAP_CXX=${FB_BOOTSTRAP_CXX:-/usr/local/gcc-15/bin/g++-15}
    [ -x "$FB_BOOTSTRAP_CC" ] || die "native build needs a C++11 compiler on this Mac: set FB_BOOTSTRAP_CC/FB_BOOTSTRAP_CXX (e.g. MacPorts gcc14: /opt/local/bin/gcc-mp-14)"
fi
: > "$LOG"
build_cctools
build_gcc
stamp
ok "toolchain ready: $PREFIX"

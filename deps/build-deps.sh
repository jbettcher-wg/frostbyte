#!/bin/bash
# Build the WPE dependency stack for ppc64 Mac OS X 10.5 into $WPE_STAGE/opt/wpe.
#   deps/build-deps.sh <package> [<package>...]
#   LEOPARD_TARGET=g5 deps/build-deps.sh ...     (toolchain/target.sh: t4240 default, g5, generic)
# Each package unpacks into build/deps/src/<name> (shared by all targets) and builds out of tree in
# build/deps<suffix>/obj/<name> into stage-wpe<suffix>. Logs: build/deps<suffix>/<name>.log.
set -e
S="$(cd "$(dirname "$0")/.." && pwd)"
. "$S/toolchain/wpe-env.sh"
# Dependencies probe libc honestly: no forced leopard-compat.h include (it
# breaks autoconf/meson function checks); packages use their own fallbacks.
# toolchain/sdkfix only fixes SDK header bugs (LP64 CMSG_*: GLib's GSocket fd passing), so probes are unaffected.
SDKFIX="-isystem $S/toolchain/sdkfix"
export CFLAGS="-O2 $SDKFIX -I$WPE_SYSROOT/include" CXXFLAGS="-O2 $SDKFIX -I$WPE_SYSROOT/include" CPPFLAGS="$SDKFIX -I$WPE_SYSROOT/include"
DL="$LEOPARD_DL/deps"
SRC="$LEOPARD_BUILD/deps/src"; OBJ="$LEOPARD_BUILD/deps$LEOPARD_SUFFIX/obj"; LOGS="$LEOPARD_BUILD/deps$LEOPARD_SUFFIX"
CROSS="$LEOPARD_MESON_CROSS"   # generated for this target by toolchain/wpe-env.sh
HOST=powerpc64-apple-darwin9
mkdir -p "$SRC" "$OBJ"

# Install into a scratch root, then copy into the stage only files whose CONTENT changed, so a
# rebuilt dependency never refreshes header timestamps (which made WebKit rebuild 686 objects
# at full width and OOM-kill the user's terminal, 2026-11-08).
stage_install() { # <install command, run with DESTDIR set>
    local tmp; tmp=$(mktemp -d "$LEOPARD_BUILD/deps/.install-XXXXXX")
    DESTDIR="$tmp" "$@" || { rm -rf "$tmp"; return 1; }
    rsync -a --checksum "$tmp"/ "$WPE_STAGE"/ && rm -rf "$tmp"
}

unpack() { # <archive> <dirname>
    [ -d "$SRC/$2" ] && return 0
    mkdir -p "$SRC/.tmp-$2" && tar -C "$SRC/.tmp-$2" -xf "$DL/$1"
    mv "$SRC/.tmp-$2"/* "$SRC/$2" && rmdir "$SRC/.tmp-$2"
    if [ -d "$S/deps/patches/$2" ]; then
        for p in "$S/deps/patches/$2"/*.patch; do patch -d "$SRC/$2" -p1 < "$p"; done
    fi
}

autotools() { # <dir> [configure args...]
    local d="$1"; shift
    rm -rf "$OBJ/$d"; mkdir -p "$OBJ/$d"; cd "$OBJ/$d"
    "$SRC/$d/configure" --host=$HOST --prefix=$WPE_PREFIX "$@"
    make -j${DEPS_JOBS:-24} && stage_install make install
}

mesonbuild() { # <dir> [meson args...]
    local d="$1"; shift
    rm -rf "$OBJ/$d"
    meson setup "$OBJ/$d" "$SRC/$d" --cross-file "$CROSS" --prefix=$WPE_PREFIX \
        --buildtype=release --default-library=shared -Dc_args="$CFLAGS" -Dc_link_args="$LDFLAGS" \
        -Dcpp_args="$CXXFLAGS" -Dcpp_link_args="$LDFLAGS" "$@"
    # MESON_TARGETS: build only these targets (packages whose tests/benches need 10.6+ APIs)
    # DEPS_JOBS: cap parallelism (unset = previous behaviour: ninja's default, make -j24)
    if [ -n "$MESON_TARGETS" ]; then meson compile -C "$OBJ/$d" ${DEPS_JOBS:+-j $DEPS_JOBS} $MESON_TARGETS || return 1
    else ninja -C "$OBJ/$d" ${DEPS_JOBS:+-j$DEPS_JOBS} || return 1; fi
    stage_install meson install -C "$OBJ/$d" --no-rebuild || return 1
    fix_install_names
}

# Rewrite meson's @rpath install names to absolute /opt/wpe/lib paths, for
# dylibs and executables in the staged prefix.
fix_install_names() {
    local f dep
    for f in "$WPE_SYSROOT"/lib/*.dylib "$WPE_SYSROOT"/lib/gio/modules/*.so "$WPE_SYSROOT"/lib/wpe-webkit-*/injected-bundle/*.so \
             "$WPE_SYSROOT"/lib/gstreamer-1.0/*.dylib "$WPE_SYSROOT"/lib/gstreamer-1.0/*.so \
             "$WPE_SYSROOT"/bin/* "$WPE_SYSROOT"/libexec/* "$WPE_SYSROOT"/libexec/*/*; do
        [ -f "$f" ] && [ ! -L "$f" ] || continue
        $OTOOL -h "$f" >/dev/null 2>&1 || continue
        case "$f" in *.dylib|*.so)
            id=$($OTOOL -D "$f" | sed -n 2p)
            case "$f:$id" in
                */lib/gstreamer-1.0/*:@rpath/*|*/lib/gstreamer-1.0/*:"$WPE_PREFIX"/lib/lib*)   # plugin modules: id = their own path
                    $INSTALL_NAME_TOOL -id "$WPE_PREFIX/lib/gstreamer-1.0/${f##*/}" "$f";;
            esac
            id=$($OTOOL -D "$f" | sed -n 2p)
            case "$id" in
                @rpath/*) $INSTALL_NAME_TOOL -id "$WPE_PREFIX/lib/${id#@rpath/}" "$f";;
                */*) ;;
                ?*) $INSTALL_NAME_TOOL -id "$WPE_PREFIX/lib/$id" "$f";;   # bare leaf (ICU)
            esac;;
        esac
        for dep in $($OTOOL -L "$f" | awk 'NR>1 && $1 ~ /^@rpath\// {print $1}'); do
            $INSTALL_NAME_TOOL -change "$dep" "$WPE_PREFIX/lib/${dep#@rpath/}" "$f"
        done
        for dep in $($OTOOL -L "$f" | awk 'NR>1 && $1 !~ /\// {print $1}'); do   # bare leaf deps
            [ -e "$WPE_SYSROOT/lib/$dep" ] && $INSTALL_NAME_TOOL -change "$dep" "$WPE_PREFIX/lib/$dep" "$f"
        done
        # ld64 253.9 ppc64 executables: srr0 entry + reloc base (tools/fix-ppc64-entry.py)
        $OTOOL -hv "$f" | grep -q EXECUTE && python3 -I "$S/tools/fix-ppc64-entry.py" "$f" >/dev/null
    done
}

cmakebuild() { # <dir> [cmake args...]
    local d="$1"; shift
    rm -rf "$OBJ/$d"; mkdir -p "$OBJ/$d"
    cat > "$OBJ/$d.toolchain.cmake" <<TC
set(CMAKE_SYSTEM_NAME Darwin)
set(CMAKE_SYSTEM_VERSION 9.8.0)
set(CMAKE_SYSTEM_PROCESSOR powerpc64)
set(CMAKE_C_COMPILER   ${CC% *})
set(CMAKE_CXX_COMPILER ${CXX% *})
set(CMAKE_C_FLAGS_INIT   "-m64 $LEOPARD_CPU_FLAGS")
set(CMAKE_CXX_FLAGS_INIT "-m64 $LEOPARD_CPU_FLAGS")
set(CMAKE_AR $AR)
set(CMAKE_RANLIB $RANLIB)
set(CMAKE_INSTALL_NAME_TOOL $INSTALL_NAME_TOOL)
set(CMAKE_OTOOL $OTOOL)
set(CMAKE_OSX_SYSROOT "" CACHE STRING "")
set(CMAKE_OSX_ARCHITECTURES "" CACHE STRING "")
set(CMAKE_OSX_DEPLOYMENT_TARGET "" CACHE STRING "")
set(CMAKE_FIND_ROOT_PATH $WPE_SYSROOT)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
TC
    cmake -S "$SRC/$d" -B "$OBJ/$d" -G Ninja -DCMAKE_TOOLCHAIN_FILE="$OBJ/$d.toolchain.cmake" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=$WPE_PREFIX -DCMAKE_INSTALL_NAME_DIR=$WPE_PREFIX/lib \
        -DCMAKE_C_FLAGS="$CFLAGS" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" "$@"
    ninja -C "$OBJ/$d" && stage_install ninja -C "$OBJ/$d" install || return 1
    fix_install_names
}

pkg_zlib() {
    unpack zlib-1.3.1.tar.gz zlib-1.3.1
    rm -rf "$OBJ/zlib-1.3.1"; cp -a "$SRC/zlib-1.3.1" "$OBJ/zlib-1.3.1"; cd "$OBJ/zlib-1.3.1"
    CHOST=$HOST ./configure --prefix=$WPE_PREFIX
    make -j24 AR="$AR" ARFLAGS=rc && stage_install make install AR="$AR" ARFLAGS=rc
}
pkg_libiconv() { unpack libiconv-1.18.tar.gz libiconv-1.18; autotools libiconv-1.18 --disable-static --disable-nls; }
pkg_libffi() { unpack libffi-3.4.6.tar.gz libffi-3.4.6; autotools libffi-3.4.6 --disable-docs --disable-static; }
pkg_pcre2() { unpack pcre2-10.44.tar.bz2 pcre2-10.44; autotools pcre2-10.44 --disable-static --enable-pcre2-16 --disable-jit; }
pkg_proxylibintl() { unpack proxy-libintl-0.4.tar.gz proxy-libintl-0.4; mesonbuild proxy-libintl-0.4 --default-library=static; }
pkg_expat() { unpack expat-2.7.1.tar.xz expat-2.7.1; autotools expat-2.7.1 --disable-static --without-docbook --without-examples --without-tests; }
pkg_libxml2() { unpack libxml2-2.13.8.tar.xz libxml2-2.13.8; autotools libxml2-2.13.8 --disable-static --without-python --without-lzma --with-zlib=$WPE_SYSROOT --with-iconv=$WPE_SYSROOT --without-icu; }
pkg_sqlite() {
    unpack sqlite-autoconf-3500400.tar.gz sqlite-autoconf-3500400
    rm -rf "$OBJ/sqlite"; cp -a "$SRC/sqlite-autoconf-3500400" "$OBJ/sqlite"; cd "$OBJ/sqlite"
    CC_FOR_BUILD=gcc ./configure --host=$HOST --prefix=$WPE_PREFIX --disable-static --disable-readline \
        CFLAGS="$CFLAGS -DSQLITE_ENABLE_COLUMN_METADATA=1 -DSQLITE_ENABLE_FTS3=1 -DSQLITE_ENABLE_UNLOCK_NOTIFY=1"
    make -j24 && stage_install make install
}
pkg_libpng() { unpack libpng-1.6.50.tar.xz libpng-1.6.50; autotools libpng-1.6.50 --disable-static --disable-tools; }
pkg_libjpeg() { unpack libjpeg-turbo-3.1.1.tar.gz libjpeg-turbo-3.1.1; cmakebuild libjpeg-turbo-3.1.1 -DENABLE_STATIC=OFF -DWITH_SIMD=ON -DREQUIRE_SIMD=ON -DWITH_TURBOJPEG=OFF -DWITH_TOOLS=OFF -DWITH_TESTS=OFF; }
pkg_libwebp() { unpack libwebp-1.6.0.tar.gz libwebp-1.6.0; autotools libwebp-1.6.0 --disable-static --enable-libwebpmux --enable-libwebpdemux --disable-gl --disable-sdl --disable-png --disable-jpeg --disable-tiff --disable-gif --disable-wic; }
pkg_freetype() { unpack freetype-2.13.3.tar.xz freetype-2.13.3; CC_BUILD=gcc autotools freetype-2.13.3 --disable-static --with-zlib=yes --with-png=yes --with-harfbuzz=no --with-brotli=no --with-bzip2=no; }
pkg_harfbuzz() { unpack harfbuzz-11.2.1.tar.xz harfbuzz-11.2.1; mesonbuild harfbuzz-11.2.1 -Dglib=enabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled -Dicu=enabled -Dfreetype=enabled -Dcoretext=disabled -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled -Dbenchmark=disabled; }
pkg_fontconfig() {
    unpack fontconfig-2.16.0.tar.xz fontconfig-2.16.0
    mesonbuild fontconfig-2.16.0 -Dxml-backend=expat -Ddoc=disabled -Dtests=disabled -Dnls=disabled -Dcache-build=disabled -Dtools=enabled -Ddefault-fonts-dirs=/System/Library/Fonts,/Library/Fonts -Dadditional-fonts-dirs=~/Library/Fonts
    # FrostByte's rules for Leopard's fonts (face weights, Mac system font names). They act at scan
    # time: an installed prefix needs `fc-cache -f` after they change (the app bundle hashes them).
    stage_install sh -c 'mkdir -p "$DESTDIR'"$WPE_PREFIX"'/etc/fonts/conf.d" && cp "'"$S"'"/frostbyte/resources/fontconfig/*.conf "$DESTDIR'"$WPE_PREFIX"'/etc/fonts/conf.d/"'
}
pkg_libgpgerror() { unpack libgpg-error-1.55.tar.bz2 libgpg-error-1.55; CC_FOR_BUILD=gcc autotools libgpg-error-1.55 --disable-static --disable-doc --disable-tests --disable-nls --disable-languages; }
pkg_libgcrypt() { unpack libgcrypt-1.11.1.tar.bz2 libgcrypt-1.11.1; CC_FOR_BUILD=gcc autotools libgcrypt-1.11.1 --disable-static --disable-doc --disable-asm --disable-jent-support --with-libgpg-error-prefix=$WPE_SYSROOT GPGRT_CONFIG=$WPE_SYSROOT/bin/gpgrt-config; }
pkg_libtasn1() { unpack libtasn1-4.20.0.tar.gz libtasn1-4.20.0; CC_FOR_BUILD=gcc autotools libtasn1-4.20.0 --disable-static --disable-doc; }
pkg_gmp() { unpack gmp-6.3.0.tar.xz gmp-6.3.0; CFLAGS="$CFLAGS -std=gnu17" CC_FOR_BUILD=gcc autotools gmp-6.3.0 --disable-static --enable-shared --disable-assembly; }
pkg_nettle() { unpack nettle-3.10.2.tar.gz nettle-3.10.2; CC_FOR_BUILD=gcc autotools nettle-3.10.2 --disable-static --disable-assembler --disable-documentation --disable-openssl --disable-fat; }
pkg_gnutls() {
    export CC_FOR_BUILD=gcc
    unpack gnutls-3.8.10.tar.xz gnutls-3.8.10
    autotools gnutls-3.8.10 --disable-static --disable-doc --disable-tools --disable-tests --disable-cxx --disable-nls \
        --with-included-unistring --without-p11-kit --without-tpm --without-tpm2 --without-zstd --without-brotli \
        --without-idn --disable-hardware-acceleration --with-default-trust-store-file=$WPE_PREFIX/etc/ssl/cert.pem
    mkdir -p "$WPE_SYSROOT/etc/ssl" && cp "$DL/cacert.pem" "$WPE_SYSROOT/etc/ssl/cert.pem"
}
pkg_glibnetworking() {
    unpack glib-networking-2.80.1.tar.xz glib-networking-2.80.1
    # Preloaded intermediates for chain completion (patch 0002): Mozilla CCADB, non-revoked
    # intermediates chaining to Mozilla roots (MozillaIntermediateCertsCSVReport).
    mkdir -p "$WPE_SYSROOT/etc/ssl"
    python3 -I - "$DL/mozilla-intermediates.csv" "$WPE_SYSROOT/etc/ssl/intermediates.pem" <<'PY' || return 1
import csv, sys
rows = csv.DictReader(open(sys.argv[1], newline=""))
pems = [r["PEM"].strip().strip("'") for r in rows if "BEGIN CERTIFICATE" in r.get("PEM", "")]
open(sys.argv[2], "w").write("\n".join(pems) + "\n")
print("intermediates.pem: %d certificates" % len(pems))
PY
    CFLAGS="$CFLAGS -DLEOPARD_TLS_INTERMEDIATES_DIR=$WPE_PREFIX/etc/ssl" \
    mesonbuild glib-networking-2.80.1 -Dgnutls=enabled -Dopenssl=disabled -Dlibproxy=disabled -Dgnome_proxy=disabled -Dinstalled_tests=false || return 1
    # gio-2.0.pc's giomoduledir gets the pkg-config sysroot prepended, then DESTDIR again: move it home.
    local stray="$WPE_STAGE$WPE_SYSROOT/lib/gio/modules"
    if [ -d "$stray" ]; then
        mkdir -p "$WPE_SYSROOT/lib/gio/modules" && mv "$stray"/* "$WPE_SYSROOT/lib/gio/modules/"
        local top; top=$(echo "$WPE_SYSROOT" | cut -d/ -f2)
        [ -n "$top" ] && [ "$top" != "${WPE_PREFIX#/}" ] && [ "$top" != opt ] && rm -rf "$WPE_STAGE/$top"
    fi
    fix_install_names
}
pkg_nghttp2() { unpack nghttp2-1.66.0.tar.xz nghttp2-1.66.0; autotools nghttp2-1.66.0 --disable-static --enable-lib-only; }
pkg_libpsl() { unpack libpsl-0.21.5.tar.gz libpsl-0.21.5; mesonbuild libpsl-0.21.5 -Druntime=no -Dtests=false -Ddocs=false; }
pkg_libsoup() { unpack libsoup-3.6.5.tar.xz libsoup-3.6.5; mesonbuild libsoup-3.6.5 -Dtests=false -Dvapi=disabled -Dintrospection=disabled -Dgssapi=disabled -Dntlm=disabled -Dbrotli=disabled -Dsysprof=disabled -Ddocs=disabled -Dtls_check=false -Dpkcs11_tests=disabled -Dautobahn=disabled; }
# Khronos EGL/GLES headers (from WPE's bundled ANGLE); LeopardEGL implements them.
pkg_khrheaders() {
    local inc="$LEOPARD_BUILD/src/wpewebkit-2.54.1/Source/ThirdParty/ANGLE/include"
    for d in EGL KHR GLES2 GLES3; do mkdir -p "$WPE_SYSROOT/include/$d" && cp "$inc/$d"/*.h "$WPE_SYSROOT/include/$d/"; done
}
# LeopardEGL (ours, leopardegl/): EGL 1.5 over CGL (README section 18). libGLESv2 presents GLES 2.0
# over a CGL 2.1 compatibility context; its stubs are generated from Khronos gl.xml (epoxy sources).
# LEOPARD_WEBGL=ON (the same switch as toolchain/configure-wpe.sh) builds the WebGL library (LEOPARD_EGL_WEBGL=1:
# the gl33 provider, little-endian client contexts, the GLES context rules); OFF is the 0.3.x library.
pkg_leopardegl() {
    local L="$S/leopardegl" o="$OBJ/leopardegl" cc="${CC% *}" webgl=
    [ "${LEOPARD_WEBGL:-OFF}" = ON ] && webgl=-DLEOPARD_EGL_WEBGL=1
    local cflags="-m64 $LEOPARD_CPU_FLAGS -O2 -std=gnu11 -Wall -Wextra -Wno-unused-parameter -fvisibility=hidden -I$WPE_SYSROOT/include -I$L $webgl"
    mkdir -p "$o" "$WPE_SYSROOT/lib/pkgconfig"
    python3 -I "$S/tools/gen-gles-stubs.py" "$LEOPARD_BUILD/deps/pristine/libepoxy-1.5.10/registry/gl.xml" "$L/gles_stubs.c" >/dev/null || return 1
    $cc $cflags -c "$L/gles.c" -o "$o/gles.o" || return 1
    $cc $cflags -Wno-unused-but-set-variable -c "$L/gles_stubs.c" -o "$o/gles_stubs.o" || return 1
    $cc -m64 -dynamiclib -o "$o/libGLESv2.2.dylib" "$o/gles.o" "$o/gles_stubs.o" $LDFLAGS \
        -install_name $WPE_PREFIX/lib/libGLESv2.2.dylib -compatibility_version 2 -current_version 2.0 || return 1
    $cc $cflags -c "$L/egl.c" -o "$o/egl.o" || return 1
    $cc -m64 -dynamiclib -o "$o/libEGL.1.dylib" "$o/egl.o" "$o/libGLESv2.2.dylib" -framework OpenGL $LDFLAGS \
        -install_name $WPE_PREFIX/lib/libEGL.1.dylib -compatibility_version 1 -current_version 1.5 || return 1
    # install only what changed (keeps WebKit's link inputs stable)
    for f in libGLESv2.2.dylib libEGL.1.dylib; do
        cmp -s "$o/$f" "$WPE_SYSROOT/lib/$f" || cp "$o/$f" "$WPE_SYSROOT/lib/$f"
    done
    ln -sf libEGL.1.dylib "$WPE_SYSROOT/lib/libEGL.dylib"
    ln -sf libGLESv2.2.dylib "$WPE_SYSROOT/lib/libGLESv2.dylib"
    sed "s|@PREFIX@|$WPE_PREFIX|" "$L/egl.pc.in" > "$WPE_SYSROOT/lib/pkgconfig/egl.pc"
}
pkg_libepoxy() { unpack libepoxy-1.5.10.tar.gz libepoxy-1.5.10; mesonbuild libepoxy-1.5.10 -Dglx=no -Degl=yes -Dx11=false -Dtests=false -Ddocs=false; }
pkg_xkbcommon() { unpack libxkbcommon-1.11.0.tar.gz libxkbcommon-xkbcommon-1.11.0; MESON_TARGETS=xkbcommon CFLAGS="$CFLAGS -Dstatic_assert=_Static_assert" mesonbuild libxkbcommon-xkbcommon-1.11.0 -Denable-x11=false -Denable-wayland=false -Denable-docs=false -Denable-tools=false -Denable-xkbregistry=false -Denable-bash-completion=false -Dxkb-config-root=$WPE_PREFIX/share/X11/xkb; }
pkg_libwpe() { unpack libwpe-1.16.2.tar.xz libwpe-1.16.2; mesonbuild libwpe-1.16.2 -Denable-xkb=true -Dbuild-docs=false; }
# ICU 77.1 shared, data inside libicudata.dylib. The cross-built data is mis-ordered (see
# toolchain/icu-data-be.sh), so libicudata is relinked from the big-endian object that script makes.
pkg_icu() {
    local d=icu-77.1
    rm -rf "$OBJ/$d"; mkdir -p "$OBJ/$d"; cd "$OBJ/$d"
    "$LEOPARD_BUILD/icu-src/source/configure" --host=$HOST --build="$(sh "$LEOPARD_BUILD/icu-src/source/config.guess")" \
        --with-cross-build="$LEOPARD_BUILD/icu-host" --prefix=$WPE_PREFIX --enable-shared --disable-static \
        --disable-tests --disable-samples --disable-extras --disable-tools --with-data-packaging=library \
        CXXFLAGS="$CXXFLAGS -std=gnu++17" \
        LDFLAGS="$LDFLAGS -Wl,-unexported_symbols_list,$S/toolchain/hide-libstdcxx.exp"   # keep GCC 15 libstdc++ private (README 19.3)
    make -j24 && stage_install make install || return 1
    "$S/toolchain/icu-data-be.sh" >/dev/null   # refreshes build/icu-data-be/icudt77b_dat.o
    local lib="$WPE_SYSROOT/lib/libicudata.77.1.dylib"
    ${CC% *} -m64 -dynamiclib -nostdlib -o "$lib" "$LEOPARD_BUILD/icu-data-be/icudt77b_dat.o" \
        -install_name $WPE_PREFIX/lib/libicudata.77.dylib -compatibility_version 77 -current_version 77.1 \
        -Wl,-headerpad_max_install_names
    fix_install_names
}
pkg_glib() {
    unpack glib-2.84.4.tar.xz glib-2.84.4
    mesonbuild glib-2.84.4 -Dtests=false -Dintrospection=disabled -Dnls=disabled -Dlibmount=disabled \
        -Dselinux=disabled -Dxattr=false -Dman-pages=disabled -Ddocumentation=false -Dsysprof=disabled \
        -Dglib_debug=disabled -Dlibelf=disabled
}

# ---- GStreamer 1.28 (README section 21) ----------------------------------------------------
# Built at -j8 (host memory is shared with WebKit builds). Everything is opt-in:
# auto_features=disabled, then only what WebKit's playback/WebAudio paths need.
GST_V=1.28.9
GST_COMMON="--wrap-mode=nodownload -Dauto_features=disabled -Dexamples=disabled -Dtests=disabled -Ddoc=disabled -Dnls=disabled"
# The freedesktop MIME database (data only), so GIO can tell a local file's type: without it every file:// URL is
# application/octet-stream and WebKit turns the load into a download (WebKitPolicyError 102). Built with the
# host's update-mime-database from shared-mime-info's freedesktop.org.xml; the outputs are portable (mime.cache
# is big-endian by spec). FrostByte puts $WPE_PREFIX/share first in XDG_DATA_DIRS.
pkg_mimedb() {
    local src="${MIME_XML:-/usr/share/mime/packages/freedesktop.org.xml}" out="$WPE_SYSROOT/share/mime"
    [ -f "$src" ] || { echo "pkg_mimedb: $src not found (set MIME_XML)" >&2; return 1; }
    rm -rf "$out"; mkdir -p "$out/packages"
    cp "$src" "$out/packages/freedesktop.org.xml"
    update-mime-database "$out"
    echo "    mime database: $(ls "$out" | wc -l) entries from $(basename "$src")"
}
pkg_orc() { export DEPS_JOBS=8; unpack orc-0.4.42.tar.xz orc-0.4.42; mesonbuild orc-0.4.42 -Dorc-test=disabled -Dbenchmarks=disabled -Dexamples=disabled -Dhotdoc=disabled -Dtests=disabled -Dtools=disabled; }
pkg_gstreamer() {
    export DEPS_JOBS=8
    unpack gstreamer-$GST_V.tar.xz gstreamer-$GST_V
    mesonbuild gstreamer-$GST_V $GST_COMMON -Dintrospection=disabled -Dtools=enabled -Dbenchmarks=disabled -Dcheck=disabled \
        -Dlibunwind=disabled -Dlibdw=disabled -Dbash-completion=disabled -Dptp-helper=disabled -Dcoretracers=enabled
}
pkg_gstpluginsbase() {
    export DEPS_JOBS=8 PATH="$LEOPARD_BUILD/host/bin:$PATH"   # host glib-mkenums for gstgl
    unpack gst-plugins-base-$GST_V.tar.xz gst-plugins-base-$GST_V
    # libgstgl over LeopardEGL + GLES2 (EGL platform/winsys only, no CGL/Cocoa): WebKit's configure
    # requires gstreamer-gl-1.0 whenever ENABLE_VIDEO is on, even with USE_GSTREAMER_GL=OFF.
    mesonbuild gst-plugins-base-$GST_V $GST_COMMON -Dintrospection=disabled -Dorc=enabled -Dtools=enabled \
        -Dgl=enabled -Dgl_api=gles2 -Dgl_platform=egl -Dgl_winsys=egl -Dgl-graphene=disabled -Dgl-jpeg=disabled -Dgl-png=disabled \
        -Degl_module_name=$WPE_PREFIX/lib/libEGL.1.dylib -Dgles2_module_name=$WPE_PREFIX/lib/libGLESv2.2.dylib \
        -Dapp=enabled -Daudioconvert=enabled -Daudiomixer=enabled -Daudiorate=enabled -Daudioresample=enabled \
        -Daudiotestsrc=enabled -Dgio=enabled -Dgio-typefinder=enabled -Dpbtypes=enabled -Dplayback=enabled \
        -Drawparse=enabled -Dtypefind=enabled -Dvideoconvertscale=enabled -Dvideorate=enabled \
        -Dvideotestsrc=enabled -Dvolume=enabled -Doverlaycomposition=enabled -Dsubparse=enabled -Dogg=enabled -Dvorbis=enabled
}
pkg_gstpluginsgood() {
    export DEPS_JOBS=8
    unpack gst-plugins-good-$GST_V.tar.xz gst-plugins-good-$GST_V
    mesonbuild gst-plugins-good-$GST_V $GST_COMMON -Dorc=enabled \
        -Disomp4=enabled -Dmatroska=enabled -Daudioparsers=enabled -Dautodetect=enabled -Dosxaudio=enabled \
        -Dinterleave=enabled -Daudiofx=enabled -Did3demux=enabled -Dwavparse=enabled -Dvideofilter=enabled \
        -Dapetag=enabled -Dicydemux=enabled
}
# Vorbis: gst-libav deliberately skips FFmpeg's vorbis decoder, so WebM/Ogg Vorbis uses libvorbis (base vorbisdec).
pkg_libogg() { export DEPS_JOBS=8; unpack libogg-1.3.6.tar.xz libogg-1.3.6; autotools libogg-1.3.6 --disable-static; }
pkg_libvorbis() { export DEPS_JOBS=8; unpack libvorbis-1.3.7.tar.xz libvorbis-1.3.7; autotools libvorbis-1.3.7 --disable-static --disable-docs --disable-examples --disable-oggtest; }
# FFmpeg for gst-libav: decoders only (H.264, VP8, VP9, AAC, MP3, Opus, Vorbis, FLAC) + their parsers.
# dav1d (AV1). Upstream's ppc code is ppc64le VSX/POWER9 only; patch 0002 adds ARCH_PPC_ALTIVEC (big-endian
# AltiVec, generic C intrinsics in src/ppc/*_altivec_tmpl.c), which "enable_asm" turns on. The dav1d CLI is built
# for md5/fps checks (--cpumask 0 = C, LEOPARD_DAV1D_NO_ALTIVEC_MC=1 = C MC only).
pkg_dav1d() {
    export DEPS_JOBS=8
    unpack dav1d-1.5.2.tar.xz dav1d-1.5.2
    mesonbuild dav1d-1.5.2 -Denable_asm=true -Denable_tools=true -Denable_tests=false -Denable_examples=false \
        -Dbitdepths=8,16 -Dlogging=true
}
# libdav1d: AV1 through dav1d (pkg_dav1d first). Not yet reachable from GStreamer: deps/patches/gst-libav-1.28.9/
# 0001-leopard-allow-libdav1d.patch.disabled registers avdec_libdav1d, but gst-libav then drops every decoded
# frame ("no valid frames"), so it stays off until fixed (docs/altivec-media-audit.md, AV1).
FFMPEG_DECODERS=h264,vp8,vp9,aac,mp3,mp3float,opus,vorbis,flac,libdav1d
FFMPEG_PARSERS=h264,vp8,vp9,av1,aac,mpegaudio,opus,vorbis,flac
pkg_ffmpeg() {
    local d=ffmpeg-8.0.3
    unpack $d.tar.xz $d
    rm -rf "$OBJ/$d"; mkdir -p "$OBJ/$d"; cd "$OBJ/$d"
    "$SRC/$d/configure" --prefix=$WPE_PREFIX --enable-cross-compile --target-os=darwin --arch=ppc64 --cpu=$LEOPARD_FFMPEG_CPU \
        --cc="${CC% -m64*}" --cxx="${CXX% -m64*}" --ar="$AR" --nm="$NM" --ranlib="$RANLIB" --strip="$STRIP" \
        --host-cc=gcc --pkg-config=pkg-config \
        --extra-cflags="-m64 $CFLAGS -Dstatic_assert=_Static_assert" --extra-ldflags="-m64 $LDFLAGS" \
        --enable-shared --disable-static --enable-pic --disable-autodetect --disable-programs --disable-doc \
        --disable-avdevice --disable-swscale --disable-network --disable-everything \
        --enable-libdav1d --enable-decoder=$FFMPEG_DECODERS --enable-parser=$FFMPEG_PARSERS || return 1
    make -j8 && stage_install make install || return 1
    fix_install_names
}
pkg_gstlibav() {
    export DEPS_JOBS=8
    unpack gst-libav-$GST_V.tar.xz gst-libav-$GST_V
    mesonbuild gst-libav-$GST_V --wrap-mode=nodownload -Dtests=disabled -Ddoc=disabled
}
# -bad: only for libgstmpegts (WebKit's configure requires gstreamer-mpegts-1.0 with ENABLE_VIDEO),
# libgstcodecparsers, the video parsers (h264parse, vp9parse, ...) that MSE playback uses, and
# debugutils (fakevideosink, used by WebKit's media pipelines).
pkg_gstpluginsbad() {
    export DEPS_JOBS=8
    unpack gst-plugins-bad-$GST_V.tar.xz gst-plugins-bad-$GST_V
    mesonbuild gst-plugins-bad-$GST_V $GST_COMMON -Dintrospection=disabled -Dorc=enabled -Dtools=disabled -Dgpl=disabled \
        -Dvideoparsers=enabled -Ddebugutils=enabled -Dgl=disabled -Dvulkan=disabled
}


[ "$1" = fix-install-names ] && { fix_install_names; exit 0; }
for p in "$@"; do
    echo "=== $p"
    ( "pkg_${p//-/}" ) > "$LOGS/$p.log" 2>&1 && echo "    ok" || { echo "    FAILED (see ${LOGS#$S/}/$p.log)"; tail -25 "$LOGS/$p.log"; exit 1; }
done

#!/usr/bin/env bash
# Stage "hosttools": programs that run on the BUILD machine during the build, into $LEOPARD_BUILD/host.
#   meson 1.12.1           pinned release, run from its tarball with the host Python (no pip)
#   gperf 3.3              WebKit's code generators
#   unifdef                WebKit's bundled copy (Source/ThirdParty/unifdef)
#   GLib 2.84.4 tools      glib-compile-resources, glib-mkenums, ... (same version as the target GLib)
#   ICU 77.1 host build    ICU's cross build needs a host build of itself (icupkg, genrb, ...)
# and unpacks the pristine libepoxy tree LeopardEGL's stub generator reads gl.xml from.
# Each piece is rebuilt only when its source archive changes (stamp files in $LEOPARD_BUILD/host).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
H="$LEOPARD_BUILD/host"
HS="$LEOPARD_BUILD/host-src"
mkdir -p "$H/bin" "$HS"
PY=$(fb_python)
JOBS=$(host_ncpu); [ "$JOBS" -gt 24 ] && JOBS=24
HOST_CC=${FB_HOST_CC:-$(command -v cc || command -v gcc || command -v clang)}
HOST_CXX=${FB_HOST_CXX:-$(command -v c++ || command -v g++ || command -v clang++)}
export CC="$HOST_CC" CXX="$HOST_CXX"
unset CFLAGS CXXFLAGS CPPFLAGS LDFLAGS PKG_CONFIG_LIBDIR PKG_CONFIG_SYSROOT_DIR
LOG="$LEOPARD_BUILD/host/build.log"
say "hosttools -> $H (log $LOG)"

stamp_ok() { [ -f "$H/.stamp-$1" ] && [ "$(cat "$H/.stamp-$1")" = "$2" ]; }
stamp_set() { printf '%s' "$2" > "$H/.stamp-$1"; }
unpack_to() { # <archive> <dir>: fresh pristine tree
    rm -rf "$2" "$2.tmp"; mkdir -p "$2.tmp"
    tar -C "$2.tmp" -xf "$1"
    mv "$2.tmp"/* "$2"; rmdir "$2.tmp"
}
step() { # <name> <cmd...>: run quietly into the log, show the tail on failure
    note "$1"; shift
    { echo "=== $*"; } >> "$LOG"
    "$@" >> "$LOG" 2>&1 || die "hosttools step failed (tail of $LOG):$(tail -30 "$LOG")"
}

# python3 under that name (MacPorts on 10.5 installs python3.13 etc.)
if ! have python3; then ln -sfn "$PY" "$H/bin/python3"; fi

# ---- meson ----
f=$(dl_path meson-1.12.1.tar.gz); s=$(sha256_file "$f")
if ! stamp_ok meson "$s"; then
    unpack_to "$f" "$H/meson"
    printf '#!/bin/sh\nexec "%s" "%s/meson.py" "$@"\n' "$PY" "$H/meson" > "$H/bin/meson"
    chmod 755 "$H/bin/meson"
    stamp_set meson "$s"
fi
ok "meson $("$H/bin/meson" --version)"
export PATH="$H/bin:$PATH"

# ---- gperf ----
f=$(dl_path gperf-3.3.tar.gz); s=$(sha256_file "$f")
if ! stamp_ok gperf "$s"; then
    unpack_to "$f" "$HS/gperf"
    ( cd "$HS/gperf" && step "gperf: configure" ./configure --prefix="$H" && step "gperf: build" make -j"$JOBS" && step "gperf: install" make install )
    stamp_set gperf "$s"
fi
ok "gperf $("$H/bin/gperf" --version | head -1 | awk '{print $NF}')"

# ---- unifdef (from the WebKit tree the fetch stage unpacked) ----
u="$LEOPARD_BUILD/src/wpewebkit-2.54.1/Source/ThirdParty/unifdef"
[ -f "$u/unifdef.c" ] || die "no WebKit source tree yet: run ./build.sh fetch first"
s=$(sha256_file "$u/unifdef.c")
if ! stamp_ok unifdef "$s"; then
    step "unifdef: build" "$HOST_CC" -std=gnu99 -O2 -o "$H/bin/unifdef" "$u/unifdef.c"
    stamp_set unifdef "$s"
fi
ok "unifdef"

# ---- GLib's host tools ----
f=$(dl_path glib-2.84.4.tar.xz); s=$(sha256_file "$f")
if ! stamp_ok glib "$s"; then
    unpack_to "$f" "$HS/glib"
    rm -rf "$LEOPARD_BUILD/host-glib"
    # nodownload: GLib's dependencies (libffi, pcre2, zlib) come from the host, never from wrapdb.
    step "glib: configure" meson setup "$LEOPARD_BUILD/host-glib" "$HS/glib" --prefix="$H" --libdir=lib \
        --buildtype=release --wrap-mode=nodownload -Dtests=false -Dintrospection=disabled -Dnls=disabled \
        -Dman-pages=disabled -Ddocumentation=false -Dsysprof=disabled -Dlibmount=disabled -Dselinux=disabled \
        -Dxattr=false -Dglib_debug=disabled -Dlibelf=disabled
    step "glib: build" ninja -C "$LEOPARD_BUILD/host-glib" -j "$JOBS"
    step "glib: install" meson install -C "$LEOPARD_BUILD/host-glib" --no-rebuild
    stamp_set glib "$s"
fi
ok "glib-compile-resources $("$H/bin/glib-compile-resources" --version 2>/dev/null || echo)"

# ---- ICU host build (for deps/build-deps.sh icu: --with-cross-build=$LEOPARD_BUILD/icu-host) ----
f=$(dl_path icu4c-77_1-src.tgz); s=$(sha256_file "$f")
if ! stamp_ok icu "$s"; then
    unpack_to "$f" "$LEOPARD_BUILD/icu-src"
    rm -rf "$LEOPARD_BUILD/icu-host"; mkdir -p "$LEOPARD_BUILD/icu-host"
    ( cd "$LEOPARD_BUILD/icu-host" &&
      step "icu: configure" "$LEOPARD_BUILD/icu-src/source/configure" --prefix="$LEOPARD_BUILD/icu-host/install" \
          --disable-tests --disable-samples --disable-extras &&
      step "icu: build" make -j"$JOBS" )
    stamp_set icu "$s"
fi
ok "ICU 77.1 host build"

# ---- pristine libepoxy (LeopardEGL's GLES stubs are generated from its registry/gl.xml) ----
f=$(dl_path libepoxy-1.5.10.tar.gz); s=$(sha256_file "$f")
p="$LEOPARD_BUILD/deps/pristine/libepoxy-1.5.10"
if ! stamp_ok epoxy-pristine "$s" || [ ! -f "$p/registry/gl.xml" ]; then
    unpack_to "$f" "$p"
    stamp_set epoxy-pristine "$s"
fi
ok "libepoxy registry"

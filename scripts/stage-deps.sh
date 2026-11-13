#!/usr/bin/env bash
# Stage "deps": cross-build the libraries FrostByte ships (deps/build-deps.sh) into
# $LEOPARD_BUILD/stage-wpe<suffix>/opt/wpe, in dependency order.
#   scripts/stage-deps.sh                 every package not yet built (or changed since)
#   scripts/stage-deps.sh zlib libffi     just these (in the order given), rebuilt unconditionally
#
# A package counts as built when its stamp matches: the pkg_<name> recipe and its helpers, its
# patches, its source archives, the target's CPU flags and the toolchain. Change any of those and
# it rebuilds; nothing else does. Logs: $LEOPARD_BUILD/deps<suffix>/<pkg>.log.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
. "$FB_ROOT/toolchain/wpe-env.sh"

# Dependency order. icu before harfbuzz (harfbuzz-icu), leopardegl before libepoxy (epoxy dlopens
# LeopardEGL), libogg/libvorbis before gst-plugins-base (vorbisdec), dav1d before ffmpeg.
ALL="zlib libiconv libffi pcre2 proxylibintl glib expat libxml2 sqlite libpng libjpeg libwebp icu
freetype harfbuzz fontconfig libgpgerror libgcrypt libtasn1 gmp nettle gnutls glibnetworking nghttp2
libpsl libsoup khrheaders leopardegl libepoxy xkbcommon libwpe mimedb orc gstreamer libogg libvorbis
gstpluginsbase gstpluginsgood dav1d ffmpeg gstlibav gstpluginsbad"

LOGS="$LEOPARD_BUILD/deps$LEOPARD_SUFFIX"
# build-deps.sh runs bare ninja (nproc + 2 jobs) unless DEPS_JOBS is set; recipes that need less
# (GStreamer, FFmpeg) set their own.
export DEPS_JOBS="${DEPS_JOBS:-$(fb_jobs)}"
mkdir -p "$LOGS"
explicit=0; pkgs="$ALL"
if [ $# -gt 0 ]; then explicit=1; pkgs="$*"; fi

# The recipes, read once: build-deps.sh only defines functions when given no package names.
RECIPES=$( set --; set +eu; . "$FB_ROOT/deps/build-deps.sh" >/dev/null 2>&1
           for f in $(declare -F | awk '{print $3}'); do declare -f "$f"; done )
recipe_of() { printf '%s\n' "$RECIPES" | awk -v f="pkg_$1 ()" '$0 == f {p=1} p {print} p && $0 == "}" {exit}'; }
archives_of() { recipe_of "$1" | grep -oE '[A-Za-z0-9_.+-]+\.(tar\.(gz|xz|bz2)|tgz)' | sort -u; }
stamp_of() { # <pkg>: what the package's build depends on
    local p="$1" a d
    {
        recipe_of "$p"
        printf '%s\n' "$RECIPES" | awk '/^(unpack|autotools|mesonbuild|cmakebuild|fix_install_names|stage_install) \(\)/ {p=1} p {print} p && $0 == "}" {p=0}'
        for a in $(archives_of "$p"); do
            [ -f "$LEOPARD_DL/deps/$a" ] && sha256_file "$LEOPARD_DL/deps/$a"
            d="$FB_ROOT/deps/patches/${a%.tar.*}"; d=${d%.tgz}
            [ -d "$d" ] && find "$d" -type f | LC_ALL=C sort | while read -r f; do sha256_file "$f"; done
        done
        case "$p" in
        leopardegl) find "$FB_ROOT/leopardegl" -type f | LC_ALL=C sort | while read -r f; do sha256_file "$f"; done
                    echo "webgl=$LEOPARD_WEBGL" ;;
        esac
        echo "$LEOPARD_CPU_FLAGS $LEOPARD_TARGET"
        cat "$LEOPARD_TOOLCHAIN/FROSTBYTE-TOOLCHAIN" 2>/dev/null || echo "$LEOPARD_TOOLCHAIN"
    } | cksum | cut -d' ' -f1
}

# pkg_mimedb reads shared-mime-info's database source; find it where Homebrew/MacPorts put it.
if [ -z "${MIME_XML:-}" ]; then
    for m in /usr/share /opt/homebrew/share /usr/local/share /opt/local/share; do
        [ -f "$m/mime/packages/freedesktop.org.xml" ] && { export MIME_XML="$m/mime/packages/freedesktop.org.xml"; break; }
    done
fi
for t in pkg-config rsync patch make; do have "$t" || die "deps need '$t' on the build host"; done
case " $pkgs " in *" mimedb "*) have update-mime-database || die "deps need update-mime-database (shared-mime-info) on the build host" ;; esac

say "deps ($LEOPARD_TARGET) -> $WPE_SYSROOT"
built=0
for p in $pkgs; do
    st=$(stamp_of "$p")
    if [ "$explicit" = 0 ] && [ -f "$LOGS/.done-$p" ] && [ "$(cat "$LOGS/.done-$p")" = "$st" ]; then
        continue
    fi
    if [ "${FB_DRY_RUN:-0}" = 1 ]; then note "would build $p"; continue; fi
    rm -f "$LOGS/.done-$p"
    capped "$FB_ROOT/deps/build-deps.sh" "$p"
    echo "$st" > "$LOGS/.done-$p"
    built=$((built + 1))
done
ok "deps: $built built, the rest up to date"

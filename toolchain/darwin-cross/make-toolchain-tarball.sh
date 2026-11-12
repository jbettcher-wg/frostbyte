#!/usr/bin/env bash
# Make the prebuilt toolchain tarball that ./build.sh downloads by default.
#
#   make-toolchain-tarball.sh [--from=<prefix>] [--out=<dir>]
#       for THIS build host (linux-x86_64, linux-aarch64, macos-x86_64, macos-arm64): builds the
#       cross toolchain with build-toolchain.sh (or packs an already built --from prefix)
#   make-toolchain-tarball.sh --host=darwin9-ppc64 --build-toolchain=<cross prefix> [--out=<dir>]
#       on Linux: a canadian build of the toolchain that runs ON Mac OS X 10.5 PowerPC
#
# The SDK must already be imported (./build.sh sdk). Output: <out>/<file> and <file>.sha256, plus
# the line to paste into config/toolchain.lock. Nothing is uploaded.
#
# What the tarball leaves out, so it holds nothing of Apple's: the <prefix>/sdk link and GCC's
# include-fixed headers (fixincludes copies of SDK headers). scripts/stage-toolchain.sh links the
# user's SDK in and regenerates include-fixed with GCC's own mkheaders. The packer refuses to
# finish if any file in the tarball is byte-identical to a file in the SDK.
#
# Portability: a Linux tarball runs on distributions with a glibc at least as new as the build
# machine's. Build the published ones on an old base (e.g. a Debian 11 or AlmaLinux 8 container)
# so they run nearly everywhere; GCC's own programs link libstdc++ statically already.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/../../scripts/lib.sh"
. "$FB_ROOT/scripts/host.sh"

T=powerpc-apple-darwin9
HOSTTAG= FROM= OUT="$LEOPARD_BUILD/dist" BTC=
for a in "$@"; do
    case "$a" in
    --host=*) HOSTTAG=${a#*=} ;;
    --from=*) FROM=${a#*=} ;;
    --out=*) OUT=${a#*=} ;;
    --build-toolchain=*) BTC=${a#*=} ;;
    -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
    *) die "unknown option $a" ;;
    esac
done
fb_detect_host
HOSTTAG=${HOSTTAG:-$FB_HOST_TAG}
ID=$(awk '$1=="id" {print $2}' "$FB_TOOLCHAIN_LOCK")
FILE=$(awk -v h="$HOSTTAG" '$1==h {print $2}' "$FB_TOOLCHAIN_LOCK")
[ -n "$FILE" ] || die "no host tag $HOSTTAG in config/toolchain.lock"
SDK=$(state_get LEOPARD_SDK); SDK=${LEOPARD_SDK:-$SDK}
[ -d "$SDK" ] || die "import the SDK first: ./build.sh sdk --sdk=..."
WORK="$LEOPARD_BUILD/toolchain-tarball/$HOSTTAG"
mkdir -p "$OUT" "$WORK"

if [ "$HOSTTAG" = darwin9-ppc64 ] && [ "$FB_HOST_MODE" = cross ]; then
    [ -n "$BTC" ] || die "--build-toolchain=<cross toolchain prefix> is required for a darwin9-ppc64 tarball"
    "$HERE/build-toolchain.sh" --mode=canadian --prefix=/usr/local/frostbyte-toolchain \
        --build-toolchain="$BTC" --sdk="$SDK" --work="$WORK/build"
    FROM="$WORK/build/root/usr/local/frostbyte-toolchain"
elif [ -z "$FROM" ]; then
    [ "$HOSTTAG" = "$FB_HOST_TAG" ] || die "a $HOSTTAG tarball must be made on a $HOSTTAG host"
    FROM="$WORK/prefix"
    "$HERE/build-toolchain.sh" --mode="$( [ "$FB_HOST_MODE" = native ] && echo native || echo cross )" \
        --prefix="$FROM" --sdk="$SDK" --work="$WORK/build"
fi
[ -f "$FROM/FROSTBYTE-TOOLCHAIN" ] || die "$FROM was not made by build-toolchain.sh (no FROSTBYTE-TOOLCHAIN)"

top="frostbyte-toolchain-$ID-$HOSTTAG"
stage="$WORK/pack/$top"
say "pack $FROM -> $OUT/$FILE"
rm -rf "$WORK/pack"; mkdir -p "$stage"
( cd "$FROM" && tar cf - . ) | ( cd "$stage" && tar xf - )
rm -f "$stage/sdk"
inc="$stage/lib/gcc/$T/15.3.0/include-fixed"
rm -rf "$inc"; mkdir -p "$inc"
printf 'Generated at install time from your SDK by GCC mkheaders (scripts/stage-toolchain.sh).\n' > "$inc/README.frostbyte"
conf="$stage/lib/gcc/$T/15.3.0/install-tools/mkheaders.conf"
[ -f "$conf" ] && sed -i.bak 's|^SYSTEM_HEADER_DIR=.*|SYSTEM_HEADER_DIR="@SDK@${sysroot_headers_suffix}/usr/include"|' "$conf" && rm -f "$conf.bak"
# Host programs only: strip their symbols (cc1plus is several hundred MB unstripped). Target
# libraries (Mach-O ppc/ppc64) are left alone.
if [ "$(host_os)" = Linux ] && [ "$HOSTTAG" != darwin9-ppc64 ]; then
    find "$stage/bin" "$stage/libexec" -type f -perm -u+x | while read -r f; do
        file -b "$f" | grep -q '^ELF' && strip --strip-unneeded "$f" 2>/dev/null || true
    done
fi

# Nothing of Apple's may ride along.
PY=$(fb_python)
"$PY" -I - "$SDK" "$stage" <<'PY'
import hashlib, os, sys
def files(root):
    for d, _, fs in os.walk(root):
        for f in fs:
            p = os.path.join(d, f)
            if os.path.isfile(p) and not os.path.islink(p):
                yield p
def digest(p):
    h = hashlib.sha256()
    with open(p, "rb") as f:
        for b in iter(lambda: f.read(1 << 20), b""):
            h.update(b)
    return h.hexdigest()
sdk = {}
for p in files(sys.argv[1]):
    if os.path.getsize(p) > 64:
        sdk.setdefault(os.path.getsize(p), []).append(p)
# GCC's own headers (gcc/ginclude in GCC's source) are installed into these two directories, and
# Apple's SDK carries copies of some of them (it ships GCC 4's): identical by origin, not copied.
GCC_OWN = ("lib/gcc/powerpc-apple-darwin9/15.3.0/include/",
           "lib/gcc/powerpc-apple-darwin9/15.3.0/install-tools/include/")
bad = []
for p in files(sys.argv[2]):
    cands = sdk.get(os.path.getsize(p))
    if cands:
        d = digest(p)
        if any(digest(c) == d for c in cands):
            rel = os.path.relpath(p, sys.argv[2])
            if rel.startswith(GCC_OWN):
                print("  GCC's own header, also in the SDK: " + rel, file=sys.stderr)
            else:
                bad.append(rel)
if bad:
    print("files identical to SDK files:", *bad[:20], sep="\n  ", file=sys.stderr)
    sys.exit(1)
PY
ok "no SDK content in the tarball"

case "$FILE" in
*.tar.xz) comp="xz -T0 -9" ;;
*.tar.gz) comp="gzip -9" ;;     # Mac OS X 10.5's tar cannot read xz
*) die "unknown compression for $FILE" ;;
esac
if tar --version 2>/dev/null | grep -q GNU; then
    tar -C "$WORK/pack" --sort=name --owner=0 --group=0 --numeric-owner --mtime=@0 -cf - "$top" | $comp > "$OUT/$FILE"
else
    tar -C "$WORK/pack" -cf - "$top" | $comp > "$OUT/$FILE"
fi
sum=$(sha256_file "$OUT/$FILE")
echo "$sum  $FILE" > "$OUT/$FILE.sha256"
rm -rf "$WORK/pack"
ok "$OUT/$FILE ($(du -h "$OUT/$FILE" | cut -f1))"
echo
echo "config/toolchain.lock line (after uploading the file to the URL listed there):"
awk -v h="$HOSTTAG" -v s="$sum" '$1==h {print $1, $2, s, $4}' "$FB_TOOLCHAIN_LOCK"

#!/bin/sh
# Regenerate patches/leopard-darwin9-wpe-2.54.1-full.patch from the working WebKit tree
# ($LEOPARD_BUILD/src/wpewebkit-2.54.1, unpacked and patched by ./build.sh fetch, then edited),
# against the vanilla release tarball, and check that the patch reproduces the tree.
#   tools/regen-wpe-patch.sh
# Commit the patch afterwards. ./build.sh fetch re-creates the tree from tarball + patch whenever
# the patch changes, so edits that are not in the patch are lost at the next fetch.
set -e
S="$(cd "$(dirname "$0")/.." && pwd)"
. "$S/toolchain/wpe-env.sh" 2>/dev/null
V=wpewebkit-2.54.1
TREE="$LEOPARD_BUILD/src/$V"
T=$(mktemp -d "${TMPDIR:-/tmp}/wpe-patch.XXXXXX")
trap 'rm -rf "$T"' EXIT
tar -C "$T" -xf "$LEOPARD_DL/wpe/$V.tar.xz"
mv "$T/$V" "$T/a"
X="-x __pycache__ -x .frostbyte-stamp"
( cd "$T" && cp -a "$TREE" b && diff -ruN --no-dereference $X a b > "$S/patches/leopard-darwin9-wpe-2.54.1-full.patch" ) || true
files=$(grep -c '^diff -ruN' "$S/patches/leopard-darwin9-wpe-2.54.1-full.patch")
( cd "$T/a" && patch -p1 -s < "$S/patches/leopard-darwin9-wpe-2.54.1-full.patch" )
diff -r -q --no-dereference $X "$T/a" "$TREE" > /dev/null && echo "patch: $files files, reproduces the tree"

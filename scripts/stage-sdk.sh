#!/usr/bin/env bash
# Stage "sdk": import the Mac OS X 10.5 SDK and verify it.
#   scripts/stage-sdk.sh [<path>]
# <path> (or FB_SDK) may be:
#   - a MacOSX10.5.sdk directory (or a /Developer folder or Xcode install containing SDKs/MacOSX10.5.sdk)
#   - the Xcode 3.1.4 disk image (xcode314_2809_developerdvd.dmg)
#   - MacOSX10.5.pkg from that image
# With no path it uses the SDK imported earlier, then /Developer/SDKs/MacOSX10.5.sdk (on a Mac).
# The SDK is copied to $FROSTBYTE_CACHE/sdk/MacOSX10.5.sdk, so the original can go afterwards.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

DEST="$FROSTBYTE_CACHE/sdk/MacOSX10.5.sdk"
PY=$(fb_python)
read -r want_digest want_files < <(awk '$1 == "xcode-3.1.4" {print $2, $3}' "$FB_ROOT/config/sdk.lock")

how_to_get() {
    cat >&2 <<'EOF'

FrostByte needs Apple's Mac OS X 10.5 SDK, which cannot be redistributed. Get it from
Xcode 3.1.4 for Leopard (file xcode314_2809_developerdvd.dmg, about 1 GB), which Apple
offers to free Apple Developer accounts at https://developer.apple.com/download/all/
(search "Xcode 3.1.4"). Then pass the image, or an SDK you already have:

    ./build.sh --sdk=/path/to/xcode314_2809_developerdvd.dmg
    ./build.sh --sdk=/path/to/MacOSX10.5.pkg
    ./build.sh --sdk=/Developer/SDKs/MacOSX10.5.sdk          (on a Mac with Xcode 3.1.4)

On Linux, extracting the image needs 7-Zip (7z) and cpio. On a Mac, hdiutil and pkgutil
(or xar) do it. See docs/building.md.
EOF
}

verify() { # <sdk dir> -> 0 verified, 1 structurally fine but different, 2 broken
    local sdk="$1" d n
    "$PY" -I "$FB_ROOT/tools/sdk-digest.py" --check "$sdk" || return 2
    # An empty usr/include/DONE is GCC fixincludes' marker (older FrostByte toolchain installs left
    # it behind); it is not part of the SDK.
    if [ -f "$sdk/usr/include/DONE" ] && [ ! -s "$sdk/usr/include/DONE" ] && [ -w "$sdk/usr/include" ]; then
        note "removing GCC fixincludes' DONE marker from $sdk/usr/include"; rm -f "$sdk/usr/include/DONE"
    fi
    read -r d n < <("$PY" -I "$FB_ROOT/tools/sdk-digest.py" "$sdk")
    if [ "$d" = "$want_digest" ]; then
        ok "SDK matches Xcode 3.1.4's MacOSX10.5.sdk ($n files, digest ${d:0:16}...)"
        return 0
    fi
    warn "$sdk is a 10.5 SDK, but not the one from Xcode 3.1.4 ($n files, digest $d; expected $want_files files, $want_digest)."
    return 1
}

# Extract MacOSX10.5.pkg's payload into <out>; leaves <out>/SDKs/MacOSX10.5.sdk.
extract_pkg() { # <pkg file or bundle> <out>
    local pkg="$1" out="$2" t="$2.pkg"
    rm -rf "$t"; mkdir -p "$t" "$out"
    if [ -d "$pkg" ]; then                                   # bundle-style package
        if [ -f "$pkg/Contents/Archive.pax.gz" ]; then cp "$pkg/Contents/Archive.pax.gz" "$t/Payload"
        else die "$pkg: no Contents/Archive.pax.gz"; fi
    elif have pkgutil && pkgutil --expand "$pkg" "$t/x" 2>/dev/null; then
        cp "$t/x/Payload" "$t/Payload" 2>/dev/null || cp "$(find "$t/x" -name Payload | head -1)" "$t/Payload"
    elif have xar; then
        ( cd "$t" && xar -xf "$pkg" Payload )
    elif have 7z; then
        7z x -y -txar -o"$t" "$pkg" Payload >/dev/null
    else
        die "need pkgutil, xar or 7z to open $pkg"
    fi
    [ -s "$t/Payload" ] || die "$pkg has no Payload"
    have cpio || die "need cpio to unpack the SDK payload"
    ( cd "$out" && gzip -dc "$t/Payload" | cpio -idm --quiet 2>/dev/null || gzip -dc "$t/Payload" | cpio -idm )
    rm -rf "$t"
}

# Find MacOSX10.5.pkg inside the Xcode 3.1.4 image and extract the SDK from it into <out>.
extract_dmg() { # <dmg> <out>
    local dmg="$1" out="$2" w="$2.dmg" pkg hfs
    rm -rf "$w"; mkdir -p "$w"
    if have hdiutil; then
        mkdir -p "$w/mnt"
        hdiutil attach -quiet -nobrowse -readonly -noverify -noautoopen -mountpoint "$w/mnt" "$dmg"
        pkg=$(find "$w/mnt" -maxdepth 3 -name MacOSX10.5.pkg | head -1)
        [ -n "$pkg" ] || { hdiutil detach -quiet "$w/mnt"; die "no MacOSX10.5.pkg in $dmg (is it the Xcode 3.1.4 image?)"; }
        extract_pkg "$pkg" "$out"
        hdiutil detach -quiet "$w/mnt"
    elif have 7z; then
        note "opening $dmg with 7z (a minute or two)"
        # -tdmg stops 7z descending into the HFS volume; the volume itself is the largest partition.
        7z x -y -tdmg -o"$w/parts" "$dmg" >/dev/null
        hfs=$(ls -S "$w/parts"/* | head -1)
        pkg=$(7z l -slt "$hfs" 2>/dev/null | awk -F' = ' '/^Path = .*Packages\/MacOSX10\.5\.pkg$/ {print $2; exit}')
        [ -n "$pkg" ] || die "no Packages/MacOSX10.5.pkg in $dmg (is it the Xcode 3.1.4 image?)"
        7z x -y -o"$w/hfs" "$hfs" "$pkg" "$pkg/*" >/dev/null
        extract_pkg "$w/hfs/$pkg" "$out"
    else
        die "need 7z (Linux: p7zip or 7zip package) or hdiutil (macOS) to open $dmg"
    fi
    rm -rf "$w"
}

src="${1:-${FB_SDK:-}}"
say "sdk"
if [ -z "$src" ]; then
    if [ -d "$DEST" ]; then src="$DEST"
    elif [ -d /Developer/SDKs/MacOSX10.5.sdk ]; then src=/Developer/SDKs/MacOSX10.5.sdk
    else
        printf '%serror:%s no Mac OS X 10.5 SDK given.\n' "$_r" "$_n" >&2
        how_to_get; exit 1
    fi
fi
[ -e "$src" ] || { printf '%serror:%s %s does not exist.\n' "$_r" "$_n" "$src" >&2; how_to_get; exit 1; }
if [ -d "$src" ]; then src=$(cd "$src" && pwd); else src=$(cd "$(dirname "$src")" && pwd)/$(basename "$src"); fi

tmp="$FROSTBYTE_CACHE/sdk/.import"
case "$src" in
*.dmg)
    note "extracting the SDK from $src"
    rm -rf "$tmp"; extract_dmg "$src" "$tmp"; sdk="$tmp/SDKs/MacOSX10.5.sdk" ;;
*.pkg)
    note "extracting the SDK from $src"
    rm -rf "$tmp"; extract_pkg "$src" "$tmp"; sdk="$tmp/SDKs/MacOSX10.5.sdk" ;;
*)
    sdk="$src"
    for c in "$src/SDKs/MacOSX10.5.sdk" "$src/Developer/SDKs/MacOSX10.5.sdk" "$src/Contents/Developer/SDKs/MacOSX10.5.sdk"; do
        [ -d "$c" ] && { sdk="$c"; break; }
    done ;;
esac
[ -d "$sdk" ] || die "no MacOSX10.5.sdk found at $src"

rc=0; verify "$sdk" || rc=$?
if [ "$rc" = 2 ]; then
    how_to_get; die "$sdk is not a usable Mac OS X 10.5 SDK"
elif [ "$rc" = 1 ] && [ "${FB_SDK_ACCEPT_UNVERIFIED:-0}" != 1 ]; then
    cat >&2 <<EOF
FrostByte is built and tested against Xcode 3.1.4's SDK. Other 10.5 SDKs (Xcode 3.0-3.1.3,
or the 10.5 SDK in Xcode 3.2) will probably work but are untested. To use this one anyway:
    FB_SDK_ACCEPT_UNVERIFIED=1 ./build.sh --sdk=$src
EOF
    exit 1
fi

if [ "$sdk" != "$DEST" ]; then
    note "importing into $DEST"
    rm -rf "$DEST.new"; mkdir -p "$DEST.new"
    ( cd "$sdk" && tar cf - . ) | ( cd "$DEST.new" && tar xf - )
    rm -rf "$DEST"; mv "$DEST.new" "$DEST"
    rm -rf "$tmp"
    [ "$rc" = 0 ] && { verify "$DEST" >/dev/null || die "the imported copy does not verify"; }
fi
state_set LEOPARD_SDK "$DEST"
ok "LEOPARD_SDK=$DEST"

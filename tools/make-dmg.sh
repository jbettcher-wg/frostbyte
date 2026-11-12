#!/bin/sh
# Make the drag-to-install disk image: FrostByte.app and an Applications link.
#
#   tools/make-dmg.sh <FrostByte.app> [<output dir>] [--finder-layout]
#       -> <output dir>/FrostByte-<version>-<target>.dmg
#
# On a Mac (Mac OS X 10.5 or any later macOS) it uses hdiutil. --finder-layout also has Finder
# place the icons, as tools/make-dmg.sh in PumaTerm does; that needs the logged-in GUI session
# (Finder writes the layout into the image's .DS_Store), so it is off by default.
# On Linux it uses mkfs.hfsplus (hfsprogs) and libdmg-hfsplus's hfsplus/dmg tools when present;
# without them it makes a .tar.gz instead and says so (Mac OS X 10.5's Finder opens it).
set -e
APP=; OUT=; LAYOUT=0
for a in "$@"; do
    case "$a" in
    --finder-layout) LAYOUT=1 ;;
    *) if [ -z "$APP" ]; then APP=$a; else OUT=$a; fi ;;
    esac
done
[ -d "$APP/Contents" ] || { echo "usage: tools/make-dmg.sh <FrostByte.app> [<output dir>] [--finder-layout]" >&2; exit 2; }
APP=$(cd "$APP" && pwd)
OUT=${OUT:-$(dirname "$APP")}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd)
plist="$APP/Contents/Info.plist"
VER=$(defaults read "$APP/Contents/Info" CFBundleShortVersionString 2>/dev/null || python3 -I -c 'import plistlib,sys; print(plistlib.load(open(sys.argv[1],"rb")).get("CFBundleShortVersionString","0"))' "$plist" 2>/dev/null || echo 0)
TGT=${LEOPARD_TARGET:-generic}
NAME="FrostByte-$VER-$TGT"
VOL=FrostByte
STAGE="$OUT/.dmg-stage"

rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
ICNS="$APP/Contents/Resources/FrostByte.icns"
[ -f "$ICNS" ] && cp "$ICNS" "$STAGE/.VolumeIcon.icns"
size_mb=$(( $(du -sk "$STAGE" | cut -f1) / 1024 + 40 ))

if command -v hdiutil >/dev/null 2>&1; then
    RW="$OUT/$NAME-rw.dmg"; rm -f "$RW" "$OUT/$NAME.dmg"
    hdiutil create -quiet -srcfolder "$STAGE" -volname "$VOL" -fs HFS+ -format UDRW -size ${size_mb}m "$RW"
    if [ "$LAYOUT" = 1 ]; then
        hdiutil detach "/Volumes/$VOL" -quiet 2>/dev/null || true
        hdiutil attach -quiet -readwrite -noverify -noautoopen "$RW"
        command -v SetFile >/dev/null 2>&1 && SetFile -a C "/Volumes/$VOL"
        osascript <<OSA
tell application "Finder"
	tell disk "$VOL"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 740, 500}
		set opts to the icon view options of container window
		set arrangement of opts to not arranged
		set icon size of opts to 112
		set position of item "FrostByte.app" of container window to {140, 175}
		set position of item "Applications" of container window to {400, 175}
		update without registering applications
		delay 2
		close
	end tell
end tell
OSA
        rm -rf "/Volumes/$VOL/.fseventsd"; sync
        hdiutil detach -quiet "/Volumes/$VOL"
    fi
    hdiutil convert -quiet "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUT/$NAME.dmg"
    rm -f "$RW"
    RESULT="$OUT/$NAME.dmg"
elif command -v mkfs.hfsplus >/dev/null 2>&1 && command -v hfsplus >/dev/null 2>&1 && command -v dmg >/dev/null 2>&1; then
    IMG="$OUT/$NAME.img"; rm -f "$IMG" "$OUT/$NAME.dmg"
    dd if=/dev/zero of="$IMG" bs=1m count=$size_mb 2>/dev/null || dd if=/dev/zero of="$IMG" bs=1M count=$size_mb 2>/dev/null
    mkfs.hfsplus -v "$VOL" "$IMG" >/dev/null
    hfsplus "$IMG" addall "$STAGE" >/dev/null
    hfsplus "$IMG" symlink /Applications /Applications >/dev/null 2>&1 || true
    dmg build "$IMG" "$OUT/$NAME.dmg" >/dev/null
    rm -f "$IMG"
    RESULT="$OUT/$NAME.dmg"
else
    echo "make-dmg: no hdiutil (macOS) and no mkfs.hfsplus + libdmg-hfsplus here; making a .tar.gz instead." >&2
    echo "          Copy it to a Mac and run tools/make-dmg.sh there for a .dmg." >&2
    ( cd "$STAGE" && tar -czf "$OUT/$NAME.tar.gz" FrostByte.app )
    RESULT="$OUT/$NAME.tar.gz"
fi
rm -rf "$STAGE"
ls -la "$RESULT"

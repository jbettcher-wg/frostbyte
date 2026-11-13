#!/bin/sh
# Write the update manifest FrostByte checks for (frostbyte/shell/fb-update.m) for one release.
#   tools/make-update-manifest.sh <version> <release-dir> [notes.md]
# <release-dir> holds the release's disk images, FrostByte-<version>-G5.dmg and FrostByte-<version>-e6500.dmg.
# Writes <release-dir>/frostbyte-update.txt; sign it next with tools/sign-release.sh, then upload both files
# (frostbyte-update.txt and frostbyte-update.txt.sig) as assets of the GitHub release, beside the DMGs.
# The notes (default docs/release-notes-<version>.md) are copied in as notes= lines, up to a "## Downloads"
# heading; the app shows them in its update window.
# Environment:
#   FROSTBYTE_UPDATE_TARGETS   the builds listed (default "g5 e6500"; also "generic")
#   FROSTBYTE_UPDATE_BASE_URL  where the DMGs download from (default the GitHub release v<version>)
#   FROSTBYTE_UPDATE_NOTES_URL the release page (default the GitHub release v<version>; "" for none)
# Copyright (c) 2026 Jordan Bettcher
# SPDX-License-Identifier: MIT
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
V="$1"
D="$2"
N="${3:-$ROOT/docs/release-notes-$V.md}"
if [ -z "$V" ] || [ ! -d "$D" ]; then
    sed -n '2,13p' "$0" >&2
    exit 2
fi
echo "$V" | grep -Eq '^[0-9]+(\.[0-9]+){0,3}$' || { echo "version must look like 0.3.4 (got $V)" >&2; exit 1; }
REPO=https://github.com/jbettcher-wg/frostbyte
BASE="${FROSTBYTE_UPDATE_BASE_URL:-$REPO/releases/download/v$V}"
NOTES_URL="${FROSTBYTE_UPDATE_NOTES_URL-$REPO/releases/tag/v$V}"
sha256() { if command -v sha256sum > /dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
OUT="$D/frostbyte-update.txt"
{
    echo "# FrostByte update manifest. Signed: frostbyte-update.txt.sig (raw Ed25519 over these exact bytes)."
    echo "format=1"
    echo "product=org.frostbyte.FrostByte"
    echo "version=$V"
    [ -n "$NOTES_URL" ] && echo "notes-url=$NOTES_URL"
    for t in ${FROSTBYTE_UPDATE_TARGETS:-g5 e6500}; do
        case "$t" in
        g5) name=G5 ;;
        e6500) name=e6500 ;;
        generic) name=generic ;;
        *) echo "unknown target $t" >&2; exit 1 ;;
        esac
        f="FrostByte-$V-$name.dmg"
        [ -f "$D/$f" ] || { echo "missing $D/$f" >&2; exit 1; }
        echo "$t.file=$f"
        echo "$t.url=$BASE/$f"
        echo "$t.size=$(wc -c < "$D/$f" | tr -d ' ')"
        echo "$t.sha256=$(sha256 "$D/$f")"
    done
    if [ -f "$N" ]; then
        sed -e 's/\r$//' -e '/^## Downloads/,$d' "$N" | while IFS= read -r line; do printf 'notes=%s\n' "$line"; done
    else
        echo "no notes file ($N); the manifest has no notes" >&2
    fi
} > "$OUT.tmp"
mv "$OUT.tmp" "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT" | tr -d ' ') bytes); sign it: tools/sign-release.sh $OUT"

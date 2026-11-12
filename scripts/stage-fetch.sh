#!/usr/bin/env bash
# Stage "fetch": download and verify every source the build needs, then unpack WebKit and apply
# our patch.
#   scripts/stage-fetch.sh [category...]      default: wpe deps host
# Downloads land in $LEOPARD_DL/<category>/ (default ~/.cache/frostbyte/dl) and are reused.
set -euo pipefail
. "$(dirname "$0")/lib.sh"

cats="${*:-wpe deps host}"
say "fetch: $cats"
n=0
while read -r line; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086
    fetch_entry $line
    n=$((n + 1))
done <<EOF
$(lock_entries $cats)
EOF
note "$n archives verified in $LEOPARD_DL"

# Mozilla CCADB intermediates (glib-networking patch 0002 completes incomplete server chains from
# them). There is no dated URL, so this one is checked for content, not pinned.
case " $cats " in *" deps "*)
    csv="$LEOPARD_DL/deps/mozilla-intermediates.csv"
    if [ -n "${FB_INTERMEDIATES_CSV:-}" ]; then
        cp "$FB_INTERMEDIATES_CSV" "$csv"
    elif [ ! -s "$csv" ]; then
        [ "${FB_OFFLINE:-0}" = 1 ] && die "mozilla-intermediates.csv is not cached and FB_OFFLINE=1"
        note "fetch Mozilla CCADB intermediate certificates (live report, not pinned)"
        fb_download "https://ccadb.my.salesforce-sites.com/mozilla/MozillaIntermediateCertsCSVReport" "$csv.part"
        mv "$csv.part" "$csv"
    fi
    c=$(grep -c "BEGIN CERTIFICATE" "$csv" || true)
    [ "$c" -gt 100 ] || die "$csv holds $c certificates; expected more than 100 (delete it to fetch again)"
    ok "mozilla-intermediates.csv ($c certificates, sha256 $(sha256_file "$csv"))"
    ;;
esac

# Unpack WebKit and apply the port. The tree is rebuilt whenever the tarball or a patch changes,
# so a patch update can never be applied on top of an older one.
case " $cats " in *" wpe "*)
    tarball=$(dl_path wpewebkit-2.54.1.tar.xz)
    src="$LEOPARD_BUILD/src/wpewebkit-2.54.1"
    patches=$(ls "$FB_ROOT"/patches/*.patch | LC_ALL=C sort)
    want=$( { sha256_file "$tarball"; for p in $patches; do sha256_file "$p"; done; } | tr '\n' ' ')
    if [ -f "$src/.frostbyte-stamp" ] && [ "$(cat "$src/.frostbyte-stamp")" = "$want" ]; then
        ok "WebKit source tree is current ($src)"
    else
        say "unpack WebKit 2.54.1 and apply patches/"
        [ "${FB_DRY_RUN:-0}" = 1 ] && { note "(dry run: would unpack into $src)"; exit 0; }
        rm -rf "$src" "$src.tmp"; mkdir -p "$src.tmp"
        tar -C "$src.tmp" -xf "$tarball"
        for p in $patches; do
            note "patch ${p##*/}"
            patch -d "$src.tmp/wpewebkit-2.54.1" -p1 -s -N < "$p" || die "${p##*/} does not apply to WebKit 2.54.1"
        done
        mv "$src.tmp/wpewebkit-2.54.1" "$src"; rmdir "$src.tmp"
        printf '%s' "$want" > "$src/.frostbyte-stamp"
        ok "WebKit source tree ready ($src)"
    fi
    ;;
esac

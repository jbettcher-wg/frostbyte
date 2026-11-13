#!/bin/sh
# Sign a FrostByte update manifest: writes <manifest>.sig, the raw 64-byte Ed25519 signature of the manifest's
# exact bytes (what fb-update.m verifies with Nettle's ed25519_sha512_verify).
#   tools/sign-release.sh <release-dir>/frostbyte-update.txt [private-key.pem]
# The key defaults to $FROSTBYTE_RELEASE_KEY, else ~/.config/frostbyte-release/ed25519-private.pem.
# The signature is checked with the public half, and the public half must be the key built into FrostByte
# (kUpdatePublicKey in frostbyte/shell/fb-update.m); FROSTBYTE_ALLOW_OTHER_KEY=1 allows a test key.
# Needs OpenSSL 3 (pkeyutl -rawin).
# Copyright (c) 2026 Jordan Bettcher
# SPDX-License-Identifier: MIT
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
M="$1"
KEY="${2:-${FROSTBYTE_RELEASE_KEY:-$HOME/.config/frostbyte-release/ed25519-private.pem}}"
if [ -z "$M" ] || [ ! -f "$M" ]; then
    sed -n '2,8p' "$0" >&2
    exit 2
fi
[ -r "$KEY" ] || { echo "cannot read the private key $KEY" >&2; exit 1; }
T=$(mktemp -d "${TMPDIR:-/tmp}/fbsign.XXXXXX")
trap 'rm -rf "$T"' EXIT
openssl pkeyutl -sign -rawin -inkey "$KEY" -in "$M" -out "$T/sig"
[ "$(wc -c < "$T/sig" | tr -d ' ')" -eq 64 ] || { echo "not a 64-byte Ed25519 signature" >&2; exit 1; }
openssl pkey -in "$KEY" -pubout -out "$T/pub.pem"
openssl pkeyutl -verify -pubin -inkey "$T/pub.pem" -rawin -in "$M" -sigfile "$T/sig" > /dev/null \
    || { echo "the new signature does not verify" >&2; exit 1; }
PUB=$(openssl pkey -pubin -in "$T/pub.pem" -outform DER | tail -c 32 | od -An -v -tx1 | tr -d ' \n')
APPKEY=$(sed -n 's/.*kUpdatePublicKey\[\] = "\([0-9a-f]*\)".*/\1/p' "$ROOT/frostbyte/shell/fb-update.m")
if [ "$PUB" != "$APPKEY" ]; then
    if [ "$FROSTBYTE_ALLOW_OTHER_KEY" = 1 ]; then
        echo "note: signed with a key that is not the one built into FrostByte ($PUB)" >&2
    else
        echo "this key ($PUB) is not the one built into FrostByte ($APPKEY); refusing" >&2
        exit 1
    fi
fi
cp "$T/sig" "$M.sig"
echo "signed: $M.sig"
